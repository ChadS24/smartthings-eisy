local cosock = require "cosock"
local ltn12 = require "ltn12"
local log = require "log"

local http = cosock.asyncify "socket.http"
local ok_https, https = pcall(function() return cosock.asyncify "ssl.https" end)
local isy_properties = require "isy_properties"
local isy_scene = require "isy_scene"

local client = {}
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local MAX_RETRIES = 5
local RETRY_BACKOFF = { 0.01, 0.10, 0.25, 1, 2 }
local EMPTY_XML_RESPONSE = '<?xml version="1.0" encoding="UTF-8"?>'
local EVENT_STATUS_CONTROLS = {
  ST = true,
  CLIMD = true,
  CLISPH = true,
  CLISPC = true,
  CLIHCS = true,
  CLIFS = true
}

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
  return isy_properties.parse_properties(block)
end

local function nested_tag_text(xml, outer, inner)
  local block = tostring(xml or ""):match("<" .. outer .. "[^>]*>(.-)</" .. outer .. ">")
  return block and tag_text(block, inner) or nil
end

-- /rest/config carries the controller identity in <root><id>/<name> and the
-- model in <product><desc>, matching PyISY's Configuration parsing.
function client.parse_config(xml)
  xml = tostring(xml or "")
  return {
    uuid = nested_tag_text(xml, "root", "id") or tag_text(xml, "uuid"),
    model = nested_tag_text(xml, "product", "desc") or tag_text(xml, "model"),
    name = nested_tag_text(xml, "root", "name") or tag_text(xml, "name")
  }
end

function client.parse_nodes(xml)
  local nodes = {}
  for attrs, block in tostring(xml):gmatch("<node%s+([^>]*)>(.-)</node>") do
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
  if not event or not event.address then return nil end
  local control = event.control
  local status_id = control
  local value = tonumber(event.action) or event.action
  local formatted = event.formatted
  local uom = event.uom

  if not EVENT_STATUS_CONTROLS[control] then
    return nil
  end

  return {
    [event.address] = {
      [status_id] = {
        id = status_id,
        value = value,
        formatted = formatted,
        uom = uom
      }
    }
  }
end

function client.event_requires_refresh(event)
  return false
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

function client.encode_path_segment(value)
  return url_encode(value)
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
    timeout = tonumber(opts.timeout) or 30,
    auth = basic_auth(opts.username, opts.password)
  }, { __index = client })
end

local function retry_delay(retries)
  local index = math.min((tonumber(retries) or 0) + 1, #RETRY_BACKOFF)
  return RETRY_BACKOFF[index]
end

function client:request(path, opts)
  opts = opts or {}
  local retries = tonumber(opts.retries) or 0
  if not self.host or self.host == "" then
    return nil, "eISY host is not configured"
  end

  local body_t = {}
  local headers = {
    Accept = "application/xml",
    Connection = "keep-alive",
    ["Keep-Alive"] = "5000"
  }
  if self.auth then headers.Authorization = self.auth end
  if self.protocol == "https" and not ok_https then
    return nil, "HTTPS support is unavailable in this Edge runtime"
  end
  local transport = self.protocol == "https" and https or http
  local previous_timeout = transport.TIMEOUT
  transport.TIMEOUT = self.timeout

  local ok, success, code, response_headers, status = pcall(transport.request, {
    url = self.base_url .. path,
    method = "GET",
    headers = headers,
    timeout = self.timeout,
    sink = ltn12.sink.table(body_t)
  })
  transport.TIMEOUT = previous_timeout

  local retryable = false
  local err
  if not ok then
    err = tostring(success)
    retryable = true
  elseif not success then
    err = tostring(code)
    retryable = true
  else
    code = tonumber(code) or 0
    if code == 401 then
      return nil, string.format("HTTP 401 %s", tostring(status or "Unauthorized"))
    elseif code == 404 and opts.ok404 then
      return "", nil, response_headers
    elseif code == 404 and opts.retry404 then
      err = string.format("HTTP 404 %s", tostring(status or "Not Found"))
      retryable = true
    elseif code == 503 then
      err = string.format("HTTP 503 %s", tostring(status or "Service Unavailable"))
      retryable = true
    elseif code < 200 or code >= 300 then
      return nil, string.format("HTTP %s %s", tostring(code), tostring(status or ""))
    else
      local body = table.concat(body_t)
      if body == EMPTY_XML_RESPONSE then
        err = "empty XML response"
        retryable = true
      else
        return body, nil, response_headers
      end
    end
  end

  if retryable and retries < MAX_RETRIES then
    cosock.socket.sleep(retry_delay(retries))
    local next_opts = {}
    for key, value in pairs(opts) do next_opts[key] = value end
    next_opts.retries = retries + 1
    return self:request(path, next_opts)
  end
  return nil, err
end

function client:get_nodes()
  local body, err = self:request("/rest/nodes?members=false")
  if not body then return nil, err end
  return client.parse_nodes(body)
end

function client:get_scene(id)
  local body, err = self:request("/rest/nodes/" .. client.encode_node_address(id) .. "?members=true")
  if not body then return nil, err end
  return isy_scene.parse(body, id)
end

-- One request with no retries, to check whether the eISY answers at all.
function client:probe()
  local body, err = self:request("/rest/config", { retries = MAX_RETRIES })
  return body ~= nil, err
end

function client:get_config()
  local body, err = self:request("/rest/config")
  if not body then return nil, err end
  return client.parse_config(body)
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
  return self:request(path, { retry404 = true })
end

return client
