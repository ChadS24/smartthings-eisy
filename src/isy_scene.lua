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

--- Every scene in a /rest/nodes response, as { address, name }.
function scene.parse_list(xml)
  local scenes = {}
  for block in tostring(xml or ""):gmatch("<group[^>]*>(.-)</group>") do
    local address = tag_text(block, "address")
    if address then
      scenes[#scenes + 1] = { address = address, name = tag_text(block, "name") or address }
    end
  end
  return scenes
end

--- Resolve sceneIds entries, each a scene's ID or its name (any case), to IDs.
---
--- @param entries table the entries from parse_ids
--- @param available table the eISY's scenes, from parse_list
--- @return table the scene IDs, in order, without duplicates
--- @return table problems, each { entry, reason }, for entries that resolved to
---   nothing ("unknown") or to several scenes ("ambiguous", with their ids)
function scene.resolve(entries, available)
  local by_address = {}
  local by_name = {}
  for _, candidate in ipairs(available or {}) do
    by_address[candidate.address] = candidate
    local name = (trim(candidate.name) or ""):lower()
    by_name[name] = by_name[name] or {}
    table.insert(by_name[name], candidate)
  end

  local ids = {}
  local seen = {}
  local problems = {}
  local function add(id)
    if not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  for _, entry in ipairs(entries or {}) do
    local matches = by_name[entry:lower()]
    if by_address[entry] then
      add(entry)
    elseif matches and #matches == 1 then
      add(matches[1].address)
    elseif matches then
      local addresses = {}
      for _, match in ipairs(matches) do addresses[#addresses + 1] = match.address end
      problems[#problems + 1] = { entry = entry, reason = "ambiguous", ids = addresses }
    elseif entry:match("^%d+$") then
      -- A numeric ID the list doesn't show; the scene fetch decides.
      add(entry)
    else
      problems[#problems + 1] = { entry = entry, reason = "unknown" }
    end
  end
  return ids, problems
end

--- The eISY's scenes as "Name (ID)", sorted by name, for the log.
function scene.describe(available)
  local sorted = {}
  for _, candidate in ipairs(available or {}) do sorted[#sorted + 1] = candidate end
  table.sort(sorted, function(a, b)
    local name_a, name_b = tostring(a.name):lower(), tostring(b.name):lower()
    if name_a == name_b then return tostring(a.address) < tostring(b.address) end
    return name_a < name_b
  end)
  local parts = {}
  for _, candidate in ipairs(sorted) do
    parts[#parts + 1] = tostring(candidate.name) .. " (" .. tostring(candidate.address) .. ")"
  end
  return table.concat(parts, ", ")
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
