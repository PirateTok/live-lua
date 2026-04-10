.PHONY: deps discipline check test test-integration test-api test-wss test-load examples clean

LUA ?= lua

deps:
	luarocks install lua-protobuf
	luarocks install luasocket
	luarocks install luasec
	luarocks install lua-zlib
	luarocks install lua-cjson

discipline:
	$(LUA) discipline/scanner.lua .

check: discipline

test:
	$(LUA) tests/replay_test.lua

# Integration tests — hit real TikTok endpoints.
# Gate env vars:
#   PIRATETOK_LIVE_TEST_USER        — live TikTok username (H1, H4, W1-W7, D1)
#   PIRATETOK_LIVE_TEST_OFFLINE_USER — offline TikTok username (H2)
#   PIRATETOK_LIVE_TEST_HTTP=1      — enables nonexistent-user probe (H3)
#   PIRATETOK_LIVE_TEST_COOKIES     — session cookies for 18+ room info (H4)
#   PIRATETOK_LIVE_TEST_USERS       — comma-separated live usernames (M1)
test-api:
	$(LUA) tests/test_api_integration.lua

test-wss:
	$(LUA) tests/test_wss_smoke.lua

test-load:
	$(LUA) tests/test_multi_stream_load.lua

test-integration: test-api test-wss test-load

test-online:
	@echo "--- online_check: offline user ---"
	$(LUA) examples/online_check.lua contexpirat || true
	@echo "--- online_check: nonexistent user ---"
	$(LUA) examples/online_check.lua fakeuser999xyznotreal || true
	@echo "--- online_check: provide a live username as arg ---"
	@echo "usage: make test-online LIVE_USER=<username>"
	@if [ -n "$(LIVE_USER)" ]; then $(LUA) examples/online_check.lua $(LIVE_USER); fi

test-chat:
	@if [ -z "$(LIVE_USER)" ]; then echo "usage: make test-chat LIVE_USER=<username>"; exit 1; fi
	$(LUA) examples/basic_chat.lua $(LIVE_USER)

clean:
	@echo "nothing to clean — pure Lua"
