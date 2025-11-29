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

--- @module ATC_API

ATC_API = {
    methods = {},
}

ATC_API.coalitionSideToName = {
    [coalition.side.BLUE] = "BLUE",
    [coalition.side.RED] = "RED",
    [coalition.side.NEUTRAL] = "NEUTRAL",
}

--ATC_API.mist_loaded, ATC_API.mist = pcall(function()
--    -- Assuming mist.lua is in the same directory as ATC_API.lua.
--    -- The path for dofile is relative to the Scripts/ folder in the .miz
--    dofile("./Scripts/mist.lua")
--    return mist
--end)

ATC_API.mist_loaded = true
ATC_API.mist = mist    

function ATC_API.json_encode(tbl)
    if net and net.lua2json then
        local ok, encoded = pcall(net.lua2json, tbl)
        if ok then
            return encoded
        end
        return nil, encoded
    end
    return nil, "json encoder unavailable"
end

function ATC_API.json_decode(text)
    if (not text) or (text == "") then
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

--- Dispatch an ATC API method call arriving from the HTTP server.
-- @tparam string methodName Name of the ATC_API method to execute.
-- @tparam string argsJson JSON encoded string of parameters (GET/PUT bodies).
-- @treturn string JSON encoded response body ready for HTTP consumption.
function ATC_API.dispatch(methodName, argsJson)

    if (not ATC_API.mist_loaded) then
        return ATC_API.encode_response(ATC_API.error_payload("mist.lua is missing or failed to load"))
    end

    local function error_payload(message)
        return { ok = false, error = tostring(message or "unknown error") }
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

    local args, decode_err = ATC_API.json_decode(argsJson)
    if not args then
        return ATC_API.encode_response(error_payload("invalid json: " .. tostring(decode_err)))
    end
    if args == nil or type(args) ~= "table" then
        return ATC_API.encode_response(error_payload("invalid json: ATC_API arguments must decode to a table"))
    end

    if (type(methodName) ~= "string") or (methodName == "") then
        return ATC_API.encode_response(error_payload("method name required"))
    end
    local handler = ATC_API.methods[methodName]
    if (handler == nil) or (type(handler) ~= "function") then
        return ATC_API.encode_response(error_payload("unknown method: " .. methodName))
    end

    local ok, result = pcall(handler, args)
    if not ok then
        return ATC_API.encode_response(error_payload(result))
    end

    if result == nil then
        result = {}
    end
    if type(result) ~= "table" then
        return ATC_API.encode_response(error_payload("ATC_API methods must return a table"))
    end

    local encoded, err = ATC_API.json_encode(result)
    if encoded then
        return encoded
    end
    return ATC_API.encode_response(error_payload(err))
end

--- Compute the bearing in degrees between two 3D points.
-- @param fromPoint table: `{x,y,z}` origin coordinates (meters). Range: finite numbers.
-- @param toPoint table: `{x,y,z}` destination coordinates. Range: finite numbers.
-- @return number: Bearing in degrees [0, 360).
function ATC_API.bearingDeg(fromPoint, toPoint)
    local vec = ATC_API.mist.vec.sub(toPoint, fromPoint)
    local dir = ATC_API.mist.utils.getDir(vec, fromPoint)
    return ATC_API.mist.utils.toDegree(dir)
end

--- Translate a unit category identifier into the enumerated name.
-- @param categoryId number|nil: Value from `Unit.Category`. Range: integer constant.
-- @return string: Category name or `"UNKNOWN"` when not matched.
function ATC_API.unitCategoryName(categoryId)
    for name, value in pairs(Unit.Category) do
        if value == categoryId then
            return name
        end
    end
    return "UNKNOWN"
end

--- Inspect the controller and set detection flags for the target.
-- @param controller Controller|nil: Sensor owner. Range: valid controller or nil.
-- @param unit Unit|nil: Target unit being evaluated. Range: existing `Unit` or nil.
-- @return table: Table with `radar`, `visual`, `optic` booleans.
function ATC_API.detectionFlags(controller, unit)
    local radar = false
    local visual = false
    local optic = false
    if controller and unit then
        radar = controller:isTargetDetected(unit, Controller.Detection.RADAR)
        visual = controller:isTargetDetected(unit, Controller.Detection.VISUAL)
        optic = controller:isTargetDetected(unit, Controller.Detection.OPTIC)
    end
    return {
        radar = radar or false,
        visual = visual or false,
        optic = optic or false,
    }
end

--- Build a normalized contact payload for a detected unit.
-- @param atcUnit Unit: Radar unit whose point defines range/bearing.
-- @param controller Controller|nil: Controller for detection flags.
-- @param unit Unit: Target unit to represent.
-- @return table: Contact schema filled per Design.md requirements.
function ATC_API.buildContact(atcUnit, controller, unit)
    local atcPosition = atcUnit:getPoint()
    local position = unit:getPoint()
    local desc = unit:getDesc()
    return {
        trackId = unit:getID(),
        unitName = unit:getName(),
        callsign = unit:getCallsign(),
        groupName = unit:getGroup():getName(),
        coalition = ATC_API.coalitionSideToName[unit:getCoalition()] or "NEUTRAL",
        unitCategory = ATC_API.unitCategoryName(desc.category) or "UNKNOWN",
        typeName = unit:getTypeName(),
        position = position,
        velocity = unit:getVelocity(),
        altitudeM = position.y,
        headingDeg = ATC_API.mist.utils.toDegree(ATC_API.mist.getAttitude(unit).Heading),
        rangeKm = ATC_API.mist.utils.get2DDist(atcPosition, position) / 1000,
        bearingDeg = ATC_API.bearingDeg(atcPosition, position),
        detection = ATC_API.detectionFlags(controller, unit),
        RCS = desc.RCS,
        lastSeenTimeSec = timer.getTime(),
    }
end

--- Validate that an ATC unit exists and is equipped with the needed sensors.
-- @param atcUnit Unit: Radar unit driving the ATC API. Range: existing `Unit` instance.
-- @return Unit, Controller: The validated unit and its controller.
function ATC_API.assertRadarUnit(atcUnit)
    assert(atcUnit, "atcUnit is required")
    assert(atcUnit.isExist and atcUnit:isExist(), "atcUnit does not exist")
    local controller = atcUnit:getController()
    assert(controller, "atcUnit is missing controller")
    if atcUnit.hasSensors then
        local hasRadar = atcUnit:hasSensors(Unit.SensorType.RADAR)
        assert(hasRadar, "atcUnit must have radar sensors")
    end
    return atcUnit, controller
end

--- Enumerate airborne contacts detected by the ATC radar sensors.
-- @param args.atcUnit Unit: Radar-capable unit. Range: must exist and have sensors.
-- @return table: Array of contact tables for in-air aircraft/helicopters.
function ATC_API.methods.listAirTraffic(args)
    if (not args.atcUnit) then
        return { ok = false, error = "atcUnit is required" } 
    end
    local atcUnit = Unit.getByName(args.atcUnit)
    if (not atcUnit) then
        return { ok = false, error = "ATC unit not found: " .. tostring(args.atcUnit) }
    end

    local _, controller = ATC_API.assertRadarUnit(atcUnit)
    local detected = controller:getDetectedTargets(Controller.Detection.RADAR, Controller.Detection.VISUAL, Controller.Detection.OPTIC)
    local contacts = {}
    for _, entry in pairs(detected) do
        local target = entry.object
        if target:inAir() then
            local desc = target:getDesc()
            if desc and (desc.category == Unit.Category.AIRPLANE or desc.category == Unit.Category.HELICOPTER) then
                    local contact = ATC_API.buildContact(atcUnit, controller, target)
                    table.insert(contacts, contact)
            end
        end
    end
    return { contacts, atcUnit:getSensors() }
end
