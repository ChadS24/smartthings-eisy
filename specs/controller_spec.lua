-- Drives src/init.lua's real handlers against a scripted eISY and a fake hub:
-- scan retries, rescans on WebSocket connect, node-changed filtering, and
-- children the user deleted.

local capabilities = require "st.capabilities"

-- init.lua reads command names off these capabilities when it builds the driver.
local function with_commands(capability, id, names)
  capability = capability or {}
  capability.ID = capability.ID or id
  capability.commands = capability.commands or {}
  for _, name in ipairs(names) do capability.commands[name] = { NAME = name } end
  return capability
end
capabilities.switch = with_commands(capabilities.switch, "switch", { "on", "off" })
capabilities.switchLevel = with_commands(capabilities.switchLevel, "switchLevel", { "setLevel" })
capabilities.fanSpeed = with_commands(capabilities.fanSpeed, "fanSpeed", { "setFanSpeed" })
capabilities.thermostatMode = with_commands(capabilities.thermostatMode, "thermostatMode", { "setThermostatMode" })
capabilities.thermostatFanMode = with_commands(capabilities.thermostatFanMode, "thermostatFanMode", { "setThermostatFanMode" })
capabilities.thermostatHeatingSetpoint = with_commands(capabilities.thermostatHeatingSetpoint, "thermostatHeatingSetpoint", { "setHeatingSetpoint" })
capabilities.thermostatCoolingSetpoint = with_commands(capabilities.thermostatCoolingSetpoint, "thermostatCoolingSetpoint", { "setCoolingSetpoint" })
capabilities.refresh = with_commands(capabilities.refresh, "refresh", { "refresh" })
capabilities["oftentrust07380.scanfordevices"] = with_commands(nil, "oftentrust07380.scanfordevices", { "scan" })

-- The scripted eISY. While `up` is false every request fails as unreachable.
local eisy = { up = true, requests = {} }

local NODES_XML = [[<nodes>
  <node flag="128" nodeDefId="RelayLampSwitch_ADV"><address>11 11 11 1</address><name>Porch</name><family>1</family><type>2.42.67.0</type><enabled>true</enabled><pnode>11 11 11 1</pnode><property id="ST" value="0" formatted="Off" uom="100"/></node>
  <node flag="128" nodeDefId="DimmerLampSwitch_ADV"><address>22 22 22 1</address><name>Hall</name><family>1</family><type>1.32.65.0</type><enabled>true</enabled><pnode>22 22 22 1</pnode><property id="ST" value="0" formatted="0%" uom="100"/></node>
</nodes>]]
local STATUS_XML = [[<nodes>
  <node id="11 11 11 1"><property id="ST" value="255" formatted="On" uom="100"/></node>
  <node id="22 22 22 1"><property id="ST" value="128" formatted="50%" uom="100"/></node>
</nodes>]]
local CONFIG_XML = [[<configuration><root><id>00:21:b9:00:00:01</id><name>Home</name></root><product><id>1</id><desc>eisy</desc></product></configuration>]]

local function respond(request)
  local path = request.url:match("^https?://[^/]+(/.*)$")
  eisy.requests[#eisy.requests + 1] = path
  if not eisy.up then return nil, "timeout" end
  local body
  if path == "/rest/config" then body = CONFIG_XML
  elseif path == "/rest/nodes?members=false" then body = NODES_XML
  elseif path == "/rest/status" then body = STATUS_XML
  elseif path:match("^/rest/status/") then body = [[<properties><property id="ST" value="0" formatted="Off" uom="100"/></properties>]]
  else return 1, 404, {}, "HTTP/1.1 404 Not Found" end
  request.sink(body)
  request.sink(nil)
  return 1, 200, {}, "HTTP/1.1 200 OK"
end

-- Load init.lua with fakes for the SmartThings driver, the HTTP transport, and the
-- WebSocket, keeping the template it builds.
local template
local ws_opts, ws_on_message
local function load_driver()
  local saved = {}
  for _, name in ipairs({ "cosock", "eisy_client", "ws_subscription", "st.driver", "init" }) do
    saved[name] = package.loaded[name]
  end
  package.loaded.cosock = {
    asyncify = function(name)
      if name == "socket.http" then return { request = respond } end
      return { request = function() error("unexpected transport " .. name) end }
    end,
    socket = { sleep = function() end }
  }
  package.loaded.eisy_client = nil
  package.loaded.ws_subscription = {
    start = function(_, _, opts, on_message)
      ws_opts, ws_on_message = opts, on_message
      return { cancel = function() end }
    end
  }
  package.loaded["st.driver"] = function(_, driver_template)
    template = driver_template
    return { run = function() end }
  end
  package.loaded.init = nil
  require "init"
  for name, value in pairs(saved) do package.loaded[name] = value end
end
load_driver()

-- A fake hub: devices, per-device fields and timers fired by hand.
local function new_hub()
  local hub = { devices = {}, timers = {}, created = {} }

  local function new_device(fields)
    local device = fields
    device.fields = {}
    device.persisted = {}
    device.events = {}
    device.thread = {
      call_with_delay = function(_, delay, callback, name)
        local timer = { delay = delay, callback = callback, name = name }
        hub.timers[#hub.timers + 1] = timer
        return timer
      end,
      cancel_timer = function(_, timer) timer.cancelled = true end
    }
    function device:get_field(key) return self.fields[key] end
    function device:set_field(key, value, opts)
      self.fields[key] = value
      self.persisted[key] = opts and opts.persist or nil
    end
    function device:emit_component_event(_, event) self.events[#self.events + 1] = event end
    hub.devices[#hub.devices + 1] = device
    return device
  end

  hub.driver = {
    get_devices = function() return hub.devices end,
    try_create_device = function(_, metadata)
      hub.created[#hub.created + 1] = metadata.parent_assigned_child_key
      new_device({
        id = "child-" .. #hub.created,
        parent_device_id = metadata.parent_device_id,
        parent_assigned_child_key = metadata.parent_assigned_child_key,
        profile = { components = { main = { id = "main" } } }
      })
    end
  }

  hub.controller = new_device({
    id = "controller",
    device_network_id = "eisy-controller",
    preferences = { eisyHost = "192.0.2.10", eisyProtocol = "http", eisyPort = 80, ignoredNodes = "", sceneIds = "" }
  })

  function hub.pending_timers(name)
    local pending = {}
    for _, timer in ipairs(hub.timers) do
      if not timer.cancelled and not timer.fired and (not name or timer.name == name) then pending[#pending + 1] = timer end
    end
    return pending
  end

  function hub.fire(timer)
    timer.fired = true
    timer.callback()
  end

  function hub.child(key)
    for _, device in ipairs(hub.devices) do
      if device.parent_assigned_child_key == key then return device end
    end
  end

  function hub.remove(device)
    for index, candidate in ipairs(hub.devices) do
      if candidate == device then table.remove(hub.devices, index) break end
    end
    template.lifecycle_handlers.removed(hub.driver, device)
  end

  return hub
end

local function start(hub)
  eisy.requests = {}
  template.lifecycle_handlers.init(hub.driver, hub.controller)
end

local function count(list)
  local n = 0
  for _ in pairs(list or {}) do n = n + 1 end
  return n
end

local PORCH_KEY = "eisy:00:21:b9:00:00:01:11_11_11_1"

describe("controller scans", function()
  it("creates children and maps them when the eISY is up", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)

    assert_equal(#hub.created, 2)
    assert_equal(count(hub.controller:get_field("eisy_devices_by_key")), 2)
    assert_equal(#hub.pending_timers("eisy debounced scan"), 0, "a successful scan schedules no retry")
  end)

  it("retries a scan that failed because the eISY was down at startup", function()
    eisy.up = false
    local hub = new_hub()
    start(hub)

    assert_equal(#hub.created, 0)
    local retries = hub.pending_timers("eisy debounced scan")
    assert_equal(#retries, 1, "a failed scan must schedule a retry")
    assert_equal(retries[1].delay, 15)
    assert_truthy(#eisy.requests <= 2, "an unreachable eISY must fail the scan fast, made " .. #eisy.requests .. " requests")

    -- Still down: the next retry backs off.
    hub.fire(retries[1])
    retries = hub.pending_timers("eisy debounced scan")
    assert_equal(retries[1].delay, 30)

    -- Back up: the retry maps the devices.
    eisy.up = true
    hub.fire(retries[1])
    assert_equal(#hub.created, 2)
    assert_equal(count(hub.controller:get_field("eisy_devices_by_key")), 2)
    assert_equal(#hub.pending_timers("eisy debounced scan"), 0)
  end)

  it("rescans as soon as the WebSocket connects after a failed scan", function()
    eisy.up = false
    local hub = new_hub()
    start(hub)
    local retry = hub.pending_timers("eisy debounced scan")[1]
    assert_equal(retry.delay, 15)

    eisy.up = true
    ws_opts.on_status("connected")

    assert_truthy(retry.cancelled, "the backoff retry should be replaced")
    local pending = hub.pending_timers("eisy debounced scan")
    assert_equal(#pending, 1)
    assert_equal(pending[1].delay, 1)
    hub.fire(pending[1])
    assert_equal(#hub.created, 2)
  end)

  it("does not rescan on connect once a scan has succeeded", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)
    ws_opts.on_status("connected")
    assert_equal(#hub.pending_timers("eisy debounced scan"), 0)
  end)

  it("ignores comm-error and device-write node changes but rescans for added nodes", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)

    for _, action in ipairs({ "NE", "CE", "WH", "WD" }) do
      ws_on_message("<Event><control>_3</control><action>" .. action .. "</action><node>11 11 11 1</node></Event>")
    end
    assert_equal(#hub.pending_timers("eisy debounced scan"), 0)

    ws_on_message("<Event><control>_3</control><action>ND</action><node>33 33 33 1</node></Event>")
    assert_equal(#hub.pending_timers("eisy debounced scan"), 1)
  end)

  it("stops refreshing a device's nodes at the first unreachable error", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)
    eisy.up = false
    eisy.requests = {}

    template.capability_handlers.refresh.refresh(hub.driver, hub.child(PORCH_KEY))

    assert_equal(#eisy.requests, 2, "one node, one retry")
  end)
end)

describe("children deleted in SmartThings", function()
  it("are not recreated by automatic scans", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)
    hub.remove(hub.child(PORCH_KEY))

    local removed = hub.controller:get_field("eisy_removed_child_keys")
    assert_truthy(removed and removed[PORCH_KEY], "the deletion must be remembered")
    assert_truthy(hub.controller.persisted.eisy_removed_child_keys, "and persisted")

    hub.created = {}
    template.lifecycle_handlers.init(hub.driver, hub.controller)
    template.capability_handlers.refresh.refresh(hub.driver, hub.controller)
    assert_equal(#hub.created, 0)
    assert_equal(hub.child(PORCH_KEY), nil)
  end)

  it("are restored by the Scan for devices button", function()
    eisy.up = true
    local hub = new_hub()
    start(hub)
    hub.remove(hub.child(PORCH_KEY))

    hub.created = {}
    template.capability_handlers["oftentrust07380.scanfordevices"].scan(hub.driver, hub.controller)

    assert_equal(#hub.created, 1)
    assert_truthy(hub.child(PORCH_KEY))
    assert_equal(count(hub.controller:get_field("eisy_removed_child_keys")), 0)
  end)
end)
