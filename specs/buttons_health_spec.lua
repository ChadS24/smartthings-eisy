-- Specs for keypad and remote button events, keypad dimmer levels, device health
-- (communication errors, eISY reachability, removed nodes), and thermostat humidity.

local classifier = require "node_classifier"
local harness = require "driver_harness"
local last_value = harness.last_value
local last_health = harness.last_health

local function node_xml(address, name, node_def, type_, properties)
  return string.format(
    '<node flag="128" nodeDefId="%s"><address>%s</address><name>%s</name><family>1</family><type>%s</type><enabled>true</enabled><pnode>%s</pnode>%s</node>',
    node_def, address, name, type_, address:gsub("%s+%d+$", " 1"), properties or "")
end

local NODES = {
  node_xml("AA BB CC 1", "Den Keypad", "KeypadDimmer", "1.66.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>'),
  node_xml("AA BB CC 3", "C - Porch", "KeypadButton", "1.66.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>'),
  node_xml("AA BB CC 4", "D - Patio", "KeypadButton", "1.66.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>'),
  node_xml("11 22 33 1", "Hall Keypad", "KeypadRelay", "2.44.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>'),
  node_xml("11 22 33 2", "B - Hall", "KeypadButton", "2.44.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>'),
  node_xml("DD EE FF 1", "Remote - A", "RemoteLinc2", "0.17.0.0"),
  node_xml("DD EE FF 2", "Remote - B", "RemoteLinc2", "0.17.0.0"),
  node_xml("DD EE FF 3", "Remote - C", "RemoteLinc2", "0.17.0.0"),
  node_xml("DD EE FF 4", "Remote - D", "RemoteLinc2", "0.17.0.0"),
  node_xml("77 88 99 1", "Upstairs", "Thermostat", "5.11.0.0"),
  node_xml("77 88 9A 1", "Downstairs", "Thermostat", "5.11.0.0"),
  node_xml("12 34 56 1", "Lamp", "DimmerLampSwitch", "1.32.65.0", '<property id="ST" value="0" uom="100" formatted="Off"/>')
}

local function nodes_xml(skip)
  local parts = { "<nodes>" }
  for _, node in ipairs(NODES) do
    if not (skip and node:find(skip, 1, true)) then parts[#parts + 1] = node end
  end
  parts[#parts + 1] = "</nodes>"
  return table.concat(parts, "\n")
end

local function status_xml(lamp_err)
  return [[<nodes>
  <node id="AA BB CC 1"><property id="ST" value="128" uom="100" formatted="50%"/></node>
  <node id="AA BB CC 3"><property id="ST" value="0" uom="100" formatted="Off"/></node>
  <node id="AA BB CC 4"><property id="ST" value="0" uom="100" formatted="Off"/></node>
  <node id="77 88 99 1"><property id="ST" value="144" uom="101" formatted="72"/><property id="CLIHUM" value="45" uom="22" formatted="45%"/></node>
  <node id="77 88 9A 1"><property id="ST" value="140" uom="101" formatted="70"/></node>
  <node id="12 34 56 1"><property id="ST" value="0" uom="100" formatted="Off"/><property id="ERR" value="]] .. tostring(lamp_err or 0) .. [[" uom="0" formatted="0"/></node>
</nodes>]]
end

local function routes(opts)
  opts = opts or {}
  return {
    ["/rest/config"] = "<configuration><root><id>00:21:b9:02:aa:bb</id></root></configuration>",
    ["/rest/nodes?members=false"] = nodes_xml(opts.skip),
    ["/rest/status"] = status_xml(opts.lamp_err)
  }
end

local function key(address) return "eisy:00:21:b9:02:aa:bb:" .. address:gsub(" ", "_") end
local DEN_KEYPAD = key("AA BB CC 1")
local HALL_KEYPAD = key("11 22 33 1")
local REMOTE = key("DD EE FF 1")
local UPSTAIRS = key("77 88 99 1")
local DOWNSTAIRS = key("77 88 9A 1")
local LAMP = key("12 34 56 1")

local function button_events(device)
  local events = {}
  for _, event in ipairs(device.events) do
    if event.capability_id == "button" and event.attribute_id == "button" then
      events[#events + 1] = { component = event.component, value = event.state.value, state_change = event.state_change }
    end
  end
  return events
end

local function requested(env, fragment)
  for _, path in ipairs(env.requests) do
    if path:find(fragment, 1, true) then return true end
  end
  return false
end

describe("eISY remotes and keypads", function()
  local function parse(xml)
    return require("eisy_client").parse_nodes(xml)
  end

  it("classifies a mini remote as a remote with a button per node instead of a switch", function()
    local devices = classifier.classify_all(parse(nodes_xml()), "")
    local remote
    for _, device in ipairs(devices) do
      if device.key == "DD EE FF 1" then remote = device end
    end
    assert_equal(remote.kind, "remote")
    assert_equal(remote.profile, "eisy-remote-4")
    assert_deep_equal(remote.components, {
      main = "DD EE FF 1", button2 = "DD EE FF 2", button3 = "DD EE FF 3", button4 = "DD EE FF 4"
    })
  end)

  it("gives a KeypadLinc dimmer a dimmable profile and a relay keypad the plain one", function()
    local profiles = {}
    for _, device in ipairs(classifier.classify_all(parse(nodes_xml()), "")) do profiles[device.key] = device.profile end
    assert_equal(profiles["AA BB CC 1"], "eisy-keypad-dimmer-8")
    assert_equal(profiles["11 22 33 1"], "eisy-keypad-8")
  end)

  it("emits presses, fast presses, and holds as button events on the pressed component", function()
    local env = harness.load_driver(routes()).start()
    local keypad = env.child(DEN_KEYPAD)
    local remote = env.child(REMOTE)

    env.ws_message(harness.control_event("AA BB CC 3", "DON"))
    env.ws_message(harness.control_event("AA BB CC 3", "DON"))
    env.ws_message(harness.control_event("DD EE FF 2", "DFOF"))
    env.ws_message(harness.control_event("DD EE FF 1", "FDUP"))
    env.ws_message(harness.control_event("DD EE FF 1", "FDSTOP"))

    assert_deep_equal(button_events(keypad), {
      { component = "button2", value = "up", state_change = true },
      { component = "button2", value = "up", state_change = true }
    })
    assert_deep_equal(button_events(remote), {
      { component = "button2", value = "down_2x", state_change = true },
      { component = "main", value = "up_hold", state_change = true }
    })
  end)

  it("declares the supported button values on every remote component", function()
    local env = harness.load_driver(routes()).start()
    local remote = env.child(REMOTE)
    for _, component in ipairs({ "main", "button2", "button3", "button4" }) do
      assert_equal(last_value(remote, "button", "numberOfButtons", component), 1)
      assert_deep_equal(last_value(remote, "button", "supportedButtonValues", component),
        { "up", "down", "up_2x", "down_2x", "up_hold", "down_hold", "held" })
    end
  end)

  it("does not query the status of a remote after a press", function()
    local env = harness.load_driver(routes()).start()
    env.ws_message(harness.control_event("DD EE FF 2", "DON"))
    env.run_timers()
    assert_equal(requested(env, "/rest/status/DD%20EE%20FF"), false)
  end)

  it("reports and sets the level of a KeypadLinc dimmer's load", function()
    local r = routes()
    r["/rest/nodes/AA%20BB%20CC%201/cmd/DON/191"] = "<RestResponse succeeded=\"true\"/>"
    local env = harness.load_driver(r).start()
    local keypad = env.child(DEN_KEYPAD)
    assert_equal(last_value(keypad, "switchLevel", "level", "main"), 50)
    assert_equal(last_value(keypad, "switch", "switch", "main"), "on")

    env.template.capability_handlers.switchLevel.setLevel(env.driver, keypad, { component = "main", args = { level = 75 } })
    assert_truthy(requested(env, "/rest/nodes/AA%20BB%20CC%201/cmd/DON/191"), "expected a DON with the level")
  end)

  it("keeps a relay keypad's main component free of level events", function()
    local env = harness.load_driver(routes()).start()
    assert_equal(last_value(env.child(HALL_KEYPAD), "switchLevel", "level", "main"), nil)
  end)
end)

describe("eISY thermostat humidity", function()
  it("uses the humidity profile only for thermostats that report humidity", function()
    local env = harness.load_driver(routes()).start()
    assert_equal(env.child(UPSTAIRS).created.profile, "eisy-thermostat-humidity")
    assert_equal(env.child(DOWNSTAIRS).created.profile, "eisy-thermostat")
    assert_equal(last_value(env.child(UPSTAIRS), "relativeHumidityMeasurement", "humidity"), 45)
  end)

  it("updates humidity from WebSocket events", function()
    local env = harness.load_driver(routes()).start()
    env.ws_message(harness.status_event("77 88 99 1", 51, "CLIHUM"))
    assert_equal(last_value(env.child(UPSTAIRS), "relativeHumidityMeasurement", "humidity"), 51)
  end)

  it("keeps the humidity profile when a later scan cannot read statuses", function()
    local r = routes()
    local env = harness.load_driver(r).start()
    r["/rest/status"] = nil
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    assert_equal(env.child(UPSTAIRS).metadata.profile, "eisy-thermostat-humidity")
  end)
end)

describe("eISY device health", function()
  it("marks a device offline while the eISY reports a communication error for it", function()
    local env = harness.load_driver(routes()).start()
    local lamp = env.child(LAMP)
    assert_equal(last_health(lamp), "online")

    env.ws_message(harness.control_event("12 34 56 1", "ERR", 1))
    assert_equal(last_health(lamp), "offline")
    env.ws_message(harness.control_event("12 34 56 1", "ERR", 0))
    assert_equal(last_health(lamp), "online")
  end)

  it("starts a device offline when the scan reports a communication error", function()
    local env = harness.load_driver(routes({ lamp_err = 1 })).start()
    assert_equal(last_health(env.child(LAMP)), "offline")
  end)

  it("marks the controller and its devices offline only after the eISY stays unreachable", function()
    local r = routes()
    local env = harness.load_driver(r).start()
    local lamp = env.child(LAMP)

    r["/rest/config"] = nil
    env.ws_status("disconnected")
    env.run_timers(1)
    assert_equal(last_health(env.controller), "online", "a short outage should not flap devices")

    env.run_timers(60)
    assert_equal(last_health(env.controller), "offline")
    assert_equal(last_health(lamp), "offline")

    env.ws_status("connected")
    assert_equal(last_health(env.controller), "online")
    assert_equal(last_health(lamp), "online")
  end)

  it("keeps devices online while the WebSocket is down but REST still answers", function()
    local env = harness.load_driver(routes()).start()
    env.ws_status("disconnected")
    env.run_timers(60)
    assert_equal(last_health(env.controller), "online")
    assert_equal(last_health(env.child(LAMP)), "online")
    assert_equal(env.pending_timers(), 1, "expected the check to be re-armed while the WebSocket stays down")

    env.routes["/rest/config"] = nil
    env.run_timers(60)
    assert_equal(last_health(env.controller), "offline")
    assert_equal(last_health(env.child(LAMP)), "offline")
  end)

  it("does not re-arm the check once the WebSocket is back", function()
    local env = harness.load_driver(routes()).start()
    env.ws_status("disconnected")
    env.ws_status("syncing")
    env.run_timers(60)
    assert_equal(env.pending_timers(), 0)
  end)

  it("does not mark devices offline when the WebSocket reconnects within the grace period", function()
    local env = harness.load_driver(routes()).start()
    env.ws_status("lost_stream_connection")
    env.ws_status("reconnecting")
    env.ws_status("syncing")
    env.run_timers(60)
    assert_equal(last_health(env.controller), "online")
    for _, entry in ipairs(env.child(LAMP).health) do assert_equal(entry, "online") end
  end)

  it("keeps a device with a communication error offline when the eISY comes back", function()
    local r = routes()
    local env = harness.load_driver(r).start()
    env.ws_message(harness.control_event("12 34 56 1", "ERR", 1))
    r["/rest/config"] = nil
    env.ws_status("disconnected")
    env.run_timers(60)
    env.ws_status("connected")
    assert_equal(last_health(env.child(LAMP)), "offline")
  end)

  it("marks a device offline when its node is removed from the eISY, and back online if it returns", function()
    local r = routes()
    local env = harness.load_driver(r).start()
    local lamp = env.child(LAMP)

    r["/rest/nodes?members=false"] = nodes_xml("12 34 56 1")
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    assert_equal(last_health(lamp), "offline")

    r["/rest/nodes?members=false"] = nodes_xml()
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    assert_equal(last_health(lamp), "online")
  end)

  it("treats a failed node scan as the eISY being unreachable", function()
    local r = routes()
    local env = harness.load_driver(r).start()
    r["/rest/nodes?members=false"] = nil
    r["/rest/config"] = nil
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    assert_equal(last_health(env.child(LAMP)), "online", "existing devices keep working during the grace period")
    env.run_timers(60)
    assert_equal(last_health(env.controller), "offline")
    assert_equal(last_health(env.child(LAMP)), "offline")
  end)
end)
