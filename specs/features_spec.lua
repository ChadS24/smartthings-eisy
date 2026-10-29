-- Specs for communication-error events, the controller's connection status,
-- 6-button keypads, sensor subnodes and heartbeats, Motion Sensor II readings,
-- scenes by name, fan speed memory, and the WebSocket over TLS.

local classifier = require "node_classifier"
local harness = require "driver_harness"
local last_value = harness.last_value
local last_health = harness.last_health

local UUID = "00:21:b9:00:00:02"

local function key(address) return "eisy:" .. UUID .. ":" .. address:gsub(" ", "_") end

local function node_xml(address, name, node_def, type_, pnode, properties)
  return string.format(
    '<node flag="128" nodeDefId="%s"><address>%s</address><name>%s</name><family>1</family><type>%s</type><enabled>true</enabled><pnode>%s</pnode>%s</node>',
    node_def, address, name, type_, pnode or address, properties or "")
end

local function st(value) return '<property id="ST" value="' .. tostring(value) .. '" uom="100" formatted="x"/>' end

local function nodes(list) return "<nodes>\n" .. table.concat(list, "\n") .. "\n</nodes>" end

local function routes(node_list, status_xml, extra)
  local result = {
    ["/rest/config"] = "<configuration><root><id>" .. UUID .. "</id></root></configuration>",
    ["/rest/nodes?members=false"] = nodes(node_list),
    ["/rest/status"] = status_xml or "<nodes></nodes>"
  }
  for path, body in pairs(extra or {}) do result[path] = body end
  return result
end

local function parse(xml) return require("eisy_client").parse_nodes(xml) end

local function find(env, profile)
  for _, device in ipairs(env.driver.devices) do
    if device.created and device.created.profile == profile then return device end
  end
end

local function has_delay(env, seconds)
  for _, delay in ipairs(env.timer_delays()) do
    if delay == seconds then return true end
  end
  return false
end

describe("communication-error events", function()
  it("take a device offline on NE and back online on CE", function()
    local env = harness.load_driver(routes({
      node_xml("12 34 56 1", "Lamp", "DimmerLampSwitch", "1.32.65.0", nil, st(0))
    })).start()
    local lamp = env.child(key("12 34 56 1"))
    assert_equal(last_health(lamp), "online")

    env.ws_message(harness.control_event("12 34 56 1", "_3", "NE"))
    assert_equal(last_health(lamp), "offline")

    env.ws_message(harness.control_event("12 34 56 1", "_3", "CE"))
    assert_equal(last_health(lamp), "online")
  end)
end)

describe("controller connection status", function()
  it("follows the WebSocket", function()
    local env = harness.load_driver(routes({})).start()
    local cap = "oftentrust07380.eisyconnectionstatus"

    env.ws_status("syncing")
    assert_equal(last_value(env.controller, cap, "connectionStatus"), "syncing")
    env.ws_status("connected")
    assert_equal(last_value(env.controller, cap, "connectionStatus"), "connected")
    env.ws_status("lost_stream_connection")
    assert_equal(last_value(env.controller, cap, "connectionStatus"), "disconnected")
    env.ws_status("reconnecting")
    assert_equal(last_value(env.controller, cap, "connectionStatus"), "reconnecting")
  end)

  it("says when no eISY is configured", function()
    local env = harness.load_driver(routes({}), { eisyHost = "" }).start()
    assert_equal(last_value(env.controller, "oftentrust07380.eisyconnectionstatus", "connectionStatus"), "notConfigured")
  end)
end)

describe("6-button keypads", function()
  local function keypad(prefix, groups, first_def)
    local list = {}
    for _, group in ipairs(groups) do
      local def = group == 1 and first_def or "KeypadButton"
      list[#list + 1] = node_xml(prefix .. " " .. group, "KP " .. group, def, "1.65.69.0", prefix .. " 1", st(0))
    end
    return list
  end

  it("get the 6-button profile and A-D letters for groups 3-6", function()
    local devices = classifier.classify_all(parse(nodes(keypad("EE 00 01", { 1, 3, 4, 5, 6 }, "KeypadDimmer"))), "")
    assert_equal(#devices, 1)
    assert_equal(devices[1].profile, "eisy-keypad-dimmer-6")
    assert_equal(devices[1].component_names.button2, "A - KP 3")
    assert_equal(devices[1].component_names.button5, "D - KP 6")
    assert_equal(devices[1].components.button5, "EE 00 01 6")
  end)

  it("keep 8-button keypads at 8 buttons when button B is ignored", function()
    local devices = classifier.classify_all(parse(nodes(keypad("FF 00 01", { 1, 2, 3, 4, 5, 6, 7, 8 }, "KeypadDimmer"))), "FF 00 01 2")
    assert_equal(devices[1].profile, "eisy-keypad-dimmer-8")
    assert_equal(devices[1].component_names.button2, "C - KP 3")
  end)

  it("load the 6-button profile's components on the hub", function()
    local env = harness.load_driver(routes(keypad("EE 00 01", { 1, 3, 4, 5, 6 }, "KeypadDimmer"))).start()
    local device = env.child(key("EE 00 01 1"))
    assert_truthy(device.profile.components.button5)
    assert_equal(device.profile.components.button6, nil)
  end)
end)

describe("motion sensor subnodes", function()
  local MS1 = {
    node_xml("AA 00 01 1", "Motion", "PIR2842", "16.1.65.0", "AA 00 01 1", st(0)),
    node_xml("AA 00 01 2", "Motion-Dusk", "PIR2842_Dusk", "16.1.65.0", "AA 00 01 1"),
    node_xml("AA 00 01 3", "Motion-LowBat", "PIR2842_LowBat", "16.1.65.0", "AA 00 01 1")
  }

  it("give a Motion Sensor dusk/dawn and battery level", function()
    local devices = classifier.classify_all(parse(nodes(MS1)), "")
    assert_equal(#devices, 1)
    assert_equal(devices[1].profile, "eisy-motion-insteon")
    assert_equal(devices[1].components.main, "AA 00 01 1")
    assert_equal(devices[1].aux.dusk_dawn, "AA 00 01 2")
    assert_equal(devices[1].aux.low_battery, "AA 00 01 3")
  end)

  it("report dusk/dawn and low battery from the subnodes", function()
    local env = harness.load_driver(routes(MS1, [[<nodes><node id="AA 00 01 1">]] .. st(0) .. [[</node></nodes>]])).start()
    local motion = env.child(key("AA 00 01 1"))
    assert_equal(last_value(motion, "batteryLevel", "battery"), "normal", "an unreported low-battery node reads as normal")
    assert_equal(last_value(motion, "oftentrust07380.duskdawn", "duskDawn"), nil, "dusk/dawn stays unknown until reported")

    env.ws_message(harness.status_event("AA 00 01 2", 255))
    assert_equal(last_value(motion, "oftentrust07380.duskdawn", "duskDawn"), "dusk")
    env.ws_message(harness.status_event("AA 00 01 3", 255))
    assert_equal(last_value(motion, "batteryLevel", "battery"), "warning")
    assert_equal(last_value(motion, "motionSensor", "motion"), "inactive", "a subnode must not change the motion state")

    env.ws_message(harness.status_event("AA 00 01 2", 0))
    assert_equal(last_value(motion, "oftentrust07380.duskdawn", "duskDawn"), "dawn")
  end)

  it("give a Motion Sensor II tamper, temperature and light level", function()
    local MS2 = {
      node_xml("BB 00 01 1", "Motion II", "PIR2844", "16.22.0.0", "BB 00 01 1", st(0)),
      node_xml("BB 00 01 2", "Dusk", "PIR2844OnOff", "16.22.0.0", "BB 00 01 1"),
      node_xml("BB 00 01 3", "Low Bat", "PIR2844OnOff", "16.22.0.0", "BB 00 01 1"),
      node_xml("BB 00 01 A", "Tamper", "PIR2844OnOff", "16.22.0.0", "BB 00 01 1"),
      node_xml("BB 00 01 D", "Motion Disabled", "PIR2844OnOff", "16.22.0.0", "BB 00 01 1")
    }
    local status = [[<nodes><node id="BB 00 01 1">]] .. st(255)
        .. [[<property id="CLITEMP" value="215" prec="1" uom="4" formatted="21.5°C"/>]]
        .. [[<property id="LUMIN" value="40" uom="36" formatted="40 lx"/>]]
        .. [[<property id="BATLVL" value="80" uom="51" formatted="80%"/>]]
        .. [[</node><node id="BB 00 01 A">]] .. st(255) .. [[</node></nodes>]]
    local env = harness.load_driver(routes(MS2, status)).start()
    local motion = env.child(key("BB 00 01 1"))

    assert_equal(motion.created.profile, "eisy-motion-ii")
    assert_equal(last_value(motion, "motionSensor", "motion"), "active")
    assert_equal(last_value(motion, "temperatureMeasurement", "temperature"), 21.5)
    assert_equal(last_value(motion, "illuminanceMeasurement", "illuminance"), 40)
    assert_equal(last_value(motion, "battery", "battery"), 80)
    assert_equal(last_value(motion, "tamperAlert", "tamper"), "detected")

    env.ws_message(harness.status_event("BB 00 01 A", 0))
    assert_equal(last_value(motion, "tamperAlert", "tamper"), "clear")
  end)

  it("leave light level out when it is not in lux", function()
    local env = harness.load_driver(routes({
      node_xml("BB 00 02 1", "Motion II", "PIR2844", "16.22.0.0", "BB 00 02 1", st(0))
    }, [[<nodes><node id="BB 00 02 1">]] .. st(0) .. [[<property id="LUMIN" value="40" uom="51" formatted="40%"/></node></nodes>]])).start()
    assert_equal(last_value(env.child(key("BB 00 02 1")), "illuminanceMeasurement", "illuminance"), nil)
  end)

  it("only use hex-numbered subnodes for sensors", function()
    local devices = classifier.classify_all(parse(nodes({
      node_xml("DD 00 01 1", "Outlet", "RelayLampSwitch", "2.42.65.0", "DD 00 01 1", st(0)),
      node_xml("DD 00 01 A", "Odd", "RelayLampSwitch", "2.42.65.0", "DD 00 01 1", st(0))
    })), "")
    assert_equal(#devices, 1)
    assert_equal(devices[1].components.main, "DD 00 01 1")
  end)
end)

describe("sensor heartbeats", function()
  local DOOR = {
    node_xml("CC 00 01 1", "Door", "BinaryAlarm", "16.2.64.0", "CC 00 01 1", st(0)),
    node_xml("CC 00 01 4", "Door-Heartbeat", "BinaryAlarm", "16.2.64.0", "CC 00 01 1", st(0))
  }

  it("keep the sensor's state when the heartbeat node changes", function()
    local env = harness.load_driver(routes(DOOR, [[<nodes><node id="CC 00 01 1">]] .. st(0) .. [[</node></nodes>]])).start()
    local door = env.child(key("CC 00 01 1"))
    assert_equal(last_value(door, "contactSensor", "contact"), "closed")

    env.ws_message(harness.status_event("CC 00 01 4", 255))
    env.ws_message(harness.control_event("CC 00 01 4", "DON"))
    assert_equal(last_value(door, "contactSensor", "contact"), "closed")
  end)

  it("take a sensor offline after 25 hours without a heartbeat, and back on the next one", function()
    local env = harness.load_driver(routes(DOOR)).start()
    local door = env.child(key("CC 00 01 1"))
    assert_truthy(has_delay(env, 3600), "the hourly health check must be scheduled")

    local store = env.controller:get_field("isy_store")
    store.heartbeats["CC 00 01 1"] = os.time() - 26 * 3600
    env.run_timers(3600)
    assert_equal(last_health(door), "offline")
    assert_truthy(has_delay(env, 3600), "the health check must re-arm")

    env.ws_message(harness.control_event("CC 00 01 4", "DOF"))
    assert_equal(last_health(door), "online")
  end)

  it("don't count a replayed status as a heartbeat", function()
    local env = harness.load_driver(routes(DOOR)).start()
    local door = env.child(key("CC 00 01 1"))
    local store = env.controller:get_field("isy_store")
    store.heartbeats["CC 00 01 1"] = os.time() - 26 * 3600

    -- The eISY replays the node's last status when the WebSocket reconnects.
    env.ws_message(harness.status_event("CC 00 01 4", 255))
    env.run_timers(3600)
    assert_equal(last_health(door), "offline")
  end)

  it("schedule no health check without heartbeat sensors", function()
    local env = harness.load_driver(routes({
      node_xml("12 34 56 1", "Lamp", "DimmerLampSwitch", "1.32.65.0", nil, st(0))
    })).start()
    assert_equal(has_delay(env, 3600), false)
  end)
end)

describe("scenes by name", function()
  local scene = require "isy_scene"
  local AVAILABLE = {
    { address = "50829", name = "Front Downlights" },
    { address = "60001", name = "Patio" },
    { address = "60002", name = "Patio" }
  }

  it("resolve names in any case, and IDs", function()
    local ids, problems = scene.resolve({ "front downlights", "60001" }, AVAILABLE)
    assert_deep_equal(ids, { "50829", "60001" })
    assert_deep_equal(problems, {})
  end)

  it("report names that match several scenes or none", function()
    local ids, problems = scene.resolve({ "Patio", "Garage", "70000" }, AVAILABLE)
    assert_deep_equal(ids, { "70000" }, "an unlisted numeric ID is still tried")
    assert_equal(problems[1].entry, "Patio")
    assert_equal(problems[1].reason, "ambiguous")
    assert_deep_equal(problems[1].ids, { "60001", "60002" })
    assert_equal(problems[2].entry, "Garage")
    assert_equal(problems[2].reason, "unknown")
  end)

  it("list the eISY's scenes from /rest/nodes", function()
    local list = scene.parse_list([[<nodes><group flag="132"><address>50829</address><name>Front Downlights</name></group>
      <group flag="132"><address>60001</address><name>Patio</name></group></nodes>]])
    assert_deep_equal(list, { { address = "50829", name = "Front Downlights" }, { address = "60001", name = "Patio" } })
    assert_equal(scene.describe(list), "Front Downlights (50829), Patio (60001)")
  end)

  it("create a scene listed by name in Scene IDs", function()
    local node_list = {
      node_xml("12 34 56 1", "Lamp", "DimmerLampSwitch", "1.32.65.0", nil, st(0)),
      '<group flag="132"><address>50829</address><name>Front Downlights</name></group>'
    }
    local env = harness.load_driver(routes(node_list, nil, {
      ["/rest/nodes/50829?members=true"] = [[<nodeInfo><group flag="132"><address>50829</address><name>Front Downlights</name>
        <members><link type="16">12 34 56 1</link></members></group></nodeInfo>]]
    }), { sceneIds = "front downlights" }).start()

    local scene_device = find(env, "eisy-scene")
    assert_truthy(scene_device, "the scene should be created from its name")
    assert_equal(scene_device.created.label, "Front Downlights")
  end)
end)

describe("fan speed memory", function()
  local FANLINC = {
    node_xml("11 00 01 1", "Fan Light", "DimmerLampOnly", "1.46.68.0", "11 00 01 1", st(0)),
    node_xml("11 00 01 2", "Fan", "FanLincMotor", "1.46.68.0", "11 00 01 1", st(0))
  }

  it("reads medium back as medium without IoX's text", function()
    local env = harness.load_driver(routes(FANLINC)).start()
    local fan = find(env, "eisy-fan")
    env.ws_message('<Event><control>ST</control><action uom="100" prec="0">191</action><node>11 00 01 2</node></Event>')
    assert_equal(last_value(fan, "fanSpeed", "fanSpeed"), 2)
  end)

  it("turns the fan back on at its last speed", function()
    local env = harness.load_driver(routes(FANLINC, nil, {
      ["/rest/nodes/11%2000%2001%202/cmd/DON/191"] = '<RestResponse succeeded="true"/>',
      ["/rest/nodes/11%2000%2001%202/cmd/DON/255"] = '<RestResponse succeeded="true"/>'
    })).start()
    local fan = find(env, "eisy-fan")
    env.ws_message('<Event><control>ST</control><action uom="100" prec="0">191</action><node>11 00 01 2</node></Event>')
    env.ws_message('<Event><control>ST</control><action uom="100" prec="0">0</action><node>11 00 01 2</node></Event>')
    assert_equal(fan.persisted.last_fan_speed, true, "the last speed must survive a restart")

    local before = #env.requests
    env.template.capability_handlers.switch.on(env.driver, fan, { component = "main" })
    assert_equal(env.requests[before + 1], "/rest/nodes/11%2000%2001%202/cmd/DON/191")
  end)

  it("turns a fan that hasn't run yet on at high", function()
    local env = harness.load_driver(routes(FANLINC, nil, {
      ["/rest/nodes/11%2000%2001%202/cmd/DON/255"] = '<RestResponse succeeded="true"/>'
    })).start()
    local fan = find(env, "eisy-fan")
    local before = #env.requests
    env.template.capability_handlers.switch.on(env.driver, fan, { component = "main" })
    assert_equal(env.requests[before + 1], "/rest/nodes/11%2000%2001%202/cmd/DON/255")
  end)
end)

describe("WebSocket over TLS", function()
  local function load_ws(fake_cosock)
    -- ws_subscription uses eisy_client, which must load against the runner's cosock.
    require "eisy_client"
    local saved = package.loaded.cosock
    package.loaded.cosock = fake_cosock
    package.loaded.ws_subscription = nil
    local ws = require "ws_subscription"
    package.loaded.ws_subscription = nil
    package.loaded.cosock = saved
    return ws
  end

  local function tls_world(handshake_ok)
    local world = { sent = {}, wrapped_with = nil, connected_port = nil, statuses = {} }
    local lines = { "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "" }
    local tls = {
      settimeout = function() end,
      dohandshake = function() if handshake_ok then return true end return nil, "handshake failed" end,
      send = function(_, data) world.sent[#world.sent + 1] = data; return #data end,
      receive = function(_, pattern)
        if pattern == "*l" then return table.remove(lines, 1) end
        world.handle.cancel()
        return nil, "closed"
      end,
      close = function() end
    }
    local plain = {
      settimeout = function() end,
      connect = function(_, _, port) world.connected_port = port; return 1 end,
      send = function() error("the upgrade must go over TLS") end,
      receive = function() error("reads must go over TLS") end,
      close = function() end
    }
    world.cosock = {
      spawn = function(fn) world.loop = fn end,
      socket = {
        tcp = function() return plain end,
        sleep = function() if not handshake_ok and #world.statuses > 0 then world.handle.cancel() end end
      },
      ssl = { wrap = function(sock, params) world.wrapped_with = params; assert(sock == plain); return tls end }
    }
    return world
  end

  it("subscribes over TLS on port 443 by default for HTTPS", function()
    local world = tls_world(true)
    local ws = load_ws(world.cosock)
    world.handle = ws.start(nil, {}, { host = "192.0.2.10", protocol = "https", on_status = function(s) world.statuses[#world.statuses + 1] = s end }, function() end)
    assert_truthy(world.loop, "HTTPS must start the subscription")
    world.loop()

    assert_equal(world.connected_port, 443)
    assert_equal(world.wrapped_with.mode, "client")
    assert_equal(world.wrapped_with.verify, "none")
    assert_truthy(world.sent[1]:find("GET /rest/subscribe HTTP/1.1", 1, true))
    assert_truthy(world.sent[1]:find("Host: 192.0.2.10:443", 1, true))
    assert_equal(world.statuses[1], "syncing")
  end)

  it("reports a failed TLS handshake as disconnected and retries", function()
    local world = tls_world(false)
    local ws = load_ws(world.cosock)
    world.handle = ws.start(nil, {}, { host = "192.0.2.10", protocol = "https", port = 8443, on_status = function(s) world.statuses[#world.statuses + 1] = s end }, function() end)
    world.loop()

    assert_equal(world.connected_port, 8443)
    assert_equal(world.statuses[1], "disconnected")
    assert_equal(world.statuses[2], "reconnecting")
    assert_equal(#world.sent, 0)
  end)
end)
