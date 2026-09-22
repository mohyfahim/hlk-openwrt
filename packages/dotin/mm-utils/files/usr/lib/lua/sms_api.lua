local M = {}

local GSM_SINGLE = {}

local function add_range(first, last)
    local value

    for value = first, last do
        GSM_SINGLE[value] = true
    end
end

-- GSM 03.38 default alphabet characters which occupy one septet.
-- "@" is deliberately excluded because this API sends it as UCS2.
local gsm_non_ascii = {
    0x00A3, 0x00A5, 0x00E8, 0x00E9, 0x00F9, 0x00EC,
    0x00F2, 0x00C7, 0x00D8, 0x00F8, 0x00C5, 0x00E5,
    0x0394, 0x03A6, 0x0393, 0x039B, 0x03A9, 0x03A0,
    0x03A8, 0x03A3, 0x0398, 0x039E, 0x00C6, 0x00E6,
    0x00DF, 0x00C9, 0x00A4, 0x00A1, 0x00C4, 0x00D6,
    0x00D1, 0x00DC, 0x00A7, 0x00BF, 0x00E4, 0x00F6,
    0x00F1, 0x00FC, 0x00E0
}

GSM_SINGLE[0x000A] = true
GSM_SINGLE[0x000D] = true
GSM_SINGLE[0x0020] = true
GSM_SINGLE[0x0021] = true
GSM_SINGLE[0x0022] = true
GSM_SINGLE[0x0023] = true
GSM_SINGLE[0x0024] = true
GSM_SINGLE[0x0025] = true
GSM_SINGLE[0x0026] = true
GSM_SINGLE[0x0027] = true
GSM_SINGLE[0x0028] = true
GSM_SINGLE[0x0029] = true
GSM_SINGLE[0x002A] = true
GSM_SINGLE[0x002B] = true
GSM_SINGLE[0x002C] = true
GSM_SINGLE[0x002D] = true
GSM_SINGLE[0x002E] = true
GSM_SINGLE[0x002F] = true
add_range(0x0030, 0x003F)
add_range(0x0041, 0x005A)
GSM_SINGLE[0x005F] = true
add_range(0x0061, 0x007A)

local index
for index = 1, #gsm_non_ascii do
    GSM_SINGLE[gsm_non_ascii[index]] = true
end


local function continuation(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
end


-- Calls callback(codepoint) for every character. Returns false for malformed
-- UTF-8. The implementation is intentionally Lua 5.1 compatible.
function M.each_codepoint(value, callback)
    if type(value) ~= "string" then
        return false
    end

    local offset = 1
    local length = #value

    while offset <= length do
        local first = value:byte(offset)
        local codepoint
        local width

        if first <= 0x7F then
            codepoint = first
            width = 1
        elseif first >= 0xC2 and first <= 0xDF then
            local second = value:byte(offset + 1)
            if not continuation(second) then
                return false
            end
            codepoint = (first - 0xC0) * 0x40 + (second - 0x80)
            width = 2
        elseif first >= 0xE0 and first <= 0xEF then
            local second = value:byte(offset + 1)
            local third = value:byte(offset + 2)

            if not continuation(second) or not continuation(third) then
                return false
            end
            if first == 0xE0 and second < 0xA0 then
                return false
            end
            if first == 0xED and second > 0x9F then
                return false
            end

            codepoint =
                (first - 0xE0) * 0x1000
                + (second - 0x80) * 0x40
                + (third - 0x80)
            width = 3
        elseif first >= 0xF0 and first <= 0xF4 then
            local second = value:byte(offset + 1)
            local third = value:byte(offset + 2)
            local fourth = value:byte(offset + 3)

            if not continuation(second)
                or not continuation(third)
                or not continuation(fourth)
            then
                return false
            end
            if first == 0xF0 and second < 0x90 then
                return false
            end
            if first == 0xF4 and second > 0x8F then
                return false
            end

            codepoint =
                (first - 0xF0) * 0x40000
                + (second - 0x80) * 0x1000
                + (third - 0x80) * 0x40
                + (fourth - 0x80)
            width = 4
        else
            return false
        end

        if callback and callback(codepoint) == false then
            return true
        end

        offset = offset + width
    end

    return true
end


function M.valid_utf8(value)
    return M.each_codepoint(value)
end


function M.validate_phone(value)
    if type(value) ~= "string" then
        return false
    end

    local digits = value
    if digits:sub(1, 1) == "+" then
        digits = digits:sub(2)
    end

    return #digits >= 3
        and #digits <= 15
        and digits:match("^[0-9]+$") ~= nil
end


function M.validate_message(value)
    if type(value) ~= "string" then
        return nil, "empty-message"
    end

    local count = 0
    local gsm = true
    local supported = true

    local valid = M.each_codepoint(
        value,
        function(codepoint)
            count = count + 1

            if codepoint > 0xFFFF
                or (codepoint >= 0xD800 and codepoint <= 0xDFFF)
                or (codepoint < 0x20
                    and codepoint ~= 0x0A
                    and codepoint ~= 0x0D)
                or (codepoint >= 0x7F and codepoint <= 0x9F)
            then
                supported = false
                return false
            end

            if not GSM_SINGLE[codepoint] then
                gsm = false
            end

            return true
        end
    )

    if not valid or not supported then
        return nil, "unsupported-character"
    end
    if count == 0 then
        return nil, "empty-message"
    end

    local limit = gsm and 160 or 70
    if count > limit then
        return nil, "message-too-long"
    end

    return {
        encoding = gsm and "gsm" or "ucs2",
        length = count,
        limit = limit
    }
end


function M.validate_request(input)
    if type(input) ~= "table" or not M.validate_phone(input.to) then
        return nil, "invalid-phone-number"
    end

    local message_info, message_error = M.validate_message(input.message)
    if not message_info then
        return nil, message_error
    end

    return {
        to = input.to,
        message = input.message,
        encoding = message_info.encoding,
        length = message_info.length
    }
end


function M.normalize_uuid(value)
    if type(value) ~= "string" then
        return nil
    end

    local normalized = value:lower()
    if normalized:match(
        "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
        .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
    ) then
        return normalized
    end

    return nil
end


return M
