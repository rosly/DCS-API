--- Mission-side ATC API dispatcher.
--
-- This module is responsible for exposing a small JSON based API that the
-- Hooks HTTP server can invoke through `net.dostring_in`.  Requests arrive as
-- method names paired with JSON encoded argument tables.  The dispatcher will
-- decode the payload, locate the requested handler and return the JSON encoded
-- result (or an error description).
--
-- The functions registered under `ATC_API.methods` should each accept a single
-- table parameter where keys match HTTP query/body parameters.  They must also
-- return a table that can be serialised back to JSON.
--
-- Example handler structure:
-- ```lua
-- ATC_API.methods.listTraffic = function(params)
--     -- params = { atcUnit = "Magic-1", coalition = "BLUE" }
--     return ATC.listAirTraffic(params)
-- end
-- ```
--
-- The dispatcher mirrors the helpers that exist in the HTTP Hooks layer
-- (`http.json_encode` / `http.json_decode`) so both ends consistently report
-- JSON issues.
--
-- NOTE: This file purposefully avoids requiring a specific JSON library.  DCS
-- exposes `net.lua2json` / `net.json2lua` inside the mission environment so we
-- rely on those helpers when present.

ATC_API = ATC_API or {}
ATC_API.methods = ATC_API.methods or {}

local function json_encode(tbl)
    if net and net.lua2json then
        local ok, encoded = pcall(net.lua2json, tbl)
        if ok then
            return encoded
        end
        return nil, encoded
    end
    return nil, "json encoder unavailable"
end

local function json_decode(text)
    if not text or text == "" then
        return {}
    end
    if net and net.json2lua then
        local ok, decoded = pcall(net.json2lua, text)
        if ok then
            return decoded
        end
        return nil, decoded
    end
    return nil, "json decoder unavailable"
end

local function encode_response(payload)
    local encoded, err = json_encode(payload)
    if encoded then
        return encoded
    end
    -- As a last resort ensure we do not propagate nil back to the HTTP layer.
    local fallback = string.format('{"ok":false,"error":"%s","encodeError":"%s"}',
        tostring(payload and payload.error or "json encode failed"),
        tostring(err))
    return fallback
end

local function error_payload(message)
    return { ok = false, error = tostring(message or "unknown error") }
end

local function ensure_args_table(args)
    if args == nil then
        return {}
    end
    assert(type(args) == "table", "ATC_API arguments must decode to a table")
    return args
end

--- Dispatch an ATC API method call arriving from the HTTP server.
-- @tparam string methodName Name of the ATC_API method to execute.
-- @tparam string argsJson JSON encoded string of parameters (GET/PUT bodies).
-- @treturn string JSON encoded response body ready for HTTP consumption.
function ATC_API.dispatch(methodName, argsJson)
    if type(methodName) ~= "string" or methodName == "" then
        return encode_response(error_payload("method name required"))
    end

    local handler = ATC_API[methodName]
    if type(handler) ~= "function" then
        handler = ATC_API.methods[methodName]
    end
    if type(handler) ~= "function" then
        return encode_response(error_payload("unknown method: " .. methodName))
    end

    local args, decode_err = json_decode(argsJson)
    if not args then
        return encode_response(error_payload("invalid json: " .. tostring(decode_err)))
    end

    local ok, result = pcall(handler, ensure_args_table(args))
    if not ok then
        return encode_response(error_payload(result))
    end

    if result == nil then
        result = {}
    end
    if type(result) ~= "table" then
        return encode_response(error_payload("ATC_API methods must return a table"))
    end

    local encoded, err = json_encode(result)
    if encoded then
        return encoded
    end
    return encode_response(error_payload(err))
end

return ATC_API
