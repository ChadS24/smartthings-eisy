-- Regression specs for the WebSocket threading, leak sensor, controller uuid, and
-- thermostat fixes.

local function load_ws_with_fake_cosock(fake_cosock)
  local saved_cosock = package.loaded.cosock
  package.loaded.cosock = fake_cosock
  package.loaded.ws_subscription = nil
  local ws = require "ws_subscription"
  package.loaded.ws_subscription = nil
  package.loaded.cosock = saved_cosock
  return ws
end

-- A socket that completes the WebSocket upgrade and then plays back `frames`
-- (each a raw frame string, or a function returning one) before closing.
local function fake_upgraded_socket(frames)
  local header_lines = { "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "" }
  local buffer = ""
  local frame_index = 0
  return {
    settimeout = function() end,
    connect = function() return 1 end,
    send = function(_, data) return #data end,
    close = function() end,
    receive = function(_, pattern)
      if pattern == "*l" then
        return table.remove(header_lines, 1)
      end
      if buffer == "" then
        frame_index = frame_index + 1
        local frame = frames[frame_index]
        if type(frame) == "function" then frame = frame() end
        if not frame then return nil, "closed" end
        buffer = frame
      end
      local chunk = buffer:sub(1, pattern)
      buffer = buffer:sub(pattern + 1)
      return chunk
    end
  }
end

local function text_frame(payload)
  return string.char(0x81, #payload) .. payload
end

describe("eISY WebSocket subscription", function()
  it("runs on its own cosock coroutine instead of the controller device thread", function()
    local spawned
    local fake_cosock = {
      spawn = function(fn) spawned = fn end,
      socket = { sleep = function() end, tcp = function() error("not started") end }
    }
    local ws = load_ws_with_fake_cosock(fake_cosock)
    local controller = setmetatable({}, {
      __index = function(_, key) error("controller." .. tostring(key) .. " must not be used") end
    })

    local handle = ws.start(nil, controller, { host = "192.0.2.10", port = 80, protocol = "http" }, function() end)

    assert_truthy(spawned, "expected the loop to be started with cosock.spawn")
    assert_truthy(handle and handle.cancel, "expected a cancellable handle")
  end)

  it("keeps backing off when the eISY accepts the upgrade and immediately drops it", function()
    local delays = {}
    local sleeps = 0
    local handle
    local fake_cosock = {
      socket = {
        tcp = function() return fake_upgraded_socket({}) end,
        sleep = function(delay)
          sleeps = sleeps + 1
          -- The first sleep is the startup delay, not a reconnect backoff.
          if sleeps > 1 then delays[#delays + 1] = delay end
          if #delays >= 4 then handle.cancel() end
        end
      }
    }
    local spawned
    fake_cosock.spawn = function(fn) spawned = fn end
    local ws = load_ws_with_fake_cosock(fake_cosock)

    handle = ws.start(nil, {}, { host = "192.0.2.10", port = 80, protocol = "http" }, function() end)
    spawned()

    assert_equal(#delays, 4)
    assert_truthy(delays[4] > delays[1], "expected the reconnect delay to grow, got " .. table.concat(delays, ", "))
    assert_truthy(delays[4] >= 10, "expected at least a 10s delay by the fourth reconnect")
  end)

  it("stops routing frames once cancelled", function()
    local handle
    local routed = {}
    local frames = {
      text_frame("<Event><control>ST</control><action>255</action><node>11 22 33 1</node></Event>"),
      function()
        handle.cancel()
        return text_frame("<Event><control>ST</control><action>0</action><node>11 22 33 1</node></Event>")
      end
    }
    local sockets = 0
    local fake_cosock = {
      socket = {
        tcp = function()
          sockets = sockets + 1
          return fake_upgraded_socket(frames)
        end,
        sleep = function() end
      }
    }
    local spawned
    fake_cosock.spawn = function(fn) spawned = fn end
    local ws = load_ws_with_fake_cosock(fake_cosock)

    handle = ws.start(nil, {}, { host = "192.0.2.10", port = 80, protocol = "http" }, function(message)
      routed[#routed + 1] = message
    end)
    spawned()

    assert_equal(#routed, 1, "frame read after cancel must not be routed")
    assert_equal(sockets, 1, "loop must not reconnect after cancel")
  end)
end)

describe("Insteon leak sensors", function()
  local classifier = require "node_classifier"
  local state = require "device_state"

  local function leak_group()
    return {
      { address = "AA BB CC 1", name = "Leak-Dry", family = "1", type = "16.8.70.0", nodeDefId = "BinaryAlarm", pnode = "AA BB CC 1", enabled = "true", properties = { ST = { id = "ST", value = 255 } } },
      { address = "AA BB CC 2", name = "Leak-Wet", family = "1", type = "16.8.70.0", nodeDefId = "BinaryAlarm", pnode = "AA BB CC 1", enabled = "true", properties = { ST = { id = "ST", value = 0 } } },
      { address = "AA BB CC 4", name = "Leak-Heartbeat", family = "1", type = "16.8.70.0", nodeDefId = "BinaryAlarm", pnode = "AA BB CC 1", enabled = "true", properties = { ST = { id = "ST", value = 255 } } }
    }
  end

  local function water_events(properties)
    local emitted = {}
    local device = {
      profile = { components = { main = { id = "main", capabilities = { "waterSensor" } } } },
      emit_component_event = function(_, _, event) emitted[#emitted + 1] = event.state.value end
    }
    state.emit_component(device, "main", "water", properties)
    return emitted
  end

  it("identifies the Dry and Wet nodes", function()
    local devices = classifier.classify_all(leak_group())
    assert_equal(#devices, 1)
    assert_equal(devices[1].kind, "water")
    assert_equal(devices[1].components.main, "AA BB CC 1")
    assert_equal(devices[1].leak.dry, "AA BB CC 1")
    assert_equal(devices[1].leak.wet, "AA BB CC 2")
  end)

  it("reports dry when only the Dry node is On", function()
    local leak_state = state.leak_state_from_status({ ST = { id = "ST", value = 255 } }, { ST = { id = "ST", value = 0 } })
    assert_equal(leak_state, "dry")
    assert_deep_equal(water_events(state.leak_properties({ ST = { id = "ST", value = 255 } }, leak_state)), { "dry" })
  end)

  it("reports wet when only the Wet node is On", function()
    assert_equal(state.leak_state_from_status({ ST = { id = "ST", value = 0 } }, { ST = { id = "ST", value = 255 } }), "wet")
  end)

  it("treats both nodes On as unknown and emits nothing", function()
    local leak_state = state.leak_state_from_status({ ST = { id = "ST", value = 255 } }, { ST = { id = "ST", value = 255 } })
    assert_equal(leak_state, nil)
    assert_deep_equal(water_events(state.leak_properties({ ST = { id = "ST", value = 255 } }, leak_state)), {})
  end)

  it("follows command events from the Dry and Wet nodes", function()
    assert_equal(state.leak_state_from_control("wet", "DON"), "wet")
    assert_equal(state.leak_state_from_control("dry", "DON"), "dry")
    assert_equal(state.leak_state_from_control("dry", "DOF"), "wet")
    assert_equal(state.leak_state_from_control("wet", "DOF"), nil)
    assert_deep_equal(water_events(state.leak_properties({ ST = { id = "ST", value = 255 } }, "wet")), { "wet" })
  end)
end)

describe("controller config", function()
  local client = require "eisy_client"

  it("reads the uuid, name, and model from IoX /rest/config", function()
    local parsed = client.parse_config([[
      <configuration>
        <deviceSpecs><make>Universal Devices Inc.</make><model>IoX</model></deviceSpecs>
        <app>Insteon_UD994</app>
        <root><id>00:21:b9:02:5a:11</id><name>Home</name></root>
        <product><id>1120</id><desc>eisy</desc></product>
      </configuration>
    ]])

    assert_equal(parsed.uuid, "00:21:b9:02:5a:11")
    assert_equal(parsed.name, "Home")
    assert_equal(parsed.model, "eisy")
  end)
end)

describe("thermostat temperatures", function()
  local state = require "device_state"

  local function thermostat_events(properties)
    local events = {}
    local device = {
      profile = { components = { main = { id = "main" } } },
      emit_component_event = function(_, _, event)
        events[event.attribute_id] = { value = event.state.value, unit = event.state.unit }
      end,
      get_latest_state = function() return nil end
    }
    state.emit_component(device, "main", "thermostat", properties)
    return events
  end

  it("applies the reported precision", function()
    local events = thermostat_events({ ST = { id = "ST", value = 725, precision = "1", uom = "17" } })
    assert_equal(events.temperature.value, 72.5)
    assert_equal(events.temperature.unit, "F")
  end)

  it("reports Celsius thermostats in Celsius", function()
    local events = thermostat_events({
      ST = { id = "ST", value = 22, uom = "4" },
      CLISPH = { id = "CLISPH", value = 20, uom = "4" }
    })
    assert_equal(events.temperature.value, 22)
    assert_equal(events.temperature.unit, "C")
    assert_equal(events.heatingSetpoint.unit, "C")
  end)

  it("halves half-degree readings", function()
    local events = thermostat_events({ ST = { id = "ST", value = 144, uom = "101", formatted = "72°F" } })
    assert_equal(events.temperature.value, 72)
    assert_equal(events.temperature.unit, "F")
  end)
end)

describe("thermostat setpoint commands", function()
  local state = require "device_state"
  local encode = state.thermostat_setpoint_to_insteon

  it("doubles only for half-degree setpoints", function()
    assert_equal(encode(72, { id = "CLISPH", uom = "101", formatted = "72°F" }), 144)
    assert_equal(encode(72, { id = "CLISPH", uom = "17" }), 72)
  end)

  it("keeps the half-degree encoding when no uom is cached", function()
    assert_equal(encode(72, nil, nil), 144)
  end)

  it("scales by the setpoint precision", function()
    assert_equal(encode(72.5, { id = "CLISPH", uom = "17", precision = "1" }), 725)
  end)

  it("converts a Celsius setpoint for a Fahrenheit thermostat", function()
    assert_equal(encode(22, { id = "CLISPH", uom = "17" }), 72)
  end)

  it("converts a Fahrenheit setpoint for a Celsius thermostat", function()
    assert_equal(encode(72, { id = "CLISPH", uom = "4" }), 22)
  end)

  it("sends a Celsius setpoint to a Celsius thermostat unchanged", function()
    assert_equal(encode(21, { id = "CLISPH", uom = "4" }), 21)
  end)
end)
