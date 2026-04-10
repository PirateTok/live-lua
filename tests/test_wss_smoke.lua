#!/usr/bin/env lua
--- WSS smoke tests against a real live TikTok room.
--- Flaky by design — quiet streams may not emit all event types within the timeout.
--- Gated on PIRATETOK_LIVE_TEST_USER.
---
--- W1: receives any traffic within 90s
--- W2: receives chat within 120s
--- W3: receives gift within 180s
--- W4: receives like within 120s
--- W5: receives join within 150s
--- W6: receives follow within 180s
--- W7: receives subscription signal within 240s (disabled by default)
--- D1: disconnect unblocks poll loop within 18s of connect
---
--- Usage: lua tests/test_wss_smoke.lua

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

-- ---- WSS client config constants (per spec) ----

local WSS_TIMEOUT    = 15  -- HTTP/room-resolution timeout
local WSS_RETRIES    = 5
local WSS_STALE      = 45  -- stale timeout (shorter than production for fast failure)
local POLL_INTERVAL  = 0.05

-- ---- Lua WSS smoke test helper ----
-- Lua is single-threaded. Instead of OS threads + countdown latches we use a
-- poll loop with a deadline. The client:poll() call is non-blocking; we spin
-- until the event fires or the deadline expires, then disconnect.
--
-- Pattern (matches spec pseudocode semantics):
--   1. Build client with test config
--   2. Register listener that sets `hit = true` on target event
--   3. client:connect() — blocking room-resolution, then WSS returns
--   4. Spin poll loop until hit or deadline
--   5. client:disconnect()
--   6. Assert hit and no connect error
--
-- For D1 (disconnect test) we measure wall-clock time from connect to
-- disconnect-loop-exit instead of using thread join.

local function run_wss_test(name, user, timeout_secs, register_listeners)
    local builder = PirateTok.builder(user)
        :cdn("eu")
        :timeout(WSS_TIMEOUT)
        :max_retries(WSS_RETRIES)
        :stale_timeout(WSS_STALE)

    local client = builder:build()

    local hit = false
    local connect_err = nil

    register_listeners(client, function() hit = true end)

    client:on("error", function(err)
        connect_err = err
    end)

    -- connect() resolves room ID (blocking) then establishes WSS
    local ok, conn_err = client:connect()
    if not ok then
        client:disconnect()
        fail(name, "connect() failed: " .. errors.format(conn_err or {}))
        return
    end

    -- poll loop with deadline
    local deadline = socket.gettime() + timeout_secs
    while not hit and socket.gettime() < deadline and client._state ~= "disconnected" do
        client:poll()
        if not hit then
            socket.sleep(POLL_INTERVAL)
        end
    end

    client:disconnect()

    if connect_err then
        fail(name, "connect error during poll: " .. errors.format(connect_err))
        return
    end

    if not hit then
        fail(name, "no event within " .. timeout_secs .. "s (quiet stream or block?)")
        return
    end

    pass(name)
end

-- ---- W1: receives any traffic within 90s ----

local function test_w1_receives_traffic(user)
    local name = "W1: connect_receivesTrafficBeforeTimeout"
    run_wss_test(name, user, 90, function(client, hit)
        client:on("room_user_seq", function(_) hit() end)
        client:on("member",        function(_) hit() end)
        client:on("chat",          function(_) hit() end)
        client:on("like",          function(_) hit() end)
        client:on("control",       function(_) hit() end)
    end)
end

-- ---- W2: receives chat within 120s ----

local function test_w2_receives_chat(user)
    local name = "W2: connect_receivesChatBeforeTimeout"
    run_wss_test(name, user, 120, function(client, hit)
        client:on("chat", function(msg)
            local nickname = msg.user and msg.user.nickname or "?"
            local content  = msg.comment or ""
            io.write("[integration test chat] " .. nickname .. ": " .. content .. "\n")
            io.flush()
            hit()
        end)
    end)
end

-- ---- W3: receives gift within 180s ----

local function test_w3_receives_gift(user)
    local name = "W3: connect_receivesGiftBeforeTimeout"
    run_wss_test(name, user, 180, function(client, hit)
        client:on("gift", function(msg)
            local nickname   = msg.user and msg.user.nickname or "?"
            local gift_name  = msg.gift_details and msg.gift_details.name or "?"
            local diamonds   = PirateTok.events.diamond_total(msg)
            local count      = msg.repeat_count or 1
            io.write("[integration test gift] " .. nickname
                .. " -> " .. gift_name
                .. " x" .. count
                .. " (" .. diamonds .. " diamonds each)\n")
            io.flush()
            hit()
        end)
    end)
end

-- ---- W4: receives like within 120s ----

local function test_w4_receives_like(user)
    local name = "W4: connect_receivesLikeBeforeTimeout"
    run_wss_test(name, user, 120, function(client, hit)
        client:on("like", function(msg)
            local nickname = msg.user and msg.user.nickname or "?"
            io.write("[integration test like] " .. nickname
                .. " count=" .. tostring(msg.count or 0)
                .. " total=" .. tostring(msg.total or 0) .. "\n")
            io.flush()
            hit()
        end)
    end)
end

-- ---- W5: receives join within 150s ----

local function test_w5_receives_join(user)
    local name = "W5: connect_receivesJoinBeforeTimeout"
    run_wss_test(name, user, 150, function(client, hit)
        client:on("join", function(msg)
            local nickname = msg.user and msg.user.nickname or "?"
            io.write("[integration test join] " .. nickname .. "\n")
            io.flush()
            hit()
        end)
    end)
end

-- ---- W6: receives follow within 180s ----

local function test_w6_receives_follow(user)
    local name = "W6: connect_receivesFollowBeforeTimeout"
    run_wss_test(name, user, 180, function(client, hit)
        client:on("follow", function(msg)
            local nickname = msg.user and msg.user.nickname or "?"
            io.write("[integration test follow] " .. nickname .. "\n")
            io.flush()
            hit()
        end)
    end)
end

-- ---- W7: receives subscription signal within 240s (disabled by default) ----

local function test_w7_receives_subscription(user)
    local name = "W7: connect_receivesSubscriptionSignalBeforeTimeout"
    -- Disabled by default — subscriptions are too rare on most streams
    skip(name, "disabled by default — too rare; enable manually in test_wss_smoke.lua")
    -- To enable: uncomment the block below and comment out the skip() above.
    --
    -- run_wss_test(name, user, 240, function(client, hit)
    --     client:on("sub_notify",        function(_) io.write("[integration test subscription] subNotify\n"); io.flush(); hit() end)
    --     client:on("subscription_notify", function(_) io.write("[integration test subscription] subscriptionNotify\n"); io.flush(); hit() end)
    --     client:on("sub_capsule",       function(_) io.write("[integration test subscription] subCapsule\n"); io.flush(); hit() end)
    --     client:on("sub_pin",           function(_) io.write("[integration test subscription] subPinEvent\n"); io.flush(); hit() end)
    -- end)
end

-- ---- D1: disconnect unblocks poll loop after CONNECTED event ----

local function test_d1_disconnect_unblocks_after_connected(user)
    local name = "D1: disconnect_unblocksConnectThreadAfterConnected"

    local client = PirateTok.builder(user)
        :cdn("eu")
        :timeout(WSS_TIMEOUT)
        :max_retries(WSS_RETRIES)
        :stale_timeout(WSS_STALE)
        :build()

    local connected = false
    local connect_err = nil

    client:on("connected", function(_) connected = true end)
    client:on("error", function(err) connect_err = err end)

    local ok, conn_err = client:connect()
    if not ok then
        client:disconnect()
        fail(name, "connect() failed before CONNECTED event: "
            .. errors.format(conn_err or {}))
        return
    end

    -- Wait up to 90s for CONNECTED event to have been emitted.
    -- In the Lua poll model, "connected" fires synchronously inside connect()
    -- when room ID resolves successfully, so it will already be true here.
    -- We still run the poll loop briefly to handle the WSS handshake path.
    local connect_deadline = socket.gettime() + 90
    while not connected and socket.gettime() < connect_deadline
        and client._state ~= "disconnected" do
        client:poll()
        socket.sleep(POLL_INTERVAL)
    end

    if connect_err then
        client:disconnect()
        fail(name, "connect error during poll: " .. errors.format(connect_err))
        return
    end

    if not connected then
        client:disconnect()
        fail(name, "never reached CONNECTED within 90s")
        return
    end

    -- Now disconnect and measure how long it takes the poll loop to exit.
    local t0 = socket.gettime()
    client:disconnect()

    -- Poll loop should exit immediately after disconnect (state = "disconnected").
    local exit_deadline = socket.gettime() + 20
    while client._state ~= "disconnected" and socket.gettime() < exit_deadline do
        client:poll()
        socket.sleep(POLL_INTERVAL)
    end

    local elapsed = socket.gettime() - t0

    if client._state ~= "disconnected" then
        fail(name, "client state is still '" .. client._state
            .. "' after 20s — disconnect() did not stop the loop")
        return
    end

    if elapsed >= 18 then
        fail(name, string.format(
            "poll loop took %.2fs to exit after disconnect() — must be < 18s", elapsed))
        return
    end

    pass(name)
end

-- ---- main ----

local user = os.getenv("PIRATETOK_LIVE_TEST_USER")
if not user or user == "" then
    io.write("SKIP ALL: set PIRATETOK_LIVE_TEST_USER to a currently-live TikTok username\n")
    io.write("\n--- 0 passed, 0 failed, 7 skipped ---\n\n")
    os.exit(0)
end
user = user:match("^%s*(.-)%s*$")

io.write("\n--- WSS smoke tests (user=" .. user .. ") ---\n\n")

test_w1_receives_traffic(user)
test_w2_receives_chat(user)
test_w3_receives_gift(user)
test_w4_receives_like(user)
test_w5_receives_join(user)
test_w6_receives_follow(user)
test_w7_receives_subscription(user)
test_d1_disconnect_unblocks_after_connected(user)

io.write(string.format(
    "\n--- %d passed, %d failed, %d skipped ---\n\n",
    pass_count, fail_count, skip_count))

if fail_count > 0 then os.exit(1) end
