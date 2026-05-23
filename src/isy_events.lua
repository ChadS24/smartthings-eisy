local constants = require "isy_constants"
local properties = require "isy_properties"

local events = {}

local function xml_unescape(value)
  if not value then return nil end
  return (value:gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", "\"")
    :gsub("&apos;", "'")
    :gsub("&amp;", "&"))
end

local function trim(value)
  if not value then return nil end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function tag_text(block, tag)
  local value = tostring(block or ""):match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
  return xml_unescape(trim(value))
end

local function tag_attrs(block, tag)
  local attrs = tostring(block or ""):match("<" .. tag .. "%s+([^>]*)>") or tostring(block or ""):match("<" .. tag .. "%s+([^>]*)/>")
  return attrs or ""
end

local function event_address(xml)
  return tag_text(xml, "node") or tostring(xml or ""):match("<event[^>]-node=\"(.-)\"")
end

local function event_property(control, xml, address)
  local attrs = tag_attrs(xml, "action")
  return properties.new_property(
    control,
    tag_text(xml, "action"),
    attrs:match("prec%s*=%s*[\"'](.-)[\"']"),
    attrs:match("uom%s*=%s*[\"'](.-)[\"']"),
    tag_text(xml, "fmtAct"),
    address
  )
end

function events.parse_xml(xml)
  xml = tostring(xml or "")
  local control = tag_text(xml, "control")
  local address = event_address(xml)
  local property = control and event_property(control, xml, address) or nil
  return {
    control = control,
    address = address,
    action = tag_text(xml, "action"),
    formatted = tag_text(xml, "fmtAct"),
    property = property,
    raw = xml
  }
end

function events.route(parsed)
  local event = parsed.control and parsed or events.parse_xml(parsed.raw or parsed)
  local control = event.control
  if control == constants.CONTROL_HEARTBEAT then
    return {
      kind = "heartbeat",
      heartbeat_wait = tonumber(event.action),
      raw = event.raw
    }
  end
  if control == constants.CONTROL_NODE_CHANGED then
    return {
      kind = "node_changed",
      address = event.address,
      action = event.action,
      requires_scan = true,
      raw = event.raw
    }
  end
  if control == constants.CONTROL_SYSTEM_STATUS then
    return {
      kind = "system_status",
      action = event.action,
      raw = event.raw
    }
  end
  if control == constants.CONTROL_PROGRESS then
    return {
      kind = "progress",
      address = event.address,
      property = event.property,
      action = event.action,
      raw = event.raw
    }
  end
  if control == constants.CONTROL_SYSTEM_CONFIG then
    return {
      kind = "system_config",
      address = event.address,
      action = event.action,
      requires_scan = false,
      raw = event.raw
    }
  end
  if constants.STATUS_CONTROLS[control] then
    local property = event.property
    if property then property.id = control end
    return {
      kind = "status",
      address = event.address,
      property = property,
      raw = event.raw
    }
  end
  if control and control:sub(1, 1) ~= "_" then
    return {
      kind = "control",
      address = event.address,
      property = event.property,
      raw = event.raw
    }
  end
  return {
    kind = "ignored",
    address = event.address,
    control = control,
    raw = event.raw
  }
end

function events.route_xml(xml)
  return events.route(events.parse_xml(xml))
end

return events
