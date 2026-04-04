#!/usr/bin/env luajit
--- Discipline scanner for PirateTok Lua live.
--- Enforces: R1 (800 LOC max), R2 (no silent error suppression), R3 (no glob imports).
local MAX_LOC = 800
local MAX_LOC_PROTO = 900

local violations = {}

local function add_violation(file, line, rule, message)
    violations[#violations + 1] = {
        file = file, line = line, rule = rule, message = message,
    }
end

local function scan_file(path)
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("cannot open: " .. path .. ": " .. tostring(err) .. "\n")
        return
    end

    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()

    -- R1: file size
    local is_proto = path:match("/proto/")
    local limit = is_proto and MAX_LOC_PROTO or MAX_LOC
    if #lines > limit then
        add_violation(path, #lines, "R1",
            "file has " .. #lines .. " lines (max " .. limit .. ")")
    end

    for i, line in ipairs(lines) do
        -- R2: silent error suppression
        -- Bare pcall without capturing error return
        if line:match("^%s*pcall%(") and not line:match("=%s*pcall%(") then
            add_violation(path, i, "R2",
                "bare pcall() — capture and handle the error return")
        end

        -- Ignoring second return value (nil, err pattern)
        -- Matches: local x = something() where something could return nil, err
        -- This is hard to detect statically, so we focus on obvious patterns

        -- Empty error handler after pcall
        if line:match("pcall%b()%s*$") and not line:match("[=,]%s*pcall") then
            add_violation(path, i, "R2",
                "pcall result not captured — errors silently swallowed")
        end

        -- R3: glob/wildcard imports (Lua doesn't really have these,
        -- but check for require("*") or dofile patterns)
        if line:match('require%s*%(?%s*"[^"]*%*') then
            add_violation(path, i, "R3", "wildcard require pattern")
        end
    end
end

-- Find all .lua files under piratetok/
local function find_lua_files(dir)
    local handle = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
    if not handle then return {} end
    local files = {}
    for line in handle:lines() do
        files[#files + 1] = line
    end
    handle:close()
    return files
end

-- Main
local root = arg[1] or "."
local files = find_lua_files(root .. "/piratetok")

if #files == 0 then
    io.stderr:write("no .lua files found under " .. root .. "/piratetok/\n")
    os.exit(1)
end

for _, path in ipairs(files) do
    scan_file(path)
end

if #violations == 0 then
    io.write("discipline: all " .. #files .. " files pass\n")
    os.exit(0)
else
    io.stderr:write("DISCIPLINE VIOLATIONS:\n")
    for _, v in ipairs(violations) do
        io.stderr:write(string.format("  %s:%d [%s] %s\n",
            v.file, v.line, v.rule, v.message))
    end
    io.stderr:write("\n" .. #violations .. " violation(s) in "
        .. #files .. " files\n")
    os.exit(1)
end
