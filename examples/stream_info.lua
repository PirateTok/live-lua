#!/usr/bin/env lua
--- Fetch room metadata and stream URLs for a TikTok Live user.
-- Usage: lua examples/stream_info.lua <username> [cookies]

package.path = "./?/init.lua;./?.lua;" .. package.path

local piratetok = require "piratetok"

local username = arg[1]
if not username then
    print("usage: stream_info.lua <username> [cookies]")
    os.exit(1)
end

local cookies = arg[2]

local result, err = piratetok.check_online(username)
if err then
    print("check_online failed: " .. err.message)
    os.exit(1)
end

print("room_id: " .. result.room_id)

local info, info_err = piratetok.fetch_room_info(result.room_id, 10, cookies)
if info_err then
    print("room info failed: " .. info_err.message)
    if info_err.code == "AGE_RESTRICTED" then
        print("hint: pass session cookies as second argument")
    end
    os.exit(1)
end

print("title:   " .. info.title)
print("viewers: " .. tostring(info.viewers))
print("likes:   " .. tostring(info.likes))
print("total:   " .. tostring(info.total_viewers))

if info.stream_url then
    print("\n=== Stream URLs (FLV) ===")
    if info.stream_url.flv_origin then print("Origin: " .. info.stream_url.flv_origin) end
    if info.stream_url.flv_hd     then print("HD:     " .. info.stream_url.flv_hd) end
    if info.stream_url.flv_sd     then print("SD:     " .. info.stream_url.flv_sd) end
    if info.stream_url.flv_ld     then print("LD:     " .. info.stream_url.flv_ld) end
    if info.stream_url.flv_ao     then print("Audio:  " .. info.stream_url.flv_ao) end
else
    print("(no stream URLs)")
end
