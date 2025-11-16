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
    functions = {}, -- Route handlers keyed as "<METHOD> <path>"
    clients = {}, -- Active connected clients being incrementally read
    bridge = { -- Mission bridge helpers to invoke ATC mission-side dispatch
        call_mission = nil,
    },
}

function http.log(msg)
    env.info("[SmartATC] " .. msg)
end

function http.send_json(client, status, payload)
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

function http.parse_request_line(line)
    local method, path, proto = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
    return method, path, proto
end

function http.split_path_and_query(url_path)
    local path, qs = url_path:match("^([^?]+)%??(.*)$")
    return path or "/", qs or ""
end

function http.parse_query(qs)
    local t = {}
    for pair in string.gmatch(qs, "([^&]+)") do
        local k, v = pair:match("([^=]+)=?(.*)")
        if k then
            v = v or ""
            v = v:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
            t[k] = v
        end
    end
    return t
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

function http.bridge.call_mission(method_name, args)
    args = args or {}

    local encoded_args, err = http.json_encode(args)
    if not encoded_args then
        return nil, "failed to encode args: " .. tostring(err)
    end

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
    ]==], method_name, encoded_args)

    local ok, result, err_msg = net.dostring_in("mission", mission_code)

    if not ok then
        http.log(string.format("mission dispatch failed for %s: %s", method_name, tostring(err_msg or result)))
        return nil, tostring(err_msg or result or "unknown error")
    end

    return result
end

function http.route_request(method, url_path, headers, body)
    local path, qs = http.split_path_and_query(url_path)
    local query = http.parse_query(qs)

    local handler = http.functions[method .. " " .. path]
    if not handler then
        return "404 Not Found", '{"ok":false,"error":"no such endpoint"}'
    end

    local ok, status, response_body = pcall(handler, {
        method = method,
        path = path,
        query = query,
        headers = headers,
        body = body or "",
    })

    if not ok then
        http.log("handler crash for " .. method .. " " .. path .. ": " .. tostring(status))
        return "500 Internal Server Error", string.format('{"ok":false,"error":"%s"}', tostring(status))
    end

    return status or "200 OK", response_body or "{}"
end

function http.poll_http()
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
            local method, url_path = http.parse_request_line(request_line or "")

            if not method then
                http.send_json(client_socket, "400 Bad Request", '{"ok":false,"error":"bad request line"}')
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
                    local status, response_body = http.route_request(method, url_path, headers, body)
                    http.send_json(client_socket, status, response_body)
                    client.closing = true
                elseif not cl then
                    local status, response_body = http.route_request(method, url_path, headers, remaining)
                    http.send_json(client_socket, status, response_body)
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

function http.init_http_server()
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
    http.init_http_server()
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

function http.validate_body_json(raw)
    local decoded, err = http.json_decode(raw or "{}")
    if not decoded then
        return nil, "invalid json: " .. tostring(err)
    end
    return decoded
end

function http.dispatch(method_name, args)
    local result, err = http.bridge.call_mission(method_name, args)
    if not result then
        return "500 Internal Server Error", string.format('{"ok":false,"error":"%s"}', tostring(err))
    end
    return "200 OK", result
end

http.functions["GET /atc/ping"] = function()
    return "200 OK", '{"ok":true}'
end

http.functions["GET /atc/traffic"] = function(req)
    return http.dispatch("listTraffic", req.query)
end

http.functions["GET /atc/airfields"] = function(req)
    return http.dispatch("listAirfields", req.query)
end

http.functions["GET /atc/runway-state"] = function(req)
    return http.dispatch("getRunwayState", req.query)
end

http.functions["POST /atc/landing-task"] = function(req)
    if req.method ~= "POST" then
        return "405 Method Not Allowed", '{"ok":false,"error":"method not allowed"}'
    end

    local body_tbl, err = http.validate_body_json(req.body)
    if not body_tbl then
        return "400 Bad Request", string.format('{"ok":false,"error":"%s"}', tostring(err))
    end

    return http.dispatch("pushLandingTask", body_tbl)
end

http.functions["POST /atc/route-task"] = function(req)
    if req.method ~= "POST" then
        return "405 Method Not Allowed", '{"ok":false,"error":"method not allowed"}'
    end

    local body_tbl, err = http.validate_body_json(req.body)
    if not body_tbl then
        return "400 Bad Request", string.format('{"ok":false,"error":"%s"}', tostring(err))
    end

    return http.dispatch("pushRouteTask", body_tbl)
end

Sim.setUserCallbacks(http.callbacks)
return http
