#!/usr/bin/env lua
--- Replay test -- reads a capture file, processes it through the full decode
--- pipeline, and asserts every value matches the manifest JSON.
---
--- Skips if testdata is not available. Set PIRATETOK_TESTDATA env var or
--- place captures in ../live-testdata/.
---
--- Usage: lua tests/replay_test.lua

-- Module paths -- run from live-lua/ root
package.path = "./?.lua;./?/init.lua;" .. package.path

local pb = require "pb"
local zlib = require "zlib"
local cjson = require "cjson"
local proto_registry = require "piratetok.proto"
local events_mod = require "piratetok.events"
local LikeAccumulator = require "piratetok.helpers.like_accumulator"
local GiftStreakTracker = require "piratetok.helpers.gift_streak"

-- Load proto schemas once
proto_registry.register()

-- ---- assertion helpers ----

local test_failed = false
local assertion_count = 0

local function assert_eq(got, expected, label)
    assertion_count = assertion_count + 1
    -- normalize floats from cjson to integers for comparison
    if type(expected) == "number" and expected == math.floor(expected) then
        expected = math.floor(expected)
    end
    if type(got) == "number" and got == math.floor(got) then
        got = math.floor(got)
    end
    if got ~= expected then
        io.stderr:write(string.format(
            "FAIL %s: got %s, expected %s\n",
            label, tostring(got), tostring(expected)))
        test_failed = true
    end
end

local function assert_map_eq(got, expected, label)
    -- check all keys in expected exist in got with same value
    for k, v in pairs(expected) do
        local ev = math.floor(v)
        local gv = got[k]
        if gv == nil then
            io.stderr:write(string.format(
                "FAIL %s: missing key '%s' (expected %d)\n",
                label, k, ev))
            test_failed = true
        else
            assert_eq(gv, ev, label .. "[" .. k .. "]")
        end
    end
    -- check no extra keys in got
    for k, v in pairs(got) do
        if expected[k] == nil then
            io.stderr:write(string.format(
                "FAIL %s: unexpected key '%s' = %d\n",
                label, k, v))
            test_failed = true
        end
    end
end

-- ---- event name mapping (Lua snake_case -> manifest PascalCase) ----

local EVENT_NAME_MAP = {
    chat = "Chat",
    gift = "Gift",
    like = "Like",
    member = "Member",
    social = "Social",
    follow = "Follow",
    share = "Share",
    join = "Join",
    room_user_seq = "RoomUserSeq",
    control = "Control",
    live_ended = "LiveEnded",
    live_intro = "LiveIntro",
    room_message = "RoomMessage",
    caption = "Caption",
    goal_update = "GoalUpdate",
    im_delete = "ImDelete",
    rank_update = "RankUpdate",
    poll = "Poll",
    envelope = "Envelope",
    room_pin = "RoomPin",
    unauthorized_member = "UnauthorizedMember",
    link_mic_method = "LinkMicMethod",
    link_mic_battle = "LinkMicBattle",
    link_mic_armies = "LinkMicArmies",
    link_message = "LinkMessage",
    link_layer = "LinkLayer",
    link_mic_layout_state = "LinkMicLayoutState",
    gift_panel_update = "GiftPanelUpdate",
    in_room_banner = "InRoomBanner",
    guide = "Guide",
    emote_chat = "EmoteChat",
    question_new = "QuestionNew",
    sub_notify = "SubNotify",
    barrage = "Barrage",
    hourly_rank = "HourlyRank",
    msg_detect = "MsgDetect",
    link_mic_fan_ticket = "LinkMicFanTicket",
    room_verify = "RoomVerify",
    oec_live_shopping = "OecLiveShopping",
    gift_broadcast = "GiftBroadcast",
    rank_text = "RankText",
    gift_dynamic_restriction = "GiftDynamicRestriction",
    viewer_picks_update = "ViewerPicksUpdate",
    -- secondary
    access_control = "AccessControl",
    access_recall = "AccessRecall",
    alert_box_audit = "AlertBoxAuditResult",
    binding_gift = "BindingGift",
    boost_card = "BoostCard",
    bottom_message = "BottomMessage",
    game_rank_notify = "GameRankNotify",
    gift_prompt = "GiftPrompt",
    link_state = "LinkState",
    link_mic_battle_punish = "LinkMicBattlePunishFinish",
    link_mic_battle_task = "LinkmicBattleTask",
    marquee_announcement = "MarqueeAnnouncement",
    notice = "Notice",
    notify = "Notify",
    partnership_drops = "PartnershipDropsUpdate",
    partnership_game_offline = "PartnershipGameOffline",
    partnership_punish = "PartnershipPunish",
    perception = "Perception",
    speaker = "Speaker",
    sub_capsule = "SubCapsule",
    sub_pin = "SubPinEvent",
    subscription_notify = "SubscriptionNotify",
    toast = "Toast",
    system_message = "SystemMessage",
    live_game_intro = "LiveGameIntro",
    unknown = "Unknown",
}

-- ---- testdata location ----

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function find_paths(name)
    -- 1. $PIRATETOK_TESTDATA
    local env = os.getenv("PIRATETOK_TESTDATA")
    if env and env ~= "" then
        local cap = env .. "/captures/" .. name .. ".bin"
        local man = env .. "/manifests/" .. name .. ".json"
        if file_exists(cap) and file_exists(man) then
            return cap, man
        end
    end
    -- 2. testdata/ in repo root
    local cap2 = "testdata/captures/" .. name .. ".bin"
    local man2 = "testdata/manifests/" .. name .. ".json"
    if file_exists(cap2) and file_exists(man2) then
        return cap2, man2
    end
    return nil, nil
end

-- ---- binary frame reader ----

local function read_capture(path)
    local f, err = io.open(path, "rb")
    if not f then error("cannot read " .. path .. ": " .. tostring(err)) end
    local data = f:read("*a")
    f:close()

    local frames = {}
    local pos = 1
    local len_data = #data
    while pos + 3 <= len_data do
        local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
        local frame_len = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        pos = pos + 4
        if pos + frame_len - 1 > len_data then
            error("truncated frame at offset " .. (pos - 5))
        end
        frames[#frames + 1] = string.sub(data, pos, pos + frame_len - 1)
        pos = pos + frame_len
    end
    return frames
end

-- ---- gzip decompression ----

local function decompress_if_gzipped(data)
    if #data >= 2
        and string.byte(data, 1) == 0x1f
        and string.byte(data, 2) == 0x8b then
        local stream = zlib.inflate()
        local decompressed = stream(data)
        if decompressed then return decompressed, true end
        return nil, false
    end
    return data, true
end

-- ---- replay engine ----

local function replay(frames)
    local r = {
        frame_count = #frames,
        message_count = 0,
        event_count = 0,
        decode_failures = 0,
        decompress_failures = 0,
        payload_types = {},
        message_types = {},
        event_types = {},
        follow_count = 0,
        share_count = 0,
        join_count = 0,
        live_ended_count = 0,
        unknown_types = {},
        like_events = {},
        gift_groups = {},
        combo_count = 0,
        non_combo_count = 0,
        streak_finals = 0,
        negative_deltas = 0,
    }

    local like_acc = LikeAccumulator.new()
    local gift_tracker = GiftStreakTracker.new()

    for i = 1, #frames do
        local raw = frames[i]
        local frame = pb.decode("WebcastPushFrame", raw)
        if not frame then
            r.decode_failures = r.decode_failures + 1
            goto continue_frame
        end

        local ptype = frame.payload_type or ""
        r.payload_types[ptype] = (r.payload_types[ptype] or 0) + 1

        if ptype ~= "msg" then goto continue_frame end

        local payload, decomp_ok = decompress_if_gzipped(frame.payload)
        if not decomp_ok then
            r.decompress_failures = r.decompress_failures + 1
            goto continue_frame
        end

        local response = pb.decode("WebcastResponse", payload)
        if not response then
            r.decode_failures = r.decode_failures + 1
            goto continue_frame
        end

        local msgs = response.messages or {}
        for mi = 1, #msgs do
            local msg = msgs[mi]
            r.message_count = r.message_count + 1
            local msg_type = msg.type or ""
            r.message_types[msg_type] = (r.message_types[msg_type] or 0) + 1

            local evts = events_mod.decode_message(msg_type, msg.payload)
            for ei = 1, #evts do
                r.event_count = r.event_count + 1
                local evt = evts[ei]
                local canonical = EVENT_NAME_MAP[evt.name] or evt.name
                r.event_types[canonical] = (r.event_types[canonical] or 0) + 1

                if evt.name == "follow" then
                    r.follow_count = r.follow_count + 1
                elseif evt.name == "share" then
                    r.share_count = r.share_count + 1
                elseif evt.name == "join" then
                    r.join_count = r.join_count + 1
                elseif evt.name == "live_ended" then
                    r.live_ended_count = r.live_ended_count + 1
                elseif evt.name == "unknown" then
                    local method = evt.data.method or "?"
                    r.unknown_types[method] =
                        (r.unknown_types[method] or 0) + 1
                end
            end

            -- Like accumulator
            if msg_type == "WebcastLikeMessage" then
                local like_msg = pb.decode("WebcastLikeMessage", msg.payload)
                if like_msg then
                    local stats = like_acc:process(like_msg)
                    r.like_events[#r.like_events + 1] = {
                        wire_count = like_msg.count or 0,
                        wire_total = like_msg.total or 0,
                        acc_total = stats.total_like_count,
                        accumulated = stats.accumulated_count,
                        went_backwards = stats.went_backwards,
                    }
                end
            end

            -- Gift streak tracker
            if msg_type == "WebcastGiftMessage" then
                local gift_msg = pb.decode("WebcastGiftMessage", msg.payload)
                if gift_msg then
                    local is_combo = events_mod.is_combo_gift(gift_msg)
                    if is_combo then
                        r.combo_count = r.combo_count + 1
                    else
                        r.non_combo_count = r.non_combo_count + 1
                    end

                    local streak = gift_tracker:process(gift_msg)
                    if streak.is_final then
                        r.streak_finals = r.streak_finals + 1
                    end
                    if streak.event_gift_count < 0 then
                        r.negative_deltas = r.negative_deltas + 1
                    end

                    local key = tostring(gift_msg.group_id or 0)
                    if not r.gift_groups[key] then
                        r.gift_groups[key] = {}
                    end
                    local g = r.gift_groups[key]
                    g[#g + 1] = {
                        gift_id = gift_msg.gift_id or 0,
                        repeat_count = gift_msg.repeat_count or 0,
                        delta = streak.event_gift_count,
                        is_final = streak.is_final,
                        diamond_total = streak.total_diamond_count,
                    }
                end
            end
        end

        ::continue_frame::
    end

    return r
end

-- ---- assertion runner ----

local function assert_replay(name, r, m)
    assert_eq(r.frame_count, m.frame_count, name .. ": frame_count")
    assert_eq(r.message_count, m.message_count, name .. ": message_count")
    assert_eq(r.event_count, m.event_count, name .. ": event_count")
    assert_eq(r.decode_failures, m.decode_failures, name .. ": decode_failures")
    assert_eq(r.decompress_failures, m.decompress_failures,
        name .. ": decompress_failures")

    assert_map_eq(r.payload_types, m.payload_types, name .. ": payload_types")
    assert_map_eq(r.message_types, m.message_types, name .. ": message_types")
    assert_map_eq(r.event_types, m.event_types, name .. ": event_types")

    assert_eq(r.follow_count, m.sub_routed.follow,
        name .. ": sub_routed.follow")
    assert_eq(r.share_count, m.sub_routed.share,
        name .. ": sub_routed.share")
    assert_eq(r.join_count, m.sub_routed.join,
        name .. ": sub_routed.join")
    assert_eq(r.live_ended_count, m.sub_routed.live_ended,
        name .. ": sub_routed.live_ended")

    assert_map_eq(r.unknown_types, m.unknown_types,
        name .. ": unknown_types")

    -- like accumulator
    local ml = m.like_accumulator
    assert_eq(#r.like_events, ml.event_count,
        name .. ": like event_count")

    local backwards = 0
    for i = 1, #r.like_events do
        if r.like_events[i].went_backwards then backwards = backwards + 1 end
    end
    assert_eq(backwards, ml.backwards_jumps, name .. ": like backwards_jumps")

    if #r.like_events > 0 then
        local last = r.like_events[#r.like_events]
        assert_eq(last.acc_total, ml.final_max_total,
            name .. ": like final_max_total")
        assert_eq(last.accumulated, ml.final_accumulated,
            name .. ": like final_accumulated")
    end

    -- monotonicity checks
    local acc_mono = true
    local accum_mono = true
    for i = 2, #r.like_events do
        if r.like_events[i].acc_total < r.like_events[i - 1].acc_total then
            acc_mono = false
        end
        if r.like_events[i].accumulated < r.like_events[i - 1].accumulated then
            accum_mono = false
        end
    end
    assert_eq(acc_mono, ml.acc_total_monotonic,
        name .. ": like acc_total_monotonic")
    assert_eq(accum_mono, ml.accumulated_monotonic,
        name .. ": like accumulated_monotonic")

    -- like event-by-event
    local ml_events = ml.events
    assert_eq(#r.like_events, #ml_events, name .. ": like events length")
    local like_count = math.min(#r.like_events, #ml_events)
    for i = 1, like_count do
        local got = r.like_events[i]
        local exp = ml_events[i]
        local pfx = string.format("%s: like[%d]", name, i)
        assert_eq(got.wire_count, exp.wire_count, pfx .. ".wire_count")
        assert_eq(got.wire_total, exp.wire_total, pfx .. ".wire_total")
        assert_eq(got.acc_total, exp.acc_total, pfx .. ".acc_total")
        assert_eq(got.accumulated, exp.accumulated, pfx .. ".accumulated")
        assert_eq(got.went_backwards, exp.went_backwards,
            pfx .. ".went_backwards")
    end

    -- gift streaks
    local mg = m.gift_streaks
    assert_eq(r.combo_count + r.non_combo_count, mg.event_count,
        name .. ": gift event_count")
    assert_eq(r.combo_count, mg.combo_count, name .. ": gift combo_count")
    assert_eq(r.non_combo_count, mg.non_combo_count,
        name .. ": gift non_combo_count")
    assert_eq(r.streak_finals, mg.streak_finals,
        name .. ": gift streak_finals")
    assert_eq(r.negative_deltas, mg.negative_deltas,
        name .. ": gift negative_deltas")

    -- gift group-by-group
    local got_group_count = 0
    for _ in pairs(r.gift_groups) do got_group_count = got_group_count + 1 end
    local exp_group_count = 0
    for _ in pairs(mg.groups) do exp_group_count = exp_group_count + 1 end
    assert_eq(got_group_count, exp_group_count,
        name .. ": gift groups count")

    for gid, got_evts in pairs(r.gift_groups) do
        local exp_evts = mg.groups[gid]
        if not exp_evts then
            io.stderr:write(string.format(
                "FAIL %s: missing gift group %s in manifest\n", name, gid))
            test_failed = true
            goto continue_group
        end
        assert_eq(#got_evts, #exp_evts,
            name .. ": gift group " .. gid .. " length")
        local gc = math.min(#got_evts, #exp_evts)
        for i = 1, gc do
            local g = got_evts[i]
            local e = exp_evts[i]
            local pfx = string.format("%s: gift[%s][%d]", name, gid, i)
            assert_eq(g.gift_id, e.gift_id, pfx .. ".gift_id")
            assert_eq(g.repeat_count, e.repeat_count, pfx .. ".repeat_count")
            assert_eq(g.delta, e.delta, pfx .. ".delta")
            assert_eq(g.is_final, e.is_final, pfx .. ".is_final")
            assert_eq(g.diamond_total, e.diamond_total, pfx .. ".diamond_total")
        end
        ::continue_group::
    end
end

-- ---- test runner ----

local function run_capture_test(name)
    local cap_path, man_path = find_paths(name)
    if not cap_path then
        io.write(string.format(
            "SKIP %s: no testdata (set PIRATETOK_TESTDATA or clone "
            .. "live-testdata)\n", name))
        return "skip"
    end

    io.write(string.format("RUN  %s ... ", name))
    io.flush()

    local man_f = io.open(man_path, "r")
    local man_json = man_f:read("*a")
    man_f:close()
    local manifest = cjson.decode(man_json)

    local frames = read_capture(cap_path)
    local result = replay(frames)

    local prev_failed = test_failed
    assert_replay(name, result, manifest)

    if test_failed and not prev_failed then
        io.write("FAIL\n")
        return "fail"
    elseif test_failed then
        io.write("FAIL\n")
        return "fail"
    else
        io.write(string.format("OK (%d assertions)\n", assertion_count))
        return "pass"
    end
end

-- ---- main ----

local captures = {
    "calvinterest6",
    "happyhappygaltv",
    "fox4newsdallasfortworth",
}

local pass, fail, skip = 0, 0, 0

io.write("\n--- replay tests ---\n\n")

for _, name in ipairs(captures) do
    assertion_count = 0
    local result = run_capture_test(name)
    if result == "pass" then pass = pass + 1
    elseif result == "fail" then fail = fail + 1
    else skip = skip + 1 end
end

io.write(string.format(
    "\n--- %d passed, %d failed, %d skipped ---\n\n",
    pass, fail, skip))

if fail > 0 then os.exit(1) end
