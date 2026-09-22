local io = require "io"
local json = require "luci.jsonc"
local sms_api = require "sms_api"
local ubus = require "ubus"

local MMCLI = "/usr/bin/mmcli"
local MODEM_ID = "any"

-- Only these hosts may use this API.
-- 127.0.0.1 / ::1 are useful for local diagnostics.
local ALLOWED_CLIENTS = {
    ["192.168.2.127"] = true,
    ["192.168.2.100"] = true,
    ["127.0.0.1"] = true,
    ["::1"] = true
}


------------------------------------------------------------
-- Common helpers
------------------------------------------------------------

local function trim(value)
    if value == nil then
        return nil
    end

    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end


local function send_json(status, body, headers)
    uhttpd.send("Status: " .. status .. "\r\n")
    uhttpd.send("Content-Type: application/json\r\n")
    uhttpd.send("Cache-Control: no-store\r\n")
    uhttpd.send("X-Content-Type-Options: nosniff\r\n")

    if headers then
        local name, value
        for name, value in pairs(headers) do
            uhttpd.send(name .. ": " .. value .. "\r\n")
        end
    end

    uhttpd.send("\r\n")
    uhttpd.send(json.stringify(body))
    uhttpd.send("\n")
end


local function get_header(env, wanted)
    wanted = string.lower(wanted)

    if env.headers then
        local name, value
        for name, value in pairs(env.headers) do
            if string.lower(name) == wanted then
                return value
            end
        end
    end

    return nil
end


local function content_type_is_json(env)
    local value = env.CONTENT_TYPE or get_header(env, "content-type")

    if type(value) ~= "string" then
        return false
    end

    local media_type = value:match("^%s*([^;]+)")
    return media_type
        and string.lower(trim(media_type)) == "application/json"
end


local function read_json_body(env)
    if not content_type_is_json(env) then
        return nil
    end

    local length = tonumber(env.CONTENT_LENGTH or get_header(env, "content-length"))
    if not length or length < 1 or length > 4096 or length ~= math.floor(length) then
        return nil
    end

    local received, body = uhttpd.recv(length)
    if received ~= length
        or type(body) ~= "string"
        or #body ~= length
        or not sms_api.valid_utf8(body)
    then
        return nil
    end

    local ok, parsed = pcall(json.parse, body)
    if not ok or type(parsed) ~= "table" then
        return nil
    end

    return parsed
end


local function call_sms_worker(method, arguments)
    local connection = ubus.connect()
    if not connection then
        return nil
    end

    local ok, response = pcall(
        function()
            return connection:call("sms.api", method, arguments)
        end
    )

    connection:close()

    if not ok or type(response) ~= "table" then
        return nil
    end

    return response
end


local function command_output(command)
    local handle = io.popen(command .. " 2>/dev/null", "r")

    if not handle then
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    if not output or output == "" then
        return nil
    end

    return output
end


------------------------------------------------------------
-- Parse mmcli -K output
--
-- Example:
--
-- modem.location.3gpp.mcc : 432
-- modem.location.3gpp.mnc : 11
------------------------------------------------------------

local function parse_keyvalue(text)
    local values = {}

    if not text then
        return values
    end

    for line in text:gmatch("[^\r\n]+") do
        local key, value =
            line:match("^%s*(.-)%s*:%s*(.-)%s*$")

        if key and key ~= "" then
            values[key] = value
        end
    end

    return values
end


------------------------------------------------------------
-- HTTP query parsing
------------------------------------------------------------

local function get_query_parameter(query, wanted)
    query = query or ""

    for pair in query:gmatch("[^&]+") do
        local key, value =
            pair:match("^([^=]+)=?(.*)$")

        if key then
            key = uhttpd.urldecode(key)
            value = uhttpd.urldecode(value or "")

            if key == wanted then
                return value
            end
        end
    end

    return nil
end


local function valid_ipv4(ip)
    if not ip then
        return false
    end

    return ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end


------------------------------------------------------------
-- DHCP / MAC lookup
------------------------------------------------------------

local function get_mac_from_dhcp(ip)
    local dhcp_file = io.open("/tmp/dhcp.leases", "r")

    if not dhcp_file then
        return nil
    end

    for line in dhcp_file:lines() do
        local timestamp, mac, client_ip =
            line:match("^(%S+)%s+(%S+)%s+(%S+)")

        if client_ip == ip then
            dhcp_file:close()
            return mac:upper()
        end
    end

    dhcp_file:close()

    return nil
end


------------------------------------------------------------
-- Update process status
------------------------------------------------------------

local function get_update_pid()
    -- "[.]" style avoids accidentally matching the pgrep command.
    local handle =
        io.popen(
            "pgrep -f 'pdate[.]sh' 2>/dev/null | head -n 1",
            "r"
        )

    if not handle then
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    if not output then
        return nil
    end

    local pid = output:match("(%d+)")

    if pid then
        return tonumber(pid)
    end

    return nil
end


------------------------------------------------------------
-- Current modem access technology
------------------------------------------------------------
local function get_modem_status()
    local output =
        command_output(
            MMCLI .. " -K -m " .. MODEM_ID
        )

    if not output then
        return {
            accessTechnology = "unknown",
            signalQuality = nil,
            signalRecent = false
        }
    end

    local data = parse_keyvalue(output)

    --------------------------------------------------------
    -- Access technology
    --------------------------------------------------------

    local access =
        data["modem.generic.access-technologies"]

    if not access then
        access =
            data[
            "modem.generic.access-technologies.value[1]"
            ]
    end

    access = trim(access) or "unknown"


    --------------------------------------------------------
    -- Signal quality
    --------------------------------------------------------

    local signal_value =
        trim(
            data["modem.generic.signal-quality.value"]
        )

    local signal_recent =
        trim(
            data["modem.generic.signal-quality.recent"]
        )

    local signal_quality = tonumber(signal_value)

    --------------------------------------------------------
    -- Validate percentage
    --------------------------------------------------------

    if signal_quality then
        if signal_quality < 0 then
            signal_quality = 0
        elseif signal_quality > 100 then
            signal_quality = 100
        end
    end

    return {
        accessTechnology = access,
        signalQuality = signal_quality,
        signalRecent = (signal_recent == "yes")
    }
end

local function get_access_technology()
    local output =
        command_output(
            MMCLI .. " -K -m " .. MODEM_ID
        )

    if not output then
        return "unknown"
    end

    local data = parse_keyvalue(output)

    local access =
        data["modem.generic.access-technologies"]

    -- Some mmcli versions may represent list-style values
    -- with a numbered machine-output key.
    if not access then
        access =
            data[
            "modem.generic.access-technologies.value[1]"
            ]
    end

    return trim(access) or "unknown"
end


------------------------------------------------------------
-- Normalize RAT family
------------------------------------------------------------

local function classify_rat(access)
    local value = string.lower(access or "")

    if value:find("5g", 1, true) then
        return "5g"
    end

    if value:find("lte", 1, true) then
        return "lte"
    end

    if value:find("umts", 1, true)
        or value:find("hspa", 1, true)
        or value:find("hsdpa", 1, true)
        or value:find("hsupa", 1, true)
    then
        return "3g"
    end

    if value:find("gsm", 1, true)
        or value:find("gprs", 1, true)
        or value:find("edge", 1, true)
    then
        return "2g"
    end

    return "unknown"
end


------------------------------------------------------------
-- Get MCC/MNC/LAC/TAC/CID from ModemManager
------------------------------------------------------------

local function read_location()
    local command =
        MMCLI
        .. " -K -m "
        .. MODEM_ID
        .. " --location-get"

    local output = command_output(command)

    if not output then
        return nil
    end

    local data = parse_keyvalue(output)

    return {
        mcc =
            trim(
                data["modem.location.3gpp.mcc"]
            ),

        mnc =
            trim(
                data["modem.location.3gpp.mnc"]
            ),

        lac =
            trim(
                data["modem.location.3gpp.lac"]
            ),

        tac =
            trim(
                data["modem.location.3gpp.tac"]
            ),

        cellId =
            trim(
                data["modem.location.3gpp.cid"]
            )
    }
end


local function get_cell_location()
    local location = read_location()

    --------------------------------------------------------
    -- After a modem / ModemManager restart, 3GPP location
    -- may not yet be enabled. Enable it and retry once.
    --------------------------------------------------------

    if not location
        or not location.mcc
        or not location.cellId
    then
        os.execute(
            MMCLI
            .. " -m "
            .. MODEM_ID
            .. " --location-enable-3gpp"
            .. " >/dev/null 2>&1"
        )

        location = read_location()
    end

    if not location then
        return nil
    end

    local modem_status = get_modem_status()

    local access = modem_status.accessTechnology
    local rat = classify_rat(access)

    --------------------------------------------------------
    -- Keep MCC/MNC/TAC/LAC/Cell ID as strings.
    --
    -- This preserves:
    --     leading zeroes
    --     hexadecimal representation
    --     MCC/MNC formatting
    --------------------------------------------------------

    local result = {
        available = true,


        rat = rat,
        accessTechnology = access,

        signalQuality = modem_status.signalQuality,
        signalRecent = modem_status.signalRecent,

        mcc = location.mcc or "",
        mnc = location.mnc or "",

        lac = location.lac or "",
        tac = location.tac or "",

        cellId = location.cellId or ""
    }


    --------------------------------------------------------
    -- Indicate which area code is actually meaningful.
    --
    -- LTE/5G -> TAC
    -- GSM/UMTS/HSPA -> LAC
    --------------------------------------------------------

    if rat == "lte" or rat == "5g" then
        result.areaCodeType = "tac"
        result.areaCode = location.tac or ""
    elseif rat == "2g" or rat == "3g" then
        result.areaCodeType = "lac"
        result.areaCode = location.lac or ""
    else
        result.areaCodeType = "unknown"
        result.areaCode = ""
    end

    return result
end


------------------------------------------------------------
-- SMS API
------------------------------------------------------------

local function handle_sms_enqueue(env)
    if env.REQUEST_METHOD ~= "POST" then
        send_json(
            "405 Method Not Allowed",
            { error = "method-not-allowed" },
            { Allow = "POST" }
        )
        return
    end

    local input = read_json_body(env)
    if not input then
        send_json("400 Bad Request", { error = "invalid-json" })
        return
    end

    local request, validation_error = sms_api.validate_request(input)
    if not request then
        send_json("400 Bad Request", { error = validation_error })
        return
    end

    local response = call_sms_worker(
        "enqueue",
        {
            to = request.to,
            message = request.message
        }
    )

    if not response or response.error == "sms-queue-full" then
        send_json("503 Service Unavailable", { error = "sms-queue-full" })
        return
    end

    if response.error then
        send_json("400 Bad Request", { error = response.error })
        return
    end

    if not response.id or response.status ~= "queued" then
        send_json("503 Service Unavailable", { error = "sms-queue-full" })
        return
    end

    send_json(
        "202 Accepted",
        {
            id = response.id,
            status = "queued"
        }
    )
end


local function handle_sms_status(env, raw_id)
    if env.REQUEST_METHOD ~= "GET" then
        send_json(
            "405 Method Not Allowed",
            { error = "method-not-allowed" },
            { Allow = "GET" }
        )
        return
    end

    local id = sms_api.normalize_uuid(raw_id)
    if not id then
        send_json("404 Not Found", { error = "sms-job-not-found" })
        return
    end

    local response = call_sms_worker("status", { id = id })
    if not response or response.error == "sms-job-not-found" then
        send_json("404 Not Found", { error = "sms-job-not-found" })
        return
    end

    if response.id ~= id
        or (response.status ~= "queued"
            and response.status ~= "sending"
            and response.status ~= "sent"
            and response.status ~= "failed"
            and response.status ~= "unknown")
    then
        send_json("404 Not Found", { error = "sms-job-not-found" })
        return
    end

    local body = {
        id = response.id,
        status = response.status
    }

    if response.status == "sent" then
        body.messageReference = tonumber(response.messageReference) or 0
    elseif response.status == "failed" or response.status == "unknown" then
        body.error = response.error
    end

    send_json("200 OK", body)
end


------------------------------------------------------------
-- Main HTTP request handler
------------------------------------------------------------

function handle_request(env)
    --------------------------------------------------------
    -- Source IP allow-list
    --------------------------------------------------------

    local remote = env.REMOTE_ADDR or ""

    if not ALLOWED_CLIENTS[remote] then
        send_json(
            "403 Forbidden",
            {
                error = "forbidden"
            }
        )

        return
    end


    --------------------------------------------------------
    -- POST /api/sms
    --------------------------------------------------------

    if env.PATH_INFO == "/sms" then
        handle_sms_enqueue(env)
        return
    end


    --------------------------------------------------------
    -- GET /api/sms/{id}
    --------------------------------------------------------

    local sms_id = (env.PATH_INFO or ""):match("^/sms/([^/]+)$")
    if sms_id then
        handle_sms_status(env, sms_id)
        return
    end


    --------------------------------------------------------
    -- Existing endpoints are GET only
    --------------------------------------------------------

    if env.REQUEST_METHOD ~= "GET" then
        send_json(
            "405 Method Not Allowed",
            { error = "method-not-allowed" },
            { Allow = "GET" }
        )
        return
    end


    --------------------------------------------------------
    -- GET /api/mac?ip=192.168.2.x
    --------------------------------------------------------

    if env.PATH_INFO == "/mac" then
        local ip =
            get_query_parameter(
                env.QUERY_STRING,
                "ip"
            )

        if not valid_ipv4(ip) then
            send_json(
                "400 Bad Request",
                {
                    error = "invalid-ip"
                }
            )

            return
        end

        local mac = get_mac_from_dhcp(ip)

        if mac then
            send_json(
                "200 OK",
                {
                    mac = mac
                }
            )
        else
            send_json(
                "200 OK",
                {
                    found = false
                }
            )
        end

        return
    end


    --------------------------------------------------------
    -- GET /api/status
    --------------------------------------------------------

    if env.PATH_INFO == "/status" then
        local pid = get_update_pid()

        if pid then
            send_json(
                "200 OK",
                {
                    status = "running",
                    pid = pid
                }
            )
        else
            send_json(
                "200 OK",
                {
                    status = "stop"
                }
            )
        end

        return
    end


    --------------------------------------------------------
    -- GET /api/cell
    --------------------------------------------------------

    if env.PATH_INFO == "/cell" then
        local cell = get_cell_location()

        if not cell
            or cell.mcc == ""
            or cell.mnc == ""
            or cell.cellId == ""
        then
            send_json(
                "503 Service Unavailable",
                {
                    available = false,
                    error = "cell-location-unavailable"
                }
            )

            return
        end

        send_json(
            "200 OK",
            cell
        )

        return
    end


    --------------------------------------------------------
    -- Unknown endpoint
    --------------------------------------------------------

    send_json(
        "404 Not Found",
        {
            error = "not-found"
        }
    )
end
