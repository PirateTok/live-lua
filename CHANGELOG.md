# Changelog

## 0.2.3

- **Security: TLS certificates are verified.** Previously every connection used `verify = "none"` (MITM-able). New `piratetok.tls`: chain verification against the system trust store (`SSL_CERT_FILE` / `SSL_CERT_DIR`, then the standard distro bundle paths) plus subjectAltName hostname matching, which luasec does not do itself. Windows needs `SSL_CERT_FILE`. Override: `require("piratetok.tls").ca_file`.
- `http.parse_profile()` split out of `scrape_profile()` (pure); `ProfileCache` fetches ttwid with the bounded retry.
- Tests: TLS valid/invalid pair (unknown CA rejected by default, trusted CA + wrong host rejected), hostname matcher, ProfileCache against a local origin (parse, cache hit, negative caching, single ttwid); `make test` runs `luac -p` over the examples.

## 0.2.2

- Proxy: one shared HTTP CONNECT tunnel (`piratetok.proxy`) for ttwid, HTTP API and WSS; `http://user:pass@host:port` sends `Proxy-Authorization: Basic`; SOCKS URLs are rejected with `InvalidUrl`.
- WSS `Accept-Language` follows `:language()` / `:region()` (was hardcoded en-US).
- `http.parse_room_info()` split out of `fetch_room_info()` (pure, testable).
- Tests: `tests/wire_test.lua` — real client through a local Basic-auth CONNECT proxy + TLS fake (needs `openssl` for the test cert); unit tests for acks, room info parsing, proxy URLs.

## 0.2.1

- `check_online()` error mapping: a non-zero `statusCode` is now `ApiError` (with `.code`), not `InvalidResponse`; a non-JSON / mangled body is `TikTokBlocked`.

## 0.2.0 (tagged, never published to LuaRocks)

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
