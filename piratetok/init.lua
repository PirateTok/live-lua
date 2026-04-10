--- PirateTok Lua Live — TikTok Live event streaming for game engines.
-- Poll-based API: call client:poll() in your game loop.
-- No event loop dependency, no coroutine magic, no background threads.
local socket = require "socket"
local pb = require "pb"
local proto_registry = require "piratetok.proto"
local auth = require "piratetok.auth"
local http = require "piratetok.http"
local ws = require "piratetok.websocket"
local frames = require "piratetok.proto.frames"
local events_mod = require "piratetok.events"
local errors = require "piratetok.errors"
local url_mod = require "piratetok.url"
local ua_mod = require "piratetok.ua"

-- Ensure proto schemas are loaded
proto_registry.register()

local Client = {}
Client.__index = Client

local Builder = {}
Builder.__index = Builder

local M = {}

--- Create a new connection builder for a TikTok username.
---@param username string TikTok username (with or without @)
---@return table builder
function M.builder(username)
    local b = setmetatable({
        _username = username:match("^%s*(.-)%s*$"):gsub("^@", ""),
        _cdn = "global",
        _timeout = 10,
        _heartbeat_interval = 10,
        _stale_timeout = 60,
        _max_retries = 5,
        _proxy = nil,
        _user_agent = nil,
        _cookies = nil,
    }, Builder)
    return b
end

function Builder:cdn(ep) self._cdn = ep; return self end
function Builder:timeout(s) self._timeout = s; return self end
function Builder:heartbeat_interval(s) self._heartbeat_interval = s; return self end
function Builder:stale_timeout(s) self._stale_timeout = s; return self end
function Builder:max_retries(n) self._max_retries = n; return self end
function Builder:proxy(u) self._proxy = u; return self end

--- Set a custom user-agent. When set, disables UA rotation — this exact
-- string is used for all HTTP and WSS requests.
---@param agent string user-agent string
---@return table self
function Builder:user_agent(agent) self._user_agent = agent; return self end

--- Set session cookies for 18+ room info and/or custom auth.
-- Format: "sessionid=xxx; sid_tt=xxx"
-- Only required for: fetching room metadata on age-restricted (18+) rooms.
-- NOT required for: WSS connection, event streaming, or any other functionality.
---@param c string cookie header value
---@return table self
function Builder:cookies(c) self._cookies = c; return self end

--- Build the client (does not connect yet).
---@return table client
function Builder:build()
    local cdn_host = url_mod.CDN_HOSTS[self._cdn] or url_mod.CDN_HOSTS.global
    return setmetatable({
        username = self._username,
        cdn_host = cdn_host,
        timeout = self._timeout,
        heartbeat_interval = self._heartbeat_interval,
        stale_timeout = self._stale_timeout,
        max_retries = self._max_retries,
        proxy = self._proxy,
        user_agent = self._user_agent,
        cookies = self._cookies,
        _ws = nil,
        _room_id = nil,
        _listeners = {},
        _state = "idle",
        _attempt = 0,
        _reconnect_at = 0,
        _last_heartbeat = 0,
        _last_data = 0,
    }, Client)
end

--- Register a callback for an event type.
---@param event_name string event name (chat, gift, follow, join, etc.)
---@param callback function receives (event_data) table
function Client:on(event_name, callback)
    if not self._listeners[event_name] then
        self._listeners[event_name] = {}
    end
    local cbs = self._listeners[event_name]
    cbs[#cbs + 1] = callback
end

--- Fire an event to all registered listeners.
function Client:_emit(event_name, data)
    local cbs = self._listeners[event_name]
    if not cbs then return end
    for i = 1, #cbs do
        cbs[i](data)
    end
end

--- Start connecting. Room ID resolution is blocking; WSS is non-blocking via poll().
---@return boolean started
---@return table|nil error
function Client:connect()
    if self._state == "connected" or self._state == "connecting" then
        return true, nil
    end
    self._state = "connecting"
    self._attempt = 0

    local result, room_err = http.fetch_room_id(
        self.username, self.timeout, self.user_agent, self.proxy)
    if not result then
        self._state = "disconnected"
        self:_emit("error", room_err)
        return false, room_err
    end

    self._room_id = result.room_id
    self:_emit("connected", { room_id = self._room_id })

    local ws_err = self:_connect_ws()
    if ws_err then
        self._state = "reconnecting"
        self._reconnect_at = socket.gettime() + 2
    end
    return true, nil
end

--- Internal: establish WSS connection with fresh ttwid.
--- Uses user-configured UA if set, otherwise picks random from pool.
--- Uses user-configured cookies appended to ttwid cookie if set.
function Client:_connect_ws()
    -- Pick UA: user override or random from pool
    local active_ua = self.user_agent or ua_mod.random_ua()

    local ttwid, ttwid_err = auth.fetch_ttwid(self.timeout, active_ua, self.proxy)
    if not ttwid then return ttwid_err end

    -- Build cookie header: ttwid always present, user cookies appended if set
    local cookie_val = "ttwid=" .. ttwid
    if self.cookies and self.cookies ~= "" then
        cookie_val = cookie_val .. "; " .. self.cookies
    end

    local ws_url = url_mod.build_ws_url(self.cdn_host, self._room_id)
    local conn, ws_err = ws.connect(
        ws_url, { Cookie = cookie_val }, active_ua)
    if not conn then return ws_err end

    self._ws = conn
    self._state = "connected"
    self._last_data = socket.gettime()
    self._last_heartbeat = 0

    local hb, hb_err = frames.build_heartbeat(self._room_id)
    if not hb then return errors.new(errors.WEBSOCKET_ERROR, hb_err) end
    local ok, send_err = self._ws:send_binary(hb)
    if not ok then return errors.new(errors.WEBSOCKET_ERROR, send_err) end

    local enter, enter_err = frames.build_enter_room(self._room_id)
    if not enter then return errors.new(errors.WEBSOCKET_ERROR, enter_err) end
    local ok2, send_err2 = self._ws:send_binary(enter)
    if not ok2 then return errors.new(errors.WEBSOCKET_ERROR, send_err2) end

    self._last_heartbeat = socket.gettime()
    return nil
end

--- Disconnect and stop reconnecting.
function Client:disconnect()
    self._state = "disconnected"
    if self._ws then
        self._ws:close()
        self._ws = nil
    end
    self:_emit("disconnected", {})
end

--- Process pending WebSocket data. Call this every frame in your game loop.
function Client:poll()
    local now = socket.gettime()

    if self._state == "reconnecting" then
        if now < self._reconnect_at then return end
        self:_try_reconnect()
        return
    end
    if self._state ~= "connected" then return end

    -- Heartbeat
    if now - self._last_heartbeat >= self.heartbeat_interval then
        local hb = frames.build_heartbeat(self._room_id)
        if hb then self._ws:send_binary(hb) end
        self._last_heartbeat = now
    end

    -- Stale check
    if now - self._last_data > self.stale_timeout then
        self:_start_reconnect("stale — no data for " .. self.stale_timeout .. "s")
        return
    end

    -- Read frames (non-blocking, cap at 50 per poll)
    local count = 0
    while count < 50 do
        local opcode, payload, read_err = self._ws:read_frame()
        if not opcode then
            if read_err == "timeout" then break end
            self:_start_reconnect(read_err or "read error")
            return
        end
        count = count + 1
        self._last_data = now
        if opcode == 0x02 then
            self:_process_binary(payload)
        elseif opcode == 0x09 then
            self._ws:send_pong(payload)
        elseif opcode == 0x08 then
            self:_start_reconnect("server sent close frame")
            return
        end
    end
end

--- Internal: process a binary WebSocket frame (protobuf PushFrame).
function Client:_process_binary(data)
    local frame = pb.decode("WebcastPushFrame", data)
    if not frame then return end

    local ptype = frame.payload_type or ""
    if ptype == "msg" then
        local payload = url_mod.decompress_if_gzipped(frame.payload)
        local response = pb.decode("WebcastResponse", payload)
        if not response then return end

        if response.needs_ack and response.internal_ext
            and response.internal_ext ~= "" then
            local ack = frames.build_ack(frame.log_id, response.internal_ext)
            if ack then self._ws:send_binary(ack) end
        end

        local msgs = response.messages or {}
        for i = 1, #msgs do
            local msg = msgs[i]
            local evts = events_mod.decode_message(msg.type, msg.payload)
            for j = 1, #evts do
                self:_emit(evts[j].name, evts[j].data)
            end
        end
    elseif ptype == "im_enter_room_resp" then
        self:_emit("room_entered", {})
    end
end

--- Internal: enter reconnection state.
---@param reason string human-readable reason
---@param device_blocked boolean|nil true if DEVICE_BLOCKED triggered this
function Client:_start_reconnect(reason, device_blocked)
    if self._ws then self._ws:close(); self._ws = nil end
    self._attempt = self._attempt + 1
    if self._attempt > self.max_retries then
        self._state = "disconnected"
        self:_emit("disconnected", { reason = reason })
        return
    end
    -- DEVICE_BLOCKED: short 2s delay, will get fresh ttwid+UA in _try_reconnect
    local delay
    if device_blocked then
        delay = 2
    else
        delay = math.min(2 ^ self._attempt, 30)
    end
    self._state = "reconnecting"
    self._reconnect_at = socket.gettime() + delay
    self:_emit("reconnecting", {
        attempt = self._attempt,
        max_retries = self.max_retries,
        delay_secs = delay,
        reason = reason,
        device_blocked = device_blocked or false,
    })
end

function Client:_try_reconnect()
    local ws_err = self:_connect_ws()
    if ws_err then
        local is_blocked = ws_err.type == errors.DEVICE_BLOCKED
        self:_start_reconnect(errors.format(ws_err), is_blocked)
    end
end

--- Run the event loop (blocking). For non-game standalone scripts.
---@param poll_interval number seconds between polls (default 0.05)
function Client:run(poll_interval)
    poll_interval = poll_interval or 0.05
    local ok, err = self:connect()
    if not ok then return nil, err end
    while self._state ~= "disconnected" do
        self:poll()
        socket.sleep(poll_interval)
    end
    return true, nil
end

M.check_online = http.check_online
M.fetch_room_info = http.fetch_room_info
M.errors = errors
M.events = events_mod
M.ProfileCache = require "piratetok.helpers.profile_cache"
M.GiftStreakTracker = require "piratetok.helpers.gift_streak"
M.LikeAccumulator = require "piratetok.helpers.like_accumulator"

return M
