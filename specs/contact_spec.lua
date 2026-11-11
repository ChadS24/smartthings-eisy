-- Specs for Insteon open/close sensors in "two groups" mode, where closing sends
-- On to a separate Closed node (subnode 2) and the Opened node stays On. As in
-- Home Assistant's ISY integration, subnode 2 is the sensor's "negative" node.

local classifier = require "node_classifier"
local harness = require "driver_harness"
local last_value = harness.last_value

local UUID = "00:21:b9:00:00:03"
local function key(address) return "eisy:" .. UUID .. ":" .. address:gsub(" ", "_") end

local function node_xml(address, name, type_, properties)
  return string.format(
    '<node flag="128" nodeDefId="BinaryAlarm"><address>%s</address><name>%s</name><family>1</family><type>%s</type><enabled>true</enabled><pnode>%s</pnode>%s</node>',
    address, name, type_, address:gsub("%s+%x+$", " 1"), properties or "")
end

local function st(value) return '<property id="ST" value="' .. tostring(value) .. '" uom="2" formatted="x"/>' end

local function routes(node_list, statuses)
  local status_parts = { "<nodes>" }
  for address, value in pairs(statuses or {}) do
    status_parts[#status_parts + 1] = '<node id="' .. address .. '">' .. st(value) .. "</node>"
  end
  status_parts[#status_parts + 1] = "</nodes>"
  return {
    ["/rest/config"] = "<configuration><root><id>" .. UUID .. "</id></root></configuration>",
    ["/rest/nodes?members=false"] = "<nodes>\n" .. table.concat(node_list, "\n") .. "\n</nodes>",
    ["/rest/status"] = table.concat(status_parts)
  }
end

local TWO_GROUP_DOOR = {
  node_xml("AA 00 01 1", "Door-Opened", "16.6.65.0"),
  node_xml("AA 00 01 2", "Door-Closed", "16.6.65.0"),
  node_xml("AA 00 01 4", "Door-Heartbeat", "16.6.65.0")
}
local SINGLE_GROUP_DOOR = {
  node_xml("BB 00 01 1", "Closet-Opened", "16.6.65.0"),
  node_xml("BB 00 01 4", "Closet-Heartbeat", "16.6.65.0")
}
local DOOR = key("AA 00 01 1")
local CLOSET = key("BB 00 01 1")

local function contact(device) return last_value(device, "contactSensor", "contact") end

describe("two-group open/close sensors", function()
  it("classify subnode 2 as the sensor's Closed node", function()
    local devices = classifier.classify_all(require("eisy_client").parse_nodes(
      "<nodes>" .. table.concat(TWO_GROUP_DOOR) .. "</nodes>"), "")
    assert_equal(#devices, 1)
    assert_equal(devices[1].kind, "contact")
    assert_deep_equal(devices[1].opening, { opened = "AA 00 01 1", closed = "AA 00 01 2" })
  end)

  it("close when the Closed node sends On, though the Opened node stays On", function()
    local env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 0, ["AA 00 01 2"] = 255 })).start()
    local door = env.child(DOOR)
    assert_equal(contact(door), "closed")

    env.ws_message(harness.control_event("AA 00 01 1", "DON"))
    env.ws_message(harness.status_event("AA 00 01 1", 255))
    assert_equal(contact(door), "open")

    env.ws_message(harness.control_event("AA 00 01 2", "DON"))
    env.ws_message(harness.status_event("AA 00 01 2", 255))
    assert_equal(contact(door), "closed")
  end)

  it("stay closed when the eISY replays the Opened node's stale On status", function()
    local env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 0, ["AA 00 01 2"] = 255 })).start()
    local door = env.child(DOOR)
    env.ws_message(harness.control_event("AA 00 01 1", "DON"))
    env.ws_message(harness.control_event("AA 00 01 2", "DON"))

    env.ws_message(harness.status_event("AA 00 01 1", 255))
    env.template.capability_handlers.refresh.refresh(env.driver, door)
    assert_equal(contact(door), "closed")
  end)

  it("close when the Opened node sends Off, as in single-group mode", function()
    local env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 255 })).start()
    local door = env.child(DOOR)
    env.ws_message(harness.control_event("AA 00 01 1", "DOF"))
    assert_equal(contact(door), "closed")
  end)

  it("read open or closed from statuses only when the two nodes disagree", function()
    local open_env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 255, ["AA 00 01 2"] = 0 })).start()
    assert_equal(contact(open_env.child(DOOR)), "open")

    local unknown_env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 255, ["AA 00 01 2"] = 255 })).start()
    assert_equal(contact(unknown_env.child(DOOR)), nil, "both On is ambiguous; keep the last state")
  end)

  it("remember the state across a driver restart", function()
    local env = harness.load_driver(routes(TWO_GROUP_DOOR, { ["AA 00 01 1"] = 255, ["AA 00 01 2"] = 255 })).start()
    env.ws_message(harness.control_event("AA 00 01 2", "DON"))
    local persisted = env.controller:get_field("contact_states")
    assert_equal(persisted and persisted["AA 00 01 1"], "closed")
  end)
end)

describe("single-group open/close sensors", function()
  it("still follow the Opened node's status", function()
    local env = harness.load_driver(routes(SINGLE_GROUP_DOOR, { ["BB 00 01 1"] = 0 })).start()
    local closet = env.child(CLOSET)
    assert_equal(contact(closet), "closed")
    env.ws_message(harness.status_event("BB 00 01 1", 255))
    assert_equal(contact(closet), "open")
    env.ws_message(harness.status_event("BB 00 01 1", 0))
    assert_equal(contact(closet), "closed")
  end)
end)
