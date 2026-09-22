local sms_api = require "sms_api"

local tests = 0

local function check(condition, message)
    tests = tests + 1
    if not condition then
        error(message or ("assertion " .. tests .. " failed"), 2)
    end
end

local function valid_message(value, encoding, length)
    local result, err = sms_api.validate_message(value)
    check(result ~= nil, "expected valid message, got " .. tostring(err))
    check(result.encoding == encoding, "unexpected encoding")
    check(result.length == length, "unexpected character count")
end

local function invalid_message(value, expected)
    local result, err = sms_api.validate_message(value)
    check(result == nil, "expected invalid message")
    check(err == expected, "expected " .. expected .. ", got " .. tostring(err))
end

check(sms_api.validate_phone("123"), "minimum phone number")
check(sms_api.validate_phone("+989121234567"), "international phone number")
check(sms_api.validate_phone(string.rep("9", 15)), "maximum phone number")
check(not sms_api.validate_phone("12"), "short phone number")
check(not sms_api.validate_phone(string.rep("9", 16)), "long phone number")
check(not sms_api.validate_phone("+98 912"), "phone number with spaces")
check(not sms_api.validate_phone("۱۲۳"), "non-ASCII phone digits")

valid_message(string.rep("A", 160), "gsm", 160)
invalid_message(string.rep("A", 161), "message-too-long")
valid_message("Hello\r\nworld", "gsm", 12)
valid_message("Δ", "gsm", 1)
valid_message("سلام", "ucs2", 4)
valid_message(string.rep("@", 70), "ucs2", 70)
invalid_message(string.rep("@", 71), "message-too-long")
valid_message(string.rep("{", 70), "ucs2", 70)
invalid_message(string.rep("{", 71), "message-too-long")
invalid_message("", "empty-message")
invalid_message("a" .. string.char(0) .. "b", "unsupported-character")
invalid_message("a" .. string.char(0x1B) .. "b", "unsupported-character")
invalid_message("a" .. string.char(0x1A) .. "b", "unsupported-character")
invalid_message(string.char(0xC2, 0x85), "unsupported-character")
invalid_message(string.char(0xF0, 0x9F, 0x98, 0x80), "unsupported-character")
invalid_message(string.char(0xC0, 0xAF), "unsupported-character")

local id = "ee20e864-8896-4fc7-9a0d-2c614d69f14a"
check(sms_api.normalize_uuid(id) == id, "valid UUID")
check(sms_api.normalize_uuid(string.upper(id)) == id, "uppercase UUID")
check(sms_api.normalize_uuid("not-a-uuid") == nil, "invalid UUID")

print("validation tests: " .. tests .. " passed")

