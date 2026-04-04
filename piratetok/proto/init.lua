--- Proto schema registry. Call register() once at startup to load all schemas.
-- Uses a single protoc instance so types defined in common.proto are visible
-- to messages.proto and messages_ext.proto.
local protoc = require "protoc"
local common = require "piratetok.proto.common"
local frames = require "piratetok.proto.frames"
local messages = require "piratetok.proto.messages"
local messages_ext = require "piratetok.proto.messages_ext"

local M = {}

local registered = false

--- Load all protobuf schemas into the lua-protobuf registry.
-- Safe to call multiple times; schemas are only loaded once.
function M.register()
    if registered then return end
    -- Single protoc instance — types accumulate across loads
    local p = protoc.new()
    common.register(p)
    frames.register(p)
    messages.register(p)
    messages_ext.register(p)
    registered = true
end

return M
