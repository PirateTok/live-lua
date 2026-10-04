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

--- TikTok only sets ttwid on an anonymous GET intermittently, so a
-- response without the cookie is retried this many times, this far apart.
M.TTWID_FETCH_ATTEMPTS = 8
M.TTWID_RETRY_DELAY = 0.75

--- Pick the ttwid value out of a list of raw response header lines.
---@param lines table list of header lines (status line excluded)
---@return string|nil ttwid value
function M.parse_ttwid(lines)
    local ttwid = nil
    for i = 1, #lines do
        local header_value = lines[i]:match("^[Ss]et%-[Cc]ookie:%s*(.+)")
        if header_value then
            local found = extract_ttwid(header_value)
            if found then ttwid = found end
        end
    end
    return ttwid
end

--- GET https://www.tiktok.com/ and return the response header lines.
-- Transport only; overridable so tests can feed canned responses.
---@return table|nil header lines
---@return table|nil error
function M.request_headers(timeout, active_ua, proxy)
    local tcp = socket.tcp()
    tcp:settimeout(timeout)

    if proxy and proxy ~= "" then
        local phost, pport = proxy:match("^https?://([^:/]+):?(%d*)/?$")
        if not phost then
            return nil, errors.new(errors.HTTP_ERROR,
                "invalid proxy URL: " .. tostring(proxy))
        end
        pport = tonumber(pport) or 8080

        local ok, conn_err = tcp:connect(phost, pport)
        if not ok then
            return nil, errors.new(errors.HTTP_ERROR,
                "proxy connect failed: " .. tostring(conn_err))
        end

        local connect_req = "CONNECT " .. TIKTOK_HOST .. ":443 HTTP/1.1\r\n"
            .. "Host: " .. TIKTOK_HOST .. ":443\r\n\r\n"
        tcp:send(connect_req)

        local status_line = tcp:receive("*l")
        if not status_line or not status_line:match("^HTTP/1%.. 200") then
            tcp:close()
            return nil, errors.new(errors.HTTP_ERROR,
                "proxy CONNECT failed: " .. tostring(status_line))
        end
        while true do
            local line = tcp:receive("*l")
            if not line or line == "" then break end
        end
    else
        local ok, conn_err = tcp:connect(TIKTOK_HOST, 443)
        if not ok then
            return nil, errors.new(errors.HTTP_ERROR,
                "connect to tiktok.com failed: " .. tostring(conn_err))
        end
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

    local lines = {}
    while true do
        local line, recv_err = conn:receive("*l")
        if not line then
            conn:close()
            -- headers cut short but the cookie already arrived: good enough
            if M.parse_ttwid(lines) then return lines, nil end
            return nil, errors.new(errors.HTTP_ERROR,
                "receive failed: " .. tostring(recv_err))
        end
        if line == "" then break end
        lines[#lines + 1] = line
    end

    conn:close()
    return lines, nil
end

--- Fetch a ttwid cookie from TikTok — single request, no retry.
---@param timeout number request timeout in seconds (default 10)
---@param user_agent string|nil override UA (default: random from pool)
---@param proxy string|nil HTTP proxy URL
---@return string|nil ttwid value
---@return table|nil error (INVALID_RESPONSE when the cookie is missing)
function M.fetch_ttwid(timeout, user_agent, proxy)
    local lines, err = M.request_headers(
        timeout or 10, user_agent or ua.random_ua(), proxy)
    if not lines then return nil, err end

    local ttwid = M.parse_ttwid(lines)
    if not ttwid then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "no ttwid cookie in tiktok.com response")
    end
    return ttwid, nil
end

--- Fetch a ttwid, retrying while TikTok answers without the cookie.
-- Up to TTWID_FETCH_ATTEMPTS requests, TTWID_RETRY_DELAY seconds apart.
-- Transport errors are returned immediately.
---@return string|nil ttwid value
---@return table|nil error
function M.fetch_ttwid_retrying(timeout, user_agent, proxy)
    local attempt = 1
    while true do
        local ttwid, err = M.fetch_ttwid(timeout, user_agent, proxy)
        if ttwid then return ttwid, nil end
        if err.type ~= errors.INVALID_RESPONSE
            or attempt >= M.TTWID_FETCH_ATTEMPTS then
            return nil, err
        end
        attempt = attempt + 1
        M.sleep(M.TTWID_RETRY_DELAY)
    end
end

--- Sleep hook (overridable in tests).
M.sleep = socket.sleep

return M
