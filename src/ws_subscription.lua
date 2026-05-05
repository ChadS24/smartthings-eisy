local cosock = require "cosock"
local log = require "log"
local ok_mime, mime = pcall(require, "mime")
local EisyClient = require "eisy_client"

local ws = {}
local WS_HEARTBEAT = 30
local WS_HEARTBEAT_GRACE = 5

local function mask_payload(payload, mask)
  local out = {}
  for index = 1, #payload do
    local payload_byte = string.byte(payload, index)
    local mask_byte = string.byte(mask, ((index - 1) % 4) + 1)
    out[index] = string.char(payload_byte ~ mask_byte)
  end
  return table.concat(out)
end

local function random_key()
  local raw = {}
  for index = 1, 16 do
    raw[index] = string.char(math.random(0, 255))
  end
  raw = table.concat(raw)
  if ok_mime and mime.b64 then return mime.b64(raw) end
  return EisyClient.base64_encode(raw)
end

local function read_http_headers(sock)
  local lines = {}
  while true do
    local line, err = sock:receive("*l")
    if not line then return nil, err end
    if line == "" then break end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

local function send_frame(sock, opcode, payload)
  payload = payload or ""
  local len = #payload
  local mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
  local header = { string.char(0x80 + opcode) }
  if len < 126 then
    header[#header + 1] = string.char(0x80 + len)
  elseif len <= 65535 then
    header[#header + 1] = string.char(0x80 + 126)
    header[#header + 1] = string.char(math.floor(len / 256) % 256, len % 256)
  else
    return nil, "large websocket frames are not supported"
  end
  header[#header + 1] = mask
  header[#header + 1] = mask_payload(payload, mask)
  return sock:send(table.concat(header))
end

local function read_frame(sock)
  local h1, err = sock:receive(1)
  if not h1 then return nil, err end
  local h2, h2_err = sock:receive(1)
  if not h2 then return nil, h2_err end
  local b1, b2 = string.byte(h1), string.byte(h2)
  local opcode = b1 % 16
  local len = b2 % 128
  if len == 126 then
    local ext = assert(sock:receive(2))
    local a, b = string.byte(ext, 1, 2)
    len = a * 256 + b
  elseif len == 127 then
    return nil, "large websocket frames are not supported"
  end
  if len == 0 then return "", nil, opcode end
  local payload, payload_err, partial = sock:receive(len)
  if payload then return payload, nil, opcode end
  if partial and #partial > 0 then return partial end
  return nil, payload_err
end

function ws.start(driver, controller_device, opts, on_message)
  if opts.protocol == "https" then
    log.info("eISY WebSocket over TLS is not implemented; polling fallback remains active")
    return nil
  end
  if not opts.host or opts.host == "" then return nil end

  local cancelled = false
  local connected = false
  local thread = controller_device.thread:call_with_delay(1, function()
    math.randomseed(os.time())
    local backoff = 5
    while not cancelled do
      local sock = cosock.socket.tcp()
      sock:settimeout(10)
      local ok, err = sock:connect(opts.host, tonumber(opts.port) or 80)
      if ok then
        local headers = {
          "GET /rest/subscribe HTTP/1.1",
          "Host: " .. opts.host .. ":" .. tostring(opts.port or 80),
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: " .. random_key(),
          "Sec-WebSocket-Version: 13",
          "Sec-WebSocket-Protocol: ISYSUB",
          "Origin: com.universal-devices.websockets.isy"
        }
        if opts.auth then headers[#headers + 1] = "Authorization: " .. opts.auth end
        sock:send(table.concat(headers, "\r\n") .. "\r\n\r\n")
        local response, header_err = read_http_headers(sock)
        if response and response:find("101", 1, true) then
          log.info("Connected to eISY WebSocket subscription")
          backoff = 5
          connected = true
          sock:settimeout(WS_HEARTBEAT + WS_HEARTBEAT_GRACE)
          while not cancelled do
            local frame, frame_err, opcode = read_frame(sock)
            if not frame then
              log.info("eISY WebSocket subscription closed; polling fallback remains active: " .. tostring(frame_err))
              connected = false
              break
            end
            if opcode == 1 or opcode == 2 or opcode == 0 then
              on_message(frame)
            elseif opcode == 8 then
              pcall(function() send_frame(sock, 8, frame) end)
              log.info("eISY WebSocket subscription closed by eISY; polling fallback remains active")
              connected = false
              break
            elseif opcode == 9 then
              local _, pong_err = send_frame(sock, 10, frame)
              if pong_err then log.warn("Unable to send eISY WebSocket pong: " .. tostring(pong_err)) end
            elseif opcode == 10 then
              log.debug("Received eISY WebSocket pong")
            else
              log.debug("Ignoring eISY WebSocket opcode " .. tostring(opcode))
            end
          end
        else
          connected = false
          log.info(string.format(
            "eISY WebSocket subscription unavailable at %s:%s; polling fallback remains active: %s",
            tostring(opts.host),
            tostring(opts.port or 80),
            tostring(header_err or response)
          ))
          break
        end
      else
        connected = false
        log.warn("eISY WebSocket connection failed: " .. tostring(err))
      end
      pcall(function() sock:close() end)
      connected = false
      cosock.socket.sleep(backoff)
      backoff = math.min(backoff * 2, 120)
    end
  end, "eisy websocket subscription")

  return {
    is_connected = function()
      return connected
    end,
    cancel = function()
      cancelled = true
      connected = false
      if thread and thread.cancel then thread:cancel() end
    end
  }
end

return ws
