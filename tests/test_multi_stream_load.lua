#!/usr/bin/env lua
--- Multi-stream concurrent load test.
--- Gated on PIRATETOK_LIVE_TEST_USERS (comma-separated list of live usernames).
--- All usernames must be live simultaneously.
---
--- M1: Create N clients, connect all, count chat events for 60s, disconnect all.
---
--- Lua is single-threaded, so "concurrent" means we multiplex all clients in a
--- shared poll loop — each client gets a poll() call every iteration. This is
--- the same approach the game engine use case demands and matches how the lib
--- is designed (poll-based, non-blocking after connect()).
---
--- Usage: lua tests/test_multi_stream_load.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local socket = require "socket"
local PirateTok = require "piratetok"
local errors = PirateTok.errors

-- ---- test harness ----

local pass_count = 0
local fail_count = 0
local skip_count = 0

local function pass(name)
    io.write("PASS " .. name .. "\n")
    io.flush()
    pass_count = pass_count + 1
end

local function fail(name, reason)
    io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
    io.flush()
    fail_count = fail_count + 1
end

local function skip(name, reason)
    io.write("SKIP " .. name .. ": " .. tostring(reason) .. "\n")
    io.flush()
    skip_count = skip_count + 1
end

-- ---- WSS client config (per spec) ----

local WSS_TIMEOUT   = 15   -- HTTP/room-resolution timeout
local WSS_RETRIES   = 5
local WSS_STALE     = 120  -- longer stale for multi-stream load test (per spec)
local POLL_INTERVAL = 0.02 -- tighter poll for multi-client fairness
local CONNECT_WAIT  = 120  -- max seconds to wait for all clients to reach CONNECTED
local LIVE_WINDOW   = 60   -- seconds to listen for events
local SESSION_WAIT  = 120  -- max seconds for all clients to disconnect cleanly

-- ---- M1: multiple live clients, track chat for one minute ----

local function test_m1_multiple_live_clients(usernames)
    local name = "M1: multipleLiveClients_trackChatForOneMinute"
    local n = #usernames

    io.write("[M1] connecting " .. n .. " client(s): "
        .. table.concat(usernames, ", ") .. "\n")
    io.flush()

    -- Per-client state
    local clients    = {}
    local connected  = {}   -- [i] = true when CONNECTED fired
    local chat_count = {}   -- [i] = number of chat events received
    local errs       = {}   -- [i] = first connect error, if any

    for i = 1, n do
        local user = usernames[i]
        local client = PirateTok.builder(user)
            :cdn("eu")
            :timeout(WSS_TIMEOUT)
            :max_retries(WSS_RETRIES)
            :stale_timeout(WSS_STALE)
            :build()

        connected[i]  = false
        chat_count[i] = 0
        errs[i]       = nil

        local idx = i   -- capture for closure
        client:on("connected", function(_) connected[idx] = true end)
        client:on("chat", function(_) chat_count[idx] = chat_count[idx] + 1 end)
        client:on("error", function(err)
            if not errs[idx] then errs[idx] = err end
        end)

        clients[i] = client
    end

    -- Connect all clients (room ID resolution is blocking per client).
    -- We connect sequentially — each connect() resolves the room ID synchronously.
    for i = 1, n do
        local ok, conn_err = clients[i]:connect()
        if not ok then
            -- Disconnect any already-connected clients before failing
            for j = 1, n do
                pcall(function() clients[j]:disconnect() end)
            end
            fail(name, "client[" .. i .. "] (" .. usernames[i] .. ") connect() failed: "
                .. errors.format(conn_err or {}))
            return
        end
    end

    -- Wait for all clients to reach CONNECTED state (WSS handshake).
    -- In the Lua model, "connected" fires inside connect() on room ID resolution.
    -- We poll to handle any deferred state transitions and WSS setup.
    local connect_deadline = socket.gettime() + CONNECT_WAIT
    local all_connected = false

    while not all_connected and socket.gettime() < connect_deadline do
        all_connected = true
        for i = 1, n do
            if not connected[i] and clients[i]._state ~= "disconnected" then
                clients[i]:poll()
                if not connected[i] then all_connected = false end
            end
        end
        if not all_connected then
            socket.sleep(POLL_INTERVAL)
        end
    end

    -- Check for errors during connect phase
    for i = 1, n do
        if errs[i] then
            for j = 1, n do
                pcall(function() clients[j]:disconnect() end)
            end
            fail(name, "client[" .. i .. "] (" .. usernames[i] .. ") error during connect: "
                .. errors.format(errs[i]))
            return
        end
    end

    if not all_connected then
        -- Report which clients didn't connect
        local missing = {}
        for i = 1, n do
            if not connected[i] then
                missing[#missing + 1] = usernames[i] .. " (state=" .. clients[i]._state .. ")"
            end
        end
        for j = 1, n do
            pcall(function() clients[j]:disconnect() end)
        end
        fail(name, "not all clients reached CONNECTED within " .. CONNECT_WAIT .. "s: "
            .. table.concat(missing, ", "))
        return
    end

    io.write("[M1] all " .. n .. " client(s) connected — live window " .. LIVE_WINDOW .. "s\n")
    io.flush()

    -- Live window: poll all clients for LIVE_WINDOW seconds
    local live_deadline = socket.gettime() + LIVE_WINDOW
    while socket.gettime() < live_deadline do
        for i = 1, n do
            if clients[i]._state ~= "disconnected" then
                clients[i]:poll()
            end
        end
        socket.sleep(POLL_INTERVAL)
    end

    -- Disconnect all clients
    io.write("[M1] live window done — disconnecting " .. n .. " client(s)\n")
    io.flush()
    for i = 1, n do
        pcall(function() clients[i]:disconnect() end)
    end

    -- Wait for all clients to reach disconnected state
    local session_deadline = socket.gettime() + SESSION_WAIT
    local all_done = false
    while not all_done and socket.gettime() < session_deadline do
        all_done = true
        for i = 1, n do
            if clients[i]._state ~= "disconnected" then
                clients[i]:poll()
                all_done = false
            end
        end
        if not all_done then
            socket.sleep(POLL_INTERVAL)
        end
    end

    -- Check for errors during live window
    for i = 1, n do
        if errs[i] then
            fail(name, "client[" .. i .. "] (" .. usernames[i] .. ") error during live window: "
                .. errors.format(errs[i]))
            return
        end
    end

    -- Log per-channel chat counts
    io.write("[M1] chat counts:\n")
    for i = 1, n do
        io.write("  " .. usernames[i] .. ": " .. chat_count[i] .. " chat events\n")
    end
    io.flush()

    -- Check all clients are now disconnected
    local not_done = {}
    for i = 1, n do
        if clients[i]._state ~= "disconnected" then
            not_done[#not_done + 1] = usernames[i] .. " (state=" .. clients[i]._state .. ")"
        end
    end
    if #not_done > 0 then
        fail(name, "clients still not disconnected after " .. SESSION_WAIT .. "s: "
            .. table.concat(not_done, ", "))
        return
    end

    pass(name)
end

-- ---- main ----

local users_env = os.getenv("PIRATETOK_LIVE_TEST_USERS")
if not users_env or users_env == "" then
    skip("M1: multipleLiveClients_trackChatForOneMinute",
        "set PIRATETOK_LIVE_TEST_USERS to comma-separated live TikTok usernames (all must be live)")
    io.write("\n--- 0 passed, 0 failed, 1 skipped ---\n\n")
    os.exit(0)
end

-- Parse comma-separated usernames
local usernames = {}
for u in users_env:gmatch("[^,]+") do
    local trimmed = u:match("^%s*(.-)%s*$"):gsub("^@", "")
    if trimmed ~= "" then
        usernames[#usernames + 1] = trimmed
    end
end

if #usernames == 0 then
    skip("M1: multipleLiveClients_trackChatForOneMinute",
        "PIRATETOK_LIVE_TEST_USERS is set but contains no valid usernames")
    io.write("\n--- 0 passed, 0 failed, 1 skipped ---\n\n")
    os.exit(0)
end

io.write("\n--- multi-stream load test (" .. #usernames .. " user(s)) ---\n\n")

test_m1_multiple_live_clients(usernames)

io.write(string.format(
    "\n--- %d passed, %d failed, %d skipped ---\n\n",
    pass_count, fail_count, skip_count))

if fail_count > 0 then os.exit(1) end
