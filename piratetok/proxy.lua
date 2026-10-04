--- HTTP CONNECT proxy tunnel shared by the ttwid, HTTP API and WSS transports.
-- Proxy URL: http://[user:pass@]host[:port] (port defaults to 8080). Credentials are
-- sent as Proxy-Authorization: Basic. SOCKS proxies are not supported.
local mime = require "mime"
local errors = require "piratetok.errors"

local M = {}

local function unescape(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Parse a proxy URL.
---@param url string
---@return table|nil {host, port, auth} (auth = "Basic ..." or nil)
---@return table|nil error
function M.parse(url)
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme or (scheme ~= "http" and scheme ~= "https") then
        return nil, errors.new(errors.INVALID_URL, "unsupported proxy URL '" .. url
            .. "' — only HTTP CONNECT proxies (http://[user:pass@]host:port)")
    end
    local userinfo, hostport = rest:match("^([^@/]*)@([^/]+)/?$")
    if not userinfo then hostport = rest:match("^([^/]+)/?$") end
    local host, port = (hostport or ""):match("^([^:]+):?(%d*)$")
    if not host then
        return nil, errors.new(errors.INVALID_URL, "invalid proxy URL: " .. url)
    end
    local auth = nil
    if userinfo and userinfo ~= "" then
        auth = "Basic " .. mime.b64(unescape(userinfo))
    end
    return { host = host, port = tonumber(port) or 8080, auth = auth }, nil
end

--- Connect `tcp` to the proxy and open a CONNECT tunnel to target_host:target_port.
---@return boolean ok
---@return table|nil error
function M.tunnel(tcp, proxy_url, target_host, target_port)
    local p, perr = M.parse(proxy_url)
    if not p then return false, perr end

    local ok, conn_err = tcp:connect(p.host, p.port)
    if not ok then
        return false, errors.new(errors.HTTP_ERROR, "proxy connect failed: " .. tostring(conn_err))
    end
    local target = target_host .. ":" .. target_port
    local req = "CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n"
    if p.auth then req = req .. "Proxy-Authorization: " .. p.auth .. "\r\n" end
    local _, send_err = tcp:send(req .. "\r\n")
    if send_err then
        return false, errors.new(errors.HTTP_ERROR, "proxy CONNECT send failed: " .. tostring(send_err))
    end

    local status_line, recv_err = tcp:receive("*l")
    if not status_line then
        return false, errors.new(errors.HTTP_ERROR, "proxy CONNECT response failed: " .. tostring(recv_err))
    end
    if not status_line:match("^HTTP/1%.%d 200") then
        return false, errors.new(errors.HTTP_ERROR, "proxy CONNECT failed: " .. status_line)
    end
    while true do -- drain the rest of the proxy response head
        local line, line_err = tcp:receive("*l")
        if not line then
            return false, errors.new(errors.HTTP_ERROR, "proxy CONNECT header read failed: " .. tostring(line_err))
        end
        if line == "" then break end
    end
    return true, nil
end

return M
