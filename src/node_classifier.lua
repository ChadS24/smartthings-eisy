local classifier = {}

local FAMILY_INSTEON = "1"
local FAMILY_NODESERVER = "10"
local FAMILY_ZMATTER_ZWAVE = "12"
local INSTEON_SUBNODE_DIMMABLE = "1"
local UOM_PERCENTAGE = "51"

local THERMOSTAT_TYPES = {
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
}

local DIMMER_NODE_DEFS = {
  dimmerlamp = true,
  dimmerlamponly = true,
  dimmerlamponly_adv = true,
  dimmerlampswitch = true,
  dimmerlampswitch_adv = true,
  dimmermotor = true,
  dimmermotorswitch = true,
  dimmermotorswitch_adv = true,
  dimmerswitch = true,
  dimmerswitchonly = true,
  dimmerswitchonly_adv = true,
  keypaddimmer = true,
  keypaddimmer_adv = true
}

local SWITCH_NODE_DEFS = {
  onoffcontrol = true,
  onoffcontrol_adv = true,
  keypadrelay = true,
  keypadrelay_adv = true,
  relaylamp = true,
  relaylampswitch = true,
  relaylampswitch_adv = true,
  relayswitch = true,
  relayswitchonly = true,
  relayswitchonly_adv = true,
  relayswitchonlyplusquery = true,
  relayswitchonlyplusquery_adv = true
}

local KEYPAD_NODE_DEFS = {
  keypadbutton = true,
  keypadbutton_adv = true,
  keypaddimmer = true,
  keypaddimmer_adv = true,
  keypadrelay = true,
  keypadrelay_adv = true
}

local STATELESS_NODE_DEFS = {
  binaryalarm = true,
  binaryalarm_adv = true,
  binarycontrol = true,
  binarycontrol_adv = true,
  dimmerswitchonly = true,
  remotelinc2 = true,
  remotelinc2_adv = true
}

local WATER_SENSOR_TYPES = {
  ["16.8"] = true
}

local MOTION_SENSOR_TYPES = {
  ["16.1"] = true,
  ["16.3"] = true,
  ["16.10"] = true
}

local CONTACT_SENSOR_TYPES = {
  ["16.2"] = true,
  ["16.4"] = true,
  ["16.5"] = true,
  ["16.6"] = true,
  ["16.7"] = true
}

local function lower(value)
  return tostring(value or ""):lower()
end

local function starts_with_any(text, prefixes)
  for _, prefix in ipairs(prefixes) do
    if text:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function node_def(node)
  return lower(node.nodeDefId)
end

local function type_text(node)
  return lower(node.type)
end

local function type_major(node)
  return type_text(node):match("^(%d+)") or ""
end

local function type_key(node)
  local major, minor = type_text(node):match("^(%d+)%.(%d+)")
  if not major or not minor then return "" end
  return major .. "." .. minor
end

local function address_group(address)
  return tonumber(lower(address):match("%s+(%d+)$"))
end

local function is_primary_subnode(node)
  return tostring(address_group(node.address) or "") == INSTEON_SUBNODE_DIMMABLE
end

local function property(node, id)
  return node.properties and node.properties[id] or nil
end

local function property_uom(node, id)
  local prop = property(node, id)
  return prop and tostring(prop.uom or "") or ""
end

local function property_formatted(node, id)
  local prop = property(node, id)
  return prop and tostring(prop.formatted or "") or ""
end

local function has_status(node)
  return property(node, "ST") ~= nil
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

local function is_insteon_address(address)
  local b1, b2, b3, group = lower(address):match("^(%x+)%s+(%x+)%s+(%x+)%s+(%d+)$")
  return b1 ~= nil and #b1 <= 2 and #b2 <= 2 and #b3 <= 2 and group ~= ""
end

local function is_native_insteon_node(node)
  local address = lower(node.address)
  local family = lower(node.family)
  local def = node_def(node)

  if address:match("^n%d+_") then return false end
  if address:match("^z[myb]") then return false end
  if family ~= "" and family ~= FAMILY_INSTEON then return false end
  if family == FAMILY_NODESERVER or family == FAMILY_ZMATTER_ZWAVE then return false end
  if def:match("^z[myb]") then return false end

  return is_insteon_address(address)
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

local function is_stateless_node(node)
  return STATELESS_NODE_DEFS[node_def(node)] == true
end

local function is_thermostat_node(node)
  return starts_with_any(type_text(node), THERMOSTAT_TYPES)
      or node_def(node):match("^templinc") ~= nil
      or node_def(node):match("^thermostat") ~= nil
end

local function is_dimmable_node(node)
  return property_uom(node, "ST") == UOM_PERCENTAGE
      or property_formatted(node, "ST"):find("%%") ~= nil
      or (type_text(node):sub(1, 2) == "1." and is_primary_subnode(node))
      or DIMMER_NODE_DEFS[node_def(node)] == true
end

local function is_fan_node(node)
  return node_def(node) == "fanlincmotor"
end

local function is_water_node(node)
  local def = node_def(node)
  return WATER_SENSOR_TYPES[type_key(node)] == true
      or def:match("leak") ~= nil
      or def:match("water") ~= nil
      or def:match("moisture") ~= nil
end

local function is_motion_node(node)
  local def = node_def(node)
  return MOTION_SENSOR_TYPES[type_key(node)] == true
      or def:match("^pir") ~= nil
      or def:match("motion") ~= nil
      or def:match("occupancy") ~= nil
end

local function is_contact_node(node)
  if is_water_node(node) or is_motion_node(node) then return false end
  local def = node_def(node)
  return CONTACT_SENSOR_TYPES[type_key(node)] == true
      or (type_major(node) == "16" and is_stateless_node(node))
      or (type_major(node) == "7" and is_stateless_node(node))
      or def:match("triggerlinc") ~= nil
      or def:match("contact") ~= nil
      or def:match("door") ~= nil
      or def:match("window") ~= nil
end

local function is_switch_node(node)
  return SWITCH_NODE_DEFS[node_def(node)] == true
      or type_major(node) == "2"
end

local function classify_single(node)
  if is_water_node(node) then
    return "water", "eisy-water"
  end
  if is_thermostat_node(node) then
    return "thermostat", "eisy-thermostat"
  end
  if is_motion_node(node) then
    return "motion", "eisy-motion"
  end
  if is_contact_node(node) then
    return "contact", "eisy-contact"
  end
  if is_fan_node(node) then
    return "fan", "eisy-fan"
  end
  if is_dimmable_node(node) then
    return "dimmer", "eisy-dimmer"
  end
  if is_switch_node(node) then
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
  return is_stateless_node(node) or is_motion_node(node) or is_contact_node(node) or is_water_node(node)
end

local function node_order(node)
  return tonumber(node.sgid) or address_group(node.address) or 0
end

local function wet_node(group)
  for _, node in ipairs(group) do
    if is_water_node(node) and is_primary_subnode(node) then return node end
  end
  for _, node in ipairs(group) do
    if is_water_node(node) and has_status(node) then return node end
  end
  for _, node in ipairs(group) do
    if is_water_node(node) then return node end
  end
  return group[1]
end

local function group_has(group, predicate)
  for _, node in ipairs(group) do
    if predicate(node) then return true end
  end
  return false
end

local function is_fanlinc_group(group)
  if #group ~= 2 then return false end
  return group_has(group, is_fan_node) and group_has(group, function(node)
    return node_def(node) == "dimmerlamponly" or node_def(node) == "dimmerlamponly_adv"
  end)
end

local function is_keypad_group(group)
  if #group > 1 and group_has(group, function(node)
    return KEYPAD_NODE_DEFS[node_def(node)] == true
  end) then
    return true
  end

  return #group > 2
      and group_has(group, function(node) return is_dimmable_node(node) or is_switch_node(node) end)
      and group_has(group, is_stateless_node)
end

local function iolinc_nodes(group)
  local relay
  local sensor
  for _, node in ipairs(group) do
    if not relay and is_switch_node(node) then relay = node end
    if not sensor and is_contact_node(node) then sensor = node end
  end
  return relay, sensor
end

local function is_iolinc_group(group)
  if #group < 2 then return false end
  local relay, sensor = iolinc_nodes(group)
  return relay ~= nil and sensor ~= nil
      and (group_has(group, function(node) return type_major(node) == "7" end) or #group == 2)
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
      local order_a = node_order(a)
      local order_b = node_order(b)
      if order_a == order_b then return tostring(a.address) < tostring(b.address) end
      return order_a < order_b
    end)

    if group_has(group, is_water_node) then
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
    elseif is_fanlinc_group(group) then
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
    elseif is_keypad_group(group) then
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
    elseif is_iolinc_group(group) then
      local relay, sensor = iolinc_nodes(group)
      devices[#devices + 1] = {
        key = key,
        kind = "iolinc",
        profile = "eisy-iolinc",
        label = (relay or group[1]).name or key,
        primary = (relay or group[1]).address,
        components = {
          main = (relay or group[1]).address,
          sensor = (sensor or group[2] or group[1]).address
        },
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
