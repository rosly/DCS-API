-- SmartATC HTTP server state and configuration
local http = {
    socket = require("socket"), -- LuaSocket dependency used for the TCP listener
    callbacks = { -- DCS simulation callbacks registered via Sim.setUserCallbacks
        onSimulationStart = nil,
        onSimulationStop = nil,
        onSimulationFrame = nil,
    },
    config = { -- Listener binding details
        host = "127.0.0.1",
        port = 5011,
    },
    server = nil, -- Active LuaSocket server instance
    http_mission_handlers = { -- Route handlers keyed by method, then path
        GET = {
            ["/atc/traffic"] = "listTraffic",
            ["/atc/airfields"] = "listAirfields",
            ["/atc/runway-state"] = "getRunwayState",
        },
        POST = {
            ["/atc/landing-task"] = "pushLandingTask",
            ["/atc/route-task"] = "pushRouteTask",
        },
        PUT = {}, -- Not used yet
        DELETE = {}, -- Not used yet
    },
    clients = {}, -- Active connected clients being incrementally read
}

function http.log(msg)
    env.info("[SmartATC] " .. msg)
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

    local mission_code = string.format([==[
        return a_do_script([=[
            if not ATC_API or not ATC_API.dispatch then
                return [[{"error":"ATC_API not loaded"}]]
            end
            local status, result = pcall(ATC_API.dispatch, %q, %q)
            if not status then
                return string.format([[{"error":"%s"}]], tostring(result))
            end
            return result
        ]=])
    ]==], method_name, args or "{}") -- args are expected to be a JSON encoded string

    local ok, result, err_msg = net.dostring_in("mission", mission_code)

    if not ok then
        http.log(string.format("mission dispatch failed for %s: %s", method_name, tostring(err_msg or result)))
        return nil, tostring(err_msg or result or "unknown error")
    end

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
    if not http_handlers then
        return "405 Method Not Allowed", '{"ok":false,"error":"method not allowed"}'
    end

    local mission_api_handler = http_handlers[path]
    if not mission_api_handler then
        return "404 Not Found", '{"ok":false,"error":"no such endpoint"}'
    end

    if method == "GET" then
        local encoded_args, json_err = http.json_encode(query_params)
        if not encoded_args then
            http.log("json_encode failed for " .. mission_api_handler .. ": " .. tostring(json_err))
            return "500 Internal Server Error", string.format('{"ok":false,"error":"failed to encode arguments: %s"}', tostring(json_err))
        end
    else
        local req_body = body or ""
        local body_tbl, json_err = http.json_decode(req_body)
        if not body_tbl then
            return "400 Bad Request", string.format('{"ok":false,"error":"%s"}', "invalid json: " .. tostring(json_err))
        end
        encoded_args = req_body
    end

    local result, err = http.call_mission(mission_api_handler, encoded_args)
    if not result then
        return "499 Internal Server Error", string.format('{"ok":false,"error":"%s"}', tostring(err))
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
        if not client_socket then
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

            if not method then
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
                elseif not cl then
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
    http.server = assert(http.socket.bind(http.config.host, http.config.port))
    http.server:settimeout(0)
    http.log(string.format("HTTP server listening on %s:%d", http.config.host, http.config.port))
end

function http.stop()
    if http.server then
        http.server:close()
        http.server = nil
    end
end

http.callbacks.onSimulationStart = function()
    http.log("Simulation started")
    http.init()
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
