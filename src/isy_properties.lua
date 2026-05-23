local constants = require "isy_constants"

local props = {}

local function xml_unescape(value)
  if not value then return nil end
  return (value:gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", "\"")
    :gsub("&apos;", "'")
    :gsub("&amp;", "&"))
end

local function parse_attrs(raw)
  local attrs = {}
  for key, _, value in tostring(raw or ""):gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
    attrs[key] = xml_unescape(value)
  end
  return attrs
end

local function number_or_string(value)
  local numeric = tonumber(value)
  if numeric ~= nil then return numeric end
  return value
end

function props.new_property(id, value, prec, uom, formatted, address)
  if not id or id == "" then return nil end
  local property = {
    id = id,
    value = number_or_string(value),
    precision = prec ~= nil and tostring(prec) or nil,
    uom = uom ~= nil and tostring(uom) or nil,
    formatted = formatted,
    address = address
  }
  if id == constants.PROP_RAMP_RATE then
    local raw = tonumber(value)
    if raw and constants.INSTEON_RAMP_RATES[raw] ~= nil then
      property.seconds = constants.INSTEON_RAMP_RATES[raw]
    end
  end
  return property
end

function props.parse_property_attrs(raw_attrs, address)
  local attrs = parse_attrs(raw_attrs)
  return props.new_property(attrs.id, attrs.value, attrs.prec, attrs.uom, attrs.formatted, address)
end

function props.parse_properties(block, address)
  local properties = {}
  for raw_attrs in tostring(block or ""):gmatch("<property%s+([^>]-)/>") do
    local property = props.parse_property_attrs(raw_attrs, address)
    if property then properties[property.id] = property end
  end
  return properties
end

function props.parse_xml_properties(block, address)
  local properties = props.parse_properties(block, address)
  local state = properties[constants.PROP_STATUS]
  local state_set = state ~= nil
  if not state and properties[constants.PROP_BATTERY] then
    state = properties[constants.PROP_BATTERY]
  end

  local aux = {}
  for id, property in pairs(properties) do
    if not (state and id == state.id) then aux[id] = property end
  end

  return {
    state = state,
    aux = aux,
    properties = properties,
    state_set = state_set
  }
end

return props
