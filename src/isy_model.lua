local constants = require "isy_constants"

local model = {}
local node_methods = {}
local store_methods = {}

local function now()
  return os.time()
end

local function copy_property(property)
  if not property then return nil end
  local copy = {}
  for key, value in pairs(property) do copy[key] = value end
  return copy
end

local function property_changed(previous, property)
  if not previous then return true end
  return previous.value ~= property.value
      or previous.uom ~= property.uom
      or previous.precision ~= property.precision
      or previous.formatted ~= property.formatted
end

function node_methods:update_property(property)
  if not property or not property.id then return false end
  local existing = self.properties[property.id]
  local next_property = copy_property(property)
  if (not next_property.uom or next_property.uom == "") and existing and existing.uom and existing.uom ~= "" then
    next_property.uom = existing.uom
  end
  if (not next_property.precision or next_property.precision == "") and existing and existing.precision then
    next_property.precision = existing.precision
  end

  local changed = property_changed(existing, next_property)
  self.properties[next_property.id] = next_property
  if next_property.id == constants.PROP_STATUS or (not self.status and next_property.id == constants.PROP_BATTERY) then
    self.status = next_property
  else
    self.aux_properties[next_property.id] = next_property
  end
  self.last_update = now()
  if changed then self.last_changed = self.last_update end
  return changed
end

function node_methods:update_properties(properties)
  local changed = false
  for _, property in pairs(properties or {}) do
    if self:update_property(property) then changed = true end
  end
  return changed
end

function node_methods:snapshot_properties()
  local snapshot = {}
  for id, property in pairs(self.properties or {}) do
    snapshot[id] = copy_property(property)
  end
  return snapshot
end

local function new_node(record)
  local node = {
    address = record.address,
    name = record.name or record.address,
    family = tostring(record.family or ""),
    type = tostring(record.type or ""),
    deviceClass = record.deviceClass,
    nodeDefId = record.nodeDefId,
    parent = record.parent,
    pnode = record.pnode,
    sgid = record.sgid,
    flag = record.flag,
    enabled = record.enabled,
    properties = {},
    aux_properties = {},
    last_update = nil,
    last_changed = nil
  }
  setmetatable(node, { __index = node_methods })
  node:update_properties(record.properties)
  return node
end

function store_methods:upsert_node(record)
  if not record or not record.address then return nil end
  local node = self.nodes_by_address[record.address]
  if not node then
    node = new_node(record)
    self.nodes_by_address[record.address] = node
    self.nodes[#self.nodes + 1] = node
  else
    for _, key in ipairs({ "name", "family", "type", "deviceClass", "nodeDefId", "parent", "pnode", "sgid", "flag", "enabled" }) do
      if record[key] ~= nil then node[key] = record[key] end
    end
    node:update_properties(record.properties)
  end
  return node
end

function store_methods:upsert_nodes(records)
  for _, record in ipairs(records or {}) do self:upsert_node(record) end
  return self.nodes
end

function store_methods:replace_nodes(records)
  self.nodes = {}
  self.nodes_by_address = {}
  return self:upsert_nodes(records)
end

function store_methods:update_status(address, properties)
  local node = self.nodes_by_address[address]
  if not node then
    node = self:upsert_node({ address = address, name = address, family = constants.FAMILY_INSTEON })
  end
  node:update_properties(properties)
  return node
end

function store_methods:get_node(address)
  return self.nodes_by_address[address]
end

function store_methods:as_node_list()
  return self.nodes
end

function model.new_store()
  return setmetatable({
    nodes = {},
    nodes_by_address = {},
    uuid = nil,
    model = nil,
    name = nil,
    websocket_status = "not_started",
    last_heartbeat = nil,
    last_system_status = nil
  }, { __index = store_methods })
end

return model
