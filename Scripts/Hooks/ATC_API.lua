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

local ATC_API = {
    methods = {},
}
local coalitionSideToName = {
    [coalition.side.BLUE] = "BLUE",
    [coalition.side.RED] = "RED",
    [coalition.side.NEUTRAL] = "NEUTRAL",
}

local mist_loaded, mist = pcall(function()
    -- Assuming mist.lua is in the same directory as ATC_API.lua.
    -- The path for dofile is relative to the Scripts/ folder in the .miz
    dofile("./Scripts/Hooks/mist.lua")
    return mist
end)

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

--- Dispatch an ATC API method call arriving from the HTTP server.
-- @tparam string methodName Name of the ATC_API method to execute.
-- @tparam string argsJson JSON encoded string of parameters (GET/PUT bodies).
-- @treturn string JSON encoded response body ready for HTTP consumption.
function ATC_API.dispatch(methodName, argsJson)

    if not mist_loaded then
        return encode_response(error_payload("mist.lua is missing or failed to load"))
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

    local args, decode_err = json_decode(argsJson)
    if not args then
        return encode_response(error_payload("invalid json: " .. tostring(decode_err)))
    end
    if args == nil or type(args) ~= "table" then
        return encode_response(error_payload("invalid json: ATC_API arguments must decode to a table"))
    end

    if type(methodName) ~= "string" or methodName == "" then
        return encode_response(error_payload("method name required"))
    end
    local handler = ATC_API.methods[methodName]
    if handler == nil or type(handler) ~= "function" then
        return encode_response(error_payload("unknown method: " .. methodName))
    end

    local ok, result = pcall(handler, args)
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

--- Compute the bearing in degrees between two 3D points.
-- @param fromPoint table: `{x,y,z}` origin coordinates (meters). Range: finite numbers.
-- @param toPoint table: `{x,y,z}` destination coordinates. Range: finite numbers.
-- @return number: Bearing in degrees [0, 360).
local function bearingDeg(fromPoint, toPoint)
    local bearing = mist.utils.getHeadingPoints(fromPoint, toPoint, true) or 0
    return mist.utils.toDegree(bearing)
end

--- Safely retrieve the callsign for a unit if available.
-- @param unit Unit|nil: Source unit. Range: any `Unit` or nil.
-- @return string|nil: Callsign text when accessible.
local function getCallsign(unit)
    if not unit or not unit.getCallsign then
        return nil
    end
    local ok, value = pcall(unit.getCallsign, unit)
    if ok then
        return value
    end
    return nil
end

--- Translate a unit category identifier into the enumerated name.
-- @param categoryId number|nil: Value from `Unit.Category`. Range: integer constant.
-- @return string: Category name or `"UNKNOWN"` when not matched.
local function unitCategoryName(categoryId)
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
local function detectionFlags(controller, unit)
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
local function buildContact(atcUnit, controller, unit)
    local position = unit:getPoint()
    local velocity = unit:getVelocity() or { x = 0, y = 0, z = 0 }
    local horizontalSpeed = math.sqrt((velocity.x or 0) ^ 2 + (velocity.z or 0) ^ 2)
    local groundSpeedKmh = mist.utils.mpsToKmph(horizontalSpeed)
    local headingRad = math.atan2(velocity.z or 0, velocity.x or 0)
    if headingRad < 0 then
        headingRad = headingRad + (2 * math.pi)
    end
    local headingDeg = mist.utils.toDegree(headingRad)
    local atcPoint = atcUnit:getPoint()
    local rangeKm = mist.utils.get3DDist(atcPoint, position) / 1000
    local bearing = bearingDeg(atcPoint, position)
    local group = unit:getGroup()
    local desc = unit:getDesc()
    return {
        trackId = unit:getName(),
        unitName = unit:getName(),
        groupName = group and group:getName() or nil,
        callsign = getCallsign(unit),
        coalition = coalitionSideToName[unit:getCoalition()] or "NEUTRAL",
        unitCategory = desc and unitCategoryName(desc.category) or "UNKNOWN",
        typeName = unit:getTypeName(),
        position = position,
        velocity = velocity,
        groundSpeedKmh = groundSpeedKmh,
        altitudeM = position.y,
        headingDeg = headingDeg,
        inAir = unit:inAir(),
        rangeKm = rangeKm,
        bearingDeg = bearing,
        detection = detectionFlags(controller, unit),
        lastSeenTimeSec = timer.getTime(),
    }
end

--- Validate that an ATC unit exists and is equipped with the needed sensors.
-- @param atcUnit Unit: Radar unit driving the ATC API. Range: existing `Unit` instance.
-- @return Unit, Controller: The validated unit and its controller.
local function assertRadarUnit(atcUnit)
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
    if not args.atcUnit then
        return { ok = false, error = "atcUnit is required" }
    end
    local atcUnit = Unit.getByName(args.atcUnit)
    if not atcUnit then
        return { ok = false, error = "ATC unit not found: " .. tostring(args.atcUnit) }
    end

    local _, controller = assertRadarUnit(atcUnit)
    local detected = controller:getDetectedTargets(
        Controller.Detection.RADAR,
        Controller.Detection.VISUAL,
        Controller.Detection.OPTIC
    ) or {}
    local contacts = {}
    for _, entry in pairs(detected) do
        local target = entry.object
        if target and target.inAir and target.getDesc then
            if target:inAir() then
                local desc = target:getDesc()
                if desc and (desc.category == Unit.Category.AIRPLANE or desc.category == Unit.Category.HELICOPTER) then
                        local contact = buildContact(atcUnit, controller, target)
                        table.insert(contacts, contact)
                    end
                end
            end
        end
    end
    return contacts
end

return ATC_API
