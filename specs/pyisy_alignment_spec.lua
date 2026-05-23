describe("pyISY-style property parsing", function()
  local props = require "isy_properties"

  it("parses node properties with value, precision, uom, and formatted text", function()
    local parsed = props.parse_xml_properties([[
      <properties>
        <property id="ST" value="128" prec="0" uom="51" formatted="50%"/>
        <property id="RR" value="31" prec="0" uom="25" formatted="0.1 seconds"/>
      </properties>
    ]])

    assert_equal(parsed.state.id, "ST")
    assert_equal(parsed.state.value, 128)
    assert_equal(parsed.state.uom, "51")
    assert_equal(parsed.state.formatted, "50%")
    assert_equal(parsed.aux.RR.value, 31)
    assert_equal(parsed.aux.RR.formatted, "0.1 seconds")
  end)

  it("uses BATLVL as state when ST is absent", function()
    local parsed = props.parse_xml_properties([[
      <properties>
        <property id="BATLVL" value="92" prec="0" uom="51" formatted="92%"/>
      </properties>
    ]])

    assert_equal(parsed.state.id, "BATLVL")
    assert_equal(parsed.state.value, 92)
    assert_equal(parsed.state_set, false)
  end)
end)

describe("pyISY-style node model", function()
  local model = require "isy_model"

  it("preserves a known property uom when a later event omits it", function()
    local store = model.new_store()
    local node = store:upsert_node({
      address = "11 22 33 1",
      name = "Dimmer A",
      family = "1",
      type = "1.1.65.0",
      properties = {
        ST = { id = "ST", value = 128, uom = "51", formatted = "50%" }
      }
    })

    node:update_property({ id = "ST", value = 64, formatted = "25%" })

    assert_equal(node.status.value, 64)
    assert_equal(node.status.uom, "51")
    assert_equal(node.properties.ST.uom, "51")
  end)

  it("replaces scanned topology so removed ISY nodes do not stay classified", function()
    local store = model.new_store()
    store:replace_nodes({
      { address = "11 22 33 1", name = "First", family = "1", properties = { ST = { id = "ST", value = 0 } } },
      { address = "22 33 44 1", name = "Second", family = "1", properties = { ST = { id = "ST", value = 0 } } }
    })
    store:replace_nodes({
      { address = "22 33 44 1", name = "Second", family = "1", properties = { ST = { id = "ST", value = 0 } } }
    })

    assert_equal(store:get_node("11 22 33 1"), nil)
    assert_equal(#store:as_node_list(), 1)
  end)
end)

describe("pyISY-style event routing", function()
  local events = require "isy_events"

  it("routes ST websocket events as status updates", function()
    local routed = events.route_xml([[
      <Event seqnum="1">
        <control>ST</control>
        <action uom="51" prec="0">255</action>
        <node>11 22 33 1</node>
        <fmtAct>100%</fmtAct>
      </Event>
    ]])

    assert_equal(routed.kind, "status")
    assert_equal(routed.address, "11 22 33 1")
    assert_equal(routed.property.id, "ST")
    assert_equal(routed.property.value, 255)
    assert_equal(routed.property.uom, "51")
  end)

  it("routes DON as a control event instead of pretending it is ST", function()
    local routed = events.route_xml([[
      <Event seqnum="2">
        <control>DON</control>
        <action uom="51" prec="0">255</action>
        <node>11 22 33 1</node>
        <fmtAct>100%</fmtAct>
      </Event>
    ]])

    assert_equal(routed.kind, "control")
    assert_equal(routed.property.id, "DON")
    assert_equal(routed.property.value, 255)
  end)

  it("routes node-change events separately for discovery reconciliation", function()
    local routed = events.route_xml([[
      <Event seqnum="3">
        <control>_3</control>
        <action>1</action>
        <node>11 22 33 1</node>
      </Event>
    ]])

    assert_equal(routed.kind, "node_changed")
    assert_equal(routed.address, "11 22 33 1")
    assert_equal(routed.requires_scan, true)
  end)

  it("routes _1 system config events without requesting an Insteon node scan", function()
    local routed = events.route_xml([[
      <Event seqnum="4">
        <control>_1</control>
        <action>1</action>
      </Event>
    ]])

    assert_equal(routed.kind, "system_config")
    assert_equal(routed.requires_scan, false)
  end)
end)

describe("pyISY-style REST helpers", function()
  local client = require "eisy_client"

  it("parses controller config uuid and model metadata", function()
    local parsed = client.parse_config([[
      <configuration>
        <uuid>00:21:b9:12:34:56</uuid>
        <model>eisy</model>
        <name>Sample Controller</name>
      </configuration>
    ]])

    assert_equal(parsed.uuid, "00:21:b9:12:34:56")
    assert_equal(parsed.model, "eisy")
    assert_equal(parsed.name, "Sample Controller")
  end)

  it("percent-encodes command path segments", function()
    assert_equal(client.encode_path_segment("11 22/33 1"), "11%2022%2F33%201")
  end)
end)

describe("native Insteon classification", function()
  local classifier = require "node_classifier"

  it("excludes node-server and Matter/ZMatter style nodes", function()
    local devices = classifier.classify_all({
      { address = "n001_sensor", name = "Plugin Node", family = "10", type = "0.0", nodeDefId = "plugin", enabled = "true", properties = { ST = { id = "ST", value = 1 } } },
      { address = "zw 001", name = "Matter Node", family = "12", type = "0.0", nodeDefId = "zwave", enabled = "true", properties = { ST = { id = "ST", value = 1 } } },
      { address = "11 22 33 1", name = "Native Switch", family = "1", type = "2.1", nodeDefId = "relaySwitch", enabled = "true", properties = { ST = { id = "ST", value = 0 } } }
    })

    assert_equal(#devices, 1)
    assert_equal(devices[1].label, "Native Switch")
  end)

  it("splits FanLinc light and motor nodes into separate SmartThings devices", function()
    local devices = classifier.classify_all({
      { address = "22 33 44 1", name = "Fan Light", family = "1", type = "1.1", nodeDefId = "dimmerLampOnly", pnode = "22 33 44 1", sgid = "1", enabled = "true", properties = { ST = { id = "ST", value = 0, uom = "51" } } },
      { address = "22 33 44 2", name = "Fan Motor", family = "1", type = "1.46", nodeDefId = "fanLincMotor", pnode = "22 33 44 1", sgid = "2", enabled = "true", properties = { ST = { id = "ST", value = 0 } } }
    })

    assert_equal(#devices, 2)
    assert_equal(devices[1].kind, "dimmer")
    assert_equal(devices[2].kind, "fan")
  end)

  it("uses battery sensor profiles only when BATLVL is available", function()
    local devices = classifier.classify_all({
      { address = "33 44 55 1", name = "Motion No Battery", family = "1", type = "16.1", nodeDefId = "pir", enabled = "true", properties = { ST = { id = "ST", value = 0 } } },
      { address = "44 55 66 1", name = "Motion Battery", family = "1", type = "16.1", nodeDefId = "pir", enabled = "true", properties = { ST = { id = "ST", value = 0 }, BATLVL = { id = "BATLVL", value = 91 } } }
    })

    assert_equal(devices[1].profile, "eisy-motion")
    assert_equal(devices[2].profile, "eisy-motion-battery")
  end)
end)

describe("child device identity", function()
  local identity = require "child_identity"

  it("uses the controller uuid for new child keys", function()
    local key = identity.select_child_key("00:21:b9:12:34:56", { key = "11 22 33 1" }, function() return nil end)
    assert_equal(key, "eisy:00:21:b9:12:34:56:11_22_33_1")
  end)

  it("preserves an existing legacy child key to avoid duplicate devices", function()
    local key = identity.select_child_key("00:21:b9:12:34:56", { key = "11 22 33 1" }, function(candidate)
      if candidate == "eisy:11_22_33_1" then return true end
      return nil
    end)

    assert_equal(key, "eisy:11_22_33_1")
  end)
end)

describe("SmartThings state translation", function()
  local state = require "device_state"

  it("emits battery only when the component supports battery", function()
    local emitted = {}
    local device = {
      profile = {
        components = {
          main = {
            id = "main",
            capabilities = { "motionSensor", "battery" }
          }
        }
      },
      emit_component_event = function(_, _, event)
        emitted[#emitted + 1] = event
      end
    }

    state.emit_component(device, "main", "motion", {
      ST = { id = "ST", value = 0 },
      BATLVL = { id = "BATLVL", value = 92, uom = "51", formatted = "92%" }
    })

    assert_equal(emitted[1].capability_id, "motionSensor")
    assert_equal(emitted[2].capability_id, "battery")
    assert_equal(emitted[2].state.value, 92)
  end)

  it("uses pyISY thermostat operating state values", function()
    local emitted = {}
    local device = {
      profile = {
        components = {
          main = {
            id = "main",
            capabilities = {
              "temperatureMeasurement",
              "thermostatMode",
              "thermostatOperatingState",
              "thermostatHeatingSetpoint",
              "thermostatCoolingSetpoint",
              "thermostatFanMode"
            }
          }
        }
      },
      emit_component_event = function(_, _, event)
        emitted[#emitted + 1] = event
      end,
      get_latest_state = function() return nil end
    }

    state.emit_component(device, "main", "thermostat", {
      ST = { id = "ST", value = 144, uom = "101", formatted = "72 F" },
      CLIMD = { id = "CLIMD", value = 6, formatted = "Program Cool" },
      CLIHCS = { id = "CLIHCS", value = 5, formatted = "Pending Cool" },
      CLIFS = { id = "CLIFS", value = 8, formatted = "Auto" }
    })

    local operating_state
    local mode
    for _, event in ipairs(emitted) do
      if event.attribute_id == "thermostatOperatingState" then operating_state = event.state.value end
      if event.attribute_id == "thermostatMode" then mode = event.state.value end
    end
    assert_equal(mode, "cool")
    assert_equal(operating_state, "pending cool")
  end)
end)
