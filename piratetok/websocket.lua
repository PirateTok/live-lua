--- Minimal WebSocket client for TikTok Live WSS.
-- Hand-rolled framing on top of luasocket + luasec.
-- Supports binary frames, ping/pong, close, non-blocking reads.
local unpack = unpack or table.unpack
local socket = require "socket"
local ssl = require "ssl"
local errors = require "piratetok.errors"
local ua_mod = require "piratetok.ua"

-- Bit ops compat: LuaJIT uses 'bit' library, Lua 5.3+ has native operators
local bit = bit  -- luacheck: ignore
if not bit then
    bit = {
        bxor  = function(a, b) return a ~ b end,
        band  = function(a, b) return a & b end,
        bor   = function(a, b) return a | b end,
        lshift = function(a, n) return a << n end,
        rshift = function(a, n) return a >> n end,
    }
end

local M = {}
M.__index = M

local OPCODE_CONT = 0x00
local OPCODE_TEXT = 0x01
local OPCODE_BINARY = 0x02
local OPCODE_CLOSE = 0x08
local OPCODE_PING = 0x09
local OPCODE_PONG = 0x0A

local function generate_mask_key()
    local bytes = {}
    for i = 1, 4 do
        bytes[i] = math.random(0, 255)
    end
    return string.char(unpack(bytes))
end

local function mask_payload(data, mask_key)
    local out = {}
    for i = 1, #data do
        local j = ((i - 1) % 4) + 1
        out[i] = string.char(bit.bxor(string.byte(data, i), string.byte(mask_key, j)))
    end
    return table.concat(out)
end

local function encode_frame(opcode, payload)
    local mask_key = generate_mask_key()
    local len = #payload
    local header

    -- FIN bit set (0x80) + opcode, masked bit set (0x80) + length
    if len < 126 then
        header = string.char(0x80 + opcode, 0x80 + len)
    elseif len < 65536 then
        header = string.char(
            0x80 + opcode, 0x80 + 126,
            bit.rshift(len, 8), bit.band(len, 0xFF)
        )
    else
        -- 8-byte extended length
        header = string.char(0x80 + opcode, 0x80 + 127)
        local len_bytes = {}
        for i = 7, 0, -1 do
            len_bytes[#len_bytes + 1] = string.char(
                bit.band(bit.rshift(len, i * 8), 0xFF)
            )
        end
        header = header .. table.concat(len_bytes)
    end

    return header .. mask_key .. mask_payload(payload, mask_key)
end

--- Parse the URL into host, port, path components.
---@param url string wss:// URL
---@return string host
---@return number port
---@return string path
---@return nil
local function parse_wss_url(url)
    local proto, host, port, path = url:match("^(wss?)://([^/:]+):?(%d*)(/.*)$")
    if not proto then
        return nil, nil, nil, "invalid websocket URL: " .. url
    end
    port = tonumber(port) or (proto == "wss" and 443 or 80)
    return host, port, path, nil
end

--- Perform WebSocket upgrade handshake over an existing TLS socket.
---@param conn userdata TLS-wrapped socket
---@param host string
---@param path string
---@param cookie string Cookie header value
---@param user_agent string|nil override UA (default: random from pool)
---@return boolean success
---@return string|nil error message or nil
---@return boolean|nil is_device_blocked (true when DEVICE_BLOCKED detected)
local function do_handshake(conn, host, path, cookie, user_agent)
    local active_ua = user_agent or ua_mod.random_ua()

    -- Generate random Sec-WebSocket-Key
    local key_bytes = {}
    for i = 1, 16 do
        key_bytes[i] = math.random(0, 255)
    end
    local b64 = require("mime").b64
    local ws_key = b64(string.char(unpack(key_bytes)))

    local lines = {
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. ws_key,
        "Sec-WebSocket-Version: 13",
        "User-Agent: " .. active_ua,
        "Referer: https://www.tiktok.com/",
        "Origin: https://www.tiktok.com",
        "Accept-Language: en-US,en;q=0.9",
        "Accept-Encoding: gzip, deflate",
        "Cache-Control: no-cache",
        "Cookie: " .. cookie,
        "",
        "",
    }

    local request = table.concat(lines, "\r\n")
    local bytes_sent, send_err = conn:send(request)
    if not bytes_sent then
        return false, "handshake send failed: " .. tostring(send_err), false
    end

    -- Read response line by line until blank line
    local status_line, recv_err = conn:receive("*l")
    if not status_line then
        return false, "handshake receive failed: " .. tostring(recv_err), false
    end

    local status_code = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))

    -- Read remaining headers — check for DEVICE_BLOCKED
    local device_blocked = false
    while true do
        local line, line_err = conn:receive("*l")
        if not line then
            return false, "handshake header read failed: " .. tostring(line_err), false
        end
        if line == "" then break end
        -- TikTok signals device block via Handshake-Msg header
        if line:lower():match("handshake%-msg:%s*device_blocked") then
            device_blocked = true
        end
    end

    if status_code ~= 101 then
        if device_blocked or status_code == 415 then
            return false, "DEVICE_BLOCKED", true
        end
        return false, "websocket upgrade failed: HTTP " .. tostring(status_code), false
    end

    return true, nil, false
end

--- Connect to a WSS endpoint.
---@param url string full wss:// URL
---@param extra_headers table headers to send with upgrade (Cookie field)
---@param user_agent string|nil override UA (default: random from pool)
---@return table|nil websocket client object
---@return table|nil error
function M.connect(url, extra_headers, user_agent)
    local host, port, path, parse_err = parse_wss_url(url)
    if parse_err then
        return nil, errors.new(errors.INVALID_URL, parse_err)
    end

    local tcp = socket.tcp()
    tcp:settimeout(10)
    local ok, conn_err = tcp:connect(host, port)
    if not ok then
        return nil, errors.new(errors.WEBSOCKET_ERROR,
            "tcp connect to " .. host .. ":" .. port .. " failed: " .. tostring(conn_err))
    end

    -- Disable Nagle's algorithm — tiny frames (heartbeat 20B, enter_room 46B)
    -- must hit the wire immediately, not get buffered. Python websockets sets this
    -- by default; luasocket does not.
    tcp:setoption("tcp-nodelay", true)

    -- TLS wrap
    local params = {
        mode = "client",
        protocol = "any",
        verify = "none",
        options = "all",
    }
    local tls_conn, tls_err = ssl.wrap(tcp, params)
    if not tls_conn then
        tcp:close()
        return nil, errors.new(errors.WEBSOCKET_ERROR, "tls wrap failed: " .. tostring(tls_err))
    end

    tls_conn:sni(host)
    local hs_ok, hs_err = tls_conn:dohandshake()
    if not hs_ok then
        tcp:close()
        return nil, errors.new(errors.WEBSOCKET_ERROR, "tls handshake failed: " .. tostring(hs_err))
    end

    -- WebSocket upgrade
    local cookie = (extra_headers or {}).Cookie or ""

    local ws_ok, ws_err, is_blocked = do_handshake(
        tls_conn, host, path, cookie, user_agent)
    if not ws_ok then
        tls_conn:close()
        if is_blocked then
            return nil, errors.new(errors.DEVICE_BLOCKED,
                "ttwid fingerprint blocked by TikTok — will retry with fresh ttwid")
        end
        return nil, errors.new(errors.WEBSOCKET_ERROR, ws_err)
    end

    -- Switch to non-blocking for poll-based reads
    tls_conn:settimeout(0)

    local self = setmetatable({
        conn = tls_conn,
        tcp = tcp,
        closed = false,
        read_buf = "",
    }, M)

    return self, nil
end

--- Send a binary frame.
---@param data string binary payload
---@return boolean success
---@return string|nil error
function M:send_binary(data)
    if self.closed then
        return false, "connection closed"
    end
    local frame = encode_frame(OPCODE_BINARY, data)
    self.conn:settimeout(5)
    local sent = 0
    while sent < #frame do
        local bytes, err, partial = self.conn:send(frame, sent + 1)
        if bytes then
            sent = bytes
        elseif err == "wantwrite" or err == "wantread" then
            sent = partial or sent
        else
            self.conn:settimeout(0)
            return false, "send failed: " .. tostring(err)
        end
    end
    self.conn:settimeout(0)
    return true, nil
end

--- Send a pong frame (response to ping).
---@param data string ping payload to echo back
function M:send_pong(data)
    if self.closed then return end
    local frame = encode_frame(OPCODE_PONG, data or "")
    self.conn:settimeout(5)
    self.conn:send(frame)
    self.conn:settimeout(0)
end

--- Non-blocking read of one WebSocket frame.
---@return number|nil opcode
---@return string|nil payload
---@return string|nil error
function M:read_frame()
    if self.closed then
        return nil, nil, "closed"
    end

    -- Try to read 2-byte header
    local header, header_err = self:_read_exact(2)
    if not header then
        return nil, nil, header_err
    end

    local b1 = string.byte(header, 1)
    local b2 = string.byte(header, 2)
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(b2, 0x80) ~= 0
    local payload_len = bit.band(b2, 0x7F)

    -- Extended payload length
    if payload_len == 126 then
        local ext, ext_err = self:_read_exact(2)
        if not ext then return nil, nil, ext_err end
        payload_len = bit.lshift(string.byte(ext, 1), 8) + string.byte(ext, 2)
    elseif payload_len == 127 then
        local ext, ext_err = self:_read_exact(8)
        if not ext then return nil, nil, ext_err end
        payload_len = 0
        for i = 1, 8 do
            payload_len = payload_len * 256 + string.byte(ext, i)
        end
    end

    -- Mask key (servers shouldn't mask, but handle it)
    local mask_key
    if masked then
        local mk, mk_err = self:_read_exact(4)
        if not mk then return nil, nil, mk_err end
        mask_key = mk
    end

    -- Payload
    local payload = ""
    if payload_len > 0 then
        local pl, pl_err = self:_read_exact(payload_len)
        if not pl then return nil, nil, pl_err end
        payload = pl
        if masked then
            payload = mask_payload(payload, mask_key)
        end
    end

    return opcode, payload, nil
end

--- Read exactly n bytes, buffering partial reads.
---@param n number bytes needed
---@return string|nil data
---@return string|nil error
function M:_read_exact(n)
    while #self.read_buf < n do
        -- Short blocking timeout for frame completion
        self.conn:settimeout(0.05)
        local chunk, err, partial = self.conn:receive(n - #self.read_buf)
        self.conn:settimeout(0)
        if chunk then
            self.read_buf = self.read_buf .. chunk
        elseif partial and #partial > 0 then
            self.read_buf = self.read_buf .. partial
        elseif err == "timeout" or err == "wantread" or err == "wantwrite" then
            -- timeout: no data yet; wantread/wantwrite: LuaSec TLS renegotiation
            if #self.read_buf == 0 then
                return nil, "timeout"
            end
            -- Keep trying if we have partial data
        elseif err == "closed" then
            self.closed = true
            return nil, "closed"
        else
            return nil, err or "read error"
        end
    end

    local result = self.read_buf:sub(1, n)
    self.read_buf = self.read_buf:sub(n + 1)
    return result, nil
end

--- Close the connection cleanly.
function M:close()
    if self.closed then return end
    self.closed = true
    -- Send close frame (best-effort)
    local frame = encode_frame(OPCODE_CLOSE, "")
    self.conn:settimeout(2)
    self.conn:send(frame)
    self.conn:close()
end

return M
