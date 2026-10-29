-- Specs for eISY scene support: parsing, status, and the driver wiring from the
-- sceneIds preference through scan, WebSocket events, and commands.

local isy_scene = require "isy_scene"
local classifier = require "node_classifier"

local SCENE_XML = [[<?xml version="1.0" encoding="UTF-8"?>
<nodeInfo>
  <group flag="132" nodeDefId="InsteonDimmer">
    <address>12345</address>
    <name>Kitchen &amp; Dining</name>
    <parent type="3">17234</parent>
    <deviceGroup>16</deviceGroup>
    <members>
      <link type="16">1A 2B 3C 1</link>
      <link type="32">4D 5E 6F 1</link>
      <link type="16">7A 8B 9C 1</link>
    </members>
  </group>
</nodeInfo>]]

local function node(address, properties, extra)
  local record = { address = address, nodeDefId = "DimmerLampSwitch", type = "1.32.65.0", properties = properties or {} }
  for key, value in pairs(extra or {}) do record[key] = value end
  return record
end

local function lookup(nodes)
  local by_address = {}
  for _, n in ipairs(nodes) do by_address[n.address] = n end
  return function(address) return by_address[address] end
end

describe("eISY scene parsing", function()
  it("splits the sceneIds preference and drops blanks and duplicates", function()
    assert_deep_equal(isy_scene.parse_ids(" 12345, 23456,,12345 , "), { "12345", "23456" })
    assert_deep_equal(isy_scene.parse_ids(nil), {})
  end)

  it("reads the scene name, address, and members with their controller role", function()
    local parsed = isy_scene.parse(SCENE_XML, "12345")
    assert_equal(parsed.address, "12345")
    assert_equal(parsed.name, "Kitchen & Dining")
    assert_deep_equal(parsed.members, {
      { address = "1A 2B 3C 1", controller = true },
      { address = "4D 5E 6F 1", controller = false },
      { address = "7A 8B 9C 1", controller = true }
    })
  end)

  it("rejects a device id entered as a scene", function()
    local parsed, err = isy_scene.parse([[<nodeInfo><node flag="128"><address>1A 2B 3C 1</address></node></nodeInfo>]], "1A 2B 3C 1")
    assert_equal(parsed, nil)
    assert_truthy(err:find("not a scene", 1, true), err)
  end)

  it("builds a switch device keyed apart from Insteon nodes", function()
    local device = isy_scene.device(isy_scene.parse(SCENE_XML, "12345"))
    assert_equal(device.key, "scene:12345")
    assert_equal(device.kind, "scene")
    assert_equal(device.profile, "eisy-scene")
    assert_equal(device.label, "Kitchen & Dining")
    assert_deep_equal(device.components, { main = "12345" })
  end)
end)

describe("eISY scene status", function()
  local members = {
    { address = "A", controller = true },
    { address = "B", controller = false },
    { address = "M", controller = true }
  }

  it("is on while any member is on, including members that are also controllers", function()
    local get = lookup({ node("A", { ST = { value = 255 } }), node("B", { ST = { value = 0 } }) })
    assert_equal(isy_scene.status(members, get, classifier.has_scene_status).value, 255)
  end)

  it("is off when every member is off or unknown", function()
    local get = lookup({ node("A", { ST = { value = 0 } }), node("B", { ST = { value = " " } }) })
    assert_equal(isy_scene.status(members, get, classifier.has_scene_status).value, 0)
  end)

  it("ignores a motion sensor controller's status", function()
    local get = lookup({
      node("A", { ST = { value = 0 } }),
      node("B", { ST = { value = 0 } }),
      node("M", { ST = { value = 255 } }, { nodeDefId = "PIR2844", type = "16.1.65.0" })
    })
    assert_equal(isy_scene.status(members, get, classifier.has_scene_status).value, 0)
    assert_deep_equal(isy_scene.status_addresses(members, get, classifier.has_scene_status), { "A", "B" })
  end)
end)

local harness = require "driver_harness"

local function load_driver(routes)
  return harness.load_driver(routes, { sceneIds = "12345" })
end

local CONFIG_XML = "<configuration><root><id>00:21:b9:02:aa:bb</id><name>eisy</name></root></configuration>"
local NODES_XML = [[<nodes>
  <node flag="128" nodeDefId="DimmerLampSwitch"><address>1A 2B 3C 1</address><name>Island</name><family>1</family><type>1.32.65.0</type><enabled>true</enabled><pnode>1A 2B 3C 1</pnode><property id="ST" value="0" uom="100" formatted="Off"/></node>
  <node flag="128" nodeDefId="DimmerLampSwitch"><address>4D 5E 6F 1</address><name>Pendants</name><family>1</family><type>1.32.65.0</type><enabled>true</enabled><pnode>4D 5E 6F 1</pnode><property id="ST" value="0" uom="100" formatted="Off"/></node>
  <group flag="132"><address>12345</address><name>Kitchen</name></group>
</nodes>]]
local STATUS_XML = [[<nodes>
  <node id="1A 2B 3C 1"><property id="ST" value="0" uom="100" formatted="Off"/></node>
  <node id="4D 5E 6F 1"><property id="ST" value="0" uom="100" formatted="Off"/></node>
</nodes>]]

local function base_routes()
  return {
    ["/rest/config"] = CONFIG_XML,
    ["/rest/nodes?members=false"] = NODES_XML,
    ["/rest/status"] = STATUS_XML,
    ["/rest/nodes/12345?members=true"] = SCENE_XML
  }
end

local SCENE_KEY = "eisy:00:21:b9:02:aa:bb:scene:12345"

local function last_switch(device)
  for index = #device.events, 1, -1 do
    local event = device.events[index]
    if event.capability_id == "switch" then return event.state.value end
  end
end

local function st_event(address, value)
  return '<Event seqnum="1" sid="uuid:1"><control>ST</control><action uom="100" prec="0">' .. value
      .. '</action><node>' .. address .. '</node><eventInfo></eventInfo><fmtAct>x</fmtAct></Event>'
end

describe("eISY scene driver wiring", function()
  it("creates a scene child from the sceneIds preference and reports it off", function()
    local env = load_driver(base_routes())
    env.template.lifecycle_handlers.init(env.driver, env.controller)

    local scene = env.child(SCENE_KEY)
    assert_truthy(scene, "expected a scene child")
    assert_equal(scene.created.label, "Kitchen & Dining")
    assert_equal(scene.created.profile, "eisy-scene")
    assert_equal(last_switch(scene), "off")
  end)

  it("turns the scene on and off from member status events", function()
    local env = load_driver(base_routes())
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    local scene = env.child(SCENE_KEY)

    -- 4D 5E 6F 1 is a responder; 7A 8B 9C 1 has no child and was not scanned.
    env.ws_message(st_event("4D 5E 6F 1", 255))
    assert_equal(last_switch(scene), "on")
    env.ws_message(st_event("7A 8B 9C 1", 255))
    env.ws_message(st_event("4D 5E 6F 1", 0))
    assert_equal(last_switch(scene), "on", "an unscanned member that is on keeps the scene on")
    env.ws_message(st_event("7A 8B 9C 1", 0))
    assert_equal(last_switch(scene), "off")
  end)

  it("sends DON and DOF to the scene address", function()
    local routes = base_routes()
    routes["/rest/nodes/12345/cmd/DON"] = "<RestResponse succeeded=\"true\"/>"
    routes["/rest/nodes/12345/cmd/DOF"] = "<RestResponse succeeded=\"true\"/>"
    local env = load_driver(routes)
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    local scene = env.child(SCENE_KEY)
    local handlers = env.template.capability_handlers.switch

    handlers.on(env.driver, scene, { component = "main" })
    handlers.off(env.driver, scene, { component = "main" })

    local sent = {}
    for _, path in ipairs(env.requests) do
      if path:find("/cmd/", 1, true) then sent[#sent + 1] = path end
    end
    assert_deep_equal(sent, { "/rest/nodes/12345/cmd/DON", "/rest/nodes/12345/cmd/DOF" })
  end)

  it("reads member statuses after a command when the WebSocket is not connected", function()
    local routes = base_routes()
    routes["/rest/nodes/12345/cmd/DON"] = "<RestResponse succeeded=\"true\"/>"
    routes["/rest/status/4D%205E%206F%201"] = '<properties><property id="ST" value="255" uom="100" formatted="On"/></properties>'
    local env = load_driver(routes)
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    local scene = env.child(SCENE_KEY)

    env.template.capability_handlers.switch.on(env.driver, scene, { component = "main" })
    env.run_timers()

    assert_equal(last_switch(scene), "on")
  end)

  it("keeps a scene the eISY fails to return on a later scan", function()
    local routes = base_routes()
    local env = load_driver(routes)
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    routes["/rest/nodes/12345?members=true"] = nil
    env.template.capability_handlers.refresh.refresh(env.driver, env.controller)

    env.ws_message(st_event("1A 2B 3C 1", 255))
    assert_equal(last_switch(env.child(SCENE_KEY)), "on")
  end)

  it("rescans without restarting the WebSocket when only sceneIds changes", function()
    local routes = base_routes()
    routes["/rest/nodes/23456?members=true"] = (SCENE_XML:gsub("12345", "23456"):gsub("Kitchen &amp; Dining", "Porch"))
    local env = load_driver(routes)
    env.template.lifecycle_handlers.init(env.driver, env.controller)
    local ws_handle = env.controller:get_field("ws_handle")

    local old = { preferences = {} }
    for key, value in pairs(env.controller.preferences) do old.preferences[key] = value end
    env.controller.preferences.sceneIds = "12345, 23456"
    env.template.lifecycle_handlers.infoChanged(env.driver, env.controller, nil, { old_st_store = old })

    assert_equal(env.child("eisy:00:21:b9:02:aa:bb:scene:23456").created.label, "Porch")
    assert_equal(env.controller:get_field("ws_handle"), ws_handle)
  end)
end)
