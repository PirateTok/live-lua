#!/usr/bin/env luajit
--- Basic chat example — connects to a live stream and prints chat events.
--- Demonstrates blocking mode (client:run) for standalone scripts.
io.stdout:setvbuf("no")
local PirateTok = require "piratetok"

local username = arg[1]
if not username then
    io.stderr:write("usage: luajit basic_chat.lua <username>\n")
    os.exit(1)
end

local client = PirateTok.builder(username)
    :cdn("eu")
    :max_retries(5)
    :build()

client:on("connected", function(info)
    io.write("[connected] room_id=" .. info.room_id .. "\n")
end)

client:on("chat", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    io.write("[chat] " .. name .. ": " .. (msg.comment or "") .. "\n")
end)

client:on("gift", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    local gift_name = msg.gift_details and msg.gift_details.name or "unknown"
    local diamonds = PirateTok.events.diamond_total(msg)
    io.write("[gift] " .. name .. " sent " .. gift_name
        .. " x" .. (msg.repeat_count or 1)
        .. " (" .. diamonds .. " diamonds)\n")
end)

client:on("like", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    io.write("[like] " .. name .. " x" .. (msg.count or 1) .. "\n")
end)

client:on("join", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    io.write("[join] " .. name .. "\n")
end)

client:on("follow", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    io.write("[follow] " .. name .. "\n")
end)

client:on("share", function(msg)
    local name = msg.user and msg.user.nickname or "???"
    io.write("[share] " .. name .. "\n")
end)

client:on("room_user_seq", function(msg)
    io.write("[viewers] " .. (msg.viewer_count or 0) .. "\n")
end)

client:on("live_ended", function(msg)
    io.write("[ended] stream ended: " .. (msg.reason or "") .. "\n")
end)

client:on("reconnecting", function(info)
    io.write("[reconnecting] attempt " .. info.attempt
        .. "/" .. info.max_retries
        .. " in " .. info.delay_secs .. "s"
        .. " (" .. (info.reason or "") .. ")\n")
end)

client:on("disconnected", function(info)
    io.write("[disconnected] " .. (info.reason or "") .. "\n")
end)

client:on("error", function(err)
    io.stderr:write("[error] " .. PirateTok.errors.format(err) .. "\n")
end)

io.write("connecting to " .. username .. "...\n")
client:run()
