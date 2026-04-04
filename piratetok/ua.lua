--- User-Agent rotation and system timezone detection.
-- Provides a pool of browser user-agents that rotate on each call,
-- and timezone detection for WSS URL parameters.
local M = {}

--- Pool of realistic browser user-agents.
-- Mix of Firefox and Chrome across Linux, Windows, macOS.
M.USER_AGENTS = {
    "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:139.0) Gecko/20100101 Firefox/139.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
        .. "Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        .. "Chrome/132.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        .. "Chrome/131.0.0.0 Safari/537.36",
}

--- Return a random user-agent from the pool.
---@return string user_agent
function M.random_ua()
    return M.USER_AGENTS[math.random(1, #M.USER_AGENTS)]
end

--- Detect the system IANA timezone.
-- Checks in order: $TZ env var, /etc/timezone file, /etc/localtime symlink.
-- Falls back to "UTC" if none found.
---@return string iana timezone name (e.g. "America/New_York")
function M.system_timezone()
    -- 1. Check TZ environment variable
    local tz_env = os.getenv("TZ")
    if tz_env and tz_env ~= "" then
        -- Strip leading colon (POSIX allows ":/path" or "Region/City")
        local cleaned = tz_env:match("^:?(.+)$")
        if cleaned and cleaned ~= "" then
            return cleaned
        end
    end

    -- 2. Try /etc/timezone (Debian/Ubuntu)
    local tz_file = io.open("/etc/timezone", "r")
    if tz_file then
        local content = tz_file:read("*l")
        tz_file:close()
        if content then
            local trimmed = content:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                return trimmed
            end
        end
    end

    -- 3. Try /etc/localtime symlink (Arch, Fedora, macOS)
    -- readlink via Lua: use lfs if available, otherwise popen
    local link_ok, lfs = pcall(require, "lfs")
    if link_ok and lfs.symlinkattributes then
        local attrs = lfs.symlinkattributes("/etc/localtime")
        if attrs and attrs.target then
            local iana = attrs.target:match("/zoneinfo/(.+)$")
            if iana and iana ~= "" then
                return iana
            end
        end
    end

    -- Fallback: use readlink command
    local handle = io.popen("readlink /etc/localtime 2>/dev/null")
    if handle then
        local target = handle:read("*l")
        handle:close()
        if target then
            local iana = target:match("/zoneinfo/(.+)$")
            if iana and iana ~= "" then
                return iana
            end
        end
    end

    return "UTC"
end

return M
