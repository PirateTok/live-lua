#!/usr/bin/env luajit
--- Audience roster — the full named viewer list of a live room.
--- Login-gated: pass TikTok session cookies ("sessionid=xxx; sid_tt=xxx").
local PirateTok = require "piratetok"

local username, cookies = arg[1], arg[2]
if not username or not cookies then
    io.stderr:write("usage: luajit audience.lua <username> \"sessionid=xxx; sid_tt=xxx\"\n")
    os.exit(1)
end

local live, err = PirateTok.check_online(username, 10)
if not live then
    io.stderr:write(PirateTok.errors.format(err) .. "\n")
    os.exit(2)
end

local aud, aud_err = PirateTok.fetch_room_audience(
    live.room_id, live.anchor_id, cookies, 10)
if not aud then
    io.stderr:write(PirateTok.errors.format(aud_err) .. "\n")
    os.exit(aud_err.type == "SessionRequired" and 4 or 3)
end

io.write(string.format("total=%d anonymous=%d named=%d\n",
    aud.total, aud.anonymous, #aud.viewers))
for _, v in ipairs(aud.viewers) do
    io.write(string.format("#%d %s (%s) score=%d followers=%d\n",
        v.rank, v.username, v.nickname, v.score, v.follower_count))
end
