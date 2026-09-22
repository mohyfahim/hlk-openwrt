local tests = 0
local timers = {}
local processes = {}
local objects
local last_reply
local original_time = os.time
local now = 1000

os.time = function() return now end

local function check(condition, message)
    tests = tests + 1
    if not condition then
        error(message or ("assertion " .. tests .. " failed"), 2)
    end
end

local function write_file(path, contents)
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(contents))
    handle:close()
end

local uloop_mock = {}
function uloop_mock.init() end
function uloop_mock.run() end
function uloop_mock.timer(callback)
    local timer = {
        callback = callback,
        set = function(self, delay) self.delay = delay end
    }
    timers[#timers + 1] = timer
    return timer
end
function uloop_mock.process(path, arguments, environment, callback)
    local process = {
        path = path,
        arguments = arguments,
        environment = environment,
        callback = callback
    }
    processes[#processes + 1] = process
    return process
end

local connection = {
    add = function(_, value) objects = value end,
    reply = function(_, _, value) last_reply = value end,
    close = function() end
}

package.loaded["uloop"] = uloop_mock
package.loaded["ubus"] = {
    STRING = 3,
    connect = function() return connection end
}

SMS_API_TEST_OPTIONS = {
    helper = "/test/sms-api-send",
    runtime_dir = assert(os.getenv("SMS_API_TEST_TMP")),
    runtime_ready = true
}
arg = {
    "--queue-limit", "2",
    "--terminal-limit", "1",
    "--terminal-ttl", "86400",
    "--retry-interval", "5"
}

assert(loadfile("packages/dotin/mm-utils/files/usr/sbin/sms-api-worker"))()
check(objects and objects["sms.api"], "worker registered ubus object")
check(#timers == 3, "worker timers")

local enqueue = objects["sms.api"].enqueue[1]
local status = objects["sms.api"].status[1]

local function call(method, message)
    last_reply = nil
    method({}, message)
    return last_reply
end

local first = call(enqueue, { to = "+989121234567", message = "one" })
local second = call(enqueue, { to = "+989121234568", message = "two" })
local full = call(enqueue, { to = "+989121234569", message = "three" })
check(first.status == "queued", "first enqueue")
check(second.status == "queued", "second enqueue")
check(full.error == "sms-queue-full", "active queue limit")

timers[1].callback()
check(#processes == 1, "first worker process")
check(call(status, { id = first.id }).status == "sending", "sending status")
check(call(status, { id = second.id }).status == "queued", "FIFO queued status")

local first_result = SMS_API_TEST_OPTIONS.runtime_dir .. "/" .. first.id .. ".result"
write_file(first_result, "state=retry\n")
processes[1].callback()
check(call(status, { id = first.id }).status == "queued", "retry returns to queue")
check(#processes == 1, "retry does not overtake FIFO")

timers[1].callback()
check(#processes == 2, "retried first process")
write_file(
    SMS_API_TEST_OPTIONS.runtime_dir .. "/" .. first.id .. ".submitted",
    "/org/freedesktop/ModemManager1/SMS/7\n"
)
write_file(
    first_result,
    "state=unknown\nerror=modem-response-timeout\n"
    .. "smsPath=/org/freedesktop/ModemManager1/SMS/7\n"
)
processes[2].callback()
local first_terminal = call(status, { id = first.id })
check(first_terminal.status == "unknown", "unknown terminal state")
check(first_terminal.error == "modem-response-timeout", "unknown error")

timers[1].callback()
check(#processes == 3, "second job starts after first terminal")
local second_result = SMS_API_TEST_OPTIONS.runtime_dir .. "/" .. second.id .. ".result"
write_file(second_result, "state=sent\n")
processes[3].callback()
local second_terminal = call(status, { id = second.id })
check(second_terminal.status == "sent", "sent terminal state")
check(second_terminal.messageReference == 0, "missing reference defaults to zero")
check(call(status, { id = first.id }).error == "sms-job-not-found", "terminal history eviction")

now = now + 86401
timers[2].callback()
check(call(status, { id = second.id }).error == "sms-job-not-found", "terminal TTL expiry")

local queued_before_restart = call(enqueue, { to = "+989121234570", message = "restart" })
check(queued_before_restart.status == "queued", "queued job before restart")

-- Loading a new worker simulates a service restart: no old in-memory IDs exist.
timers = {}
processes = {}
objects = nil
assert(loadfile("packages/dotin/mm-utils/files/usr/sbin/sms-api-worker"))()
status = objects["sms.api"].status[1]
check(
    call(status, { id = queued_before_restart.id }).error == "sms-job-not-found",
    "restart clears jobs"
)

os.time = original_time

print("worker tests: " .. tests .. " passed")
