.PHONY: deps discipline check test examples clean

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
