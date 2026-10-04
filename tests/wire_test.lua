#!/usr/bin/env lua
--- Offline wire tests (F6/F7/F8 + F2 frames on the wire): the real client runs through a
--- local Basic-auth CONNECT proxy that terminates TLS (tests/fake_tiktok.lua, cert made
--- with openssl). No TikTok traffic. Usage: lua tests/wire_test.lua (from live-lua/)
package.path = "./?.lua;./?/init.lua;" .. package.path

local socket = require "socket"
local pb = require "pb"
local cjson = require "cjson"
local mime = require "mime"
local piratetok = require "piratetok"
local auth = require "piratetok.auth"
local ws = require "piratetok.websocket"

local passed, failed = 0, 0
local function check(cond, label) if not cond then error("assertion failed: " .. label, 2) end end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; io.write("ok   " .. name .. "\n")
    else failed = failed + 1; io.write("FAIL " .. name .. ": " .. tostring(err) .. "\n") end
end

-- ---- fixture: cert + helper process ----
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir))
local cert, key, log_path = dir .. "/cert.pem", dir .. "/key.pem", dir .. "/log.jsonl"
assert(os.execute("openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=pirate-test -keyout "
    .. key .. " -out " .. cert .. " >/dev/null 2>&1"), "openssl is required for the wire tests")

local probe = assert(socket.bind("127.0.0.1", 0))
local _, port = probe:getsockname()
probe:close()
local want_auth = "Basic " .. mime.b64("user:p@ss")
local lua_bin = arg[-1] or "lua"
assert(os.execute(string.format("%s tests/fake_tiktok.lua %d %s %s %s '%s' >/dev/null 2>&1 &",
    lua_bin, port, cert, key, log_path, want_auth)))

local function entries()
    local f = io.open(log_path, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = cjson.decode(line) end
    f:close()
    return out
end
local function wait_for(pred)
    local deadline = socket.gettime() + 5
    while socket.gettime() < deadline do
        if pred(entries()) then return true end
        socket.sleep(0.05)
    end
    return false
end
local function of_kind(kind)
    local out = {}
    for _, e in ipairs(entries()) do if e.kind == kind then out[#out + 1] = e end end
    return out
end
local function first_line(s) return s:match("^[^\r\n]*") end

assert(wait_for(function(es) return #es > 0 end), "fake proxy did not start")
local proxy_url = "http://user:p%40ss@127.0.0.1:" .. port

test("proxy: ttwid GET tunnels via authenticated CONNECT www.tiktok.com:443", function()
    local ttwid, err = auth.fetch_ttwid(5, "UA-Test/1", proxy_url)
    check(ttwid == "1%7Cwire%7C9", "ttwid: " .. tostring(ttwid) .. " " .. tostring(err and err.message))
    local p = of_kind("proxy")
    check(first_line(p[#p].head) == "CONNECT www.tiktok.com:443 HTTP/1.1", "CONNECT target")
    check(p[#p].head:find("Proxy-Authorization: " .. want_auth, 1, true), "Basic auth sent")
    local s = of_kind("server")
    check(first_line(s[#s].head) == "GET / HTTP/1.1" and s[#s].head:find("User-Agent: UA-Test/1", 1, true), "GET / with UA")
end)

test("connect: room id + ttwid + WSS through the proxy; UA/cookies/locale/compress on the wire", function()
    local before = #entries()
    local client = piratetok.builder("someone"):proxy(proxy_url):user_agent("UA-Test/1")
        :cookies("sessionid=abc; sid_tt=def"):language("ro"):region("RO"):compress(false)
        :heartbeat_interval(7):cdn("eu"):build()
    local ok, err = client:connect()
    check(ok and client._state == "connected", "connected: " .. tostring(err and err.message) .. " " .. client._state)
    check(wait_for(function(es)
        local n = 0
        for i = before + 1, #es do if es[i].kind == "frame" then n = n + 1 end end
        return n >= 2
    end), "2 frames reached the fake")
    client:disconnect()

    local targets = {}
    for _, e in ipairs(of_kind("proxy")) do
        if e.head:find(want_auth, 1, true) then targets[first_line(e.head)] = true end
    end
    check(targets["CONNECT www.tiktok.com:443 HTTP/1.1"], "room/ttwid tunnel")
    check(targets["CONNECT webcast-ws.eu.tiktok.com:443 HTTP/1.1"], "wss tunnel (eu)")

    local room, up
    for _, e in ipairs(of_kind("server")) do
        if e.head:match("^GET /api%-live/user/room") then room = e.head end
        if e.head:lower():find("\nupgrade: websocket", 1, true) then up = e.head end
    end
    check(room and room:find("app_language=ro&browser_language=ro-RO&region=RO", 1, true), "room locale")
    check(room:find("User-Agent: UA-Test/1", 1, true), "room UA")
    local line = first_line(up)
    for _, q in ipairs({ "room_id=730002", "browser_language=ro-RO", "app_language=ro", "webcast_language=ro",
            "compress=&", "heartbeat_duration=7000" }) do
        check(line:find(q, 1, true), "upgrade URL has " .. q)
    end
    check(up:find("Host: webcast-ws.eu.tiktok.com", 1, true), "eu host")
    local header_lines = {}
    for l in (up .. "\r\n"):gmatch("([^\r\n]*)\r\n") do header_lines[l] = true end
    check(header_lines["Cookie: ttwid=1%7Cwire%7C9; sessionid=abc; sid_tt=def"], "cookie: ttwid + user cookies")
    check(up:find("User-Agent: UA-Test/1", 1, true), "WSS UA")
    check(up:find("Accept-Language: ro-RO,ro;q=0.9", 1, true), "accept-language")

    local frames = {}
    for i = before + 1, #entries() do
        local e = entries()[i]
        if e.kind == "frame" then frames[#frames + 1] = (e.hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end
    end
    local hb = pb.decode("WebcastPushFrame", frames[1])
    local enter = pb.decode("WebcastPushFrame", frames[2])
    check(hb.payload_type == "hb" and pb.decode("HeartbeatMessage", hb.payload).room_id == 730002, "heartbeat frame")
    local er = pb.decode("WebcastImEnterRoomMessage", enter.payload)
    check(enter.payload_type == "im_enter_room" and er.room_id == 730002 and er.identity == "audience", "enter_room frame")
end)

test("proxy: wrong credentials -> WSS dial fails at CONNECT (407)", function()
    local conn, err = ws.connect("wss://webcast-ws.tiktok.com/x", { Cookie = "ttwid=x" }, "UA",
        "http://user:nope@127.0.0.1:" .. port)
    check(conn == nil and err.message:find("proxy CONNECT failed: HTTP/1.1 407", 1, true), tostring(err and err.message))
end)

-- stop the helper
local q = socket.tcp()
q:connect("127.0.0.1", port)
q:send("QUIT\r\n\r\n")
q:close()
os.execute("rm -rf " .. dir)

io.write(string.format("\n--- %d passed, %d failed ---\n", passed, failed))
if failed > 0 or passed == 0 then os.exit(1) end
