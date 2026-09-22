#!/bin/sh

set -eu

repo_root=$1
test_root=$2
helper="$repo_root/packages/dotin/mm-utils/files/usr/libexec/sms-api-send"
fake_mmcli="$repo_root/tests/sms-api/fake-mmcli"

run_send() {
	mode=$1
	case_dir="$test_root/$mode"
	mkdir -p "$case_dir"
	printf 'hello' >"$case_dir/message"
	: >"$case_dir/mmcli.log"

	MOCK_MODE=$mode \
	MOCK_MMCLI_LOG="$case_dir/mmcli.log" \
	SMS_API_TEST_MMCLI="$fake_mmcli" \
		"$helper" \
		--modem any \
		--timeout 120 \
		--to +989121234567 \
		--text "$case_dir/message" \
		--result "$case_dir/result" \
		--marker "$case_dir/submitted"
}

run_send sent
grep -qx 'state=sent' "$test_root/sent/result"
grep -qx 'messageReference=23' "$test_root/sent/result"
grep -q '^deleted$' "$test_root/sent/mmcli.log"
! grep -q 'hello' "$test_root/sent/mmcli.log"

run_send rejected
grep -qx 'state=failed' "$test_root/rejected/result"
grep -qx 'error=modem-rejected' "$test_root/rejected/result"

run_send timeout
grep -qx 'state=unknown' "$test_root/timeout/result"
grep -qx 'error=modem-response-timeout' "$test_root/timeout/result"

run_send lost
grep -qx 'state=unknown' "$test_root/lost/result"
grep -qx 'error=modem-connection-lost' "$test_root/lost/result"

run_send unavailable
grep -qx 'state=retry' "$test_root/unavailable/result"
[ ! -e "$test_root/unavailable/submitted" ]

disconnected_dir="$test_root/disconnected"
mkdir -p "$disconnected_dir"
printf 'hello' >"$disconnected_dir/message"
: >"$disconnected_dir/mmcli.log"
MOCK_MODE=sent MOCK_MODEM_STATE=enabled MOCK_MMCLI_LOG="$disconnected_dir/mmcli.log" \
SMS_API_TEST_MMCLI="$fake_mmcli" \
	"$helper" --modem any --timeout 120 --to +989121234567 \
	--text "$disconnected_dir/message" --result "$disconnected_dir/result" \
	--marker "$disconnected_dir/submitted"
grep -qx 'state=retry' "$disconnected_dir/result"
[ ! -e "$disconnected_dir/submitted" ]

cleanup_dir="$test_root/cleanup"
mkdir -p "$cleanup_dir"
: >"$cleanup_dir/mmcli.log"
MOCK_MODE=sent MOCK_SMS_STATE=sending MOCK_MMCLI_LOG="$cleanup_dir/mmcli.log" \
SMS_API_TEST_MMCLI="$fake_mmcli" \
	"$helper" --cleanup --modem any \
	--sms-path /org/freedesktop/ModemManager1/SMS/7 \
	--result "$cleanup_dir/result"
grep -qx 'state=retry' "$cleanup_dir/result"

MOCK_MODE=sent MOCK_SMS_STATE=sent MOCK_MMCLI_LOG="$cleanup_dir/mmcli.log" \
SMS_API_TEST_MMCLI="$fake_mmcli" \
	"$helper" --cleanup --modem any \
	--sms-path /org/freedesktop/ModemManager1/SMS/7 \
	--result "$cleanup_dir/result"
grep -qx 'state=done' "$cleanup_dir/result"

printf '%s\n' 'helper tests: passed'
