# Changelog

## 0.2.0

- ttwid fetch retries up to 8× (750 ms apart) when tiktok.com answers without the cookie; transport errors still fail fast.
- Reconnect loop: ttwid + UA fetched once per stream and reused across reconnects; rotated only on `DEVICE_BLOCKED` or a session that died within 30 s. A ttwid failure is a failed attempt (`reconnecting` fires), never an abort.
- `max_retries` now counts consecutive failures — a session that stayed up 30 s resets the counter.
- WSS `heartbeat_duration` URL param follows `:heartbeat_interval()`.
- `check_online()` / `fetch_room_id()` return `anchor_id` (streamer user id).
- `room_user_seq` decodes `ranks_list`, `seats_list`, `pop_str`, `anonymous`; new `PirateTok.top_viewers(seq)` helper.
- New `PirateTok.fetch_room_audience(room_id, anchor_id, cookies, ...)` — full viewer roster, login-gated; new `SessionRequired` error. `examples/audience.lua`.
- `fetch_room_info()` takes a trailing `proxy` argument.
- Replay tests fail (instead of skip) on missing testdata and also look in `../live-testdata`; new offline `tests/unit_test.lua`.
- Homepage: https://piratetok.rosint.org
