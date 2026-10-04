--- TLS client wrap with certificate verification against the system trust store.
-- luasec verifies the chain (verify = "peer") but loads no CA store by itself and does
-- not check the hostname, so this module finds the CA bundle and matches the peer
-- certificate's subjectAltName DNS names against the host.
--
-- Trust store: tls.ca_file (override, e.g. tests) → $SSL_CERT_FILE / $SSL_CERT_DIR →
-- the standard bundle locations of Linux / BSD / macOS distributions.
local ssl = require "ssl"
local errors = require "piratetok.errors"

local M = {}

--- CA bundle path override (PEM). nil = system trust store.
M.ca_file = nil

local BUNDLES = {
    "/etc/ssl/certs/ca-certificates.crt",                -- Debian/Ubuntu/Arch/Gentoo
    "/etc/pki/tls/certs/ca-bundle.crt",                  -- Fedora/RHEL
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", -- RHEL 7+
    "/etc/ssl/ca-bundle.pem",                            -- openSUSE
    "/etc/ssl/cert.pem",                                 -- macOS, Alpine, OpenBSD, Arch
    "/usr/local/etc/ssl/cert.pem",                       -- FreeBSD
    "/usr/local/share/certs/ca-root-nss.crt",            -- FreeBSD (nss)
}

local function readable(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

--- Resolve the trust store.
---@return string|nil cafile
---@return string|nil capath
---@return table|nil error when no trust store exists
function M.trust_store()
    if M.ca_file then return M.ca_file, nil, nil end
    local env_file, env_dir = os.getenv("SSL_CERT_FILE"), os.getenv("SSL_CERT_DIR")
    if (env_file and env_file ~= "") or (env_dir and env_dir ~= "") then
        return env_file ~= "" and env_file or nil, env_dir ~= "" and env_dir or nil, nil
    end
    for _, path in ipairs(BUNDLES) do
        if readable(path) then return path, nil, nil end
    end
    return nil, nil, errors.new(errors.HTTP_ERROR,
        "no CA trust store found — set SSL_CERT_FILE to a PEM CA bundle")
end

--- RFC 6125 DNS-ID match: exact, or a single leftmost "*" label.
---@param pattern string name from the certificate
---@param host string host we connected to
---@return boolean
function M.host_matches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local suffix = pattern:match("^%*(%..+%..+)$")
    if not suffix then return false end
    local label, rest = host:match("^([^.]+)(%..+)$")
    return label ~= nil and rest == suffix
end

local function check_hostname(conn, host)
    local cert = conn:getpeercertificate()
    if not cert then return "no peer certificate" end
    local san = (cert:extensions() or {})["2.5.29.17"]
    local names = san and san.dNSName or {}
    for _, name in ipairs(names) do
        if M.host_matches(name, host) then return nil end
    end
    return "certificate does not match host " .. host .. " (SAN: " .. table.concat(names, ",") .. ")"
end

--- Wrap a connected TCP socket in verified TLS for `host`.
---@param tcp userdata connected luasocket TCP socket (direct or CONNECT tunnel)
---@param host string server name (SNI + hostname check)
---@return userdata|nil TLS connection
---@return table|nil error (type HTTP_ERROR, message prefixed "tls: ")
function M.wrap(tcp, host)
    local cafile, capath, store_err = M.trust_store()
    if store_err then return nil, store_err end
    local conn, wrap_err = ssl.wrap(tcp, {
        mode = "client", protocol = "any", options = "all",
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = cafile, capath = capath,
    })
    if not conn then
        return nil, errors.new(errors.HTTP_ERROR, "tls: wrap failed: " .. tostring(wrap_err))
    end
    conn:sni(host)
    local ok, hs_err = conn:dohandshake()
    if not ok then
        conn:close()
        return nil, errors.new(errors.HTTP_ERROR, "tls: handshake with " .. host .. " failed: " .. tostring(hs_err))
    end
    local mismatch = check_hostname(conn, host)
    if mismatch then
        conn:close()
        return nil, errors.new(errors.HTTP_ERROR, "tls: " .. mismatch)
    end
    return conn, nil
end

return M
