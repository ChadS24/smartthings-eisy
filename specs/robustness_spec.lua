-- Regression specs for request retries, node-change filtering, and classification
-- of multi-load devices and remotes.

-- Load eisy_client against a fake HTTP transport. `respond(request)` returns what
-- socket.http's request would: (1, code, headers, status) after writing the body
-- to request.sink, or (nil, err).
local function load_client_with_http(respond)
  local saved_cosock = package.loaded.cosock
  local saved_client = package.loaded.eisy_client
  local fake_http = { request = respond }
  package.loaded.cosock = {
    asyncify = function(name)
      if name == "socket.http" then return fake_http end
      return { request = function() error("unexpected transport " .. name) end }
    end,
    socket = { sleep = function() end }
  }
  package.loaded.eisy_client = nil
  local client = require "eisy_client"
  package.loaded.eisy_client = saved_client
  package.loaded.cosock = saved_cosock
  return client
end

local function body_response(body)
  return function(request)
    request.sink(body)
    request.sink(nil)
    return 1, 200, {}, "HTTP/1.1 200 OK"
  end
end

describe("eISY requests", function()
  it("retries an unreachable eISY once, then reports it unreachable", function()
    local calls = 0
    local client = load_client_with_http(function()
      calls = calls + 1
      return nil, "timeout"
    end)

    local body, err, failure = client.new({ host = "192.0.2.10" }):request("/rest/config")

    assert_equal(body, nil)
    assert_equal(err, "timeout")
    assert_equal(failure, client.UNREACHABLE)
    assert_equal(calls, 2, "an unreachable eISY must not be retried five times")
  end)

  it("still retries a busy eISY's 503 responses", function()
    local calls = 0
    local client = load_client_with_http(function()
      calls = calls + 1
      return 1, 503, {}, "HTTP/1.1 503 Service Unavailable"
    end)

    local body, _, failure = client.new({ host = "192.0.2.10" }):request("/rest/config")

    assert_equal(body, nil)
    assert_equal(failure, nil, "a 503 means the eISY was reached")
    assert_equal(calls, 6)
  end)

  it("passes the unreachable marker through the REST helpers", function()
    local client = load_client_with_http(function() return nil, "connection refused" end)
    local config, _, failure = client.new({ host = "192.0.2.10" }):get_config()
    assert_equal(config, nil)
    assert_equal(client.UNREACHABLE, "unreachable")
    assert_equal(failure, "unreachable")
  end)

  it("uses a 15 second timeout by default", function()
    local client = load_client_with_http(body_response("<x/>"))
    assert_equal(client.new({ host = "192.0.2.10" }).timeout, 15)
  end)
end)

describe("node-changed events", function()
  local events = require "isy_events"

  local function requires_scan(action)
    return events.route_xml("<Event><control>_3</control><action>" .. action .. "</action><node>11 22 33 1</node></Event>").requires_scan
  end

  it("rescan for topology changes", function()
    for _, action in ipairs({ "ND", "NR", "NN", "EN", "PC", "MV", "RG", "GD", "GR", "GN" }) do
      assert_equal(requires_scan(action), true, action)
    end
  end)

  it("do not rescan for comm errors or device writes", function()
    for _, action in ipairs({ "NE", "CE", "WH", "WD" }) do
      assert_equal(requires_scan(action), false, action)
    end
  end)
end)

describe("multi-load classification", function()
  local classifier = require "node_classifier"

  local function node(address, def, insteon_type, pnode, sgid)
    return {
      address = address, name = def .. " " .. address, family = "1", type = insteon_type,
      nodeDefId = def, pnode = pnode, sgid = sgid, enabled = "true",
      properties = { ST = { id = "ST", value = 0 } }
    }
  end

  it("gives each load of a dual outlet its own device", function()
    local devices = classifier.classify_all({
      node("AA AA AA 1", "RelayLampSwitch", "2.57.65.0", "AA AA AA 1", "1"),
      node("AA AA AA 2", "RelayLampSwitch", "2.57.65.0", "AA AA AA 1", "2")
    })

    assert_equal(#devices, 2)
    assert_equal(devices[1].key, "AA AA AA 1", "the first outlet keeps the key the single device had")
    assert_equal(devices[1].components.main, "AA AA AA 1")
    assert_equal(devices[2].key, "AA AA AA 2")
    assert_equal(devices[2].components.main, "AA AA AA 2")
    assert_equal(devices[2].kind, "switch")
  end)

  it("keeps the group's key on the parent load when it does not sort first", function()
    local devices = classifier.classify_all({
      node("BB BB BB 1", "RelayLampSwitch", "2.57.65.0", "BB BB BB 2", "1"),
      node("BB BB BB 2", "RelayLampSwitch", "2.57.65.0", "BB BB BB 2", "2")
    })

    local keys = {}
    for _, device in ipairs(devices) do keys[device.components.main] = device.key end
    assert_equal(keys["BB BB BB 2"], "BB BB BB 2")
    assert_equal(keys["BB BB BB 1"], "BB BB BB 1")
  end)

  it("leaves remotes to their button devices", function()
    local devices = classifier.classify_all({
      node("CC CC CC 1", "RemoteLinc2", "0.16.65.0", "CC CC CC 1"),
      node("DD DD DD 1", "DimmerSwitchOnly", "0.18.65.0", "DD DD DD 1"),
      node("EE EE EE 1", "RelayLampSwitch", "2.57.65.0", "EE EE EE 1")
    })

    local kinds = {}
    for _, device in ipairs(devices) do kinds[device.components.main] = device.kind end
    assert_equal(kinds["CC CC CC 1"], "remote")
    assert_equal(kinds["DD DD DD 1"], "remote")
    assert_equal(kinds["EE EE EE 1"], "switch")
  end)

  it("keeps PyISY's view that DimmerSwitchOnly does not count toward scene status", function()
    -- PyISY lists DimmerSwitchOnly with the battery controllers whose state a
    -- group ignores (INSTEON_STATELESS_NODEDEFID).
    assert_equal(classifier.has_scene_status(node("FF FF FF 1", "DimmerSwitchOnly", "1.32.65.0", "FF FF FF 1")), false)
  end)
end)
