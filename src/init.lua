local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local EisyClient = require "eisy_client"
local classifier = require "node_classifier"
local device_state = require "device_state"
local ws_subscription = require "ws_subscription"

local CONTROLLER_DNI = "eisy-controller"
local scan_capability = capabilities["oftentrust07380.scanfordevices"]
local handle_child_info_changed

local function controller_opts(device)
  local normalized = EisyClient.normalize_config({
    host = device.preferences.eisyHost,
    protocol = device.preferences.eisyProtocol,
    port = device.preferences.eisyPort
  })
  return {
    host = normalized.host,
    protocol = normalized.protocol,
    port = normalized.port,
    username = device.preferences.eisyUsername,
    password = device.preferences.eisyPassword,
    polling_interval = tonumber(device.preferences.pollingInterval) or 0,
    ignored_nodes = device.preferences.ignoredNodes or ""
  }
end

local function client_for(device)
  local opts = controller_opts(device)
  return EisyClient.new({
    host = opts.host,
    protocol = opts.protocol,
    port = opts.port,
    username = opts.username,
    password = opts.password
  })
end

local function get_controller(driver, device)
  if device.device_network_id == CONTROLLER_DNI then return device end
  for _, candidate in ipairs(driver:get_devices()) do
    if candidate.device_network_id == CONTROLLER_DNI then return candidate end
  end
  return nil
end

local function find_device_by_dni(driver, dni)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == dni then return device end
  end
  return nil
end

local function child_key(eisy_device)
  return "eisy:" .. eisy_device.key:gsub("%s+", "_"):gsub("[^%w%-%._:]", "_")
end

local function device_child_key(device)
  if device.parent_assigned_child_key then return device.parent_assigned_child_key end
  if device.get_parent_assigned_child_key then return device:get_parent_assigned_child_key() end
  return device.device_network_id
end

local function find_child_by_key(driver, key)
  for _, device in ipairs(driver:get_devices()) do
    if device_child_key(device) == key then return device end
  end
  return nil
end

local function emit_child_state(driver, child, eisy_device, statuses)
  if child and eisy_device and statuses then
    device_state.emit_device(driver, child, eisy_device, statuses)
  end
end

local function refresh_child(driver, controller, child)
  local by_key = controller:get_field("eisy_devices_by_key") or {}
  local key = device_child_key(child)
  local eisy_device = by_key[key]
  if not eisy_device then
    log.warn("No eISY mapping found for " .. tostring(key))
    return
  end
  local client = client_for(controller)
  local statuses = {}
  for _, address in pairs(eisy_device.components or {}) do
    local status, err = client:get_node_status(address)
    if status then
      statuses[address] = status
    else
      log.warn("Unable to refresh eISY node " .. tostring(address) .. ": " .. tostring(err))
    end
  end
  emit_child_state(driver, child, eisy_device, statuses)
end

local function refresh_known_statuses(driver, controller)
  local client = client_for(controller)
  local statuses, status_err = client:get_all_status()
  if not statuses then
    log.warn("Unable to fetch eISY status fallback: " .. tostring(status_err))
    return
  end

  local by_key = controller:get_field("eisy_devices_by_key") or {}
  for key, eisy_device in pairs(by_key) do
    emit_child_state(driver, find_child_by_key(driver, key), eisy_device, statuses)
  end
end

local function apply_event_update(driver, controller, event)
  local statuses = EisyClient.event_statuses(event)
  if not statuses then return false end

  local by_address = controller:get_field("eisy_devices_by_address") or {}
  local mapped = by_address[event.address]
  if not mapped then return true end

  local child = find_child_by_key(driver, mapped.child_key)
  if child then
    emit_child_state(driver, child, mapped.device, statuses)
  end
  return true
end

local function scan_eisy(driver, controller)
  local opts = controller_opts(controller)
  if not opts.host or opts.host == "" then
    log.info("eISY host is not configured yet")
    return
  end

  local client = client_for(controller)
  local nodes, nodes_err = client:get_nodes()
  if not nodes then
    log.warn("Unable to fetch eISY nodes: " .. tostring(nodes_err))
    return
  end

  local eisy_devices = classifier.classify_all(nodes, opts.ignored_nodes)
  local by_key = {}
  local by_address = {}
  for _, eisy_device in ipairs(eisy_devices) do
    local key = child_key(eisy_device)
    eisy_device.child_key = key
    by_key[key] = eisy_device
    for component, address in pairs(eisy_device.components or {}) do
      by_address[address] = { child_key = key, component = component, device = eisy_device }
    end

    local child = find_child_by_key(driver, key)
    if not child or eisy_device.kind == "keypad" then
      log.info("Creating eISY child device " .. eisy_device.label .. " as " .. eisy_device.profile)
      driver:try_create_device({
        type = "EDGE_CHILD",
        parent_device_id = controller.id,
        parent_assigned_child_key = key,
        label = eisy_device.label,
        profile = eisy_device.profile,
        manufacturer = "Universal Devices",
        model = "eISY Insteon " .. eisy_device.kind,
        vendor_provided_label = eisy_device.label,
        external_id = eisy_device.key
      })
    elseif child.try_update_metadata then
      local ok, err = pcall(function()
        child:try_update_metadata({
          profile = eisy_device.profile,
          manufacturer = "Universal Devices",
          model = "eISY Insteon " .. eisy_device.kind,
          vendor_provided_label = eisy_device.label
        })
      end)
      if not ok then
        log.warn("Unable to update eISY child metadata for " .. tostring(eisy_device.label) .. ": " .. tostring(err))
      end
    end
  end

  controller:set_field("eisy_devices_by_key", by_key, { persist = true })
  controller:set_field("eisy_devices_by_address", by_address, { persist = true })

  local statuses, status_err = client:get_all_status()
  if statuses then
    for key, eisy_device in pairs(by_key) do
      emit_child_state(driver, find_child_by_key(driver, key), eisy_device, statuses)
    end
  else
    log.warn("Unable to fetch eISY status: " .. tostring(status_err))
  end
end

local function stop_controller_threads(controller)
  local poll_timer = controller:get_field("poll_timer")
  if poll_timer and poll_timer.cancel then poll_timer:cancel() end
  local ws_handle = controller:get_field("ws_handle")
  if ws_handle and ws_handle.cancel then ws_handle.cancel() end
  controller:set_field("poll_timer", nil)
  controller:set_field("ws_handle", nil)
end

local function start_controller_threads(driver, controller)
  stop_controller_threads(controller)
  scan_eisy(driver, controller)

  local opts = controller_opts(controller)
  if not opts.host or opts.host == "" then return end

  local rest_client = client_for(controller)
  local ws_handle
  ws_handle = ws_subscription.start(driver, controller, {
    host = opts.host,
    protocol = opts.protocol,
    port = opts.port,
    auth = rest_client.auth
  }, function(message)
    local event = EisyClient.parse_event(message)
    if event.control == "_0" then
      log.debug("eISY WebSocket heartbeat received")
      return
    end

    if apply_event_update(driver, controller, event) then
      return
    end

    if event.control == "_3" then
      scan_eisy(driver, controller)
    end
  end)
  controller:set_field("ws_handle", ws_handle)

  if opts.polling_interval > 0 then
    local poll_timer = controller.thread:call_on_schedule(opts.polling_interval, function()
      local active_ws = ws_handle and ws_handle.is_connected and ws_handle.is_connected()
      if active_ws then
        log.debug("Skipping eISY polling because WebSocket updates are active")
      else
        refresh_known_statuses(driver, controller)
      end
    end, "eisy status fallback")
    controller:set_field("poll_timer", poll_timer)
  end
end

local function discovery_handler(driver, _, should_continue)
  if should_continue and not should_continue() then return end
  if find_device_by_dni(driver, CONTROLLER_DNI) then return end
  driver:try_create_device({
    type = "LAN",
    device_network_id = CONTROLLER_DNI,
    label = "eISY Controller",
    profile = "eisy-controller",
    manufacturer = "Universal Devices",
    model = "eISY / IoX",
    vendor_provided_label = "eISY Controller"
  })
end

local function added_handler(driver, device)
  if device.device_network_id == CONTROLLER_DNI then
    start_controller_threads(driver, device)
  else
    local controller = get_controller(driver, device)
    if controller then refresh_child(driver, controller, device) end
  end
end

local function init_handler(driver, device)
  if device.device_network_id == CONTROLLER_DNI then
    start_controller_threads(driver, device)
  end
end

local function removed_handler(_, device)
  if device.device_network_id == CONTROLLER_DNI then
    stop_controller_threads(device)
  end
end

local function info_changed_handler(driver, device, _, args)
  if device.device_network_id ~= CONTROLLER_DNI then
    if handle_child_info_changed then handle_child_info_changed(driver, device, args) end
    return
  end
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  local prefs = device.preferences
  if old.eisyHost ~= prefs.eisyHost
      or old.eisyProtocol ~= prefs.eisyProtocol
      or old.eisyPort ~= prefs.eisyPort
      or old.eisyUsername ~= prefs.eisyUsername
      or old.eisyPassword ~= prefs.eisyPassword
      or old.pollingInterval ~= prefs.pollingInterval
      or old.ignoredNodes ~= prefs.ignoredNodes then
    start_controller_threads(driver, device)
  end
end

local function command_address(controller, device, component)
  local by_key = controller:get_field("eisy_devices_by_key") or {}
  local eisy_device = by_key[device_child_key(device)]
  if not eisy_device then return nil, nil end
  return (eisy_device.components or {})[component or "main"], eisy_device
end

local function preference_changed(old, prefs, name)
  if not old or old[name] == nil then return false end
  return tostring(old[name]) ~= tostring(prefs[name])
end

local function bounded_integer(value, minimum, maximum)
  local number = tonumber(value)
  if not number then return nil end
  number = math.floor(number)
  if number < minimum or number > maximum then return nil end
  return number
end

local function send_device_command(driver, device, eisy_command, params)
  local controller = get_controller(driver, device)
  if not controller then return false end
  local address = command_address(controller, device, "main")
  if not address then
    log.warn("No eISY node address for preference command on " .. tostring(device.device_network_id))
    return false
  end
  local client = client_for(controller)
  local _, err = client:command(address, eisy_command, params)
  if err then
    log.warn("eISY preference command failed: " .. tostring(err))
    return false
  end
  refresh_child(driver, controller, device)
  return true
end

handle_child_info_changed = function(driver, device, args)
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  local prefs = device.preferences or {}
  if prefs.dimmerOnLevel == nil and prefs.dimmerRampRate == nil then return end

  if preference_changed(old, prefs, "dimmerOnLevel") then
    local on_level = bounded_integer(prefs.dimmerOnLevel, 0, 255)
    if on_level then
      log.info("Setting Insteon dimmer on level to " .. tostring(on_level))
      send_device_command(driver, device, "OL", { on_level })
    else
      log.warn("Invalid Insteon dimmer on level: " .. tostring(prefs.dimmerOnLevel))
    end
  end

  if preference_changed(old, prefs, "dimmerRampRate") then
    local ramp_rate = bounded_integer(prefs.dimmerRampRate, 0, 31)
    if ramp_rate then
      log.info("Setting Insteon dimmer ramp rate to " .. tostring(ramp_rate))
      send_device_command(driver, device, "RR", { ramp_rate })
    else
      log.warn("Invalid Insteon dimmer ramp rate: " .. tostring(prefs.dimmerRampRate))
    end
  end
end

local function send_command_and_refresh(driver, device, command, params)
  local controller = get_controller(driver, device)
  if not controller then return end
  local address = command_address(controller, device, command.component)
  if not address then
    log.warn("No eISY node address for command on " .. tostring(device.device_network_id))
    return
  end
  local client = client_for(controller)
  local _, err = client:command(address, command.eisy_command, params)
  if err then
    log.warn("eISY command failed: " .. tostring(err))
    return
  end
  refresh_child(driver, controller, device)
end

local function switch_on(driver, device, command)
  command.eisy_command = "DON"
  local controller = get_controller(driver, device)
  local eisy_device
  if controller then
    local _
    _, eisy_device = command_address(controller, device, command.component)
  end
  if eisy_device and eisy_device.kind == "fan" then
    send_command_and_refresh(driver, device, command, { device_state.fan_speed_to_insteon("high") })
  else
    send_command_and_refresh(driver, device, command, {})
  end
end

local function switch_off(driver, device, command)
  command.eisy_command = "DOF"
  send_command_and_refresh(driver, device, command, {})
end

local function set_level(driver, device, command)
  command.eisy_command = "DON"
  local level = command.args and command.args.level or command.positional_args and command.positional_args[1] or 100
  send_command_and_refresh(driver, device, command, { device_state.level_to_insteon(level) })
end

local function set_fan_speed(driver, device, command)
  local speed = command.args and (command.args.fanSpeed or command.args.speed) or command.positional_args and command.positional_args[1] or "high"
  local insteon_speed = device_state.fan_speed_to_insteon(speed)
  if insteon_speed <= 0 then
    command.eisy_command = "DOF"
    send_command_and_refresh(driver, device, command, {})
  else
    command.eisy_command = "DON"
    send_command_and_refresh(driver, device, command, { insteon_speed })
  end
end

local function refresh_handler(driver, device)
  if device.device_network_id == CONTROLLER_DNI then
    scan_eisy(driver, device)
  else
    local controller = get_controller(driver, device)
    if controller then refresh_child(driver, controller, device) end
  end
end

local function scan_button_handler(driver, device)
  if device.device_network_id == CONTROLLER_DNI then
    scan_eisy(driver, device)
    return
  end

  local controller = get_controller(driver, device)
  if controller then scan_eisy(driver, controller) end
end

local eisy_driver = Driver("eisy-insteon", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = added_handler,
    init = init_handler,
    removed = removed_handler,
    infoChanged = info_changed_handler
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = set_fan_speed
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    },
    [scan_capability.ID] = {
      [scan_capability.commands.scan.NAME] = scan_button_handler
    }
  }
})

eisy_driver:run()
