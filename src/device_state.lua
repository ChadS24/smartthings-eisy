local capabilities = require "st.capabilities"
local isy_constants = require "isy_constants"

local state = {}
local keypad_button_status = capabilities["oftentrust07380.keypadbuttonstatus"]

-- Insteon button commands, as SmartThings button values. On and off are up and
-- down so automations can tell them apart; a hold is a fade (BMAN on older
-- firmware, which does not say which way).
local BUTTON_VALUES = {
  DON = "up",
  DOF = "down",
  DFON = "up_2x",
  DFOF = "down_2x",
  FDUP = "up_hold",
  FDDOWN = "down_hold",
  BMAN = "held"
}
local SUPPORTED_BUTTON_VALUES = { "up", "down", "up_2x", "down_2x", "up_hold", "down_hold", "held" }
local BUTTON_KINDS = { keypad = true, remote = true }

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

local UOM_CELSIUS = "4"
local UOM_FAHRENHEIT = "17"
local UOM_HALF_DEGREES = "101"
-- SmartThings thermostat drivers treat setpoint arguments at or above this value as
-- Fahrenheit and anything below it as Celsius.
local FAHRENHEIT_SETPOINT_THRESHOLD = 40

local function precision_digits(prop)
  local prec = tonumber(prop and prop.precision)
  if prec and prec > 0 then return math.floor(prec) end
  return 0
end

local function thermostat_temperature(prop)
  local raw = tonumber(prop and prop.value)
  if not raw then
    -- The formatted text is already in display units.
    return optional_number(prop)
  end
  local value = raw / (10 ^ precision_digits(prop))
  local uom = tostring(prop.uom or "")
  if uom == UOM_HALF_DEGREES or (uom == "" and value > 130) then
    value = value / 2
  end
  return value
end

local function temperature_unit_of(prop)
  if not prop then return nil end
  local uom = tostring(prop.uom or "")
  if uom == UOM_CELSIUS then return "C" end
  if uom == UOM_FAHRENHEIT then return "F" end
  local formatted = tostring(prop.formatted or "")
  if formatted:match("C%s*$") then return "C" end
  if formatted:match("F%s*$") then return "F" end
  return nil
end

--- The temperature scale a thermostat reports in, from the first of its temperature
--- properties that identifies one. Defaults to Fahrenheit.
function state.thermostat_unit(...)
  for index = 1, select("#", ...) do
    local unit = temperature_unit_of(select(index, ...))
    if unit then return unit end
  end
  return "F"
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

local function battery_percent(prop)
  local value = optional_number(prop)
  if not value then return nil end
  return math.max(0, math.min(100, math.floor(value + 0.5)))
end

local function emit_optional_battery(device, component, properties)
  local battery = battery_percent(properties and properties.BATLVL)
  if battery then
    emit_event(device, component, capabilities.battery.ID, capabilities.battery.battery(battery))
  end
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
  local mapped = isy_constants.THERMOSTAT_MODES[value]
  if mapped == "program auto" then return "auto" end
  if mapped == "program heat" then return "heat" end
  if mapped == "program cool" then return "cool" end
  if mapped then return mapped end
  if value == 0 then return "off" end
  if value == 1 then return "heat" end
  if value == 2 then return "cool" end
  if value == 3 then return "auto" end
  return nil
end

local function thermostat_operating_state(prop)
  local formatted = tostring(prop and prop.formatted or ""):lower()
  if formatted:find("pending heat", 1, true) then return "pending heat" end
  if formatted:find("pending cool", 1, true) then return "pending cool" end
  if formatted:find("vent", 1, true) then return "vent economizer" end
  if formatted:find("heat", 1, true) then return "heating" end
  if formatted:find("cool", 1, true) then return "cooling" end
  if formatted:find("fan", 1, true) then return "fan only" end
  if formatted:find("idle", 1, true) or formatted:find("off", 1, true) then return "idle" end

  local value = tonumber(prop and prop.value)
  if not value then return nil end
  if isy_constants.THERMOSTAT_OPERATING_STATES[value] then
    return isy_constants.THERMOSTAT_OPERATING_STATES[value]
  end
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
  if isy_constants.THERMOSTAT_FAN_MODES[value] then
    return isy_constants.THERMOSTAT_FAN_MODES[value]
  end
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
    emit_optional_battery(device, component, properties)
  elseif kind == "contact" then
    emit_event(device, component, capabilities.contactSensor.ID, value > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
    emit_optional_battery(device, component, properties)
  elseif kind == "water" then
    -- No ST means the state is unknown; keep the last reported state.
    if st then
      emit_event(device, component, capabilities.waterSensor.ID, value > 0 and capabilities.waterSensor.water.wet() or capabilities.waterSensor.water.dry())
    end
    emit_optional_battery(device, component, properties)
  elseif kind == "thermostat" then
    emit_event(device, component, capabilities.thermostatMode.ID, capabilities.thermostatMode.supportedThermostatModes({ "off", "heat", "cool", "auto" }))
    emit_event(device, component, capabilities.thermostatFanMode.ID, capabilities.thermostatFanMode.supportedThermostatFanModes({ "auto", "on" }))

    local unit = state.thermostat_unit(st, properties and properties.CLISPH, properties and properties.CLISPC)
    local temp = thermostat_temperature(st)
    temp = temp or latest_number(device, component, capabilities.temperatureMeasurement, "temperatureMeasurement", "temperature")
    if temp then emit_event(device, component, capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature({ value = temp, unit = unit })) end
    local heat = thermostat_temperature(properties and properties.CLISPH)
    heat = heat or latest_number(device, component, capabilities.thermostatHeatingSetpoint, "thermostatHeatingSetpoint", "heatingSetpoint")
    if heat then emit_event(device, component, capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = heat, unit = unit })) end
    local cool = thermostat_temperature(properties and properties.CLISPC)
    cool = cool or latest_number(device, component, capabilities.thermostatCoolingSetpoint, "thermostatCoolingSetpoint", "coolingSetpoint")
    if cool then emit_event(device, component, capabilities.thermostatCoolingSetpoint.ID, capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = cool, unit = unit })) end
    local mode = thermostat_mode(properties and properties.CLIMD)
    mode = mode or latest_string(device, component, capabilities.thermostatMode, "thermostatMode", "thermostatMode")
    if mode then emit_event(device, component, capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode(mode)) end
    local operating_state = thermostat_operating_state(properties and properties.CLIHCS)
        or inferred_thermostat_operating_state(mode, temp, heat, cool)
    emit_event(device, component, capabilities.thermostatOperatingState.ID, capabilities.thermostatOperatingState.thermostatOperatingState(operating_state))
    local fan_mode = thermostat_fan_mode(properties and properties.CLIFS)
    if fan_mode then emit_event(device, component, capabilities.thermostatFanMode.ID, capabilities.thermostatFanMode.thermostatFanMode(fan_mode)) end
    local humidity = optional_number(properties and properties.CLIHUM)
    if humidity then
      humidity = math.max(0, math.min(100, math.floor(humidity + 0.5)))
      emit_event(device, component, capabilities.relativeHumidityMeasurement.ID, capabilities.relativeHumidityMeasurement.humidity(humidity))
    end
  elseif kind == "fan" then
    emit_event(device, component, capabilities.switch.ID, switch_event(value))
    emit_event(device, component, capabilities.fanSpeed.ID, capabilities.fanSpeed.fanSpeed(fan_speed_from_property(st)))
  elseif kind == "dimmer" then
    emit_event(device, component, capabilities.switch.ID, switch_event(value))
    emit_event(device, component, capabilities.switchLevel.ID, capabilities.switchLevel.level(percent_from_property(st)))
  elseif kind == "remote" then
    -- Remotes have no status, only button presses.
    return
  elseif kind == "keypad" and component == "main" then
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

--- Leak state implied by a command event from one of a leak sensor's nodes.
---
--- The Dry node sends DON when the sensor dries out (and DOF when it gets wet, on
--- some configurations); the Wet node sends DON when a leak is detected.
---
--- @param role string "dry" or "wet"
--- @param control string the event's control, e.g. "DON"
--- @return string|nil "wet", "dry", or nil when the event says nothing about the state
function state.leak_state_from_control(role, control)
  if role == "dry" then
    if control == "DON" then return "dry" end
    if control == "DOF" then return "wet" end
  elseif role == "wet" then
    if control == "DON" then return "wet" end
  end
  return nil
end

--- Leak state implied by the Dry and Wet nodes' ST values.
---
--- Only usable before any command event has been seen: both nodes can be On at
--- the same time, so equal values are ambiguous and return nil.
function state.leak_state_from_status(dry_properties, wet_properties)
  local dry_value = dry_properties and dry_properties.ST and tonumber(dry_properties.ST.value)
  if dry_value == nil then return nil end
  local dry_on = dry_value > 0
  local wet_value = wet_properties and wet_properties.ST and tonumber(wet_properties.ST.value)
  if wet_value ~= nil and (wet_value > 0) == dry_on then return nil end
  return dry_on and "dry" or "wet"
end

--- Properties for a leak sensor's main component, with ST replaced by the
--- resolved leak state (removed when the state is unknown).
function state.leak_properties(dry_properties, leak_state)
  local properties = {}
  for id, prop in pairs(dry_properties or {}) do properties[id] = prop end
  if leak_state == "wet" then
    properties.ST = { id = "ST", value = 1 }
  elseif leak_state == "dry" then
    properties.ST = { id = "ST", value = 0 }
  else
    properties.ST = nil
  end
  return properties
end

--- The SmartThings button value for an Insteon command, or nil if it is not a press.
function state.button_value(control)
  return BUTTON_VALUES[control]
end

--- Emit a button press on a keypad or remote component.
function state.emit_button(device, component, control)
  if not device then return false end
  local value = BUTTON_VALUES[control]
  local attribute = value and capabilities.button.button[value]
  if not attribute then return false end
  -- state_change so that pressing the same button twice fires twice.
  emit_event(device, component or "main", capabilities.button.ID, attribute({ state_change = true }))
  return true
end

local function emit_button_setup(device, eisy_device)
  if not BUTTON_KINDS[eisy_device.kind] then return end
  for component in pairs(eisy_device.components or {}) do
    emit_event(device, component, capabilities.button.ID, capabilities.button.numberOfButtons({ value = 1 }, { visibility = { displayed = false } }))
    emit_event(device, component, capabilities.button.ID, capabilities.button.supportedButtonValues(SUPPORTED_BUTTON_VALUES, { visibility = { displayed = false } }))
  end
end

function state.emit_device(driver, device, eisy_device, statuses)
  if not eisy_device then return end
  emit_button_setup(device, eisy_device)
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

--- Encode a SmartThings setpoint for an eISY setpoint command.
---
--- @param value number|table the SmartThings setpoint argument
--- @param setpoint_prop table|nil the cached CLISPH/CLISPC property (uom, precision)
--- @param status_prop table|nil the cached ST property, used when the setpoint lacks a scale
--- @return number|nil the value to send, in the setpoint property's encoding
function state.thermostat_setpoint_to_insteon(value, setpoint_prop, status_prop)
  local numeric = tonumber(type(value) == "table" and value.value or value)
  if not numeric then return nil end

  local command_unit = numeric >= FAHRENHEIT_SETPOINT_THRESHOLD and "F" or "C"
  local device_unit = state.thermostat_unit(setpoint_prop, status_prop)
  if command_unit == "C" and device_unit == "F" then
    numeric = (numeric * 9 / 5) + 32
  elseif command_unit == "F" and device_unit == "C" then
    numeric = (numeric - 32) * 5 / 9
  end

  local encoding = setpoint_prop or status_prop
  local uom = tostring(encoding and encoding.uom or "")
  if uom == UOM_HALF_DEGREES or uom == "" then
    -- Insteon thermostats report and accept setpoints in half degrees. With no
    -- cached uom, keep the historical half-degree encoding.
    numeric = numeric * 2
  else
    numeric = numeric * (10 ^ precision_digits(encoding))
  end
  return math.floor(numeric + 0.5)
end

return state
