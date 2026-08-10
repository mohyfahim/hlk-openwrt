local io = require "io"
local json = require "luci.jsonc"

local MMCLI = "/usr/bin/mmcli"
local MODEM_ID = "0"

-- Only these hosts may use this API.
-- 127.0.0.1 / ::1 are useful for local diagnostics.
local ALLOWED_CLIENTS = {
    ["192.168.2.127"] = true,
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


local function send_json(status, body)
    uhttpd.send("Status: " .. status .. "\r\n")
    uhttpd.send("Content-Type: application/json\r\n")
    uhttpd.send("Cache-Control: no-store\r\n")
    uhttpd.send("X-Content-Type-Options: nosniff\r\n")
    uhttpd.send("\r\n")
    uhttpd.send(json.stringify(body))
    uhttpd.send("\n")
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

    local access = get_access_technology()
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
    -- GET only
    --------------------------------------------------------

    if env.REQUEST_METHOD ~= "GET" then
        send_json(
            "405 Method Not Allowed",
            {
                error = "method-not-allowed"
            }
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
