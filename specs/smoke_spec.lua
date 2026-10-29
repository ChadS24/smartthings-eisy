-- Specs for the Insteon Smoke Bridge: classified as a smoke and CO detector, not
-- a motion sensor, and alarms that an all clear has reset stay cleared when the
-- eISY replays a stale On status.

local classifier = require "node_classifier"
local harness = require "driver_harness"
local last_value = harness.last_value

local UUID = "00:21:b9:00:00:03"
local MAIN = "26 7D 5D 1"
local KEY = "eisy:" .. UUID .. ":26_7D_5D_1"

local NAMES = { "Smoke", "CO", "Test", "Unknown Message", "Clear", "Low Bat", "Malfunction" }

local function bridge_nodes()
  local list = {}
  for group, name in ipairs(NAMES) do
    list[#list + 1] = string.format(
      '<node flag="128" nodeDefId="BinaryAlarm"><address>26 7D 5D %d</address><name>26.7D.5D-%s</name><family>1</family><type>16.10.65.0</type><enabled>true</enabled><pnode>%s</pnode></node>',
      group, name, MAIN)
  end
  return "<nodes>\n" .. table.concat(list, "\n") .. "\n</nodes>"
end

local function st(address, value)
  return '<node id="' .. address .. '"><property id="ST" value="' .. tostring(value) .. '" uom="100" formatted="x"/></node>'
end

-- Routes whose /rest/status the spec can change between scans.
local function bridge(status_nodes)
  local world = { status = status_nodes or { st("26 7D 5D 6", 0) } }
  world.routes = {
    ["/rest/config"] = "<configuration><root><id>" .. UUID .. "</id></root></configuration>",
    ["/rest/nodes?members=false"] = bridge_nodes(),
    ["/rest/status"] = function() return "<nodes>" .. table.concat(world.status) .. "</nodes>" end
  }
  return world
end

local function smoke(device) return last_value(device, "smokeDetector", "smoke") end
local function co(device) return last_value(device, "carbonMonoxideDetector", "carbonMonoxide") end

describe("Smoke Bridge classification", function()
  it("makes one smoke and CO detector from the bridge's nodes", function()
    local devices = classifier.classify_all(require("eisy_client").parse_nodes(bridge_nodes()), "")
    assert_equal(#devices, 1)
    local device = devices[1]
    assert_equal(device.kind, "smoke")
    assert_equal(device.profile, "eisy-smoke", "type 16.10 is the Smoke Bridge, not a motion sensor")
    assert_equal(device.label, "26.7D.5D-Smoke")
    assert_equal(device.components.main, "26 7D 5D 1")
    assert_equal(device.smoke.co, "26 7D 5D 2")
    assert_equal(device.smoke.clear, "26 7D 5D 5")
    assert_equal(device.smoke.low_battery, "26 7D 5D 6")
    assert_equal(device.heartbeat, nil, "its group 4 is an unknown-message node, not a heartbeat")
  end)
end)

describe("Smoke Bridge alarms", function()
  it("read clear and battery normal before any alarm", function()
    local env = harness.load_driver(bridge().routes).start()
    local detector = env.child(KEY)
    assert_equal(detector.created.profile, "eisy-smoke")
    assert_equal(smoke(detector), "clear")
    assert_equal(co(detector), "clear")
    assert_equal(last_value(detector, "batteryLevel", "battery"), "normal")
  end)

  it("follow smoke and CO commands", function()
    local env = harness.load_driver(bridge().routes).start()
    local detector = env.child(KEY)

    env.ws_message(harness.control_event("26 7D 5D 1", "DON"))
    assert_equal(smoke(detector), "detected")
    env.ws_message(harness.control_event("26 7D 5D 2", "DON"))
    assert_equal(co(detector), "detected")

    env.ws_message(harness.control_event("26 7D 5D 2", "DOF"))
    assert_equal(co(detector), "clear")
    assert_equal(smoke(detector), "detected", "CO clearing leaves the smoke alarm")
  end)

  it("clear both alarms on an all clear, even while the eISY still shows them On", function()
    local env = harness.load_driver(bridge().routes).start()
    local detector = env.child(KEY)
    env.ws_message(harness.status_event("26 7D 5D 1", 255))
    env.ws_message(harness.control_event("26 7D 5D 1", "DON"))
    env.ws_message(harness.control_event("26 7D 5D 2", "DON"))

    env.ws_message(harness.control_event("26 7D 5D 5", "DON"))
    assert_equal(smoke(detector), "clear")
    assert_equal(co(detector), "clear")

    -- The eISY replays the stale On status when the WebSocket reconnects.
    env.ws_message(harness.status_event("26 7D 5D 1", 255))
    assert_equal(smoke(detector), "clear", "a replayed On must not raise a false alarm")

    env.ws_message(harness.control_event("26 7D 5D 1", "DON"))
    assert_equal(smoke(detector), "detected", "a new alarm after an all clear still counts")
  end)

  it("stay cleared after a restart while the eISY still shows them On", function()
    local world = bridge()
    local env = harness.load_driver(world.routes).start()
    local detector = env.child(KEY)
    env.ws_message(harness.control_event("26 7D 5D 1", "DON"))
    env.ws_message(harness.control_event("26 7D 5D 5", "DON"))
    assert_truthy(env.controller.persisted.smoke_states, "cleared alarms must be persisted")

    world.status = { st("26 7D 5D 1", 255), st("26 7D 5D 6", 0) }
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    assert_equal(smoke(detector), "clear")
  end)

  it("clear when the eISY reports Off, whatever the last command was", function()
    local world = bridge()
    local env = harness.load_driver(world.routes).start()
    local detector = env.child(KEY)
    env.ws_message(harness.control_event("26 7D 5D 1", "DON"))
    assert_equal(smoke(detector), "detected")

    -- Read over REST, as after the WebSocket was down when the alarm ended.
    world.status = { st("26 7D 5D 1", 0), st("26 7D 5D 6", 0) }
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    assert_equal(smoke(detector), "clear")
  end)

  it("show an alarm the eISY reports before any command was seen", function()
    local env = harness.load_driver(bridge({ st("26 7D 5D 1", 255), st("26 7D 5D 6", 0) }).routes).start()
    assert_equal(smoke(env.child(KEY)), "detected")
  end)

  it("never read another node as smoke when the Smoke node is ignored", function()
    local world = bridge({ st("26 7D 5D 2", 255), st("26 7D 5D 6", 0) })
    local env = harness.load_driver(world.routes, { ignoredNodes = "26.7D.5D-Smoke" }).start()
    local detector
    for _, device in ipairs(env.driver.devices) do
      if device.created and device.created.profile == "eisy-smoke" then detector = device end
    end
    assert_truthy(detector, "the rest of the bridge is still a smoke detector")
    assert_equal(co(detector), "detected")
    assert_equal(smoke(detector), nil, "the CO node must not be shown as smoke")
  end)

  it("show readings as soon as a bridge created as a motion sensor becomes a detector", function()
    local env = harness.load_driver(bridge().routes)
    env.driver:try_create_device({ parent_assigned_child_key = KEY, label = "26.7D.5D-Smoke", profile = "eisy-motion" })
    env.start()
    local detector = env.child(KEY)
    assert_equal(detector.pending_profile, "eisy-smoke")
    assert_equal(smoke(detector), nil, "the hub hasn't applied the new profile yet")

    env.apply_profile_changes()
    assert_equal(smoke(detector), "clear")
    assert_equal(co(detector), "clear")
    assert_equal(last_value(detector, "batteryLevel", "battery"), "normal")
  end)

  it("report low battery from the Low Bat node", function()
    local env = harness.load_driver(bridge().routes).start()
    local detector = env.child(KEY)
    env.ws_message(harness.status_event("26 7D 5D 6", 255))
    assert_equal(last_value(detector, "batteryLevel", "battery"), "warning")
    assert_equal(smoke(detector), "clear", "low battery is not an alarm")
  end)
end)
