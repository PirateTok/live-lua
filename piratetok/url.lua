--- WSS URL construction and gzip decompression helpers.
local zlib = require "zlib"
local ua = require "piratetok.ua"

local M = {}

--- CDN endpoint hostnames.
M.CDN_HOSTS = {
    global = "webcast-ws.tiktok.com",
    eu = "webcast-ws.eu.tiktok.com",
    us = "webcast-ws.us.tiktok.com",
}

--- Build the full WSS URL with all required TikTok params.
---@param cdn_host string
---@param room_id string
---@return string
function M.build_ws_url(cdn_host, room_id)
    local last_rtt = string.format("%.3f", 100 + math.random() * 100)
    local tz_name = ua.system_timezone():gsub("/", "%%2F")
    local ws_lang = ua.system_language()
    local ws_region = ua.system_region()
    local params = {
        "version_code=180800",
        "device_platform=web",
        "cookie_enabled=true",
        "screen_width=1920",
        "screen_height=1080",
        "browser_language=" .. ws_lang .. "-" .. ws_region,
        "browser_platform=Linux%20x86_64",
        "browser_name=Mozilla",
        "browser_version=5.0%20(X11)",
        "browser_online=true",
        "tz_name=" .. tz_name,
        "app_name=tiktok_web",
        "sup_ws_ds_opt=1",
        "update_version_code=2.0.0",
        "compress=gzip",
        "webcast_language=" .. ws_lang,
        "ws_direct=1",
        "aid=1988",
        "live_id=12",
        "app_language=" .. ws_lang,
        "client_enter=1",
        "room_id=" .. room_id,
        "identity=audience",
        "history_comment_count=6",
        "last_rtt=" .. last_rtt,
        "heartbeat_duration=10000",
        "resp_content_type=protobuf",
        "did_rule=3",
    }
    return "wss://" .. cdn_host
        .. "/webcast/im/ws_proxy/ws_reuse_supplement/?"
        .. table.concat(params, "&")
end

--- Decompress gzipped data, or return as-is if not gzipped.
---@param data string
---@return string
function M.decompress_if_gzipped(data)
    if #data >= 2
        and string.byte(data, 1) == 0x1f
        and string.byte(data, 2) == 0x8b then
        local stream = zlib.inflate()
        local decompressed = stream(data)
        if decompressed then
            return decompressed
        end
    end
    return data
end

return M
