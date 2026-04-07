--- Cached profile fetcher — wraps http.scrape_profile with TTL cache + ttwid.
-- Thread-safe is N/A in Lua (single-threaded). Just call from your event loop.
local socket = require "socket"
local http = require "piratetok.http"
local auth = require "piratetok.auth"
local errors = require "piratetok.errors"

local DEFAULT_TTL = 300 -- 5 minutes
local TTWID_TIMEOUT = 10
local SCRAPE_TIMEOUT = 15

local ProfileCache = {}
ProfileCache.__index = ProfileCache

--- Create a new cache.
---@param opts table|nil optional: ttl (seconds), user_agent, cookies
---@return table cache
function ProfileCache.new(opts)
    opts = opts or {}
    return setmetatable({
        _entries = {},
        _ttwid = nil,
        _ttl = opts.ttl or DEFAULT_TTL,
        _user_agent = opts.user_agent,
        _cookies = opts.cookies,
    }, ProfileCache)
end

--- Fetch a profile, returning cached data if available and not expired.
-- Private/not-found profiles are negatively cached.
---@param username string
---@return table|nil profile
---@return table|nil error
function ProfileCache:fetch(username)
    local key = normalize_key(username)
    local now = socket.gettime()

    local entry = self._entries[key]
    if entry and (now - entry.at) < self._ttl then
        if entry.err then return nil, entry.err end
        return entry.profile, nil
    end

    local ttwid, ttwid_err = self:_ensure_ttwid()
    if not ttwid then return nil, ttwid_err end

    local profile, scrape_err = http.scrape_profile(
        key, ttwid, SCRAPE_TIMEOUT, self._user_agent, self._cookies)

    if scrape_err then
        if is_negative_cacheable(scrape_err) then
            self._entries[key] = { err = scrape_err, at = now }
        end
        return nil, scrape_err
    end

    self._entries[key] = { profile = profile, at = now }
    return profile, nil
end

--- Return cached profile without fetching. Returns nil on miss or expiry.
---@param username string
---@return table|nil profile
function ProfileCache:cached(username)
    local key = normalize_key(username)
    local entry = self._entries[key]
    if not entry then return nil end
    if (socket.gettime() - entry.at) >= self._ttl then return nil end
    if entry.err then return nil end
    return entry.profile
end

--- Remove one entry from the cache.
---@param username string
function ProfileCache:invalidate(username)
    self._entries[normalize_key(username)] = nil
end

--- Clear the entire cache.
function ProfileCache:invalidate_all()
    self._entries = {}
end

function ProfileCache:_ensure_ttwid()
    if self._ttwid then return self._ttwid, nil end
    local ttwid, err = auth.fetch_ttwid(TTWID_TIMEOUT, self._user_agent)
    if not ttwid then return nil, err end
    self._ttwid = ttwid
    return ttwid, nil
end

function normalize_key(username)
    return username:gsub("^@", ""):match("^%s*(.-)%s*$"):lower()
end

function is_negative_cacheable(err)
    return err.type == errors.PROFILE_PRIVATE
        or err.type == errors.PROFILE_NOT_FOUND
        or err.type == errors.PROFILE_ERROR
end

return ProfileCache
