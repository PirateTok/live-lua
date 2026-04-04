#!/usr/bin/env luajit
--- Standalone online check — polls a user's live status without connecting WSS.
local PirateTok = require "piratetok"

local username = arg[1]
if not username then
    io.stderr:write("usage: luajit online_check.lua <username>\n")
    os.exit(1)
end

io.write("checking: " .. username .. "\n")

local result, err = PirateTok.check_online(username, 10)
if err then
    if err.type == "UserNotFound" then
        io.write("NOT FOUND: " .. err.message .. "\n")
        os.exit(2)
    elseif err.type == "HostNotOnline" then
        io.write("OFFLINE: " .. err.message .. "\n")
        os.exit(0)
    else
        io.stderr:write("ERROR [" .. err.type .. "]: " .. err.message .. "\n")
        os.exit(3)
    end
end

io.write("LIVE — room_id: " .. result.room_id .. "\n")
