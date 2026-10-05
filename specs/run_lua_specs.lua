package.path = table.concat({
  "src/?.lua",
  "specs/?.lua",
  package.path
}, ";")

package.preload.cosock = function()
  return {
    asyncify = function(name)
      if name == "socket.http" then
        return {
          request = function() error("HTTP is not available in unit specs") end
        }
      end
      if name == "ssl.https" then
        return {
          request = function() error("HTTPS is not available in unit specs") end
        }
      end
      return {}
    end,
    socket = {
      sleep = function() end
    }
  }
end

package.preload.ltn12 = function()
  return {
    sink = {
      table = function(target)
        return function(chunk)
          if chunk then target[#target + 1] = chunk end
          return 1
        end
      end
    }
  }
end

package.preload.log = function()
  return {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end
  }
end

package.preload["st.capabilities"] = function()
  local capabilities = {}
  local function event(capability_id, attribute_id, value, unit)
    local state = { value = value }
    if unit then state.unit = unit end
    return { capability_id = capability_id, attribute_id = attribute_id, state = state }
  end
  capabilities.switch = {
    ID = "switch",
    switch = {
      on = function() return event("switch", "switch", "on") end,
      off = function() return event("switch", "switch", "off") end
    }
  }
  capabilities.switchLevel = {
    ID = "switchLevel",
    level = function(value) return event("switchLevel", "level", value) end
  }
  capabilities.motionSensor = {
    ID = "motionSensor",
    motion = {
      active = function() return event("motionSensor", "motion", "active") end,
      inactive = function() return event("motionSensor", "motion", "inactive") end
    }
  }
  capabilities.contactSensor = {
    ID = "contactSensor",
    contact = {
      open = function() return event("contactSensor", "contact", "open") end,
      closed = function() return event("contactSensor", "contact", "closed") end
    }
  }
  capabilities.waterSensor = {
    ID = "waterSensor",
    water = {
      wet = function() return event("waterSensor", "water", "wet") end,
      dry = function() return event("waterSensor", "water", "dry") end
    }
  }
  capabilities.battery = {
    ID = "battery",
    battery = function(value) return event("battery", "battery", value) end
  }
  capabilities.fanSpeed = {
    ID = "fanSpeed",
    fanSpeed = function(value) return event("fanSpeed", "fanSpeed", value) end
  }
  capabilities.temperatureMeasurement = {
    ID = "temperatureMeasurement",
    temperature = function(value) return event("temperatureMeasurement", "temperature", value.value, value.unit) end
  }
  capabilities.thermostatMode = {
    ID = "thermostatMode",
    thermostatMode = function(value) return event("thermostatMode", "thermostatMode", value) end,
    supportedThermostatModes = function(value) return event("thermostatMode", "supportedThermostatModes", value) end
  }
  capabilities.thermostatFanMode = {
    ID = "thermostatFanMode",
    thermostatFanMode = function(value) return event("thermostatFanMode", "thermostatFanMode", value) end,
    supportedThermostatFanModes = function(value) return event("thermostatFanMode", "supportedThermostatFanModes", value) end
  }
  capabilities.thermostatOperatingState = {
    ID = "thermostatOperatingState",
    thermostatOperatingState = function(value) return event("thermostatOperatingState", "thermostatOperatingState", value) end
  }
  capabilities.thermostatHeatingSetpoint = {
    ID = "thermostatHeatingSetpoint",
    heatingSetpoint = function(value) return event("thermostatHeatingSetpoint", "heatingSetpoint", value.value, value.unit) end
  }
  capabilities.thermostatCoolingSetpoint = {
    ID = "thermostatCoolingSetpoint",
    coolingSetpoint = function(value) return event("thermostatCoolingSetpoint", "coolingSetpoint", value.value, value.unit) end
  }
  capabilities["oftentrust07380.keypadbuttonstatus"] = {
    ID = "oftentrust07380.keypadbuttonstatus",
    buttonName = function(value) return event("oftentrust07380.keypadbuttonstatus", "buttonName", value) end,
    buttonStatus = function(value) return event("oftentrust07380.keypadbuttonstatus", "buttonStatus", value) end
  }
  return capabilities
end

local failures = 0

local function deep_equal(a, b, path)
  path = path or "value"
  if type(a) ~= type(b) then
    return false, path .. " type expected " .. type(b) .. " got " .. type(a)
  end
  if type(a) ~= "table" then
    if a ~= b then return false, path .. " expected " .. tostring(b) .. " got " .. tostring(a) end
    return true
  end
  for key, expected in pairs(b) do
    local ok, err = deep_equal(a[key], expected, path .. "." .. tostring(key))
    if not ok then return false, err end
  end
  for key, _ in pairs(a) do
    if b[key] == nil then return false, path .. "." .. tostring(key) .. " unexpected" end
  end
  return true
end

function describe(name, fn)
  print(name)
  fn()
end

function it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("  ok - " .. name)
  else
    failures = failures + 1
    print("  not ok - " .. name)
    print("    " .. tostring(err))
  end
end

function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_equal failed") .. ": expected " .. tostring(expected) .. " got " .. tostring(actual), 2)
  end
end

function assert_deep_equal(actual, expected, message)
  local ok, err = deep_equal(actual, expected)
  if not ok then error((message or "assert_deep_equal failed") .. ": " .. err, 2) end
end

function assert_truthy(value, message)
  if not value then error(message or "expected truthy value", 2) end
end

require "pyisy_alignment_spec"
require "review_fixes_spec"

if failures > 0 then
  error(tostring(failures) .. " spec(s) failed")
end

print("All Lua specs passed")
