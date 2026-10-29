-- Loads the real driver (src/init.lua) against a fake hub runtime and a fake eISY
-- at the HTTP layer. Child devices get their components and capabilities from the
-- real profiles/*.yaml, so an event the profile does not declare is dropped just
-- as it is on a hub.

local harness = {}

-- The components of a profile and the capabilities of each, from its YAML.
local function load_profile(name)
  local file = io.open("profiles/" .. name .. ".yaml", "r")
  if not file then error("no profile " .. tostring(name)) end
  local components = {}
  local current
  for line in file:lines() do
    local component = line:match("^  %- id: (%S+)")
    local capability = line:match("^      %- id: (%S+)")
    if component then
      current = { id = component, capabilities = {} }
      components[component] = current
    elseif capability and current then
      current.capabilities[#current.capabilities + 1] = capability
    end
  end
  file:close()
  return { components = components }
end
harness.load_profile = load_profile

local function with_commands(cap, id, commands)
  cap = cap or {}
  cap.ID = cap.ID or id
  cap.commands = {}
  for _, command in ipairs(commands) do cap.commands[command] = { NAME = command } end
  return cap
end

function harness.load_driver(routes, preferences)
  local requests = {}
  local fake_http = {
    request = function(req)
      local path = req.url:gsub("^https?://[^/]+", "")
      requests[#requests + 1] = path
      local body = routes[path]
      if type(body) == "function" then body = body() end
      if not body then return 1, 404, {}, "Not Found" end
      req.sink(body)
      return 1, 200, {}, "OK"
    end
  }
  local fake_cosock = {
    asyncify = function(name)
      if name == "socket.http" then return fake_http end
      error("unavailable")
    end,
    socket = { sleep = function() end }
  }

  local driver
  local ws_callback
  local ws_status
  local saved = {}
  local function stub(name, value)
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end

  local capabilities = require "st.capabilities"
  capabilities.switch = with_commands(capabilities.switch, "switch", { "on", "off" })
  capabilities.switchLevel = with_commands(capabilities.switchLevel, "switchLevel", { "setLevel" })
  capabilities.fanSpeed = with_commands(capabilities.fanSpeed, "fanSpeed", { "setFanSpeed" })
  capabilities.thermostatMode = with_commands(capabilities.thermostatMode, "thermostatMode", { "setThermostatMode" })
  capabilities.thermostatFanMode = with_commands(capabilities.thermostatFanMode, "thermostatFanMode", { "setThermostatFanMode" })
  capabilities.thermostatHeatingSetpoint = with_commands(capabilities.thermostatHeatingSetpoint, "thermostatHeatingSetpoint", { "setHeatingSetpoint" })
  capabilities.thermostatCoolingSetpoint = with_commands(capabilities.thermostatCoolingSetpoint, "thermostatCoolingSetpoint", { "setCoolingSetpoint" })
  capabilities.refresh = with_commands(capabilities.refresh, "refresh", { "refresh" })
  capabilities["oftentrust07380.scanfordevices"] = with_commands(nil, "oftentrust07380.scanfordevices", { "scan" })

  stub("cosock", fake_cosock)
  stub("eisy_client", nil)
  stub("init", nil)
  stub("ws_subscription", {
    start = function(_, _, opts, on_message)
      ws_callback = on_message
      ws_status = opts.on_status
      return { cancel = function() end }
    end
  })
  stub("st.driver", function(name, template)
    driver = { name = name, template = template, devices = {} }
    function driver:get_devices() return self.devices end
    function driver:run() end
    return driver
  end)

  require "init"

  for name, value in pairs(saved) do package.loaded[name] = value end
  package.loaded.init = nil
  package.loaded.eisy_client = nil

  local timers = {}
  local function new_device(fields, profile)
    local device = fields
    device.fields = {}
    device.events = {}
    device.health = {}
    device.profile = profile
    device.thread = {
      call_with_delay = function(_, delay, fn) timers[#timers + 1] = { delay = delay, fn = fn }; return fn end,
      cancel_timer = function(_, timer)
        for index, pending in ipairs(timers) do
          if pending.fn == timer then table.remove(timers, index) return end
        end
      end
    }
    function device:get_field(key) return self.fields[key] end
    function device:set_field(key, value) self.fields[key] = value end
    function device:emit_component_event(component, event)
      event.component = component.id
      self.events[#self.events + 1] = event
    end
    function device:try_update_metadata(metadata)
      self.metadata = metadata
      if metadata.profile then self.profile = load_profile(metadata.profile) end
    end
    function device:online() self.health[#self.health + 1] = "online" end
    function device:offline() self.health[#self.health + 1] = "offline" end
    driver.devices[#driver.devices + 1] = device
    return device
  end

  function driver:try_create_device(info)
    new_device({
      id = "child-" .. info.parent_assigned_child_key,
      parent_assigned_child_key = info.parent_assigned_child_key,
      created = info
    }, load_profile(info.profile))
  end

  local prefs = { eisyHost = "192.0.2.10", eisyProtocol = "http", eisyPort = 80, sceneIds = "" }
  for key, value in pairs(preferences or {}) do prefs[key] = value end
  local controller = new_device({
    id = "controller",
    device_network_id = "eisy-controller",
    preferences = prefs
  }, load_profile("eisy-controller"))

  local env = {
    driver = driver,
    controller = controller,
    requests = requests,
    routes = routes,
    template = driver.template,
    ws_message = function(xml) ws_callback(xml) end,
    ws_status = function(status) ws_status(status) end,
    pending_timers = function() return #timers end
  }

  -- Run the timers due within `seconds` (all of them when omitted).
  function env.run_timers(seconds)
    local pending = timers
    timers = {}
    for _, timer in ipairs(pending) do
      if seconds == nil or (timer.delay or 0) <= seconds then
        timer.fn()
      else
        timers[#timers + 1] = timer
      end
    end
  end

  function env.child(key)
    for _, device in ipairs(driver.devices) do
      if device.parent_assigned_child_key == key then return device end
    end
  end

  function env.start()
    driver.template.lifecycle_handlers.init(driver, controller)
    return env
  end

  return env
end

-- The last value of a capability attribute emitted on a component.
function harness.last_value(device, capability, attribute, component)
  for index = #device.events, 1, -1 do
    local event = device.events[index]
    if event.capability_id == capability and (attribute == nil or event.attribute_id == attribute)
        and (component == nil or event.component == component) then
      return event.state.value
    end
  end
end

function harness.last_health(device)
  return device.health[#device.health]
end

function harness.control_event(address, control, action)
  return '<Event seqnum="1" sid="uuid:1"><control>' .. control .. '</control><action>' .. tostring(action or 0)
      .. '</action><node>' .. address .. '</node><eventInfo></eventInfo></Event>'
end

function harness.status_event(address, value, control)
  return '<Event seqnum="1" sid="uuid:1"><control>' .. (control or "ST") .. '</control><action uom="100" prec="0">' .. tostring(value)
      .. '</action><node>' .. address .. '</node><eventInfo></eventInfo><fmtAct>x</fmtAct></Event>'
end

return harness
