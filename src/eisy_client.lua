local cosock = require "cosock"
local ltn12 = require "ltn12"
local log = require "log"

local http = cosock.asyncify "socket.http"
local ok_https, https = pcall(function() return cosock.asyncify "ssl.https" end)

local client = {}
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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

local function sanitize_host(value)
  value = trim(tostring(value or ""))
  value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
  return trim(value)
end

local function tag_text(block, tag)
  local value = block:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
  return xml_unescape(trim(value))
end

local function parse_attrs(raw)
  local attrs = {}
  for key, quote, value in tostring(raw):gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
    attrs[key] = xml_unescape(value)
  end
  return attrs
end

local function tag_attrs(block, tag)
  local attrs = block:match("<" .. tag .. "%s+([^>]*)>") or block:match("<" .. tag .. "%s+([^>]*)/>")
  return attrs and parse_attrs(attrs) or {}
end

local function parse_properties(block)
  local properties = {}
  for raw_attrs in tostring(block):gmatch("<property%s+([^>]-)/>") do
    local attrs = parse_attrs(raw_attrs)
    if attrs.id then
      properties[attrs.id] = {
        id = attrs.id,
        value = tonumber(attrs.value) or attrs.value,
        formatted = attrs.formatted,
        uom = attrs.uom
      }
    end
  end
  return properties
end

function client.parse_nodes(xml)
  local nodes = {}
  for attrs, block in tostring(xml):gmatch("<node%s*([^>]*)>(.-)</node>") do
    local address = tag_text(block, "address")
    if address then
      local node_attrs = parse_attrs(attrs)
      local node = {
        address = address,
        name = tag_text(block, "name") or address,
        parent = tag_text(block, "parent"),
        family = tag_text(block, "family"),
        type = tag_text(block, "type"),
        enabled = tag_text(block, "enabled"),
        deviceClass = tag_text(block, "deviceClass"),
        nodeDefId = node_attrs.nodeDefId,
        pnode = tag_text(block, "pnode"),
        sgid = tag_text(block, "sgid"),
        flag = node_attrs.flag,
        raw = block,
        properties = parse_properties(block)
      }
      nodes[#nodes + 1] = node
    end
  end
  return nodes
end

function client.parse_status(xml)
  local statuses = {}
  for attrs, block in tostring(xml):gmatch("<node%s+([^>]*)>(.-)</node>") do
    local node_attrs = parse_attrs(attrs)
    if node_attrs.id then
      statuses[node_attrs.id] = parse_properties(block)
    end
  end
  if next(statuses) == nil then
    statuses.main = parse_properties(xml)
  end
  return statuses
end

function client.parse_event(xml)
  xml = tostring(xml or "")
  local control = tag_text(xml, "control")
  local address = tag_text(xml, "node") or xml:match("<event[^>]-node=\"(.-)\"")
  local action_attrs = tag_attrs(xml, "action")
  local action = tag_text(xml, "action")
  return {
    control = control,
    address = address,
    action = action,
    formatted = tag_text(xml, "fmtAct"),
    uom = action_attrs.uom,
    precision = action_attrs.prec,
    raw = xml
  }
end

function client.event_statuses(event)
  if not event or not event.address or event.control ~= "ST" then return nil end
  return {
    [event.address] = {
      ST = {
        id = "ST",
        value = tonumber(event.action) or event.action,
        formatted = event.formatted,
        uom = event.uom
      }
    }
  }
end

local function basic_auth(username, password)
  if not username or username == "" then return nil end
  return "Basic " .. client.base64_encode(username .. ":" .. (password or ""))
end

function client.base64_encode(value)
  local bytes = { string.byte(tostring(value or ""), 1, -1) }
  local encoded = {}

  for index = 1, #bytes, 3 do
    local b1 = bytes[index]
    local b2 = bytes[index + 1]
    local b3 = bytes[index + 2]
    local triple = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)

    local c1 = math.floor(triple / 262144) % 64
    local c2 = math.floor(triple / 4096) % 64
    local c3 = math.floor(triple / 64) % 64
    local c4 = triple % 64

    encoded[#encoded + 1] = B64_ALPHABET:sub(c1 + 1, c1 + 1)
    encoded[#encoded + 1] = B64_ALPHABET:sub(c2 + 1, c2 + 1)
    encoded[#encoded + 1] = b2 and B64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
    encoded[#encoded + 1] = b3 and B64_ALPHABET:sub(c4 + 1, c4 + 1) or "="
  end

  return table.concat(encoded)
end

local function url_encode(value)
  return tostring(value):gsub("([^%w%-%._~ ])", function(char)
    return string.format("%%%02X", string.byte(char))
  end):gsub(" ", "%%20")
end

function client.encode_node_address(address)
  return url_encode(address)
end

function client.normalize_config(opts)
  opts = opts or {}
  local protocol = tostring(opts.protocol or "http"):lower()
  local host = sanitize_host(opts.host)
  local port = tonumber(opts.port)

  local scheme, rest = host:match("^(https?)://(.+)$")
  if scheme then
    protocol = scheme
    host = rest
  end

  host = host:gsub("^//", "")
  host = host:match("^([^/%?#]+)") or host
  host = sanitize_host(host)

  local host_part, port_part = host:match("^([^:]+):(%d+)$")
  if host_part and port_part then
    host = host_part
    port = tonumber(port_part)
  end

  if protocol ~= "https" then protocol = "http" end
  port = port or (protocol == "https" and 443 or 80)

  if host == "" or host:find("%s") then
    host = ""
  end

  return {
    host = host,
    port = port,
    protocol = protocol
  }
end

function client.new(opts)
  opts = opts or {}
  local normalized = client.normalize_config(opts)
  local protocol = normalized.protocol
  local port = normalized.port
  local host = normalized.host
  local base = string.format("%s://%s:%s", protocol, host, port)
  return setmetatable({
    host = host,
    port = port,
    protocol = protocol,
    base_url = base,
    timeout = tonumber(opts.timeout) or 8,
    auth = basic_auth(opts.username, opts.password)
  }, { __index = client })
end

function client:request(path)
  if not self.host or self.host == "" then
    return nil, "eISY host is not configured"
  end

  local body_t = {}
  local headers = { Accept = "application/xml" }
  if self.auth then headers.Authorization = self.auth end
  if self.protocol == "https" and not ok_https then
    return nil, "HTTPS support is unavailable in this Edge runtime"
  end
  local transport = self.protocol == "https" and https or http

  local ok, success, code, response_headers, status = pcall(transport.request, {
    url = self.base_url .. path,
    method = "GET",
    headers = headers,
    sink = ltn12.sink.table(body_t)
  })

  if not ok then
    return nil, tostring(success)
  end
  if not success then
    return nil, tostring(code)
  end
  if tonumber(code) < 200 or tonumber(code) >= 300 then
    return nil, string.format("HTTP %s %s", tostring(code), tostring(status or ""))
  end
  return table.concat(body_t), nil, response_headers
end

function client:get_nodes()
  local body, err = self:request("/rest/nodes")
  if not body then return nil, err end
  return client.parse_nodes(body)
end

function client:get_all_status()
  local body, err = self:request("/rest/status")
  if not body then return nil, err end
  return client.parse_status(body)
end

function client:get_node_status(address)
  local body, err = self:request("/rest/status/" .. client.encode_node_address(address))
  if not body then return nil, err end
  local parsed = client.parse_status(body)
  return parsed.main or parsed[address] or {}
end

function client:query_node(address)
  return self:request("/rest/query/" .. client.encode_node_address(address))
end

function client:command(address, command, params)
  local path = "/rest/nodes/" .. client.encode_node_address(address) .. "/cmd/" .. command
  for _, param in ipairs(params or {}) do
    path = path .. "/" .. url_encode(param)
  end
  return self:request(path)
end

return client
