#!/usr/bin/env lua
--- Test helper (spawned by tests/wire_test.lua): an HTTP CONNECT proxy that requires
--- Basic auth and terminates every tunnel itself with a local TLS cert, faking
--- www.tiktok.com (room id + ttwid) and webcast-ws (101 upgrade, records client frames).
--- Every request head / frame is appended as a JSON line to the log file.
--- usage: lua tests/fake_tiktok.lua <port> <cert.pem> <key.pem> <log> <expected auth>
package.path = "./?.lua;./?/init.lua;" .. package.path
local socket = require "socket"
local ssl = require "ssl"
local cjson = require "cjson"

local port, cert, key, log_path, want_auth = tonumber(arg[1]), arg[2], arg[3], arg[4], arg[5]
local log = assert(io.open(log_path, "a"))
log:setvbuf("line")
local function rec(t) log:write(cjson.encode(t), "\n") end

local function read_head(c)
    local lines = {}
    while true do
        local l = c:receive("*l")
        if not l then return nil end
        if l == "" then return table.concat(lines, "\r\n") end
        lines[#lines + 1] = l
    end
end

local function tohex(s) return (s:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)) end

local ROOM = '{"statusCode":0,"data":{"user":{"id":"690001","roomId":"730002","status":2},"liveRoom":{"status":2}}}'

-- byte xor without bit ops (runs on Lua 5.1/LuaJIT and 5.3+)
local function bxor(a, b)
    local r, bit = 0, 1
    while a > 0 or b > 0 do
        if a % 2 ~= b % 2 then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

local function serve_ws(t)
    t:send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
    while true do
        local h = t:receive(2)
        if not h then return end
        local op, len = h:byte(1) % 16, h:byte(2) % 128
        if len == 126 then
            local e = t:receive(2)
            len = e:byte(1) * 256 + e:byte(2)
        end
        local mask = t:receive(4)
        local p = len > 0 and t:receive(len) or ""
        local out = {}
        for i = 1, #p do out[i] = string.char(bxor(p:byte(i), mask:byte((i - 1) % 4 + 1))) end
        if op == 8 then return end
        rec({ kind = "frame", hex = tohex(table.concat(out)) })
    end
end

local function sigi(detail)
    return '<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">'
        .. cjson.encode({ __DEFAULT_SCOPE__ = { ["webapp.user-detail"] = detail } }) .. "</script></html>"
end

local PROFILES = {
    ["/@someone"] = sigi({ statusCode = 0, userInfo = {
        user = { id = "6900000000000000001", uniqueId = "someone", nickname = "Some One", signature = "bio here",
            avatarLarger = "https://p16/l.jpg", verified = true, privateAccount = false,
            roomId = "7300000000000000002", bioLink = { link = "piratetok.rosint.org" } },
        stats = { followerCount = 10, followingCount = 2, heartCount = 99, videoCount = 3, friendCount = 1 } } }),
    ["/@privy"] = sigi({ statusCode = 10222 }),
    ["/@ghost"] = sigi({ statusCode = 10221 }),
}

local function serve_http(t, head)
    local body, cookie = "ok", ""
    local path = head:match("^GET (%S+)")
    if PROFILES[path] then body = PROFILES[path] end
    if head:match("^GET /api%-live/user/room") then body = ROOM end
    if head:match("^GET / ") then cookie = "Set-Cookie: ttwid=1%7Cwire%7C9; Path=/; Secure\r\n" end
    t:send("HTTP/1.1 200 OK\r\n" .. cookie .. "Content-Type: application/json\r\nContent-Length: "
        .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
end

local server = assert(socket.bind("127.0.0.1", port))
rec({ kind = "ready" })
while true do
    local c = assert(server:accept())
    c:settimeout(10)
    local head = read_head(c)
    if head and head:match("^QUIT") then c:close(); break end
    if head then
        rec({ kind = "proxy", head = head })
        local got = head:match("\n[Pp]roxy%-[Aa]uthorization: ([^\r\n]+)")
        if not head:match("^CONNECT ") or got ~= want_auth then
            c:send("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
            c:close()
        else
            c:send("HTTP/1.1 200 Connection Established\r\n\r\n")
            local t = assert(ssl.wrap(c, { mode = "server", protocol = "any", key = key, certificate = cert }))
            t:settimeout(10)
            if t:dohandshake() then
                local inner = read_head(t)
                if inner then
                    rec({ kind = "server", head = inner })
                    if inner:lower():match("\nupgrade: websocket") then serve_ws(t) else serve_http(t, inner) end
                end
            end
            t:close()
        end
    end
end
log:close()
