--- Protobuf frame types for WebSocket wire protocol.
-- PushFrame wraps all messages. Response contains decoded message batches.
local pb = require "pb"

local M = {}

--- Convert a decimal string to lua-protobuf "#hex" notation.
-- LuaJIT doubles only have 53 bits of mantissa; TikTok room IDs are
-- 63-bit integers. On LuaJIT, uses FFI uint64 to preserve all bits.
-- On Lua 5.3+, native integers handle 64-bit values natively.
---@param s string decimal number as string
---@return string lua-protobuf "#0x..." hex value
local u64_for_pb
local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
    -- LuaJIT: doubles lose precision on 63-bit room IDs, use FFI uint64
    local zero = ffi.new("uint64_t", 0)
    local ten = ffi.new("uint64_t", 10)
    u64_for_pb = function(s)
        local n = zero
        for i = 1, #s do
            n = n * ten + ffi.cast("uint64_t", string.byte(s, i) - 48)
        end
        return "#0x" .. string.format("%x", n)
    end
else
    -- Lua 5.3+: native 64-bit integers handle room IDs natively
    u64_for_pb = function(s)
        return "#0x" .. string.format("%x", tonumber(s))
    end
end

local SCHEMA = [[
syntax = "proto3";

message WebcastPushFrame {
    uint64 seq_id = 1;
    int64 log_id = 2;
    uint64 service = 3;
    uint64 method = 4;
    map<string, string> headers = 5;
    string payload_encoding = 6;
    string payload_type = 7;
    bytes payload = 8;
}

message WebcastResponseMessage {
    string type = 1;
    bytes payload = 2;
}

message WebcastResponse {
    repeated WebcastResponseMessage messages = 1;
    string cursor = 2;
    int64 fetch_interval = 3;
    int64 now = 4;
    string internal_ext = 5;
    int32 fetch_type = 6;
    map<string, string> route_params = 7;
    int64 heartbeat_duration = 8;
    bool needs_ack = 9;
    string push_server = 10;
    bool is_first = 11;
    string history_comment_cursor = 12;
    bool history_no_more = 13;
}

message HeartbeatMessage {
    uint64 room_id = 1;
}

message WebcastImEnterRoomMessage {
    int64 room_id = 1;
    string room_tag = 2;
    string live_region = 3;
    int64 live_id = 4;
    string identity = 5;
    string cursor = 6;
    int32 account_type = 7;
    int64 enter_unique_id = 8;
    string filter_welcome_msg = 9;
    bool is_anchor_continue_keep_msg = 10;
}
]]

function M.register(p)
    p:load(SCHEMA, "frames.proto")
end

--- Encode a heartbeat push frame.
---@param room_id string|number
---@return string binary protobuf bytes
---@return string|nil error message
function M.build_heartbeat(room_id)
    local hb_payload = pb.encode("HeartbeatMessage", {
        room_id = u64_for_pb(tostring(room_id)),
    })
    if not hb_payload then
        return nil, "failed to encode HeartbeatMessage"
    end
    local frame = pb.encode("WebcastPushFrame", {
        seq_id = 0,
        log_id = 0,
        payload_encoding = "pb",
        payload_type = "hb",
        payload = hb_payload,
    })
    if not frame then
        return nil, "failed to encode heartbeat PushFrame"
    end
    return frame, nil
end

--- Encode an enter_room push frame.
---@param room_id string|number
---@return string binary protobuf bytes
---@return string|nil error message
function M.build_enter_room(room_id)
    local msg_payload = pb.encode("WebcastImEnterRoomMessage", {
        room_id = u64_for_pb(tostring(room_id)),
        live_id = 12,
        identity = "audience",
        filter_welcome_msg = "0",
    })
    if not msg_payload then
        return nil, "failed to encode WebcastImEnterRoomMessage"
    end
    local frame = pb.encode("WebcastPushFrame", {
        seq_id = 0,
        log_id = 0,
        payload_encoding = "pb",
        payload_type = "im_enter_room",
        payload = msg_payload,
    })
    if not frame then
        return nil, "failed to encode enter_room PushFrame"
    end
    return frame, nil
end

--- Encode an ack push frame.
---@param log_id number
---@param internal_ext string
---@return string binary protobuf bytes
---@return string|nil error message
function M.build_ack(log_id, internal_ext)
    local frame = pb.encode("WebcastPushFrame", {
        seq_id = 0,
        log_id = log_id,
        payload_encoding = "pb",
        payload_type = "ack",
        payload = internal_ext,
    })
    if not frame then
        return nil, "failed to encode ack PushFrame"
    end
    return frame, nil
end

return M
