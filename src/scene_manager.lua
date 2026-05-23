local scene_manager = {}

local function trim(value)
  if value == nil then return nil end
  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function xml_unescape(value)
  if not value then return nil end
  return (value:gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", "\"")
    :gsub("&apos;", "'")
    :gsub("&amp;", "&"))
end

local function tag_text(block, tag)
  local value = tostring(block or ""):match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
  return xml_unescape(trim(value))
end

local function sanitize(value)
  return tostring(value or ""):gsub("%s+", "_"):gsub("[^%w%-%._:]", "_")
end

local function encode_key_token(value)
  return "h" .. tostring(value or ""):gsub(".", function(char)
    return string.format("%02X", string.byte(char))
  end)
end

local function decode_key_token(token)
  token = tostring(token or "")
  local hex = token:match("^h(%x+)$")
  if hex and #hex % 2 == 0 then
    return (hex:gsub("%x%x", function(byte)
      return string.char(tonumber(byte, 16))
    end))
  end
  return token
end

function scene_manager.parse_scene_ids(value)
  local ids = {}
  local seen = {}
  for raw in tostring(value or ""):gmatch("([^,]+)") do
    local id = trim(raw)
    if id and id ~= "" and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

function scene_manager.parse_scenes(xml)
  local scenes = {}
  for block in tostring(xml or ""):gmatch("<group[^>]*>(.-)</group>") do
    local id = tag_text(block, "address")
    if id and id ~= "" then
      scenes[id] = {
        id = id,
        name = tag_text(block, "name") or id,
        family = tag_text(block, "family"),
        raw = block
      }
    end
  end
  return scenes
end

function scene_manager.selected_scenes(scene_ids_value, scenes_by_id)
  local selected = {}
  local missing = {}
  scenes_by_id = scenes_by_id or {}
  for _, id in ipairs(scene_manager.parse_scene_ids(scene_ids_value)) do
    local scene = scenes_by_id[id]
    if scene then
      selected[#selected + 1] = scene
    else
      missing[#missing + 1] = id
    end
  end
  return selected, missing
end

function scene_manager.scene_child_key(controller_uuid, scene_id)
  local uuid = sanitize(controller_uuid)
  local scene = encode_key_token(scene_id)
  if uuid == "" then return "eisy-scene:" .. scene end
  return "eisy-scene:" .. uuid .. ":" .. scene
end

function scene_manager.select_scene_child_key(controller_uuid, scene_id, find_child_by_key)
  local uuid_key = scene_manager.scene_child_key(controller_uuid, scene_id)
  local legacy_key = scene_manager.scene_child_key(nil, scene_id)
  if uuid_key == legacy_key then return legacy_key end
  if find_child_by_key and find_child_by_key(uuid_key) then return uuid_key end
  if find_child_by_key and find_child_by_key(legacy_key) then return legacy_key end
  return uuid_key
end

function scene_manager.scene_id_from_child_key(key)
  key = tostring(key or "")
  local token = key:match("^eisy%-scene:[^:]+:(.+)$") or key:match("^eisy%-scene:(.+)$")
  return token and decode_key_token(token) or nil
end

function scene_manager.is_scene_child_key(key)
  return scene_manager.scene_id_from_child_key(key) ~= nil
end

return scene_manager
