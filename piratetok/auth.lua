--- ttwid acquisition — unauthenticated GET to tiktok.com.
-- The ttwid cookie is the sole credential needed for WSS connections.
-- No signing, no browser, no session cookies required.
local socket = require "socket"
local ssl = require "ssl"
local errors = require "piratetok.errors"
local ua = require "piratetok.ua"

local M = {}

local TIKTOK_HOST = "www.tiktok.com"

--- Extract ttwid value from a Set-Cookie header line.
---@param header string the Set-Cookie header value
---@return string|nil ttwid value or nil
local function extract_ttwid(header)
    local value = header:match("^ttwid=([^;]+)")
    if not value or value == "" then
        return nil
    end
    return value
end

--- Fetch a fresh ttwid cookie from TikTok.
---@param timeout number request timeout in seconds (default 10)
---@param user_agent string|nil override UA (default: random from pool)
---@return string|nil ttwid value
---@return table|nil error
function M.fetch_ttwid(timeout, user_agent)
    timeout = timeout or 10
    local active_ua = user_agent or ua.random_ua()

    local tcp = socket.tcp()
    tcp:settimeout(timeout)

    local ok, conn_err = tcp:connect(TIKTOK_HOST, 443)
    if not ok then
        return nil, errors.new(errors.HTTP_ERROR,
            "connect to tiktok.com failed: " .. tostring(conn_err))
    end

    local params = {
        mode = "client",
        protocol = "any",
        verify = "none",
        options = "all",
    }
    local conn, tls_err = ssl.wrap(tcp, params)
    if not conn then
        tcp:close()
        return nil, errors.new(errors.HTTP_ERROR,
            "tls wrap failed: " .. tostring(tls_err))
    end

    conn:sni(TIKTOK_HOST)
    local hs_ok, hs_err = conn:dohandshake()
    if not hs_ok then
        tcp:close()
        return nil, errors.new(errors.HTTP_ERROR,
            "tls handshake failed: " .. tostring(hs_err))
    end

    -- Send minimal GET — we only need the Set-Cookie header
    local request = "GET / HTTP/1.1\r\n"
        .. "Host: " .. TIKTOK_HOST .. "\r\n"
        .. "User-Agent: " .. active_ua .. "\r\n"
        .. "Accept: text/html\r\n"
        .. "Connection: close\r\n"
        .. "\r\n"

    local _, send_err = conn:send(request)
    if send_err then
        conn:close()
        return nil, errors.new(errors.HTTP_ERROR,
            "send failed: " .. tostring(send_err))
    end

    -- Read response headers looking for ttwid Set-Cookie
    local ttwid = nil
    while true do
        local line, recv_err = conn:receive("*l")
        if not line then
            conn:close()
            if ttwid then return ttwid, nil end
            return nil, errors.new(errors.HTTP_ERROR,
                "receive failed: " .. tostring(recv_err))
        end
        if line == "" then break end

        local header_value = line:match("^[Ss]et%-[Cc]ookie:%s*(.+)")
        if header_value then
            local found = extract_ttwid(header_value)
            if found then
                ttwid = found
            end
        end
    end

    conn:close()

    if not ttwid then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "no ttwid cookie in tiktok.com response")
    end

    return ttwid, nil
end

return M
