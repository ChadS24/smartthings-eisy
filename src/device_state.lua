local capabilities = require "st.capabilities"

local state = {}
local keypad_button_status = capabilities["oftentrust07380.keypadbuttonstatus"]

local function component_ref(device, component_id)
  if device.profile and device.profile.components then
    return device.profile.components[component_id] or component_id
  end
  return component_id
end

local function number_value(prop)
  if not prop then return 0 end
  return tonumber(prop.value) or 0
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

function state.emit_component(device, component, kind, properties, component_name)
  local st = properties and properties.ST
  local value = number_value(st)
  component = component or "main"

  if kind == "motion" then
    device:emit_component_event(component_ref(device, component), value > 0 and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive())
  elseif kind == "contact" then
    device:emit_component_event(component_ref(device, component), value > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
  elseif kind == "fan" then
    device:emit_component_event(component_ref(device, component), switch_event(value))
    device:emit_component_event(component_ref(device, component), capabilities.fanSpeed.fanSpeed(fan_speed_from_property(st)))
  elseif kind == "dimmer" then
    device:emit_component_event(component_ref(device, component), switch_event(value))
    device:emit_component_event(component_ref(device, component), capabilities.switchLevel.level(percent_from_property(st)))
  elseif kind == "keypad" and component ~= "main" then
    local status = value > 0 and "on" or "off"
    device:emit_component_event(component_ref(device, component), keypad_button_status.buttonName(component_name or component))
    device:emit_component_event(component_ref(device, component), keypad_button_status.buttonStatus(status))
  elseif kind == "iolinc_sensor" then
    device:emit_component_event(component_ref(device, component), value > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
  else
    device:emit_component_event(component_ref(device, component), switch_event(value))
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

return state
