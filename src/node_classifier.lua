local classifier = {}

local function lower(value)
  return tostring(value or ""):lower()
end

local function contains_any(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

local function starts_with_any(text, prefixes)
  for _, prefix in ipairs(prefixes) do
    if text:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function node_type_prefix(node)
  return lower(node.type):match("^([^.]+)%.") or ""
end

local function is_insteon_address(address)
  local b1, b2, b3, group = lower(address):match("^(%x+)%s+(%x+)%s+(%x+)%s+(%d+)$")
  return b1 ~= nil and #b1 <= 2 and #b2 <= 2 and #b3 <= 2 and group ~= ""
end

local function split_patterns(value)
  local patterns = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local trimmed = item:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then patterns[#patterns + 1] = lower(trimmed) end
  end
  return patterns
end

local function ignored(node, patterns)
  local haystack = lower((node.address or "") .. " " .. (node.name or ""))
  for _, pattern in ipairs(patterns) do
    if haystack:find(pattern, 1, true) then return true end
  end
  return false
end

local function is_native_insteon_node(node)
  local address = lower(node.address)
  local family = lower(node.family)
  local node_def = lower(node.nodeDefId)
  local name = lower(node.name)

  if address:match("^n%d+_") then return false end
  if address:match("^z[myb]") then return false end
  if family == "10" or family == "12" or family == "14" or family == "15" then return false end
  if node_def:match("^z[myb]") then return false end
  if name == "matter" then return false end

  return is_insteon_address(address)
end

local function node_text(node)
  return lower(table.concat({
    node.name or "",
    node.nodeDefId or "",
    node.type or "",
    node.deviceClass or "",
    node.raw or ""
  }, " "))
end

local function component_id(index)
  if index == 1 then return "main" end
  return "button" .. tostring(index)
end

local function keypad_letter(index)
  return string.char(string.byte("A") + index - 1)
end

local function keypad_component_name(index, node)
  local letter = keypad_letter(index)
  local name = tostring(node.name or node.address)
  local existing_letter, rest = name:match("^%s*([A-Ha-h])%s*%-%s*(.+)$")
  if existing_letter and lower(existing_letter) == lower(letter) then
    return letter .. " - " .. rest
  end
  return letter .. " - " .. name
end

local function is_water_leak_text(text)
  return contains_any(text, { "leak", "water leak", "flood", "moisture" })
end

local function is_motion_text(text)
  return contains_any(text, { "motion", "occupancy", "2420m", "2842", "2844", "pir" })
end

local function is_thermostat_node(node)
  local text = node_text(node)
  local node_def = lower(node.nodeDefId)
  local type_text = lower(node.type)
  return starts_with_any(type_text, {
        "4.8",
        "5.3",
        "5.10",
        "5.11",
        "5.14",
        "5.15",
        "5.16",
        "5.17",
        "5.18",
        "5.19",
        "5.20",
        "5.21"
      })
      or starts_with_any(node_def, { "templinc", "thermostat" })
      or contains_any(text, { "thermostat", "templinc" })
end

local function wet_node(group)
  for _, node in ipairs(group) do
    if contains_any(node_text(node), { "wet", "water leak" }) then return node end
  end
  return group[1]
end

local function classify_single(node)
  local text = node_text(node)
  local node_def = lower(node.nodeDefId)
  local type_prefix = node_type_prefix(node)
  local address = lower(node.address)

  if is_water_leak_text(text) then
    return "water", "eisy-water"
  end
  if is_thermostat_node(node) then
    return "thermostat", "eisy-thermostat"
  end
  if starts_with_any(node_def, { "pir" }) or is_motion_text(text) then
    return "motion", "eisy-motion"
  end
  if node_def == "binaryalarm_adv" or contains_any(text, { "binaryalarm", "binary alarm" }) then
    return "contact", "eisy-contact"
  end
  if contains_any(text, { "contact", "door", "window", "gate", "open", "close", "triggerlinc", "2843" }) then
    return "contact", "eisy-contact"
  end
  if node_def == "fanlincmotor" or contains_any(text, { "fanlincmotor", "fanlinc motor", "fan linc motor" }) then
    return "fan", "eisy-fan"
  end
  if starts_with_any(node_def, {
        "dimmermotor",
        "dimmerlamp",
        "dimmerswitch",
        "keypaddimmer"
      })
      or (type_prefix == "1" and address:match("%s1$"))
      or contains_any(text, { "dimmer", "switchlinc dimmer", "lamplinc", "2477d", "2476d", "2457d" }) then
    return "dimmer", "eisy-dimmer"
  end
  if starts_with_any(node_def, {
        "relaylamp",
        "relayswitch",
        "onoffcontrol",
        "keypadrelay"
      })
      or type_prefix == "2"
      or contains_any(text, { "outlet", "appliancelinc", "on/off", "relay", "switch", "2477s", "2476s", "2635" }) then
    return "switch", "eisy-switch"
  end
  return "switch", "eisy-switch"
end

local function group_key(node)
  if node.pnode and node.pnode ~= "" then return node.pnode end
  return node.address
end

local function should_include_node(node, patterns)
  local enabled = lower(node.enabled)
  if not is_native_insteon_node(node) or ignored(node, patterns) then return false end
  if enabled ~= "false" then return true end
  return is_motion_text(node_text(node))
end

function classifier.classify_all(nodes, ignored_patterns)
  local patterns = type(ignored_patterns) == "table" and ignored_patterns or split_patterns(ignored_patterns)
  local grouped = {}
  local ordered_keys = {}

  for _, node in ipairs(nodes or {}) do
    if should_include_node(node, patterns) then
      local key = group_key(node)
      if not grouped[key] then
        grouped[key] = {}
        ordered_keys[#ordered_keys + 1] = key
      end
      grouped[key][#grouped[key] + 1] = node
    end
  end

  local devices = {}
  for _, key in ipairs(ordered_keys) do
    local group = grouped[key]
    table.sort(group, function(a, b)
      return tostring(a.sgid or a.address) < tostring(b.sgid or b.address)
    end)

    local combined_text = ""
    for _, node in ipairs(group) do combined_text = combined_text .. " " .. node_text(node) end

    if is_water_leak_text(combined_text) then
      local wet = wet_node(group)
      devices[#devices + 1] = {
        key = key,
        kind = "water",
        profile = "eisy-water",
        label = group[1].name or wet.name or key,
        primary = wet.address,
        components = { main = wet.address },
        nodes = group
      }
    elseif #group == 2
        and (lower(group[1].nodeDefId) == "dimmerlamponly" or lower(group[2].nodeDefId) == "dimmerlamponly")
        and (lower(group[1].nodeDefId) == "fanlincmotor" or lower(group[2].nodeDefId) == "fanlincmotor") then
      for _, node in ipairs(group) do
        local kind, profile = classify_single(node)
        local fanlinc_suffix = kind == "fan" and ":motor" or ":light"
        devices[#devices + 1] = {
          key = node.address .. fanlinc_suffix,
          kind = kind,
          profile = profile,
          label = node.name or node.address,
          primary = node.address,
          components = { main = node.address },
          nodes = { node }
        }
      end
    elseif #group > 1 and contains_any(combined_text, { "keypad", "keypadlinc", "kpl" }) then
      local components = {}
      local component_names = {}
      for index, node in ipairs(group) do
        if index <= 8 then
          local id = component_id(index)
          components[id] = node.address
          component_names[id] = keypad_component_name(index, node)
        end
      end
      devices[#devices + 1] = {
        key = key,
        kind = "keypad",
        profile = "eisy-keypad-8",
        label = group[1].name or key,
        primary = group[1].address,
        components = components,
        component_names = component_names,
        nodes = group
      }
    elseif #group > 1 and contains_any(combined_text, { "iolinc", "i/o linc", "io linc", "2450" }) then
      local components = { main = group[1].address, sensor = (group[2] or group[1]).address }
      devices[#devices + 1] = {
        key = key,
        kind = "iolinc",
        profile = "eisy-iolinc",
        label = group[1].name or key,
        primary = group[1].address,
        components = components,
        nodes = group
      }
    else
      local kind, profile = classify_single(group[1])
      devices[#devices + 1] = {
        key = key,
        kind = kind,
        profile = profile,
        label = group[1].name or key,
        primary = group[1].address,
        components = { main = group[1].address },
        nodes = group
      }
    end
  end

  return devices
end

return classifier
