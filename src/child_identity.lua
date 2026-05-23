local identity = {}

local function sanitize(value)
  return tostring(value or ""):gsub("%s+", "_"):gsub("[^%w%-%._:]", "_")
end

function identity.legacy_child_key(eisy_device)
  return "eisy:" .. sanitize(eisy_device and eisy_device.key)
end

function identity.uuid_child_key(controller_uuid, eisy_device)
  local uuid = sanitize(controller_uuid)
  if uuid == "" then return identity.legacy_child_key(eisy_device) end
  return "eisy:" .. uuid .. ":" .. sanitize(eisy_device and eisy_device.key)
end

function identity.select_child_key(controller_uuid, eisy_device, find_child_by_key)
  local uuid_key = identity.uuid_child_key(controller_uuid, eisy_device)
  local legacy_key = identity.legacy_child_key(eisy_device)
  if uuid_key == legacy_key then return legacy_key end
  if find_child_by_key and find_child_by_key(uuid_key) then return uuid_key end
  if find_child_by_key and find_child_by_key(legacy_key) then return legacy_key end
  return uuid_key
end

return identity
