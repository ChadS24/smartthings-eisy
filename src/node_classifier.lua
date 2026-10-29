local classifier = {}
local isy_constants = require "isy_constants"

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

local MAX_BUTTONS = 8

-- Insteon sensor subnodes, as Home Assistant's ISY integration maps them. Motion
-- Sensors I and II (types 16.1 and 16.22) report dusk/dawn on subnode 2, low
-- battery on 3, and on the Motion Sensor II, tampering on A (or 10 on some
-- firmware). Open/close and leak sensors send a heartbeat on subnode 4.
local INSTEON_MOTION_TYPES = { ["16.1"] = true, ["16.22"] = true }
local MOTION_SENSOR_II_TYPE = "16.22"
local SUBNODE_DUSK_DAWN = 2
local SUBNODE_LOW_BATTERY = 3
local SUBNODE_HEARTBEAT = 4
local SUBNODE_TAMPER = { [10] = true, [16] = true }

local LEAK_SENSOR_TYPE = "16.8"
local LEAK_DRY_GROUP = 1
local LEAK_WET_GROUP = 2

local WATER_SENSOR_TYPES = {
  [LEAK_SENSOR_TYPE] = true
}

local MOTION_SENSOR_TYPES = {
  ["16.1"] = true,
  ["16.22"] = true,
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

-- The group (subnode) number at the end of an Insteon address. It is hex: Motion
-- Sensor II tamper and motion-disabled nodes end in "A" and "D".
local function address_group(address)
  local group = lower(address):match("%s+(%x+)$")
  return group and tonumber(group, 16) or nil
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

local function has_battery(node)
  return property(node, "BATLVL") ~= nil
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
  local b1, b2, b3, group = lower(address):match("^(%x+)%s+(%x+)%s+(%x+)%s+(%x+)$")
  return b1 ~= nil and #b1 <= 2 and #b2 <= 2 and #b3 <= 2 and group ~= ""
end

local function is_native_insteon_node(node)
  local address = lower(node.address)
  local family = lower(node.family)
  local def = node_def(node)

  if address:match("^n%d+_") then return false end
  if address:match("^z[myb]") then return false end
  if family ~= "" and family ~= isy_constants.FAMILY_INSTEON then return false end
  if family == isy_constants.FAMILY_NODESERVER or family == isy_constants.FAMILY_ZMATTER_ZWAVE then return false end
  if def:match("^z[myb]") then return false end

  return is_insteon_address(address)
end

local function component_id(index)
  if index == 1 then return "main" end
  return "button" .. tostring(index)
end

-- A button's letter. On 8-button keypads groups 1-8 are buttons A-H. On 6-button
-- keypads group 1 is the On/Off pair and groups 3-6 are buttons A-D.
local function keypad_letter(index, node, six_button)
  local group = address_group(node.address)
  if not group then return string.char(string.byte("A") + index - 1) end
  if six_button then group = group - 2 end
  return string.char(string.byte("A") + group - 1)
end

local function keypad_component_name(index, node, six_button)
  if six_button and address_group(node.address) == 1 then
    return "On/Off - " .. tostring(node.name or node.address)
  end
  local letter = keypad_letter(index, node, six_button)
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

-- Insteon category 0 is generalized controllers: mini remotes and RemoteLincs.
-- They have no status, only the button presses they send.
local function is_remote_node(node)
  return node_def(node):match("^remotelinc") ~= nil or type_major(node) == "0"
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
  -- Subnodes numbered with hex letters are only used here for sensors (category 16).
  if lower(node.address):match("%s+%x*%a%x*$") and type_major(node) ~= "16" then return false end
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

-- Insteon leak sensors expose a "Dry" node (group 1, On when dry) and a "Wet"
-- node (group 2, On when wet). IoX does not clear one when the other turns on.
local function leak_nodes(group)
  local dry, wet
  for _, node in ipairs(group) do
    if type_key(node) == LEAK_SENSOR_TYPE then
      local node_group = address_group(node.address)
      if node_group == LEAK_DRY_GROUP and not dry then dry = node end
      if node_group == LEAK_WET_GROUP and not wet then wet = node end
    end
  end
  return dry, wet
end

-- A node that switches or dims its own load. Shade motors are left out: they are
-- one device however many nodes they have.
local function is_load_node(node)
  if is_stateless_node(node) or is_water_node(node) or is_motion_node(node)
      or is_contact_node(node) or is_thermostat_node(node) or is_fan_node(node)
      or node_def(node):match("motor") then
    return false
  end
  return is_switch_node(node) or is_dimmable_node(node)
end

local function load_nodes(group)
  local loads = {}
  for _, node in ipairs(group) do
    if is_load_node(node) then loads[#loads + 1] = node end
  end
  return loads
end

local function subnode(group, number)
  for _, node in ipairs(group) do
    if address_group(node.address) == number then return node.address end
  end
  return nil
end

-- A motion sensor's extra subnodes, by role, or nil when it has none.
local function motion_aux(group)
  if not INSTEON_MOTION_TYPES[type_key(group[1])] then return nil end
  local aux = {
    dusk_dawn = subnode(group, SUBNODE_DUSK_DAWN),
    low_battery = subnode(group, SUBNODE_LOW_BATTERY)
  }
  for _, node in ipairs(group) do
    if SUBNODE_TAMPER[address_group(node.address)] then aux.tamper = node.address end
  end
  if next(aux) == nil then return nil end
  return aux
end

-- The heartbeat subnode of an Insteon open/close or leak sensor.
local function heartbeat_node(group)
  if type_major(group[1]) ~= "16" then return nil end
  return subnode(group, SUBNODE_HEARTBEAT)
end

local function group_has(group, predicate)
  for _, node in ipairs(group) do
    if predicate(node) then return true end
  end
  return false
end

local function profile_with_battery(profile, kind, group)
  if (kind == "motion" or kind == "contact" or kind == "water") and group_has(group, has_battery) then
    return profile .. "-battery"
  end
  return profile
end

local function is_fanlinc_group(group)
  if #group ~= 2 then return false end
  return group_has(group, is_fan_node) and group_has(group, function(node)
    return node_def(node) == "dimmerlamponly" or node_def(node) == "dimmerlamponly_adv"
  end)
end

local function is_remote_group(group)
  for _, node in ipairs(group) do
    if not is_remote_node(node) then return false end
  end
  return #group > 0
end

-- 6-button KeypadLincs have no group 2: their buttons are groups 1 and 3-6.
-- `all_nodes` is every node the eISY reports under the keypad, including ones
-- ignored or disabled, so a hidden button B can't make an 8-button keypad look
-- like a 6-button one.
local function is_six_button_keypad(all_nodes)
  for _, node in ipairs(all_nodes) do
    local number = address_group(node.address)
    if number == nil or number == 2 or number > 6 then return false end
  end
  return true
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

-- Whether a node's ST says if it is lit, and so counts toward its scenes' status.
-- Sensors and stateless controllers (remotes, motion sensors) can be scene
-- controllers but their status is not a light level.
function classifier.has_scene_status(node)
  return not (is_stateless_node(node) or is_water_node(node) or is_motion_node(node) or is_contact_node(node))
end

function classifier.classify_all(nodes, ignored_patterns)
  local patterns = type(ignored_patterns) == "table" and ignored_patterns or split_patterns(ignored_patterns)
  local grouped = {}
  local ordered_keys = {}
  -- Every native Insteon node by group key, before ignore patterns and disabled
  -- nodes are filtered out.
  local all_by_key = {}

  for _, node in ipairs(nodes or {}) do
    if is_native_insteon_node(node) then
      local all = all_by_key[group_key(node)] or {}
      all[#all + 1] = node
      all_by_key[group_key(node)] = all
    end
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
      local dry, wet = leak_nodes(group)
      local leak
      local main
      if dry then
        main = dry
        leak = { dry = dry.address, wet = wet and wet.address }
      else
        main = wet_node(group)
      end
      devices[#devices + 1] = {
        key = key,
        kind = "water",
        profile = profile_with_battery("eisy-water", "water", group),
        label = group[1].name or main.name or key,
        primary = main.address,
        components = { main = main.address },
        leak = leak,
        heartbeat = heartbeat_node(group),
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
    elseif is_remote_group(group) then
      local components = {}
      local count = 0
      for index, node in ipairs(group) do
        if index <= MAX_BUTTONS then
          components[component_id(index)] = node.address
          count = index
        end
      end
      devices[#devices + 1] = {
        key = key,
        kind = "remote",
        profile = "eisy-remote-" .. tostring(count),
        label = group[1].name or key,
        primary = group[1].address,
        components = components,
        nodes = group
      }
    elseif is_keypad_group(group) then
      local six_button = is_six_button_keypad(all_by_key[key] or group)
      local max_components = six_button and 5 or MAX_BUTTONS
      local components = {}
      local component_names = {}
      for index, node in ipairs(group) do
        if index <= max_components then
          local id = component_id(index)
          components[id] = node.address
          component_names[id] = keypad_component_name(index, node, six_button)
        end
      end
      -- The first node is the keypad's load, a dimmer on KeypadLinc dimmers.
      local dimmable = is_dimmable_node(group[1])
      local buttons = six_button and "6" or "8"
      devices[#devices + 1] = {
        key = key,
        kind = "keypad",
        profile = (dimmable and "eisy-keypad-dimmer-" or "eisy-keypad-") .. buttons,
        dimmable = dimmable,
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
    elseif #load_nodes(group) > 1 then
      -- Several loads under one parent, such as a dual outlet: one device per load.
      -- The group's key, which the single device used before, stays with the
      -- parent node's load (else the first load); the others are keyed by address.
      local loads = load_nodes(group)
      local keyed = loads[1]
      for _, node in ipairs(loads) do
        if node.address == key then keyed = node end
      end
      for _, node in ipairs(loads) do
        local kind, profile = classify_single(node)
        devices[#devices + 1] = {
          key = node == keyed and key or node.address,
          kind = kind,
          profile = profile,
          label = node.name or node.address,
          primary = node.address,
          components = { main = node.address },
          nodes = { node }
        }
      end
    else
      local kind, profile = classify_single(group[1])
      profile = profile_with_battery(profile, kind, group)
      local aux = kind == "motion" and motion_aux(group) or nil
      if kind == "motion" and type_key(group[1]) == MOTION_SENSOR_II_TYPE then
        profile = "eisy-motion-ii"
      elseif aux then
        profile = "eisy-motion-insteon"
      end
      devices[#devices + 1] = {
        key = key,
        kind = kind,
        profile = profile,
        label = group[1].name or key,
        primary = group[1].address,
        components = { main = group[1].address },
        aux = aux,
        heartbeat = kind == "contact" and heartbeat_node(group) or nil,
        nodes = group
      }
    end
  end

  return devices
end

return classifier
