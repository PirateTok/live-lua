#!/usr/bin/env lua
--- Integration tests for HTTP API: check_online and fetch_room_info.
--- Hits real TikTok endpoints. Skipped unless env vars are set.
---
--- H1: check_online with live user -> room_id
--- H2: check_online with offline user -> HostNotOnline
--- H3: check_online with nonexistent user -> UserNotFound
--- H4: fetch_room_info with live room -> room info with viewers
---
--- Usage: lua tests/test_api_integration.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local PirateTok = require "piratetok"
local errors = PirateTok.errors

-- Synthetic nonexistent username — hardcoded so the test is deterministic.
-- TikTok must return user-not-found for this probe.
local SYNTHETIC_NONEXISTENT_USER = "piratetok_lua_nf_7a3c9e2f1b8d4a6c0e5f3a2b1d9c8e7"

-- HTTP timeout: 25s per spec
local HTTP_TIMEOUT = 25

-- ---- test harness ----

local pass_count = 0
local fail_count = 0
local skip_count = 0

local function pass(name)
    io.write("PASS " .. name .. "\n")
    pass_count = pass_count + 1
end

local function fail(name, reason)
    io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
    fail_count = fail_count + 1
end

local function skip(name, reason)
    io.write("SKIP " .. name .. ": " .. tostring(reason) .. "\n")
    skip_count = skip_count + 1
end

local function assert_ok(name, cond, msg)
    if not cond then
        fail(name, msg or "assertion failed")
        return false
    end
    return true
end

-- ---- H1: check_online with live user returns room_id ----

local function test_h1_check_online_live_user()
    local name = "H1: check_online_liveUser_returnsRoomId"
    local user = os.getenv("PIRATETOK_LIVE_TEST_USER")
    if not user or user == "" then
        skip(name, "set PIRATETOK_LIVE_TEST_USER to a currently-live TikTok username")
        return
    end
    user = user:match("^%s*(.-)%s*$")

    local result, err = PirateTok.check_online(user, HTTP_TIMEOUT)
    if not assert_ok(name, not err,
        "check_online failed: " .. (err and errors.format(err) or "nil")) then
        return
    end
    if not assert_ok(name, result ~= nil, "result is nil") then return end
    if not assert_ok(name, result.room_id ~= nil, "room_id is nil") then return end
    if not assert_ok(name, result.room_id ~= "", "room_id is empty") then return end
    if not assert_ok(name, result.room_id ~= "0", "room_id is '0'") then return end
    pass(name)
end

-- ---- H2: check_online with offline user returns HostNotOnline ----

local function test_h2_check_online_offline_user()
    local name = "H2: check_online_offlineUser_throwsHostNotOnline"
    local user = os.getenv("PIRATETOK_LIVE_TEST_OFFLINE_USER")
    if not user or user == "" then
        skip(name, "set PIRATETOK_LIVE_TEST_OFFLINE_USER to a TikTok username that is NOT live")
        return
    end
    user = user:match("^%s*(.-)%s*$")

    local result, err = PirateTok.check_online(user, HTTP_TIMEOUT)
    if not assert_ok(name, result == nil,
        "expected error but got room_id=" .. tostring(result and result.room_id)) then
        return
    end
    if not assert_ok(name, err ~= nil, "expected an error but err is nil") then return end
    if not assert_ok(name, err.type == errors.HOST_NOT_ONLINE,
        "expected HostNotOnline, got " .. tostring(err.type)
        .. " — must NOT say 'blocked' or 'not found' for an offline user") then
        return
    end
    -- Error quality: message must say offline, not blocked or not-found
    local msg_lower = err.message:lower()
    if not assert_ok(name,
        msg_lower:find("not.*live") or msg_lower:find("offline") or msg_lower:find("not.*online"),
        "error message should mention offline/not-live, got: " .. err.message) then
        return
    end
    pass(name)
end

-- ---- H3: check_online with nonexistent user returns UserNotFound ----

local function test_h3_check_online_nonexistent_user()
    local name = "H3: check_online_nonexistentUser_throwsUserNotFound"
    local gate = os.getenv("PIRATETOK_LIVE_TEST_HTTP")
    if not gate or (gate ~= "1" and gate ~= "true" and gate ~= "yes") then
        skip(name,
            "set PIRATETOK_LIVE_TEST_HTTP=1 to enable the nonexistent-user probe (safe network call)")
        return
    end

    local result, err = PirateTok.check_online(SYNTHETIC_NONEXISTENT_USER, HTTP_TIMEOUT)
    if not assert_ok(name, result == nil,
        "expected UserNotFound but got room_id=" .. tostring(result and result.room_id)) then
        return
    end
    if not assert_ok(name, err ~= nil, "expected an error but err is nil") then return end
    if not assert_ok(name, err.type == errors.USER_NOT_FOUND,
        "expected UserNotFound, got " .. tostring(err.type)) then
        return
    end
    -- Message must include the username
    if not assert_ok(name,
        err.message:find(SYNTHETIC_NONEXISTENT_USER, 1, true),
        "error message should include the username, got: " .. err.message) then
        return
    end
    pass(name)
end

-- ---- H4: fetch_room_info with live room returns room info ----

local function test_h4_fetch_room_info_live_room()
    local name = "H4: fetchRoomInfo_liveRoom_returnsRoomInfo"
    local user = os.getenv("PIRATETOK_LIVE_TEST_USER")
    if not user or user == "" then
        skip(name, "set PIRATETOK_LIVE_TEST_USER to a currently-live TikTok username")
        return
    end
    user = user:match("^%s*(.-)%s*$")

    local check_result, check_err = PirateTok.check_online(user, HTTP_TIMEOUT)
    if not assert_ok(name, not check_err,
        "check_online failed: " .. (check_err and errors.format(check_err) or "nil")) then
        return
    end

    local cookies = os.getenv("PIRATETOK_LIVE_TEST_COOKIES") or ""

    local info, info_err = PirateTok.fetch_room_info(
        check_result.room_id, HTTP_TIMEOUT, cookies ~= "" and cookies or nil)
    if not assert_ok(name, not info_err,
        "fetch_room_info failed: " .. (info_err and errors.format(info_err) or "nil")) then
        return
    end
    if not assert_ok(name, info ~= nil, "room info is nil") then return end
    if not assert_ok(name, type(info.viewers) == "number",
        "viewers field missing or not a number") then
        return
    end
    if not assert_ok(name, info.viewers >= 0,
        "viewers must be >= 0, got " .. tostring(info.viewers)) then
        return
    end
    pass(name)
end

-- ---- main ----

io.write("\n--- HTTP API integration tests ---\n\n")

test_h1_check_online_live_user()
test_h2_check_online_offline_user()
test_h3_check_online_nonexistent_user()
test_h4_fetch_room_info_live_room()

io.write(string.format(
    "\n--- %d passed, %d failed, %d skipped ---\n\n",
    pass_count, fail_count, skip_count))

if fail_count > 0 then os.exit(1) end
