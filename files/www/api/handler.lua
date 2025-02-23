local io = require "io"


function get_mac_from_dhcp(ip)
    local dhcp_file = io.open("/tmp/dhcp.leases", "r")
    if not dhcp_file then return nil end
    
    for line in dhcp_file:lines() do
        local timestamp, mac, client_ip = line:match("(%d+) (%S+) (%S+)")
        if client_ip == ip then
            dhcp_file:close()
            return mac:upper()
        end
    end
    dhcp_file:close()
    return nil
end


function handle_request(env)
    	if env.REQUEST_METHOD == "GET" and env.PATH_INFO == "/mac" then
		uhttpd.send("Status: 200 OK\r\n")                              
        	uhttpd.send("Content-Type: application/json\r\n\r\n")
        local query = env.QUERY_STRING or ""                 
        local ip = query:match("ip=([^&]+)") or ""           
                                                             
        local mac = get_mac_from_dhcp(ip)                    
                                                  
        if mac ~= nil then                        
            local resp = string.format("{\"mac\":\"%s\"}", mac)
            uhttpd.send(resp)                                  
        else                                                   
           uhttpd.send("{\"mac\":null}")                       
        end                       
	else
		uhttpd.send("Status: 404 Not Found\r\n")
                uhttpd.send("Content-Type: application/json\r\n\r\n") 
		uhttpd.send("{\"message\":\"not found\"}")                       
	end
end
