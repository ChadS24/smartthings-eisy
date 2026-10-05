-- eISY scenes (ISY "groups"). Scenes are opted into by id from the controller's
-- sceneIds preference and exposed as switches. Like PyISY's Group, a scene has no
-- status of its own on the eISY: it is on while any of its members is on.

local scene = {}

local LINK_TYPE_CONTROLLER = "16"
local ON_VALUE = 255

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

--- Scene ids from the comma-separated sceneIds preference, in order, without
--- blanks or duplicates.
function scene.parse_ids(value)
  local ids = {}
  local seen = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local id = trim(item)
    if id ~= "" and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

--- Parse a /rest/nodes/<id> response for a scene.
---
--- @return table|nil { address, name, members = { { address, controller } } }
--- @return string|nil an error when the response is not a scene
function scene.parse(xml, requested_id)
  xml = tostring(xml or "")
  local block = xml:match("<group[^>]*>(.-)</group>")
  if not block then
    if xml:match("<node[%s>]") then
      return nil, tostring(requested_id) .. " is a device, not a scene"
    end
    return nil, "no scene found for " .. tostring(requested_id)
  end

  local address = tag_text(block, "address") or requested_id
  local members = {}
  local members_block = block:match("<members[^>]*>(.-)</members>") or ""
  for attrs, member in members_block:gmatch("<link([^>]*)>(.-)</link>") do
    member = xml_unescape(trim(member))
    if member and member ~= "" then
      local link_type = attrs:match("type%s*=%s*[\"'](.-)[\"']")
      members[#members + 1] = { address = member, controller = link_type == LINK_TYPE_CONTROLLER }
    end
  end

  return {
    address = address,
    name = tag_text(block, "name") or address,
    members = members
  }
end

--- The eISY device record for a scene, in the shape the classifier produces.
function scene.device(parsed)
  return {
    key = "scene:" .. parsed.address,
    kind = "scene",
    profile = "eisy-scene",
    label = parsed.name,
    primary = parsed.address,
    components = { main = parsed.address },
    scene = { members = parsed.members },
    nodes = {}
  }
end

--- Member addresses whose status decides whether the scene is on.
---
--- @param members table the scene's members
--- @param get_node function(address) returning the cached node, if any
--- @param has_scene_status function(node) false for sensors and other stateless nodes
function scene.status_addresses(members, get_node, has_scene_status)
  local addresses = {}
  for _, member in ipairs(members or {}) do
    local node = get_node(member.address)
    if not node or has_scene_status(node) then
      addresses[#addresses + 1] = member.address
    end
  end
  return addresses
end

--- The scene's ST: on (255) when any member with a known status is on, else off.
function scene.status(members, get_node, has_scene_status)
  for _, address in ipairs(scene.status_addresses(members, get_node, has_scene_status)) do
    local node = get_node(address)
    local st = node and node.properties and node.properties.ST
    local value = st and tonumber(st.value)
    if value and value > 0 then
      return { id = "ST", value = ON_VALUE }
    end
  end
  return { id = "ST", value = 0 }
end

return scene
