#!/usr/bin/env luajit
--- Gift streak tracker — shows per-event deltas for combo gifts.
--- Usage: luajit gift_streak.lua <username>
io.stdout:setvbuf("no")
local PirateTok = require "piratetok"
local GiftStreakTracker = require "piratetok.helpers.gift_streak"

local username = arg[1]
if not username then
    io.stderr:write("usage: luajit gift_streak.lua <username>\n")
    os.exit(1)
end

local client = PirateTok.builder(username)
    :cdn("eu")
    :max_retries(5)
    :build()

local tracker = GiftStreakTracker.new()
local total_diamonds = 0

client:on("connected", function(info)
    io.write("[connected] room_id=" .. info.room_id .. "\n\n")
end)

client:on("gift", function(msg)
    local e = tracker:process(msg)

    local nick = msg.user and msg.user.nickname or "?"
    local name = msg.gift_details and msg.gift_details.gift_name or "?"

    if e.is_final then
        total_diamonds = total_diamonds + e.total_diamond_count
        io.write("[FINAL] streak=" .. e.streak_id
            .. " " .. nick .. " -> " .. name
            .. " x" .. e.total_gift_count
            .. " -- " .. e.total_diamond_count .. " diamonds\n")
        io.write("        running total: " .. total_diamonds .. " diamonds\n\n")
    elseif e.event_gift_count > 0 then
        io.write("[ongoing] streak=" .. e.streak_id
            .. " " .. nick .. " -> " .. name
            .. " +" .. e.event_gift_count
            .. " (+" .. e.event_diamond_count .. " dmnd)\n")
    end
end)

client:on("reconnecting", function(info)
    io.write("[reconnecting] attempt " .. info.attempt
        .. "/" .. info.max_retries
        .. " in " .. info.delay_secs .. "s"
        .. " (" .. (info.reason or "") .. ")\n")
end)

client:on("disconnected", function(info)
    io.write("\n[disconnected] " .. (info.reason or "") .. "\n")
    io.write("Final total: " .. total_diamonds .. " diamonds\n")
    io.write("Active streaks at disconnect: " .. tracker:active_streaks() .. "\n")
end)

client:on("error", function(err)
    io.stderr:write("[error] " .. PirateTok.errors.format(err) .. "\n")
end)

io.write("connecting to " .. username .. "...\n")
client:run()
