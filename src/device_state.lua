local capabilities = require "st.capabilities"

local state = {}
local keypad_button_status = capabilities["oftentrust07380.keypadbuttonstatus"]

local function component_ref(device, component_id)
  component_id = component_id or "main"
  local components = device.profile and device.profile.components
  if not components then return nil end

  local direct = components[component_id]
  if direct then return direct end

  for _, component in pairs(components) do
    if type(component) == "table" and component.id == component_id then
      return component
    end
  end
  return nil
end

local function component_supports(component, capability_id)
  if not component or not capability_id then return false end
  if not component.capabilities then return true end

  for key, capability in pairs(component.capabilities) do
    if key == capability_id then return true end
    if type(capability) == "string" and capability == capability_id then return true end
    if type(capability) == "table" and (capability.id == capability_id or capability.ID == capability_id) then
      return true
    end
  end
  return false
end

local function emit_event(device, component_id, capability_id, event)
  local component = component_ref(device, component_id)
  if not component or not component_supports(component, capability_id) then return end
  device:emit_component_event(component, event)
end

local function cap_id(capability, fallback)
  return capability and capability.ID or fallback
end

local function latest_state(device, component, capability, capability_id, attribute, default)
  if not device or not device.get_latest_state then return default end
  local ok, value = pcall(function()
    return device:get_latest_state(component or "main", cap_id(capability, capability_id), attribute, default)
  end)
  if ok and value ~= nil then return value end
  return default
end

local function latest_number(device, component, capability, capability_id, attribute)
  local value = latest_state(device, component, capability, capability_id, attribute)
  if type(value) == "table" then value = value.value end
  return tonumber(value)
end

local function latest_string(device, component, capability, capability_id, attribute)
  local value = latest_state(device, component, capability, capability_id, attribute)
  if type(value) == "table" then value = value.value end
  return value and tostring(value) or nil
end

local function number_value(prop)
  if not prop then return 0 end
  return tonumber(prop.value) or 0
end

local function optional_number(prop)
  if not prop then return nil end
  local value = tonumber(prop.value)
  if value then return value end
  local formatted = tostring(prop.formatted or ""):match("%-?%d+%.?%d*")
  return tonumber(formatted)
end

local function thermostat_temperature(prop)
  local value = optional_number(prop)
  if not value then return nil end
  if tostring(prop.uom or "") == "101" or value > 130 then
    value = value / 2
  end
  return value
end

local function percent_from_property(prop)
  if not prop then return 0 end
  local formatted_percent = tostring(prop.formatted or ""):match("(%d+)%s*%%")
  if formatted_percent then
    return math.max(0, math.min(100, tonumber(formatted_percent) or 0))
  end

  local value = tonumber(prop.value) or 0
  if tostring(prop.uom or "") == "100" or value > 100 then
    return math.max(0, math.min(100, math.floor((value / 255) * 100 + 0.5)))
  end
  return math.max(0, math.min(100, math.floor(value + 0.5)))
end

local function switch_event(value)
  return value > 0 and capabilities.switch.switch.on() or capabilities.switch.switch.off()
end

local function fan_speed_number(value)
  value = tonumber(value) or 0
  if value <= 0 then return 0 end
  if value <= 85 then return 1 end
  if value <= 170 then return 2 end
  return 3
end

local function fan_speed_from_property(prop)
  local formatted = tostring(prop and prop.formatted or ""):lower()
  if formatted:find("off", 1, true) then return 0 end
  if formatted:find("low", 1, true) or formatted:find("slow", 1, true) then return 1 end
  if formatted:find("medium", 1, true) or formatted:find("med", 1, true) then return 2 end
  if formatted:find("high", 1, true) or formatted:find("fast", 1, true) then return 3 end
  return fan_speed_number(prop and prop.value)
end

local function thermostat_mode(prop)
  local formatted = tostring(prop and prop.formatted or ""):lower()
  if formatted:find("off", 1, true) then return "off" end
  if formatted:find("heat", 1, true) then return "heat" end
  if formatted:find("cool", 1, true) then return "cool" end
  if formatted:find("auto", 1, true) then return "auto" end

  local value = tonumber(prop and prop.value)
  if value == 0 then return "off" end
  if value == 1 then return "heat" end
  if value == 2 then return "cool" end
  if value == 3 then return "auto" end
  return nil
end

local function thermostat_operating_state(prop)
  local formatted = tostring(prop and prop.formatted or ""):lower()
  if formatted:find("heat", 1, true) then return "heating" end
  if formatted:find("cool", 1, true) then return "cooling" end
  if formatted:find("fan", 1, true) then return "fan only" end
  if formatted:find("idle", 1, true) or formatted:find("off", 1, true) then return "idle" end

  local value = tonumber(prop and prop.value)
  if not value then return nil end
  if value == 0 then return "idle" end
  if value == 1 then return "heating" end
  if value == 2 then return "cooling" end
  if value == 3 then return "fan only" end
  return nil
end

local function inferred_thermostat_operating_state(mode, temp, heat, cool)
  if mode == "off" then return "idle" end
  if temp and mode == "cool" and cool and temp > cool then return "cooling" end
  if temp and mode == "heat" and heat and temp < heat then return "heating" end
  if temp and mode == "auto" then
    if cool and temp > cool then return "cooling" end
    if heat and temp < heat then return "heating" end
  end
  return "idle"
end

local function thermostat_fan_mode(prop)
  local formatted = tostring(prop and prop.formatted or ""):lower()
  if formatted:find("on", 1, true) then return "on" end
  if formatted:find("auto", 1, true) then return "auto" end

  local value = tonumber(prop and prop.value)
  if value == 7 or value == 1 then return "on" end
  if value == 8 or value == 0 then return "auto" end
  return nil
end

function state.emit_component(device, component, kind, properties, component_name)
  local st = properties and properties.ST
  local value = number_value(st)
  component = component or "main"

  if kind == "motion" then
    emit_event(device, component, capabilities.motionSensor.ID, value > 0 and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive())
  elseif kind == "contact" then
    emit_event(device, component, capabilities.contactSensor.ID, value > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
  elseif kind == "water" then
    emit_event(device, component, capabilities.waterSensor.ID, value > 0 and capabilities.waterSensor.water.wet() or capabilities.waterSensor.water.dry())
  elseif kind == "thermostat" then
    emit_event(device, component, capabilities.thermostatMode.ID, capabilities.thermostatMode.supportedThermostatModes({ "off", "heat", "cool", "auto" }))
    emit_event(device, component, capabilities.thermostatFanMode.ID, capabilities.thermostatFanMode.supportedThermostatFanModes({ "auto", "on" }))

    local temp = thermostat_temperature(st)
    temp = temp or latest_number(device, component, capabilities.temperatureMeasurement, "temperatureMeasurement", "temperature")
    if temp then emit_event(device, component, capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature({ value = temp, unit = "F" })) end
    local heat = thermostat_temperature(properties and properties.CLISPH)
    heat = heat or latest_number(device, component, capabilities.thermostatHeatingSetpoint, "thermostatHeatingSetpoint", "heatingSetpoint")
    if heat then emit_event(device, component, capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = heat, unit = "F" })) end
    local cool = thermostat_temperature(properties and properties.CLISPC)
    cool = cool or latest_number(device, component, capabilities.thermostatCoolingSetpoint, "thermostatCoolingSetpoint", "coolingSetpoint")
    if cool then emit_event(device, component, capabilities.thermostatCoolingSetpoint.ID, capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = cool, unit = "F" })) end
    local mode = thermostat_mode(properties and properties.CLIMD)
    mode = mode or latest_string(device, component, capabilities.thermostatMode, "thermostatMode", "thermostatMode")
    if mode then emit_event(device, component, capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode(mode)) end
    local operating_state = thermostat_operating_state(properties and properties.CLIHCS)
        or inferred_thermostat_operating_state(mode, temp, heat, cool)
    emit_event(device, component, capabilities.thermostatOperatingState.ID, capabilities.thermostatOperatingState.thermostatOperatingState(operating_state))
    local fan_mode = thermostat_fan_mode(properties and properties.CLIFS)
    if fan_mode then emit_event(device, component, capabilities.thermostatFanMode.ID, capabilities.thermostatFanMode.thermostatFanMode(fan_mode)) end
  elseif kind == "fan" then
    emit_event(device, component, capabilities.switch.ID, switch_event(value))
    emit_event(device, component, capabilities.fanSpeed.ID, capabilities.fanSpeed.fanSpeed(fan_speed_from_property(st)))
  elseif kind == "dimmer" then
    emit_event(device, component, capabilities.switch.ID, switch_event(value))
    emit_event(device, component, capabilities.switchLevel.ID, capabilities.switchLevel.level(percent_from_property(st)))
  elseif kind == "keypad" and component ~= "main" then
    local status = value > 0 and "on" or "off"
    emit_event(device, component, keypad_button_status.ID, keypad_button_status.buttonName(component_name or component))
    emit_event(device, component, keypad_button_status.ID, keypad_button_status.buttonStatus(status))
  elseif kind == "iolinc_sensor" then
    emit_event(device, component, capabilities.contactSensor.ID, value > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
  else
    emit_event(device, component, capabilities.switch.ID, switch_event(value))
  end
end

function state.emit_device(driver, device, eisy_device, statuses)
  if not eisy_device then return end
  for component, address in pairs(eisy_device.components or {}) do
    local component_kind = eisy_device.kind
    if eisy_device.kind == "iolinc" and component == "sensor" then
      component_kind = "iolinc_sensor"
    end
    state.emit_component(device, component, component_kind, statuses[address] or {}, eisy_device.component_names and eisy_device.component_names[component])
  end
end

function state.level_to_insteon(level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  return math.floor((level / 100) * 255 + 0.5)
end

function state.fan_speed_to_insteon(speed)
  if type(speed) == "table" then speed = speed.value or speed.speed or speed.fanSpeed end
  local normalized = tostring(speed or ""):lower()
  if normalized == "off" then return 0 end
  if normalized == "low" then return 64 end
  if normalized == "medium" then return 191 end
  if normalized == "high" or normalized == "max" then return 255 end
  local numeric = tonumber(speed)
  if numeric then
    if numeric <= 0 then return 0 end
    if numeric <= 4 then
      if numeric == 1 then return 64 end
      if numeric == 2 then return 191 end
      return 255
    end
    if numeric <= 33 then return 64 end
    if numeric <= 66 then return 191 end
    return 255
  end
  return 255
end

function state.thermostat_setpoint_to_insteon(value)
  local numeric = tonumber(type(value) == "table" and value.value or value)
  if not numeric then return nil end
  if numeric <= 45 then
    numeric = (numeric * 9 / 5) + 32
  end
  return math.floor((numeric * 2) + 0.5)
end

return state
