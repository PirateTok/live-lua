--- Parsing for the online_audience endpoint (the web viewer panel roster).
-- Pure functions over the response body: no I/O, testable offline.
local errors = require "piratetok.errors"

local M = {}

local STATUS_SESSION_REQUIRED = 20003

local function str_of(t, key)
    local v = t[key]
    if type(v) == "string" then return v end
    return ""
end

local function int_of(v)
    if type(v) == "number" then return math.floor(v) end
    return 0
end

--- Stringify a user id; id_str wins because cjson turns big ints into floats.
local function user_id_of(user)
    if type(user.id_str) == "string" and user.id_str ~= "" then
        return user.id_str
    end
    if type(user.id) == "number" then
        return string.format("%.0f", user.id)
    end
    return "0"
end

--- Build an AudienceViewer from one data.ranks[] entry; nil when it has no user.
---@param rank table
---@return table|nil
function M.parse_viewer(rank)
    local user = rank.user
    if type(user) ~= "table" then return nil end

    local avatar_url = nil
    local thumb = user.avatar_thumb
    if type(thumb) == "table" and type(thumb.url_list) == "table"
        and type(thumb.url_list[1]) == "string" then
        avatar_url = thumb.url_list[1]
    end

    local follower_count = 0
    if type(user.follow_info) == "table" then
        follower_count = int_of(user.follow_info.follower_count)
    end

    return {
        rank = int_of(rank.rank),
        score = int_of(rank.score),
        user_id = user_id_of(user),
        username = str_of(user, "display_id"),
        nickname = str_of(user, "nickname"),
        sec_uid = str_of(user, "sec_uid"),
        avatar_url = avatar_url,
        follower_count = follower_count,
        verified = user.verified == true,
        is_follower = user.is_follower == true,
        is_following = user.is_following == true,
        is_subscriber = user.is_subscribe == true,
    }
end

--- Parse an online_audience response into a RoomAudience table.
---@param body string|nil raw response body
---@param http_status number|nil HTTP status (for error messages)
---@param json_decode function JSON decoder
---@return table|nil RoomAudience {total, anonymous, viewers, raw_json}
---@return table|nil error
function M.parse(body, http_status, json_decode)
    if not body or body == "" then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "empty response from online_audience (http "
            .. tostring(http_status) .. ")")
    end

    local ok, json = pcall(json_decode, body)
    if not ok or type(json) ~= "table" then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "online_audience JSON parse failed: " .. tostring(json))
    end

    local data = json.data
    local code = json.status_code
    if type(code) ~= "number" then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "no status_code in online_audience response")
    elseif code == STATUS_SESSION_REQUIRED then
        return nil, errors.new(errors.SESSION_REQUIRED,
            "audience roster needs login — pass session cookies "
            .. "(sessionid=xxx; sid_tt=xxx) to fetch_room_audience()")
    elseif code ~= 0 then
        local msg = ""
        if type(data) == "table" and type(data.message) == "string" then
            msg = data.message
        end
        return nil, errors.new(errors.INVALID_RESPONSE, string.format(
            "online_audience status_code=%d %s", code, msg))
    end

    if type(data) ~= "table" then
        return nil, errors.new(errors.INVALID_RESPONSE,
            "missing 'data' in online_audience")
    end

    local viewers = {}
    if type(data.ranks) == "table" then
        for i = 1, #data.ranks do
            local viewer = M.parse_viewer(data.ranks[i])
            if viewer then viewers[#viewers + 1] = viewer end
        end
    end

    return {
        total = int_of(data.total),
        anonymous = int_of(data.anonymous),
        viewers = viewers,
        raw_json = body,
    }, nil
end

--- Pull the streamer id (data.owner.id_str) out of a room/info body.
---@param raw_json string
---@param json_decode function
---@return string|nil anchor id
---@return table|nil error
function M.owner_id(raw_json, json_decode)
    local ok, json = pcall(json_decode, raw_json)
    local owner = ok and type(json) == "table" and type(json.data) == "table"
        and json.data.owner
    if type(owner) == "table" and type(owner.id_str) == "string"
        and owner.id_str ~= "" then
        return owner.id_str, nil
    end
    return nil, errors.new(errors.INVALID_RESPONSE, "no owner id in room info")
end

return M
