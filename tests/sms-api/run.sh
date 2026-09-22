#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
lua_bin=${LUA:-"$repo_root/openwrt-25.12/staging_dir/hostpkg/bin/lua5.1"}

[ -x "$lua_bin" ] || {
	printf 'Lua 5.1 interpreter not found: %s\n' "$lua_bin" >&2
	exit 1
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
mkdir -p "$test_root/worker"

export LUA_PATH="$repo_root/packages/dotin/mm-utils/files/usr/lib/lua/?.lua;;"

cd "$repo_root"
"$lua_bin" tests/sms-api/test_validation.lua
"$lua_bin" tests/sms-api/test_handler.lua
SMS_API_TEST_TMP="$test_root/worker" "$lua_bin" tests/sms-api/test_worker.lua
tests/sms-api/test_helper.sh "$repo_root" "$test_root/helper"
