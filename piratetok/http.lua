--- HTTP API calls — room ID resolution and optional room info fetch.
-- Uses raw luasocket+luasec for HTTP/TLS (no http library dependency).
local socket = require "socket"
local ssl = require "ssl"
local errors = require "piratetok.errors"
local ua = require "piratetok.ua"

local M = {}

--- Minimal HTTPS GET — returns response body or nil+error.
---@param host string
---@param path string
---@param timeout number seconds
---@param cookies string|nil optional Cookie header
---@param user_agent string|nil override UA (default: random from pool)
---@return string|nil body
---@return number|nil http status code
---@return table|nil error
local function https_get(host, path, timeout, cookies, user_agent, accept, proxy)
    local tcp = socket.tcp()
    tcp:settimeout(timeout)

    if proxy and proxy ~= "" then
        -- HTTP CONNECT tunneling through proxy
        local phost, pport = proxy:match("^https?://([^:/]+):?(%d*)/?$")
        if not phost then
            return nil, nil, errors.new(errors.HTTP_ERROR,
                "invalid proxy URL: " .. proxy)
        end
        pport = tonumber(pport) or 8080

        local ok, conn_err = tcp:connect(phost, pport)
        if not ok then
            return nil, nil, errors.new(errors.HTTP_ERROR,
                "proxy connect failed: " .. tostring(conn_err))
        end

        local connect_req = "CONNECT " .. host .. ":443 HTTP/1.1\r\n"
            .. "Host: " .. host .. ":443\r\n\r\n"
        tcp:send(connect_req)

        local status_line = tcp:receive("*l")
        if not status_line or not status_line:match("^HTTP/1%.. 200") then
            tcp:close()
            return nil, nil, errors.new(errors.HTTP_ERROR,
                "proxy CONNECT failed: " .. tostring(status_line))
        end
        -- drain remaining proxy response headers
        while true do
            local line = tcp:receive("*l")
            if not line or line == "" then break end
        end
    else
        local ok, conn_err = tcp:connect(host, 443)
        if not ok then
            return nil, nil, errors.new(errors.HTTP_ERROR,
                "connect failed: " .. tostring(conn_err))
        end
    end

    local params = {
        mode = "client",
        protocol = "any",
        verify = "none",
        options = "all",
    }
    local conn, tls_err = ssl.wrap(tcp, params)
    if not conn then
        tcp:close()
        return nil, nil, errors.new(errors.HTTP_ERROR,
            "tls wrap: " .. tostring(tls_err))
    end

    conn:sni(host)
    local hs_ok, hs_err = conn:dohandshake()
    if not hs_ok then
        tcp:close()
        return nil, nil, errors.new(errors.HTTP_ERROR,
            "tls handshake: " .. tostring(hs_err))
    end

    local active_ua = user_agent or ua.random_ua()
    local accept_val = accept or "application/json"
    local headers = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. "\r\n"
        .. "User-Agent: " .. active_ua .. "\r\n"
        .. "Accept: " .. accept_val .. "\r\n"
        .. "Referer: https://www.tiktok.com/\r\n"
    if cookies and cookies ~= "" then
        headers = headers .. "Cookie: " .. cookies .. "\r\n"
    end
    headers = headers .. "Connection: close\r\n\r\n"

    local _, send_err = conn:send(headers)
    if send_err then
        conn:close()
        return nil, nil, errors.new(errors.HTTP_ERROR,
            "send: " .. tostring(send_err))
    end

    -- Read status line
    local status_line, recv_err = conn:receive("*l")
    if not status_line then
        conn:close()
        return nil, nil, errors.new(errors.HTTP_ERROR,
            "receive: " .. tostring(recv_err))
    end
    local http_status = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))

    -- Read headers, find Content-Length or Transfer-Encoding
    local content_length = nil
    local chunked = false
    while true do
        local line, line_err = conn:receive("*l")
        if not line then
            conn:close()
            return nil, http_status, errors.new(errors.HTTP_ERROR,
                "header read: " .. tostring(line_err))
        end
        if line == "" then break end
        local cl = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if cl then content_length = tonumber(cl) end
        if line:lower():match("transfer%-encoding:%s*chunked") then
            chunked = true
        end
    end

    -- Read body
    local body
    if chunked then
        body = read_chunked(conn)
    elseif content_length then
        body = conn:receive(content_length)
    else
        body = conn:receive("*a")
    end

    conn:close()

    if not body then
        return nil, http_status, errors.new(errors.HTTP_ERROR, "empty body")
    end

    return body, http_status, nil
end

--- Read chunked transfer-encoding body.
---@param conn userdata
---@return string body
function read_chunked(conn)
    local parts = {}
    while true do
        local size_line = conn:receive("*l")
        if not size_line then break end
        local chunk_size = tonumber(size_line, 16)
        if not chunk_size or chunk_size == 0 then break end
        local chunk = conn:receive(chunk_size)
        if chunk then
            parts[#parts + 1] = chunk
        end
        conn:receive("*l") -- trailing \r\n
    end
    return table.concat(parts)
end

--- Try to load a JSON library (cjson preferred, dkjson fallback).
local json_decode
do
    local ok, cjson = pcall(require, "cjson")
    if ok then
        json_decode = cjson.decode
    else
        local ok2, dkjson = pcall(require, "dkjson")
        if ok2 then
            json_decode = dkjson.decode
        else
            error("piratetok requires 'cjson' or 'dkjson' — install via luarocks")
        end
    end
end

--- Resolve a TikTok username to a room ID.
---@param username string TikTok username (with or without @)
---@param timeout number request timeout in seconds (default 10)
---@param user_agent string|nil override UA (default: random from pool)
---@return table|nil result with room_id field
---@return table|nil error
function M.fetch_room_id(username, timeout, user_agent)
    timeout = timeout or 10
    local clean = username:gsub("^@", ""):match("^%s*(.-)%s*$")

    local path = "/api-live/user/room?aid=1988&app_name=tiktok_web"
        .. "&device_platform=web_pc&app_language=en&browser_language=en-US"
        .. "&region=RO&user_is_login=false"
        .. "&uniqueId=" .. clean
        .. "&sourceType=54&staleTime=600000"

    local body, http_status, http_err = https_get(
        "www.tiktok.com", path, timeout, nil, user_agent)
    if http_err then
        return nil, http_err
    end

    if http_status == 403 or http_status == 429 then
        return nil, errors.new(errors.TIKTOK_BLOCKED,
            "HTTP " .. tostring(http_status) .. " — rate-limited or geo-blocked")
    end

    if not body or body == "" then
        return nil, errors.new(errors.TIKTOK_BLOCKED,
            "empty response — TikTok blocked request")
    end

    local ok, data = pcall(json_decode, body)
    if not ok then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "JSON parse failed: " .. tostring(data))
    end

    local status_code = data.statusCode
    if status_code == 19881007 then
        return nil, errors.new(errors.USER_NOT_FOUND,
            "user '" .. clean .. "' does not exist on TikTok")
    elseif status_code ~= 0 then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "tiktok api statusCode=" .. tostring(status_code))
    end

    -- Extract room ID from nested response
    local room_id = nil
    if data.data and data.data.user then
        room_id = tostring(data.data.user.roomId or "")
    end

    if not room_id or room_id == "" or room_id == "0" then
        return nil, errors.new(errors.HOST_NOT_ONLINE,
            "'" .. clean .. "' is not currently live")
    end

    -- Check live status
    local live_status = 0
    if data.data and data.data.liveRoom then
        live_status = data.data.liveRoom.status or 0
    elseif data.data and data.data.user then
        live_status = data.data.user.status or 0
    end

    if live_status ~= 2 then
        return nil, errors.new(errors.HOST_NOT_ONLINE,
            "'" .. clean .. "' is not currently live (status=" .. tostring(live_status) .. ")")
    end

    return { room_id = room_id }, nil
end

--- Fetch detailed room info (title, viewers, stream URLs).
-- Optional call — not needed for WSS event streaming.
-- For 18+ rooms, pass session cookies ("sessionid=xxx; sid_tt=xxx").
---@param room_id string
---@param timeout number seconds (default 10)
---@param cookies string|nil session cookies for 18+ rooms
---@param user_agent string|nil override UA (default: random from pool)
---@return table|nil room info
---@return table|nil error
function M.fetch_room_info(room_id, timeout, cookies, user_agent)
    timeout = timeout or 10

    local tz_name = ua.system_timezone():gsub("/", "%%2F")
    local path = "/webcast/room/info/?aid=1988&app_name=tiktok_web"
        .. "&device_platform=web_pc&app_language=en&browser_language=en-US"
        .. "&browser_name=Mozilla&browser_online=true&browser_platform=Win32"
        .. "&cookie_enabled=true&focus_state=true&from_page=user"
        .. "&screen_height=1080&screen_width=1920"
        .. "&tz_name=" .. tz_name .. "&webcast_language=en"
        .. "&room_id=" .. room_id

    local body, http_status, http_err = https_get(
        "webcast.tiktok.com", path, timeout, cookies, user_agent)
    if http_err then
        return nil, http_err
    end

    if not body or body == "" then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "empty response from room/info (http " .. tostring(http_status) .. ")")
    end

    local ok, data = pcall(json_decode, body)
    if not ok then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "JSON parse failed: " .. tostring(data))
    end

    local sc = data.status_code
    if sc == 4003110 then
        return nil, errors.new(errors.AGE_RESTRICTED,
            "18+ room — pass session cookies (sessionid=xxx; sid_tt=xxx) to fetch_room_info()")
    elseif sc and sc ~= 0 then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "room/info status_code=" .. tostring(sc))
    end

    if not data.data then
        return nil, errors.new(errors.INVALID_RESPONSE, "missing 'data' in room info")
    end

    local d = data.data
    local info = {
        title = d.title or "",
        viewers = d.user_count or 0,
        likes = (d.stats and d.stats.like_count) or 0,
        total_viewers = (d.stats and d.stats.total_user) or 0,
        stream_url = parse_stream_urls(d),
        raw_json = body,
    }

    return info, nil
end

--- Parse nested stream URL JSON.
---@param room_data table
---@return table|nil
function parse_stream_urls(room_data)
    local su = room_data.stream_url
    if not su then return nil end
    local sdk = su.live_core_sdk_data
    if not sdk then return nil end
    local pull = sdk.pull_data
    if not pull then return nil end
    local stream_str = pull.stream_data
    if not stream_str or stream_str == "" then return nil end

    local ok, nested = pcall(json_decode, stream_str)
    if not ok or not nested or not nested.data then return nil end

    local nd = nested.data
    local function get_flv(quality)
        local q = nd[quality]
        if q and q.main and q.main.flv then
            return q.main.flv
        end
        return nil
    end

    return {
        flv_origin = get_flv("origin"),
        flv_hd = get_flv("hd") or get_flv("uhd"),
        flv_sd = get_flv("sd"),
        flv_ld = get_flv("ld"),
        flv_ao = get_flv("ao"),
    }
end

--- Check if a user is online (standalone, doesn't connect).
---@param username string
---@param timeout number seconds (default 10)
---@param user_agent string|nil override UA (default: random from pool)
---@return table|nil result with room_id and status fields
---@return table|nil error
function M.check_online(username, timeout, user_agent)
    return M.fetch_room_id(username, timeout, user_agent)
end

local SIGI_MARKER = 'id="__UNIVERSAL_DATA_FOR_REHYDRATION__"'

--- Scrape a TikTok profile page and extract profile data from the SIGI JSON.
-- Stateless — no caching. Use helpers.profile_cache for cached access.
---@param username string TikTok username (with or without @)
---@param ttwid string valid ttwid cookie value
---@param timeout number seconds (default 15)
---@param user_agent string|nil override UA (default: random from pool)
---@param cookies string|nil extra cookies (sessionid, sid_tt)
---@return table|nil profile table
---@return table|nil error
function M.scrape_profile(username, ttwid, timeout, user_agent, cookies, proxy)
    timeout = timeout or 15
    local clean = username:gsub("^@", ""):match("^%s*(.-)%s*$"):lower()

    local cookie_val = "ttwid=" .. ttwid
    if cookies and cookies ~= "" then
        -- strip user-provided ttwid so the managed one wins
        local filtered = {}
        for pair in cookies:gmatch("[^;]+") do
            pair = pair:match("^%s*(.-)%s*$")
            if not pair:match("^ttwid=") then
                filtered[#filtered + 1] = pair
            end
        end
        if #filtered > 0 then
            cookie_val = cookie_val .. "; " .. table.concat(filtered, "; ")
        end
    end

    local body, http_status, http_err = https_get(
        "www.tiktok.com", "/@" .. clean, timeout, cookie_val, user_agent,
        "text/html,application/xhtml+xml", proxy)
    if http_err then return nil, http_err end

    if not body or body == "" then
        return nil, errors.new(errors.PROFILE_SCRAPE, "empty HTML response")
    end

    -- Extract SIGI JSON from <script> tag
    local marker_pos = body:find(SIGI_MARKER, 1, true)
    if not marker_pos then
        return nil, errors.new(errors.PROFILE_SCRAPE, "SIGI script tag not found")
    end

    local gt_pos = body:find(">", marker_pos, true)
    if not gt_pos then
        return nil, errors.new(errors.PROFILE_SCRAPE, "no > after SIGI marker")
    end

    local json_start = gt_pos + 1
    local script_end = body:find("</script>", json_start, true)
    if not script_end then
        return nil, errors.new(errors.PROFILE_SCRAPE, "no </script> after SIGI JSON")
    end

    local json_str = body:sub(json_start, script_end - 1)
    if json_str == "" then
        return nil, errors.new(errors.PROFILE_SCRAPE, "empty SIGI JSON blob")
    end

    local ok_json, blob = pcall(json_decode, json_str)
    if not ok_json then
        return nil, errors.new(errors.PROFILE_SCRAPE, "JSON parse failed")
    end

    local scope = blob and blob.__DEFAULT_SCOPE__
    if not scope then
        return nil, errors.new(errors.PROFILE_SCRAPE, "missing __DEFAULT_SCOPE__")
    end

    local detail = scope["webapp.user-detail"]
    if not detail then
        return nil, errors.new(errors.PROFILE_SCRAPE, "missing webapp.user-detail")
    end

    local status_code = detail.statusCode or 0
    if status_code == 10222 then
        return nil, errors.new(errors.PROFILE_PRIVATE, "profile is private: @" .. clean)
    elseif status_code == 10221 or status_code == 10223 then
        return nil, errors.new(errors.PROFILE_NOT_FOUND, "profile not found: @" .. clean)
    elseif status_code ~= 0 then
        return nil, errors.new(errors.PROFILE_ERROR,
            "profile fetch error: statusCode=" .. tostring(status_code))
    end

    local user_info = detail.userInfo
    if not user_info or not user_info.user then
        return nil, errors.new(errors.PROFILE_SCRAPE, "missing userInfo.user")
    end

    local user = user_info.user
    local stats = user_info.stats or {}

    local bio_link = nil
    if user.bioLink and user.bioLink.link and user.bioLink.link ~= "" then
        bio_link = user.bioLink.link
    end

    return {
        user_id = tostring(user.id or ""),
        unique_id = user.uniqueId or "",
        nickname = user.nickname or "",
        bio = user.signature or "",
        avatar_thumb = user.avatarThumb or "",
        avatar_medium = user.avatarMedium or "",
        avatar_large = user.avatarLarger or "",
        verified = user.verified == true,
        private_account = user.privateAccount == true,
        is_organization = (user.isOrganization or 0) ~= 0,
        room_id = user.roomId or "",
        bio_link = bio_link,
        follower_count = stats.followerCount or 0,
        following_count = stats.followingCount or 0,
        heart_count = stats.heartCount or 0,
        video_count = stats.videoCount or 0,
        friend_count = stats.friendCount or 0,
    }, nil
end

return M
