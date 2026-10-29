-- Specs for scan retries, rescans on WebSocket connect, node-changed filtering,
-- request failures during refresh, and children the user deleted, run against the
-- real driver through the shared harness.

local harness = require "driver_harness"

local NODES_XML = [[<nodes>
  <node flag="128" nodeDefId="RelayLampSwitch_ADV"><address>11 11 11 1</address><name>Porch</name><family>1</family><type>2.42.67.0</type><enabled>true</enabled><pnode>11 11 11 1</pnode><property id="ST" value="0" formatted="Off" uom="100"/></node>
  <node flag="128" nodeDefId="DimmerLampSwitch_ADV"><address>22 22 22 1</address><name>Hall</name><family>1</family><type>1.32.65.0</type><enabled>true</enabled><pnode>22 22 22 1</pnode><property id="ST" value="0" formatted="0%" uom="100"/></node>
</nodes>]]

local function routes()
  return {
    ["/rest/config"] = "<configuration><root><id>00:21:b9:00:00:01</id><name>Home</name></root></configuration>",
    ["/rest/nodes?members=false"] = NODES_XML,
    ["/rest/status"] = [[<nodes>
  <node id="11 11 11 1"><property id="ST" value="255" formatted="On" uom="100"/></node>
  <node id="22 22 22 1"><property id="ST" value="128" formatted="50%" uom="100"/></node>
</nodes>]],
    ["/rest/status/11%2011%2011%201"] = [[<properties><property id="ST" value="0" formatted="Off" uom="100"/></properties>]]
  }
end

local PORCH_KEY = "eisy:00:21:b9:00:00:01:11_11_11_1"
local HALL_KEY = "eisy:00:21:b9:00:00:01:22_22_22_1"

local function has_delay(env, seconds)
  for _, delay in ipairs(env.timer_delays()) do
    if delay == seconds then return true end
  end
  return false
end

local function count(list)
  local n = 0
  for _ in pairs(list or {}) do n = n + 1 end
  return n
end

describe("controller scans", function()
  it("creates children and maps them when the eISY is up", function()
    local env = harness.load_driver(routes()).start()

    assert_truthy(env.child(PORCH_KEY))
    assert_truthy(env.child(HALL_KEY))
    assert_equal(count(env.controller:get_field("eisy_devices_by_key")), 2)
    assert_equal(has_delay(env, 15), false, "a successful scan schedules no retry")
  end)

  it("retries a scan that failed because the eISY was down at startup", function()
    local env = harness.load_driver(routes())
    env.set_eisy_down(true)
    env.start()

    assert_equal(env.child(PORCH_KEY), nil)
    assert_truthy(has_delay(env, 15), "a failed scan must schedule a retry")
    assert_truthy(#env.requests <= 2, "an unreachable eISY must fail the scan fast, made " .. #env.requests .. " requests")

    -- Still down: the next retry backs off.
    env.run_timers(15)
    assert_truthy(has_delay(env, 30))

    -- Back up: the retry maps the devices.
    env.set_eisy_down(false)
    env.run_timers(30)
    assert_truthy(env.child(PORCH_KEY))
    assert_equal(count(env.controller:get_field("eisy_devices_by_key")), 2)
    assert_equal(has_delay(env, 60), false, "a successful scan cancels the unreachable check")
  end)

  it("rescans as soon as the WebSocket connects after a failed scan", function()
    local env = harness.load_driver(routes())
    env.set_eisy_down(true)
    env.start()
    assert_truthy(has_delay(env, 15))

    env.set_eisy_down(false)
    env.ws_status("connected")

    assert_equal(has_delay(env, 15), false, "the backoff retry should be replaced")
    assert_truthy(has_delay(env, 1))
    env.run_timers(1)
    assert_truthy(env.child(PORCH_KEY))
  end)

  it("does not rescan on connect once a scan has succeeded", function()
    local env = harness.load_driver(routes()).start()
    env.ws_status("connected")
    assert_equal(has_delay(env, 1), false)
  end)

  it("ignores comm-error and device-write node changes but rescans for added nodes", function()
    local env = harness.load_driver(routes()).start()

    for _, action in ipairs({ "NE", "CE", "WH", "WD" }) do
      env.ws_message(harness.control_event("11 11 11 1", "_3", action))
    end
    assert_equal(has_delay(env, 2), false)

    env.ws_message(harness.control_event("33 33 33 1", "_3", "ND"))
    assert_truthy(has_delay(env, 2))
  end)

  it("stops refreshing a device's nodes at the first unreachable error", function()
    local env = harness.load_driver(routes()).start()
    env.set_eisy_down(true)
    local before = #env.requests

    env.template.capability_handlers.refresh.refresh(env.driver, env.child(PORCH_KEY))

    assert_equal(#env.requests - before, 2, "one node, one retry")
  end)
end)

describe("children deleted in SmartThings", function()
  it("are not recreated by automatic scans", function()
    local env = harness.load_driver(routes()).start()
    env.remove(env.child(PORCH_KEY))

    local removed = env.controller:get_field("eisy_removed_child_keys")
    assert_truthy(removed and removed[PORCH_KEY], "the deletion must be remembered")
    assert_truthy(env.controller.persisted.eisy_removed_child_keys, "and persisted")

    env.template.lifecycle_handlers.init(env.driver, env.controller)
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)
    env.ws_message(harness.control_event("33 33 33 1", "_3", "ND"))
    env.run_timers(2)
    assert_equal(env.child(PORCH_KEY), nil)
    assert_truthy(env.child(HALL_KEY))
  end)

  it("are restored by the Scan for devices button", function()
    local env = harness.load_driver(routes()).start()
    env.remove(env.child(PORCH_KEY))

    env.template.capability_handlers["oftentrust07380.scanfordevices"].scan(env.driver, env.controller)

    assert_truthy(env.child(PORCH_KEY))
    assert_equal(count(env.controller:get_field("eisy_removed_child_keys")), 0)
  end)
end)
