#!/usr/bin/env lua
--- Offline unit tests — no network. Transport, sleep and clock are stubbed.
--- Usage: lua tests/unit_test.lua   (run from live-lua/ root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local socket = require "socket"
local pb = require "pb"
local cjson = require "cjson"
local piratetok = require "piratetok"
local auth = require "piratetok.auth"
local http = require "piratetok.http"
local ws = require "piratetok.websocket"
local errors = require "piratetok.errors"
local events = require "piratetok.events"
local audience = require "piratetok.audience"

local passed, failed = 0, 0

local function check(cond, label)
    if not cond then error("assertion failed: " .. label, 2) end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("ok   " .. name .. "\n")
    else
        failed = failed + 1
        io.write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

-- ---- W1: ttwid fetch retry ----

local NO_COOKIE = { "Content-Type: text/html", "Set-Cookie: msToken=abc; Path=/" }
local WITH_COOKIE = { "Content-Type: text/html",
    "Set-Cookie: ttwid=1%7Cabc%7C123%7Cdef; Path=/; Secure" }

local function stub_transport(responses)
    local calls, sleeps = 0, 0
    auth.request_headers = function()
        calls = calls + 1
        local r = responses[math.min(calls, #responses)]
        if r.err then return nil, r.err end
        return r.lines, nil
    end
    auth.sleep = function() sleeps = sleeps + 1 end
    return function() return calls, sleeps end
end

local real_request_headers = auth.request_headers
local real_sleep = auth.sleep

test("ttwid: missing cookie x3 then cookie -> succeeds on 4th", function()
    local counts = stub_transport({
        { lines = NO_COOKIE }, { lines = NO_COOKIE }, { lines = NO_COOKIE },
        { lines = WITH_COOKIE },
    })
    local ttwid, err = auth.fetch_ttwid_retrying(1, "ua", nil)
    local calls, sleeps = counts()
    check(err == nil, "no error")
    check(ttwid == "1%7Cabc%7C123%7Cdef", "ttwid value")
    check(calls == 4, "4 requests, got " .. calls)
    check(sleeps == 3, "3 sleeps, got " .. sleeps)
end)

test("ttwid: never a cookie -> InvalidResponse after 8 attempts", function()
    local counts = stub_transport({ { lines = NO_COOKIE } })
    local ttwid, err = auth.fetch_ttwid_retrying(1, "ua", nil)
    local calls, sleeps = counts()
    check(ttwid == nil, "no ttwid")
    check(err.type == errors.INVALID_RESPONSE, "InvalidResponse")
    check(calls == auth.TTWID_FETCH_ATTEMPTS, "8 requests, got " .. calls)
    check(sleeps == auth.TTWID_FETCH_ATTEMPTS - 1, "7 sleeps")
end)

test("ttwid: transport error propagates without retry", function()
    local counts = stub_transport({
        { err = errors.new(errors.HTTP_ERROR, "connect refused") } })
    local ttwid, err = auth.fetch_ttwid_retrying(1, "ua", nil)
    local calls = counts()
    check(ttwid == nil and err.type == errors.HTTP_ERROR, "HttpError")
    check(calls == 1, "single request")
end)

auth.request_headers = real_request_headers
auth.sleep = real_sleep

-- ---- W1: reconnect loop ----

local now = 1000
local real_gettime = socket.gettime
socket.gettime = function() return now end

local function fake_conn()
    return {
        send_binary = function() return true, nil end,
        close = function() end,
        read_frame = function() return nil, nil, "timeout" end,
        send_pong = function() end,
    }
end

--- Build a client whose ttwid fetches and WSS dials are scripted.
--- dial_results: list of "ok" | "fail" | "blocked" consumed per dial.
local function scripted_client(dial_results, max_retries)
    local log = { ttwid_fetches = 0, uas = {}, reconnecting = {}, disconnected = 0 }
    auth.fetch_ttwid_retrying = function(_, user_agent)
        log.ttwid_fetches = log.ttwid_fetches + 1
        return "ttwid-" .. log.ttwid_fetches, nil
    end
    local dial = 0
    ws.connect = function(_, headers, user_agent)
        dial = dial + 1
        log.uas[#log.uas + 1] = user_agent
        log.last_cookie = headers.Cookie
        local r = dial_results[math.min(dial, #dial_results)]
        if r == "ok" then return fake_conn(), nil end
        if r == "blocked" then
            return nil, errors.new(errors.DEVICE_BLOCKED, "DEVICE_BLOCKED")
        end
        return nil, errors.new(errors.WEBSOCKET_ERROR, "handshake failed")
    end
    local client = piratetok.builder("someone")
        :max_retries(max_retries or 5):build()
    client._room_id = "7000000000000000000"
    client:on("reconnecting", function(e) log.reconnecting[#log.reconnecting + 1] = e end)
    client:on("disconnected", function() log.disconnected = log.disconnected + 1 end)
    return client, log
end

test("loop: consecutive failures accumulate with backoff", function()
    local client, log = scripted_client({ "fail" }, 5)
    client:_try_reconnect()
    for _ = 1, 2 do
        now = now + 60
        client:poll()
    end
    check(#log.reconnecting == 3, "3 reconnecting events")
    check(log.reconnecting[1].attempt == 1 and log.reconnecting[1].delay_secs == 2, "attempt 1 / 2s")
    check(log.reconnecting[2].attempt == 2 and log.reconnecting[2].delay_secs == 4, "attempt 2 / 4s")
    check(log.reconnecting[3].attempt == 3 and log.reconnecting[3].delay_secs == 8, "attempt 3 / 8s")
end)

test("loop: max_retries exceeded -> disconnected", function()
    local client, log = scripted_client({ "fail" }, 2)
    client:_try_reconnect()
    for _ = 1, 3 do
        now = now + 60
        client:poll()
    end
    check(#log.reconnecting == 2, "2 reconnecting events")
    check(log.disconnected == 1, "disconnected once")
    check(client._state == "disconnected", "state disconnected")
end)

test("loop: healthy session resets counter and keeps ttwid + UA", function()
    local client, log = scripted_client({ "fail", "fail", "ok", "ok" }, 5)
    client:_try_reconnect()                 -- fail -> attempt 1
    now = now + 60; client:poll()           -- fail -> attempt 2
    now = now + 60; client:poll()           -- ok
    check(client._state == "connected", "connected")
    local fetches = log.ttwid_fetches
    now = now + 45                          -- healthy (>= 30 s)
    client:_start_reconnect("stale")
    local last = log.reconnecting[#log.reconnecting]
    check(last.attempt == 1, "counter reset to 1, got " .. last.attempt)
    check(last.delay_secs == 2, "backoff restarts at 2s")
    now = now + 60; client:poll()           -- reconnect with held session
    check(log.ttwid_fetches == fetches, "ttwid reused, no new fetch")
    check(log.uas[#log.uas] == log.uas[#log.uas - 1], "UA reused")
end)

test("loop: short-lived session counts as failure and rotates ttwid", function()
    local client, log = scripted_client({ "ok" }, 5)
    client:_try_reconnect()
    check(client._state == "connected", "connected")
    now = now + 5                           -- dies within 30 s
    client:_start_reconnect("read error")
    check(log.reconnecting[1].attempt == 1, "attempt 1")
    check(client._session == nil, "session dropped")
    now = now + 60; client:poll()
    check(log.ttwid_fetches == 2, "fresh ttwid fetched")
end)

test("loop: DEVICE_BLOCKED rotates ttwid + UA with 2s delay", function()
    local client, log = scripted_client({ "blocked", "ok" }, 5)
    client:_try_reconnect()
    check(log.reconnecting[1].device_blocked == true, "flagged blocked")
    check(log.reconnecting[1].delay_secs == 2, "2s delay")
    check(client._session == nil, "session dropped")
    now = now + 3; client:poll()
    check(log.ttwid_fetches == 2, "fresh ttwid after block")
    check(log.last_cookie == "ttwid=ttwid-2", "new ttwid on the wire")
end)

test("loop: ttwid failure on connect() is a failed attempt, not an abort", function()
    local real_fetch_room_id = http.fetch_room_id
    http.fetch_room_id = function() return { room_id = "1", anchor_id = "2" }, nil end
    local client, log = scripted_client({ "ok" }, 5)
    auth.fetch_ttwid_retrying = function()
        return nil, errors.new(errors.INVALID_RESPONSE, "no ttwid cookie")
    end
    local started, err = client:connect()
    http.fetch_room_id = real_fetch_room_id
    check(started == true and err == nil, "connect() did not abort")
    check(client._state == "reconnecting", "state reconnecting")
    check(#log.reconnecting == 1, "Reconnecting emitted")
end)

test("url: heartbeat_duration follows heartbeat_interval", function()
    local url = require("piratetok.url").build_ws_url(
        "webcast-ws.tiktok.com", "1", "en", "US", true, 7)
    check(url:find("heartbeat_duration=7000", 1, true) ~= nil, "7000 ms")
end)

socket.gettime = real_gettime

-- ---- W4: ranks_list decode + top_viewers ----

test("ranks_list: decodes contributors, top_viewers sorts by rank", function()
    local seq_bytes = assert(pb.encode("WebcastRoomUserSeqMessage", {
        ranks_list = {
            { score = 300, rank = 3, delta = 1, user = { id = 33, nickname = "c" } },
            { score = 900, rank = 1, delta = 0, user = { id = 11, nickname = "a" } },
            { score = 50, rank = 4, delta = 0 },
            { score = 600, rank = 2, delta = 2, user = { id = 22, nickname = "b" } },
        },
        viewer_count = 1234,
        pop_str = "1.2K",
        total_user = 5678,
        anonymous = 9,
    }))
    local evts = events.decode_message("WebcastRoomUserSeqMessage", seq_bytes)
    local seq = evts[1].data
    check(evts[1].name == "room_user_seq", "event name")
    check(#seq.ranks_list == 4, "4 ranks decoded")
    check(seq.viewer_count == 1234 and seq.total_user == 5678, "counts")
    check(seq.pop_str == "1.2K" and seq.anonymous == 9, "pop_str/anonymous")
    local top = piratetok.top_viewers(seq)
    check(#top == 3, "contributor without user skipped")
    check(top[1].user.nickname == "a" and top[2].user.nickname == "b"
        and top[3].user.nickname == "c", "sorted by rank")
    check(top[1].score == 900, "score carried")
end)

-- ---- W5: online_audience parsing ----

local function fixture(tbl) return cjson.encode(tbl) end

test("audience: status 0 parses viewers, skips rank without user", function()
    local body = fixture({
        status_code = 0,
        data = {
            total = 42, anonymous = 7,
            ranks = {
                { rank = 1, score = 500, user = {
                    id_str = "7200000000000000001", display_id = "viewer_one",
                    nickname = "One", sec_uid = "MS4w",
                    avatar_thumb = { url_list = { "https://p16/a.jpg" } },
                    follow_info = { follower_count = 99 },
                    verified = true, is_follower = true, is_following = false,
                    is_subscribe = true } },
                { rank = 2, score = 100 },
            },
        },
    })
    local res, err = audience.parse(body, 200, cjson.decode)
    check(err == nil, "no error")
    check(res.total == 42 and res.anonymous == 7, "totals")
    check(#res.viewers == 1, "one viewer")
    local v = res.viewers[1]
    check(v.user_id == "7200000000000000001", "id_str kept exact")
    check(v.username == "viewer_one" and v.nickname == "One", "names")
    check(v.avatar_url == "https://p16/a.jpg", "avatar")
    check(v.follower_count == 99, "follower_count")
    check(v.verified and v.is_follower and not v.is_following and v.is_subscriber, "flags")
    check(res.raw_json == body, "raw_json")
end)

test("audience: status 20003 -> SessionRequired", function()
    local res, err = audience.parse(fixture({ status_code = 20003, data = {} }), 200, cjson.decode)
    check(res == nil and err.type == errors.SESSION_REQUIRED, "SessionRequired")
    check(err.message:find("session cookies", 1, true) ~= nil, "mentions cookies")
end)

test("audience: other status -> InvalidResponse with code + message", function()
    local res, err = audience.parse(fixture({
        status_code = 10011, data = { message = "param error" } }), 200, cjson.decode)
    check(res == nil and err.type == errors.INVALID_RESPONSE, "InvalidResponse")
    check(err.message == "online_audience status_code=10011 param error", err.message)
end)

test("audience: empty body / missing status_code -> InvalidResponse", function()
    local _, e1 = audience.parse("", 502, cjson.decode)
    check(e1.type == errors.INVALID_RESPONSE and e1.message:find("http 502", 1, true), "empty")
    local _, e2 = audience.parse(fixture({ data = {} }), 200, cjson.decode)
    check(e2.type == errors.INVALID_RESPONSE, "missing status_code")
end)

test("audience: owner id from room info", function()
    local id = audience.owner_id(fixture({ data = { owner = { id_str = "6800000000000000009" } } }), cjson.decode)
    check(id == "6800000000000000009", "owner id_str")
    local none, err = audience.owner_id(fixture({ data = {} }), cjson.decode)
    check(none == nil and err.message == "no owner id in room info", "missing owner")
end)

-- ---- W3: anchor_id from /api-live/user/room ----

test("check_online: anchor_id = data.user.id", function()
    local body = fixture({ statusCode = 0, data = {
        user = { id = "6900000000000000001", roomId = "7300000000000000002", status = 2 },
        liveRoom = { status = 2 } } })
    local res, err = http.parse_room_id(body, 200, "someone")
    check(err == nil, "no error")
    check(res.room_id == "7300000000000000002", "room_id")
    check(res.anchor_id == "6900000000000000001", "anchor_id")
end)

test("check_online: error mapping", function()
    local _, e1 = http.parse_room_id(fixture({ statusCode = 19881007 }), 200, "x")
    check(e1.type == errors.USER_NOT_FOUND, "UserNotFound")
    local _, e2 = http.parse_room_id("", 200, "x")
    check(e2.type == errors.TIKTOK_BLOCKED, "TikTokBlocked on empty")
    local _, e3 = http.parse_room_id("{}", 429, "x")
    check(e3.type == errors.TIKTOK_BLOCKED, "TikTokBlocked on 429")
    local _, e4 = http.parse_room_id(fixture({ statusCode = 0,
        data = { user = { id = "1", roomId = "0" } } }), 200, "x")
    check(e4.type == errors.HOST_NOT_ONLINE, "HostNotOnline")
end)

io.write(string.format("\n--- %d passed, %d failed ---\n", passed, failed))
if failed > 0 or passed == 0 then os.exit(1) end
