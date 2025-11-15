--- @module ATC

local ATC = {}

local mist = mist

local WAYPOINT_TYPE_TO_DCS = {
    TAKEOFF = 'TakeOff',
    TAKEOFF_PARKING = 'TakeOffParking',
    TAKEOFF_PARKING_HOT = 'TakeOffParkingHot',
    TURNING_POINT = 'Turning Point',
    LAND = 'Land',
}

local DCS_TYPE_TO_API = {}
for apiName, dcsName in pairs(WAYPOINT_TYPE_TO_DCS) do
    DCS_TYPE_TO_API[dcsName] = apiName
end

local TURN_METHOD_TO_DCS = {
    FLY_OVER_POINT = 'Fly Over Point',
    FIN_POINT = 'Fin Point',
}

local DCS_TURN_TO_API = {}
for apiName, dcsName in pairs(TURN_METHOD_TO_DCS) do
    DCS_TURN_TO_API[dcsName] = apiName
end

--- Resolve the airbase name that corresponds to a numeric identifier.
-- @param id number|nil: Identifier returned by DCS (`Airbase:getID()`). Range: positive integer or nil.
-- @return string|nil: Airbase name if found; otherwise `nil`.
local function _airbaseNameFromId(id)
    if not id then
        return nil
    end
    local airbases = world.getAirbases and world.getAirbases() or {}
    for _, ab in pairs(airbases) do
        if ab:getID() == id then
            return ab:getName()
        end
    end
    return nil
end

local coalitionSideToName = {
    [coalition.side.BLUE] = "BLUE",
    [coalition.side.RED] = "RED",
    [coalition.side.NEUTRAL] = "NEUTRAL",
}

--- Translate a unit category identifier into the enumerated name.
-- @param categoryId number|nil: Value from `Unit.Category`. Range: integer constant.
-- @return string: Category name or `"UNKNOWN"` when not matched.
local function _unitCategoryName(categoryId)
    for name, value in pairs(Unit.Category) do
        if value == categoryId then
            return name
        end
    end
    return "UNKNOWN"
end

--- Validate that an ATC unit exists and is equipped with the needed sensors.
-- @param atcUnit Unit: Radar unit driving the ATC API. Range: existing `Unit` instance.
-- @return Unit, Controller: The validated unit and its controller.
local function _assertRadarUnit(atcUnit)
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

--- Determine if the target coalition passes the provided filter option.
-- @param atcCoalition number: Coalition of the ATC unit (`coalition.side.*`). Range: enumeration value.
-- @param unitCoalition number: Coalition of the candidate contact. Range: enumeration value.
-- @param filter string|nil: One of `"ALL"`, `"FRIENDLY"`, `"HOSTILE"`, `"NEUTRAL"`, or nil.
-- @return boolean: `true` when the contact should be kept.
local function _coalitionFilterPasses(atcCoalition, unitCoalition, filter)
    if not filter or filter == "ALL" then
        return true
    end
    if filter == "FRIENDLY" then
        return atcCoalition == unitCoalition
    elseif filter == "HOSTILE" then
        return unitCoalition ~= coalition.side.NEUTRAL and unitCoalition ~= atcCoalition
    elseif filter == "NEUTRAL" then
        return unitCoalition == coalition.side.NEUTRAL
    end
    return true
end

--- Safely retrieve the callsign for a unit if available.
-- @param unit Unit|nil: Source unit. Range: any `Unit` or nil.
-- @return string|nil: Callsign text when accessible.
local function _getCallsign(unit)
    if not unit or not unit.getCallsign then
        return nil
    end
    local ok, value = pcall(unit.getCallsign, unit)
    if ok then
        return value
    end
    return nil
end

--- Inspect the controller and set detection flags for the target.
-- @param controller Controller|nil: Sensor owner. Range: valid controller or nil.
-- @param unit Unit|nil: Target unit being evaluated. Range: existing `Unit` or nil.
-- @return table: Table with `radar`, `visual`, `optic` booleans.
local function _detectionFlags(controller, unit)
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

--- Compute the bearing in degrees between two 3D points.
-- @param fromPoint table: `{x,y,z}` origin coordinates (meters). Range: finite numbers.
-- @param toPoint table: `{x,y,z}` destination coordinates. Range: finite numbers.
-- @return number: Bearing in degrees [0, 360).
local function _bearingDeg(fromPoint, toPoint)
    local bearing = mist.utils.getHeadingPoints(fromPoint, toPoint, true) or 0
    return mist.utils.toDegree(bearing)
end

--- Build a normalized contact payload for a detected unit.
-- @param atcUnit Unit: Radar unit whose point defines range/bearing.
-- @param controller Controller|nil: Controller for detection flags.
-- @param unit Unit: Target unit to represent.
-- @return table: Contact schema filled per Design.md requirements.
local function _buildContact(atcUnit, controller, unit)
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
    local bearingDeg = _bearingDeg(atcPoint, position)
    local group = unit:getGroup()
    local desc = unit:getDesc()
    return {
        trackId = unit:getName(),
        unitName = unit:getName(),
        groupName = group and group:getName() or nil,
        callsign = _getCallsign(unit),
        coalition = coalitionSideToName[unit:getCoalition()] or "NEUTRAL",
        unitCategory = desc and _unitCategoryName(desc.category) or "UNKNOWN",
        typeName = unit:getTypeName(),
        position = position,
        velocity = velocity,
        groundSpeedKmh = groundSpeedKmh,
        altitudeM = position.y,
        headingDeg = headingDeg,
        inAir = unit:inAir(),
        rangeKm = rangeKm,
        bearingDeg = bearingDeg,
        detection = _detectionFlags(controller, unit),
        lastSeenTimeSec = timer.getTime(),
    }
end

--- Enumerate airborne contacts detected by the ATC radar sensors.
-- @param atcUnit Unit: Radar-capable unit. Range: must exist and have sensors.
-- @param opts table|nil: Filters (`coalition`, `maxRangeKm`). Range: optional table.
-- @return table: Array of contact tables for in-air aircraft/helicopters.
function ATC.listAirTraffic(atcUnit, opts)
    opts = opts or {}
    if opts.coalition and type(opts.coalition) == 'string' then
        opts.coalition = string.upper(opts.coalition)
    end
    local _, controller = _assertRadarUnit(atcUnit)
    local detected = controller:getDetectedTargets(
        Controller.Detection.RADAR,
        Controller.Detection.VISUAL,
        Controller.Detection.OPTIC
    ) or {}
    local contacts = {}
    local atcCoalition = atcUnit:getCoalition()
    for _, entry in pairs(detected) do
        local target = entry.object
        if target and target.inAir and target.getDesc then
            if target:inAir() then
                local desc = target:getDesc()
                if desc and (desc.category == Unit.Category.AIRPLANE or desc.category == Unit.Category.HELICOPTER) then
                    if _coalitionFilterPasses(atcCoalition, target:getCoalition(), opts.coalition) then
                        local contact = _buildContact(atcUnit, controller, target)
                        if not opts.maxRangeKm or contact.rangeKm <= opts.maxRangeKm then
                            table.insert(contacts, contact)
                        end
                    end
                end
            end
        end
    end
    return contacts
end

--- Search nearby aircraft/helicopters on the ground around the ATC unit.
-- @param atcUnit Unit: Reference radar unit.
-- @param opts table: Requires `maxRangeKm` (>0) and optional `coalition`.
-- @return table: Array of contact tables with detection flags cleared.
function ATC.listGroundTraffic(atcUnit, opts)
    opts = opts or {}
    if opts.coalition and type(opts.coalition) == 'string' then
        opts.coalition = string.upper(opts.coalition)
    end
    assert(opts.maxRangeKm and opts.maxRangeKm > 0, "opts.maxRangeKm must be provided for ground traffic")
    local _ = _assertRadarUnit(atcUnit)
    local atcCoalition = atcUnit:getCoalition()
    local center = atcUnit:getPoint()
    local radiusM = opts.maxRangeKm * 1000
    local contacts = {}
    local function handler(obj)
        local unit = obj
        if unit and unit.getDesc then
            local desc = unit:getDesc()
            if desc and (desc.category == Unit.Category.AIRPLANE or desc.category == Unit.Category.HELICOPTER) then
                if not unit:inAir() then
                    if _coalitionFilterPasses(atcCoalition, unit:getCoalition(), opts.coalition) then
                        local contact = _buildContact(atcUnit, nil, unit)
                        contact.detection = { radar = false, visual = false, optic = false }
                        table.insert(contacts, contact)
                    end
                end
            end
        end
        return true
    end
    world.searchObjects(
        Object.Category.UNIT,
        {
            id = world.VolumeType.SPHERE,
            params = { point = center, radius = radiusM },
        },
        handler,
        nil
    )
    return contacts
end

--- Determine line-of-sight and range between the ATC unit and a target unit.
-- @param atcUnit Unit: Source radar unit.
-- @param targetUnit Unit: Destination unit with a valid position.
-- @return table: `{ hasLOS = boolean, rangeKm = number }`.
function ATC.checkLineOfSight(atcUnit, targetUnit)
    _assertRadarUnit(atcUnit)
    assert(targetUnit and targetUnit.isExist and targetUnit:isExist(), "targetUnit must exist")
    local p1 = atcUnit:getPoint()
    local p2 = targetUnit:getPoint()
    local hasLOS = land.isVisible(p1, p2)
    local rangeKm = mist.utils.get3DDist(p1, p2) / 1000
    return {
        hasLOS = hasLOS,
        rangeKm = rangeKm,
    }
end

--- Fetch and validate a controllable group owned by the ATC coalition.
-- @param atcUnit Unit: Radar unit defining coalition requirements.
-- @param groupName string: Exact group name to control. Range: non-empty string.
-- @return Group: Existing group owned by the same coalition.
local function _resolveGroupForControl(atcUnit, groupName)
    assert(groupName and groupName ~= "", "groupName is required")
    local group = Group.getByName(groupName)
    assert(group and group:isExist(), "group not found")
    assert(group:getCoalition() == atcUnit:getCoalition(), "group coalition mismatch")
    return group
end

--- Populate the mission point with the correct airbase/helipad identifiers.
-- @param point table: Route point table being built for DCS.
-- @param waypoint table: API waypoint containing `airbaseName`.
-- @return nil
local function _applyAirbaseIdentifier(point, waypoint)
    if not waypoint.airbaseName then
        return
    end
    local ab = Airbase.getByName(waypoint.airbaseName)
    assert(ab, string.format("Unknown airbase %s", waypoint.airbaseName))
    local abDesc = ab:getDesc()
    if abDesc and abDesc.category == Airbase.Category.HELIPAD then
        point.helipadId = ab:getID()
    else
        point.airdromeId = ab:getID()
    end
end

--- Replace or push a flight plan for a controllable group using API waypoints.
-- @param atcUnit Unit: Radar unit issuing the plan.
-- @param groupName string: Name of the target group.
-- @param waypoints table: Array of waypoint definitions (length > 0).
-- @param options table|nil: Optional `{ pushAsTask = boolean }`.
-- @return boolean: `true` after the task is queued.
function ATC.setFlightPlan(atcUnit, groupName, waypoints, options)
    local _, controller = _assertRadarUnit(atcUnit)
    local group = _resolveGroupForControl(atcUnit, groupName)
    assert(type(waypoints) == "table" and #waypoints > 0, "waypoints must be a non-empty array")
    options = options or {}
    local routePoints = {}
    for idx, wp in ipairs(waypoints) do
        assert(wp.position, string.format("waypoint %d missing position", idx))
        local pos = mist.utils.makeVec3(wp.position)
        local point = {
            x = pos.x,
            y = pos.z,
            alt = wp.altitudeM or pos.y,
            speed = wp.speedKmh and mist.utils.kmphToMps(wp.speedKmh) or 0,
            type = WAYPOINT_TYPE_TO_DCS[wp.type or 'TURNING_POINT'] or 'Turning Point',
            action = WAYPOINT_TYPE_TO_DCS[wp.type or 'TURNING_POINT'] or 'Turning Point',
            alt_type = wp.altitudeType or 'BARO',
            name = tostring(wp.id or idx),
            task = { id = 'ComboTask', params = { tasks = {} } },
        }
        if wp.turnMethod then
            point.turn = TURN_METHOD_TO_DCS[wp.turnMethod] or TURN_METHOD_TO_DCS.FLY_OVER_POINT
        end
        _applyAirbaseIdentifier(point, wp)
        table.insert(routePoints, point)
    end
    local missionTask = {
        id = 'Mission',
        params = {
            route = {
                points = routePoints,
            },
        },
    }
    local groupController = group:getController()
    if options.pushAsTask then
        groupController:pushTask(missionTask)
    else
        groupController:setTask(missionTask)
    end
    return true
end

--- Read the current mission route for a group and convert to API schema.
-- @param atcUnit Unit: Radar unit enforcing coalition ownership.
-- @param groupName string: Group whose route should be inspected.
-- @return table|nil: Array of waypoint tables or `nil` if unavailable.
function ATC.listWaypoints(atcUnit, groupName)
    _assertRadarUnit(atcUnit)
    local _ = _resolveGroupForControl(atcUnit, groupName)
    if not mist or not mist.getGroupRoute then
        return nil
    end
    local route = mist.getGroupRoute(groupName, true)
    if not route then
        return nil
    end
    local waypoints = {}
    for idx, point in ipairs(route) do
        local position = { x = point.point and point.point.x or point.x, y = point.alt, z = point.point and point.point.y or point.y }
        local typeApi = DCS_TYPE_TO_API[point.type or point.action] or 'TURNING_POINT'
        local turnApi = point.turn and DCS_TURN_TO_API[point.turn] or nil
        local wp = {
            id = point.name or idx,
            position = position,
            altitudeM = point.alt,
            altitudeType = point.alt_type,
            speedKmh = point.speed and mist.utils.mpsToKmph(point.speed) or nil,
            type = typeApi,
            turnMethod = turnApi,
        }
        if point.airdromeId then
            wp.airbaseName = _airbaseNameFromId(point.airdromeId)
        elseif point.helipadId then
            wp.airbaseName = _airbaseNameFromId(point.helipadId)
        end
        table.insert(waypoints, wp)
    end
    return waypoints
end

--- Issue a temporary vector command that keeps the group pointed and level.
-- @param atcUnit Unit: Radar controller.
-- @param groupName string: Group to vector.
-- @param vectorSpec table: Requires `headingDeg`; optional `speedKmh`, `altitudeM`, `durationH`.
-- @return boolean: `true` when the task has been pushed.
function ATC.vectorGroup(atcUnit, groupName, vectorSpec)
    local _, _ = _assertRadarUnit(atcUnit)
    local group = _resolveGroupForControl(atcUnit, groupName)
    assert(type(vectorSpec) == "table", "vectorSpec table required")
    local units = group:getUnits()
    assert(units and #units > 0, "group has no units")
    local lead = units[1]
    local startPos = lead:getPoint()
    local headingRad = math.rad(vectorSpec.headingDeg or 0)
    local speedMps = vectorSpec.speedKmh and mist.utils.kmphToMps(vectorSpec.speedKmh) or 0
    local durationSec = (vectorSpec.durationH or (5 / 60)) * 3600
    if durationSec <= 0 then
        durationSec = 60
    end
    local distance = speedMps > 0 and (speedMps * durationSec) or 5000
    local targetPos = {
        x = startPos.x + math.cos(headingRad) * distance,
        y = vectorSpec.altitudeM or startPos.y,
        z = startPos.z + math.sin(headingRad) * distance,
    }
    local routePoints = {
        {
            x = startPos.x,
            y = startPos.z,
            alt = vectorSpec.altitudeM or startPos.y,
            speed = speedMps,
            action = 'Turning Point',
            type = 'Turning Point',
            alt_type = 'BARO',
            task = { id = 'ComboTask', params = { tasks = {} } },
        },
        {
            x = targetPos.x,
            y = targetPos.z,
            alt = targetPos.y,
            speed = speedMps,
            action = 'Turning Point',
            type = 'Turning Point',
            alt_type = 'BARO',
            task = { id = 'ComboTask', params = { tasks = {} } },
        },
    }
    local task = {
        id = 'Mission',
        params = {
            route = { points = routePoints },
        },
    }
    local controller = group:getController()
    controller:pushTask(task)
    return true
end

--- Report current simulation timing values for diagnostics.
-- @param atcUnit Unit: Radar unit used only for validation.
-- @return table: `{ modelTimeSec, missionTimeSec, startTimeSec }` values.
function ATC.getTime(atcUnit)
    _assertRadarUnit(atcUnit)
    return {
        modelTimeSec = timer.getTime(),
        missionTimeSec = timer.getAbsTime(),
        startTimeSec = timer.getTime0(),
    }
end

--- Convert a DCS wind layer table into speed/direction snapshot.
-- @param layer table|nil: Wind layer from mission weather.
-- @return table: `{ speedKmh, directionDeg }`.
local function _windLayerSnapshot(layer)
    if not layer then
        return { speedKmh = nil, directionDeg = nil }
    end
    return {
        speedKmh = layer.speed and mist.utils.mpsToKmph(layer.speed) or nil,
        directionDeg = layer.dir,
    }
end

--- Capture weather data around the ATC unit using the mission table.
-- @param atcUnit Unit: Radar unit defining the reference point.
-- @return table: Weather snapshot per API schema.
function ATC.getWeather(atcUnit)
    _assertRadarUnit(atcUnit)
    local position = atcUnit:getPoint()
    local weather = env.mission and env.mission.weather or {}
    local wind = weather.wind or {}
    local temperature = weather.season and weather.season.temperature or weather.temperature
    local qnh = weather.qnh
    local pressureHpa = qnh and mist.utils.converter('mmhg', 'hpa', qnh) or nil
    local clouds = weather.clouds or {}
    return {
        position = position,
        temperatureC = temperature,
        pressureHpa = pressureHpa,
        wind = {
            atGround = _windLayerSnapshot(wind.atGround),
            at2000m = _windLayerSnapshot(wind.at2000),
            at8000m = _windLayerSnapshot(wind.at8000),
        },
        clouds = {
            baseM = clouds.base,
            thicknessM = clouds.thickness,
            density = clouds.density,
        },
        turbulence = weather.groundTurbulence,
    }
end

--- Provide metadata for an airbase and placeholder runway list.
-- @param atcUnit Unit: Radar unit used for validation.
-- @param airbaseName string: Exact name of the airbase to describe.
-- @return table: `{ airbase = {...}, runways = {} }` metadata payload.
function ATC.getAirbaseRunways(atcUnit, airbaseName)
    _assertRadarUnit(atcUnit)
    assert(airbaseName and airbaseName ~= "", "airbaseName required")
    local airbase = Airbase.getByName(airbaseName)
    assert(airbase, string.format("Airbase %s not found", airbaseName))
    local desc = airbase:getDesc() or {}
    local position = airbase:getPoint()
    return {
        airbase = {
            name = airbase:getName(),
            category = desc.category,
            coalition = coalitionSideToName[airbase:getCoalition()] or "NEUTRAL",
            position = position,
        },
        runways = {},
    }
end

return ATC
