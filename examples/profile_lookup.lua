--- Profile lookup example — fetch HD avatars + profile metadata.
-- Usage: lua examples/profile_lookup.lua [username]
local ProfileCache = require "piratetok.helpers.profile_cache"

local username = arg[1] or "tiktok"
local cache = ProfileCache.new()

print("Fetching profile for @" .. username .. "...")
local profile, err = cache:fetch(username)
if err then
    print("  [ERROR] " .. (err.message or tostring(err)))
    os.exit(1)
end

print("  User ID:    " .. profile.user_id)
print("  Nickname:   " .. profile.nickname)
print("  Verified:   " .. tostring(profile.verified))
print("  Followers:  " .. tostring(profile.follower_count))
print("  Videos:     " .. tostring(profile.video_count))
print("  Avatar (thumb):  " .. profile.avatar_thumb)
print("  Avatar (720):    " .. profile.avatar_medium)
print("  Avatar (1080):   " .. profile.avatar_large)
print("  Bio link:   " .. (profile.bio_link or "(none)"))
local room = profile.room_id ~= "" and profile.room_id or "(offline)"
print("  Room ID:    " .. room)

print()
print("Fetching @" .. username .. " again (should be cached)...")
local p2, err2 = cache:fetch(username)
if err2 then
    print("  [cached error] " .. err2.message)
else
    print("  [cached] " .. p2.nickname .. " — " .. p2.follower_count .. " followers")
end
