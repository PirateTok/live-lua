<p align="center">
  <img src="https://raw.githubusercontent.com/PirateTok/.github/main/profile/assets/og-banner-v2.png" alt="PirateTok" width="640" />
</p>

# piratetok-live-lua

Connect to any TikTok Live stream and receive real-time events in Lua — chat, gifts, likes, joins, viewer counts, and 65 decoded event types. Poll-based API for game engine integration. No signing server, no API keys, no authentication required.

```lua
local PirateTok = require "piratetok"

-- Create client with builder pattern — cdn("eu") picks the EU endpoint
local client = PirateTok.builder("username_here")
    :cdn("eu")
    :build()

-- Register event callbacks — poll-based, ideal for game engines (Love2D, Defold)
client:on("chat", function(msg)
    local name = msg.user and msg.user.nickname or "?"
    print("[chat] " .. name .. ": " .. (msg.comment or ""))
end)

client:on("gift", function(msg)
    local name = msg.user and msg.user.nickname or "?"
    local gift = msg.gift_details and msg.gift_details.name or "gift"
    local diamonds = PirateTok.events.diamond_total(msg)
    print("[gift] " .. name .. " sent " .. gift .. " (" .. diamonds .. " diamonds)")
end)

client:on("like", function(msg)
    local name = msg.user and msg.user.nickname or "?"
    print("[like] " .. name .. " (" .. (msg.total or 0) .. " total)")
end)

-- Blocks until disconnected — heartbeat and reconnection handled internally
client:run()
```

## Install

```bash
luarocks install piratetok-live-lua
```

Or install dependencies manually and copy the source:

```bash
luarocks install luasocket
luarocks install luasec
luarocks install lua-protobuf
luarocks install lua-zlib
luarocks install lua-cjson
```

Then copy the `piratetok/` directory into your project.

## Other languages

| Language | Install | Repo |
|:---------|:--------|:-----|
| **Rust** | `cargo add piratetok-live-rs` | [live-rs](https://github.com/PirateTok/live-rs) |
| **Go** | `go get github.com/PirateTok/live-go` | [live-go](https://github.com/PirateTok/live-go) |
| **Python** | `pip install piratetok-live-py` | [live-py](https://github.com/PirateTok/live-py) |
| **JavaScript** | `npm install piratetok-live-js` | [live-js](https://github.com/PirateTok/live-js) |
| **C#** | `dotnet add package PirateTok.Live` | [live-cs](https://github.com/PirateTok/live-cs) |
| **Java** | `com.piratetok:live` | [live-java](https://github.com/PirateTok/live-java) |
| **Elixir** | `{:piratetok_live, "~> 0.1"}` | [live-ex](https://github.com/PirateTok/live-ex) |
| **Dart** | `dart pub add piratetok_live` | [live-dart](https://github.com/PirateTok/live-dart) |
| **C** | `#include "piratetok.h"` | [live-c](https://github.com/PirateTok/live-c) |
| **PowerShell** | `Install-Module PirateTok.Live` | [live-ps1](https://github.com/PirateTok/live-ps1) |
| **Shell** | `bpkg install PirateTok/live-sh` | [live-sh](https://github.com/PirateTok/live-sh) |

## Game engine usage (Love2D)

Poll-based API — call `client:poll()` in your game loop instead of `client:run()`:

```lua
local PirateTok = require "piratetok"
local messages = {}

local client = PirateTok.builder("username_here"):build()
client:on("chat", function(msg)
    local name = msg.user and msg.user.nickname or "?"
    table.insert(messages, name .. ": " .. (msg.comment or ""))
end)
client:connect()

function love.update(dt)
    client:poll()  -- non-blocking, reads available frames
end

function love.draw()
    for i, line in ipairs(messages) do
        love.graphics.print(line, 10, i * 20)
    end
end
```

## Features

- **Zero signing dependency** — no API keys, no signing server, no external auth
- **65 decoded event types** — chat, gifts, likes, joins, follows, shares, battles, polls, envelopes, and more
- **Poll-based API** — `client:poll()` for game loops, `client:run()` for standalone scripts
- **Auto-reconnection** — stale detection, exponential backoff, self-healing auth
- **Enriched User data** — badges, gifter level, moderator status, follow info, fan club
- **Sub-routed convenience events** — `follow`, `share`, `join`, `live_ended` fire alongside raw events
- **No protoc** — protobuf schemas defined inline via lua-protobuf, no codegen, no build tools

## Configuration

```lua
local client = PirateTok.builder("username_here")
    :cdn("eu")                  -- "eu" / "us" / "global" (default)
    :timeout(15)                -- HTTP timeout in seconds (default 10)
    :heartbeat_interval(10)     -- seconds between heartbeats (default 10)
    :stale_timeout(90)          -- reconnect after N seconds of silence (default 60)
    :max_retries(10)            -- reconnect attempts (default 5)
    :proxy("http://host:port")   -- HTTP/HTTPS proxy URL (CONNECT tunnel)
    :compress(false)            -- disable gzip compression for WSS payloads (default true)
    :user_agent("Mozilla/...")  -- override random UA rotation with a fixed user-agent
    :cookies("sessionid=xxx; sid_tt=xxx") -- session cookies for 18+ room info
    :language("en")             -- override detected system language (two-letter code)
    :region("US")               -- override detected system region (two-letter code)
    :build()
```

## Events

| Event | Callback data |
|-------|--------------|
| `chat` | `.user`, `.comment` |
| `gift` | `.user`, `.gift_details`, `.repeat_count`, `.repeat_end`, `.combo_count` |
| `like` | `.user`, `.count`, `.total` |
| `join` | `.user` (sub-routed from MemberMessage) |
| `follow` | `.user` (sub-routed from SocialMessage) |
| `share` | `.user` (sub-routed from SocialMessage) |
| `room_user_seq` | `.viewer_count`, `.total_user` |
| `live_ended` | `.reason` (sub-routed from ControlMessage) |
| `connected` | `.room_id` |
| `reconnecting` | `.attempt`, `.max_retries`, `.delay_secs`, `.reason` |
| `disconnected` | `.reason` |
| `error` | error table (use `PirateTok.errors.format(err)`) |
| `unknown` | `.method`, `.payload` (raw bytes for unhandled types) |

Plus 58 more decoded types: `emote_chat`, `poll`, `envelope`, `rank_update`, `link_mic_battle`, etc.

## Online check (standalone)

```lua
local PirateTok = require "piratetok"

local result, err = PirateTok.check_online("username_here")
if not result then
    print(PirateTok.errors.format(err))  -- "not found" / "not online" / "blocked"
else
    print("LIVE — room_id: " .. result.room_id)
end
```

## Room info (optional, separate call)

```lua
-- Normal rooms — no cookies needed
local info, err = PirateTok.fetch_room_info("ROOM_ID")

-- 18+ rooms — pass session cookies from browser DevTools
local info, err = PirateTok.fetch_room_info("ROOM_ID", 10, "sessionid=abc; sid_tt=abc")
```

## Gift streaks

```lua
client:on("gift", function(msg)
    local events = PirateTok.events
    if events.is_combo_gift(msg) then
        if events.is_streak_over(msg) then
            print("x" .. msg.repeat_count .. " = " .. events.diamond_total(msg) .. " diamonds")
        end
    else
        print(events.diamond_total(msg) .. " diamonds")
    end
end)
```

## How it works

1. Resolves username to room ID via TikTok JSON API
2. Authenticates and opens a direct WSS connection
3. Sends protobuf heartbeats every 10s to keep alive
4. Decodes protobuf event stream into Lua tables
5. Auto-reconnects on stale/dropped connections with fresh credentials

All protobuf schemas are defined inline via `lua-protobuf` — no `.proto` files, no codegen, no build-time dependencies.

## Runtime compatibility

Requires **Lua 5.1+** (including LuaJIT) with unrestricted system access (raw TCP sockets). Works in:

- **Love2D** — poll-based API designed for game loops
- **Defold** — with native extension packaging for C deps
- **Standalone LuaJIT / Lua** — scripts, bots, monitoring tools

Does **not** work in sandboxed Lua environments (Roblox, Neovim, FiveM, OpenResty) — these restrict socket access and/or use incompatible Lua variants.

## Examples

```bash
luajit examples/basic_chat.lua <username>        # connect + print chat events
luajit examples/online_check.lua <username>      # check if user is live
luajit examples/stream_info.lua <username>       # fetch room metadata + stream URLs
luajit examples/gift_streak.lua <username>       # gift streak tracking with diamond totals
luajit examples/profile_lookup.lua <username>    # fetch profile metadata + avatars (cached)
```

See `examples/love2d/` for Love2D game engine integration.

## Replay testing

Deterministic cross-lib validation against binary WSS captures. Requires testdata from a separate repo:

```bash
git clone https://github.com/PirateTok/live-testdata testdata
make test
```

Tests skip gracefully if testdata is not found. You can also set `PIRATETOK_TESTDATA` to point to a custom location.

## License

0BSD
