--- Error types for PirateTok Lua live client.
-- Errors are plain tables with `type` and `message` fields.
-- This avoids class hierarchies while keeping errors structured and matchable.
local M = {}

--- Error type constants
M.USER_NOT_FOUND = "UserNotFound"
M.HOST_NOT_ONLINE = "HostNotOnline"
M.AGE_RESTRICTED = "AgeRestricted"
M.DEVICE_BLOCKED = "DeviceBlocked"
M.TIKTOK_BLOCKED = "TikTokBlocked"
M.CONNECTION_CLOSED = "ConnectionClosed"
M.INVALID_RESPONSE = "InvalidResponse"
M.DECODE_ERROR = "DecodeError"
M.HTTP_ERROR = "HttpError"
M.WEBSOCKET_ERROR = "WebSocketError"
M.ROOM_ID_MISSING = "RoomIdMissing"
M.INVALID_URL = "InvalidUrl"

--- Create a structured error table.
---@param err_type string one of the constants above
---@param message string human-readable description
---@return table error with type and message fields
function M.new(err_type, message)
    return { type = err_type, message = message }
end

--- Format an error for display.
---@param err table error table from M.new
---@return string
function M.format(err)
    if type(err) == "table" and err.type then
        return err.type .. ": " .. (err.message or "")
    end
    return tostring(err)
end

return M
