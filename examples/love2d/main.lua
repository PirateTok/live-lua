--- Love2D example — TikTok Live chat overlay.
--- Run: love examples/love2d -- <username>
local PirateTok = require "piratetok"

local client
local chat_lines = {}
local MAX_LINES = 25
local status = "initializing..."

local function add_line(text)
    chat_lines[#chat_lines + 1] = text
    while #chat_lines > MAX_LINES do
        table.remove(chat_lines, 1)
    end
end

function love.load()
    love.graphics.setBackgroundColor(0.1, 0.1, 0.15)

    local username = arg[2] -- love passes args offset by 1
    if not username then
        status = "usage: love examples/love2d -- <username>"
        return
    end

    client = PirateTok.builder(username)
        :cdn("eu")
        :max_retries(5)
        :build()

    client:on("connected", function(info)
        status = "connected — room " .. info.room_id
    end)

    client:on("chat", function(msg)
        local name = msg.user and msg.user.nickname or "???"
        add_line(name .. ": " .. (msg.comment or ""))
    end)

    client:on("gift", function(msg)
        local name = msg.user and msg.user.nickname or "???"
        local gift_name = msg.gift_details and msg.gift_details.name or "gift"
        add_line("[GIFT] " .. name .. " sent " .. gift_name)
    end)

    client:on("join", function(msg)
        local name = msg.user and msg.user.nickname or "???"
        add_line("[JOIN] " .. name)
    end)

    client:on("follow", function(msg)
        local name = msg.user and msg.user.nickname or "???"
        add_line("[FOLLOW] " .. name)
    end)

    client:on("room_user_seq", function(msg)
        status = "viewers: " .. (msg.viewer_count or 0)
    end)

    client:on("reconnecting", function(info)
        status = "reconnecting " .. info.attempt .. "/" .. info.max_retries
    end)

    client:on("disconnected", function()
        status = "disconnected"
    end)

    client:on("error", function(err)
        status = "error: " .. PirateTok.errors.format(err)
    end)

    local ok, err = client:connect()
    if not ok then
        status = "failed: " .. PirateTok.errors.format(err)
        client = nil
    end
end

function love.update(dt)
    if client then
        client:poll()
    end
end

function love.draw()
    -- Status bar
    love.graphics.setColor(0.3, 0.8, 0.3)
    love.graphics.print(status, 10, 10)

    -- Chat lines
    love.graphics.setColor(1, 1, 1)
    for i, line in ipairs(chat_lines) do
        love.graphics.print(line, 10, 30 + i * 20)
    end
end

function love.keypressed(key)
    if key == "escape" then
        if client then client:disconnect() end
        love.event.quit()
    end
end
