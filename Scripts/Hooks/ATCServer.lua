-- SmartATC HTTP server state and configuration
http = {
    socket = require("socket"),
    callbacks = {},
    config = {
        host = "127.0.0.1",
        port = 5014,
    },
    server = nil,
-- Route handlers keyed by method, then path
    http_mission_handlers = {
        GET = {
            ["/atc/traffic"] = "listTraffic",
--            ["/atc/airfields"] = "listAirfields",
--            ["/atc/runway-state"] = "getRunwayState",
        },
        POST = {
--            ["/atc/landing-task"] = "pushLandingTask",
--            ["/atc/route-task"] = "pushRouteTask",
        },
        PUT = {}, -- Not used yet
        DELETE = {}, -- Not used yet
    },
    clients = {}, -- Active connected clients being incrementally read
}

function http.log(msg)
    if net and net.log then
        net.log("[SmartATC] " .. msg)
--    elseif env and env.info then
--        env.info("[SmartATC] " .. msg)
    else
        print("[SmartATC] " .. msg)
    end
end

function http.json_decode(text)
    if net and net.json2lua then
        return net.json2lua(text)
    end
    return nil, "json decoder unavailable"
end

function http.json_encode(tbl)
    if net and net.lua2json then
        return net.lua2json(tbl)
    end
    return nil, "json encoder unavailable"
end

-- Helper function to serialize a Lua table into a readable string for logging.
function http.serialize_table(val, level)
    level = level or 3 -- Default max depth
    if type(val) == "string" then
        return '"' .. val .. '"'
    end
    if type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    end
    if type(val) == "table" then
        if level <= 0 then
            return "{...}"
        end
        local parts = {}
        for k, v in pairs(val) do
            local key_str = '["' .. tostring(k) .. '"]'
            local val_str = http.serialize_table(v, level - 1)
            table.insert(parts, string.format("%s=%s", key_str, val_str))
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    -- For other types like functions, userdata, etc.
    return '"' .. tostring(val) .. '"'
end


function http.send_response(client, status, payload)
    local body = payload or "{}"
    local headers = {
        "HTTP/1.1 " .. status,
        "Content-Type: application/json",
        "Content-Length: " .. tostring(#body),
        "Connection: close",
        "",
        "",
    }
    client:send(table.concat(headers, "\r\n") .. body)
end

function http.call_mission(method_name, args)
    -- args are expected to be a JSON encoded string
    if type(args) ~= "string" then
        http.log("Error: args to call_mission must be a string, got " .. type(args))
        return nil, "Internal error: arguments must be a JSON string."
    end
    local mission_code = string.format([==[
        return a_do_script([=[
            if (not ATC_API) or (not ATC_API.dispatch) then
                return [[{"error":"ATC_API not loaded"}]]
            end
            local status, result = pcall(ATC_API.dispatch, %q, %q)
            if not status then
                return string.format([[{"error":"%%s"}]], tostring(result))
            end 
            return result
        ]=])
    ]==], method_name, args)

    http.log("Calling mission:" .. method_name .. ": " .. args)
    local result, success = net.dostring_in("mission", mission_code)
    if (not success) then
        err_str = string.format("mission dispatch failed for %s: %s, %s", method_name, tostring(result), tostring(success))
        http.log(err_str)
        return err_str
    end
    http.log(string.format("mission dispatch success for %s: %s, %s", method_name, tostring(result), tostring(success)))

    return result
end

function http.handle_http_request(method, url_path, headers, body)

    function parse_path_and_query(url_path)
        -- Split URL into path and query string
        local path, qs = url_path:match("^([^?]+)%??(.*)$") -- split url /some/page?param1=value1 into path and query, [^?] everything beyond question mark, %?? is '?' which is optional, (.*) is everything else
        path = path or "/"
        qs = qs or ""

        -- Parse the query string
        local query_params = {}
        for pair in string.gmatch(qs, "([^&]+)") do -- split qs into groups, splliter is [^&] everything beside appersand
            local k, v = pair:match("([^=]+)=?(.*)") -- split into param and value between &
            if k then
                v = v or ""
                v = v:gsub("%%(%x%x)", function(h) -- convertion from hex representation, call function for each match of %%(%x%x) meaning % and two hex
                    return string.char(tonumber(h, 16))
                end)
                query_params[k] = v
            end
        end
        return path, query_params
    end

    local path, query_params = parse_path_and_query(url_path)
    local http_handlers = http.http_mission_handlers[method]
    if (not http_handlers) then
        return "405 Method Not Allowed", '{"ok":false,"error":"method not allowed"}'
    end

    local mission_api_handler = http_handlers[path]
    if (not mission_api_handler) then
        return "404 Not Found", '{"ok":false,"error":"no such endpoint"}'
    end

    local encoded_args = ""
    if method == "GET" then
        http.log(method .. " encoding query_params: " .. http.serialize_table(query_params, 3) .. " url_path: " .. url_path)
        local getargs_json, json_err = http.json_encode(query_params)
        if (not getargs_json) then
            http.log("json_encode failed for " .. mission_api_handler .. ": " .. tostring(json_err))
            return "500 Internal Server Error", string.format('{"ok":false,"error":"failed to encode arguments: %s"}', tostring(json_err))
        end
        encoded_args = getargs_json
    else
        -- verify that body is JSON encoded
        http.log(method .. " verifing/decoding JSON req_body:" .. tostring(body))
        local body_tbl, json_err = http.json_decode(body)
        if (not body_tbl) then
            return "400 Bad Request", string.format('{"ok":false,"error":"%s"}', "invalid json: " .. tostring(json_err))
        end
        encoded_args = body
    end

    local result, err = http.call_mission(mission_api_handler, encoded_args)
    if (not result) then
        http.log("Mission call error:" ..  tostring(result) .. ": " .. tostring(err))
        return "499 Internal Server Error", string.format('{"ok":false,"error":"%s"}', tostring(err))
    end
    http.log("Mission call result:" .. tostring(result))
    -- result should be JSON string, if it is not try use fallback
    if type(result) ~= "string" then
        local encoded_result, json_err = http.json_encode(result)
        if (not encoded_result) then
            http.log("Mission result JSON transcoding error: " .. tostring(json_err))
            return "500 Internal Server Error", string.format('{"ok":false,"error":"failed to encode result: %s"}', tostring(json_err))
        end
        result = encoded_result
        http.log("Mission result JSON transcoding result: " .. tostring(result))
    end

    return "200 OK", result
end

function http.poll_http()

    function parse_request_line(line)
        local method, path, proto = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
        return method, path, proto
    end

    while true do
        local client_socket = http.server:accept()
        if (not client_socket) then
            break
        end

        client_socket:settimeout(0)
        table.insert(http.clients, { socket = client_socket, buffer = "", closing = false })
    end

    for _, client in ipairs(http.clients) do
        local client_socket = client.socket
        local chunk, err, partial = client_socket:receive("*a")

        if chunk and #chunk > 0 then
            client.buffer = client.buffer .. chunk
        elseif partial and #partial > 0 then
            client.buffer = client.buffer .. partial
        end

        if err == "closed" then
            client.closing = true
        end

        local headers_end = client.buffer:find("\r\n\r\n", 1, true)
        if headers_end then
            local raw_head = client.buffer:sub(1, headers_end - 1)
            local remaining = client.buffer:sub(headers_end + 4)

            local lines = {}
            for line in string.gmatch(raw_head, "([^\r\n]+)") do
                table.insert(lines, line)
            end

            local request_line = table.remove(lines, 1)
            local method, url_path = parse_request_line(request_line or "")

            if (not method) then
                http.send_response(client_socket, "400 Bad Request", '{"ok":false,"error":"bad request line"}')
                client.closing = true
            else
                local headers = {}
                for _, hline in ipairs(lines) do
                    local k, v = hline:match("^([^:]+):%s*(.*)$")
                    if k then
                        headers[string.lower(k)] = v
                    end
                end

                local cl_header = headers["content-length"]
                local cl = cl_header and tonumber(cl_header, 10)

                if cl and #remaining >= cl then
                    local body = cl > 0 and remaining:sub(1, cl) or ""
                    local status, response_body = http.handle_http_request(method, url_path, headers, body)
                    http.send_response(client_socket, status, response_body)
                    client.closing = true
                elseif (not cl) then
                    local status, response_body = http.handle_http_request(method, url_path, headers, remaining)
                    http.send_response(client_socket, status, response_body)
                    client.closing = true
                else
                    -- Not enough body data yet; keep waiting and restore buffer
                    client.buffer = raw_head .. "\r\n\r\n" .. remaining
                end
            end
        end
    end

    -- Close processed or disconnected clients (reverse order to keep indices stable)
    for i = #http.clients, 1, -1 do
        local client = http.clients[i]
        if client.closing then
            table.remove(http.clients, i)
            if client.socket then
                client.socket:close()
            end
        end
    end
end

function http.init()
    local server, err = http.socket.bind(http.config.host, http.config.port)
    if (not server) then
        http.log(string.format("Error initializing HTTP server on %s:%d: %s", http.config.host, http.config.port, tostring(err)))
        return false, err
    end

    http.server = server
    http.server:settimeout(0)
    http.log(string.format("HTTP server listening on %s:%d", http.config.host, http.config.port))
    return true
end

function http.stop()
    for i = #http.clients, 1, -1 do
        local client = http.clients[i]
        table.remove(http.clients, i)
        if client.socket then
            client.socket:close()
        end
    end

    if http.server then
        http.server:close()
        http.server = nil
    end
end

--- Injects the ATC_API.lua script into the mission scripting environment.
-- This is called from the onSimulationStart hook to make the API available
-- to the mission without requiring manual setup by the mission author.
function http.injectApiIntoMission(file)
    -- lfs is available in the server hook environment
    local lfs = require("lfs")
    local path = lfs.writedir() .. file

    -- Check if the file exists before trying to inject it.
    if not (lfs.attributes(path, "mode") == "file") then
        http.log(path .. " script not found")
        return false
    end

    -- Read the file content to be injected.
    local file, err = io.open(path, "r")
    if not file then
        http.log("Failed to open " .. path .. ": " .. tostring(err))
        return false
    end
    local mission_code = file:read("*a")
    file:close()

    -- Execute the script content within the mission environment.
    local result, success = net.dostring_in("mission", mission_code)
    if (not success) then
        http.log("Error injecting " .. path .. " script into mission: " .. tostring(result))
        return false
    end

    http.log(path .. " script injection sucessfull")
    return true
end

http.callbacks.onSimulationStart = function()
    http.log("Simulation started")

    if (not http.injectApiIntoMission('Scripts\\mist.lua')) then
         http.log("mist.lua injection failed")
         return
    end
    if (not http.injectApiIntoMission('Scripts\\ATC_API.lua')) then
         http.log("ATC_API.lua injection failed")
         return
    end

    local ok, err = http.init()
    if (not ok) then
        http.log("HTTP server failed to start: " .. tostring(err))
    end

    http.log("HTTP Server initialized sucessfully")
end

http.callbacks.onSimulationStop = function()
    http.log("Simulation stopped")
    http.stop()
end

http.callbacks.onSimulationFrame = function()
    if http.server then
        http.poll_http()
    end
end

Sim.setUserCallbacks(http.callbacks)
return http
