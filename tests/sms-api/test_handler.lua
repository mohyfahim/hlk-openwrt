local tests = 0
local output = {}
local request_body = ""
local worker_response = nil
local worker_available = true

local function check(condition, message)
    tests = tests + 1
    if not condition then
        error(message or ("assertion " .. tests .. " failed"), 2)
    end
end

local function encode(value)
    local kind = type(value)
    if kind == "string" then
        return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif kind == "number" or kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local parts = {}
        local key, item
        for key, item in pairs(value) do
            parts[#parts + 1] = encode(tostring(key)) .. ":" .. encode(item)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local json_inputs = {
    ['{"to":"+989121234567","message":"hello"}'] = {
        to = "+989121234567",
        message = "hello"
    },
    ['{"to":"bad","message":"hello"}'] = {
        to = "bad",
        message = "hello"
    },
    ['{"to":"123","message":""}'] = {
        to = "123",
        message = ""
    }
}

package.preload["luci.jsonc"] = function()
    return {
        parse = function(value)
            local parsed = json_inputs[value]
            if not parsed then
                error("invalid json")
            end
            return parsed
        end,
        stringify = encode
    }
end

package.preload["ubus"] = function()
    return {
        connect = function()
            if not worker_available then
                return nil
            end
            return {
                call = function(_, object, method, arguments)
                    check(object == "sms.api", "unexpected ubus object")
                    if type(worker_response) == "function" then
                        return worker_response(method, arguments)
                    end
                    return worker_response
                end,
                close = function() end
            }
        end
    }
end

uhttpd = {
    send = function(value)
        output[#output + 1] = value
    end,
    recv = function(length)
        local value = request_body:sub(1, length)
        return #value, value
    end,
    urldecode = function(value)
        return value
    end
}

local original_popen = io.popen
local original_execute = os.execute
io.popen = function()
    return {
        read = function() return "" end,
        close = function() end
    }
end
os.execute = function() return 0 end

assert(loadfile("packages/dotin/mm-utils/files/www/api/handler.lua"))()

local function invoke(method, path, body, content_type, remote)
    output = {}
    request_body = body or ""

    handle_request({
        REQUEST_METHOD = method,
        PATH_INFO = path,
        REMOTE_ADDR = remote or "127.0.0.1",
        CONTENT_TYPE = content_type,
        CONTENT_LENGTH = body and tostring(#body) or nil,
        QUERY_STRING = ""
    })

    return table.concat(output)
end

local body = '{"to":"+989121234567","message":"hello"}'
worker_response = { id = "ee20e864-8896-4fc7-9a0d-2c614d69f14a", status = "queued" }
local response = invoke("POST", "/sms", body, "application/json; charset=utf-8")
check(response:find("Status: 202 Accepted", 1, true), "enqueue status")
check(response:find('"status":"queued"', 1, true), "enqueue body")

response = invoke("POST", "/sms", body, nil)
check(response:find("Status: 400 Bad Request", 1, true), "missing content type")
check(response:find("invalid-json", 1, true), "invalid JSON error")

response = invoke("POST", "/sms", "not-json", "application/json")
check(response:find("invalid-json", 1, true), "malformed JSON")

response = invoke("POST", "/sms", string.rep("x", 4097), "application/json")
check(response:find("invalid-json", 1, true), "oversized JSON")

response = invoke("POST", "/sms", '{"to":"bad","message":"hello"}', "application/json")
check(response:find("invalid-phone-number", 1, true), "phone validation")

response = invoke("POST", "/sms", '{"to":"123","message":""}', "application/json")
check(response:find("empty-message", 1, true), "message validation")

worker_response = { error = "sms-queue-full" }
response = invoke("POST", "/sms", body, "application/json")
check(response:find("Status: 503 Service Unavailable", 1, true), "queue full status")

worker_available = false
response = invoke("POST", "/sms", body, "application/json")
check(response:find("sms-queue-full", 1, true), "worker unavailable")
worker_available = true

local id = "ee20e864-8896-4fc7-9a0d-2c614d69f14a"
worker_response = { id = id, status = "queued" }
response = invoke("GET", "/sms/" .. id)
check(response:find('"status":"queued"', 1, true), "queued status response")

worker_response = { id = id, status = "sending" }
response = invoke("GET", "/sms/" .. id)
check(response:find('"status":"sending"', 1, true), "sending status response")

worker_response = { id = id, status = "sent", messageReference = 23 }
response = invoke("GET", "/sms/" .. id)
check(response:find("Status: 200 OK", 1, true), "status HTTP response")
check(response:find('"messageReference":23', 1, true), "sent reference")

worker_response = { id = id, status = "failed", error = "modem-rejected" }
response = invoke("GET", "/sms/" .. id)
check(response:find("modem-rejected", 1, true), "failed response")

worker_response = { id = id, status = "unknown", error = "modem-response-timeout" }
response = invoke("GET", "/sms/" .. id)
check(response:find("modem-response-timeout", 1, true), "unknown response")

worker_response = { error = "sms-job-not-found" }
response = invoke("GET", "/sms/" .. id)
check(response:find("Status: 404 Not Found", 1, true), "missing job")

response = invoke("GET", "/sms/not-a-uuid")
check(response:find("sms-job-not-found", 1, true), "invalid job ID")

response = invoke("GET", "/sms", nil, nil, "192.0.2.1")
check(response:find("Status: 403 Forbidden", 1, true), "source allowlist")

response = invoke("GET", "/status", nil, nil, "192.168.2.1")
check(response:find("Status: 200 OK", 1, true), "device address allowlist")

response = invoke("GET", "/sms")
check(response:find("Status: 405 Method Not Allowed", 1, true), "SMS method restriction")
check(response:find("Allow: POST", 1, true), "SMS Allow header")

response = invoke("GET", "/status")
check(response:find("Status: 200 OK", 1, true), "existing status endpoint")

response = invoke("GET", "/cell")
check(response:find("Status: 503 Service Unavailable", 1, true), "existing cell endpoint")

response = invoke("GET", "/mac")
check(response:find("invalid-ip", 1, true), "existing MAC endpoint")

io.popen = original_popen
os.execute = original_execute

print("handler tests: " .. tests .. " passed")
