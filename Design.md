````markdown
# ATC REST Backend Lua API for DCS World

This document defines a Lua API to be used as the backend of an Air Traffic Control (ATC) REST server for DCS World.

The REST layer is *not* specified here; instead, this document defines a set of Lua functions and data structures that:

- Use a single **ATC radar unit** (`Unit`) as the primary handle into the DCS world.
- Query **air traffic** and **ground traffic** (aircraft on the ground).
- Control AI **flight plans** and **vectors**.
- Query **time**, **weather**, and **airbase/runway state**.

Wherever useful, references to DCS scripting documentation are given as URLs for later implementation work.

---

## 1. Design principles and conventions

### 1.1. ATC radar unit

All public functions take an **ATC radar unit** as their first parameter:

```lua
---@param atcUnit Unit  -- DCS Unit instance representing the ATC radar / tower
````

Internally, every function must verify that:

* `atcUnit` is non-nil and `atcUnit:isExist()` is true.
* `atcUnit` is a valid `Unit` object (see DCS Unit class docs:
  [https://wiki.hoggitworld.com/view/DCS_Class_Unit](https://wiki.hoggitworld.com/view/DCS_Class_Unit)). ([wiki.hoggitworld.com][1])
* `atcUnit` has appropriate radar/sensor capabilities, via `Unit:getController()` and `Controller:hasSensors()` / `Controller.Detection` enums:
  [https://wiki.hoggitworld.com/view/DCS_Class_Controller](https://wiki.hoggitworld.com/view/DCS_Class_Controller),
  [https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets](https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets). ([wiki.hoggitworld.com][2])

The validation logic is encapsulated in an **internal helper**, described in §7.

### 1.2. Units and coordinate system

* **Positions**: DCS world coordinates, `{ x, y, z }`, in **meters** (Vec3).
  (See Object:getPoint: [https://wiki.hoggitworld.com/view/DCS_func_getPoint](https://wiki.hoggitworld.com/view/DCS_func_getPoint)). ([FlightControl][3])
* **Altitudes**: meters MSL.
* **Speeds** (external REST units): **km/h**. Internally converted to m/s where needed.
* **Ranges**: **km** in public API, meters internally.
* **Headings/Bearings**:

  * Public API uses **degrees**.
  * Any internal DCS structure that uses radians will convert as needed.

### 1.3. DCS API base references

Primary documentation used for this design:

* Scripting engine overview:
  [https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation](https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation) ([wiki.hoggitworld.com][4])
* `Unit` class:
  [https://wiki.hoggitworld.com/view/DCS_Class_Unit](https://wiki.hoggitworld.com/view/DCS_Class_Unit) ([wiki.hoggitworld.com][1])
* `Object.getDesc`, `Unit.Category` via `getDesc().category`:
  [https://wiki.hoggitworld.com/view/DCS_func_getDesc](https://wiki.hoggitworld.com/view/DCS_func_getDesc) ([wiki.hoggitworld.com][5])
* `Controller` class and AI tasking:
  [https://wiki.hoggitworld.com/view/DCS_Class_Controller](https://wiki.hoggitworld.com/view/DCS_Class_Controller) ([wiki.hoggitworld.com][2])
* `Controller.getDetectedTargets`:
  [https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets](https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets) ([wiki.hoggitworld.com][6])
* `world.searchObjects`:
  [https://wiki.hoggitworld.com/view/DCS_func_searchObjects](https://wiki.hoggitworld.com/view/DCS_func_searchObjects) ([wiki.hoggitworld.com][7])
* `land.isVisible` (terrain line-of-sight):
  [https://wiki.hoggitworld.com/view/DCS_func_isVisible](https://wiki.hoggitworld.com/view/DCS_func_isVisible) and
  [https://www.digitalcombatsimulator.com/en/support/faq/1257/](https://www.digitalcombatsimulator.com/en/support/faq/1257/) ([wiki.hoggitworld.com][8])
* Mission task, route and waypoints:
  [https://wiki.hoggitworld.com/view/DCS_task_mission](https://wiki.hoggitworld.com/view/DCS_task_mission) ([wiki.hoggitworld.com][9])

---

## 2. Data structures

### 2.1. `ATCContact`

Unified representation of both air and ground traffic (air units only).

```lua
---@class ATCContact
---@field trackId         string          -- Stable identifier for tracking (e.g. unit name or derived)
---@field unitName        string          -- Unit:getName()
---@field groupName       string          -- Group name the unit belongs to
---@field callsign        string|nil      -- Optional radio callsign if available
---@field coalition       "BLUE"|"RED"|"NEUTRAL"
---@field unitCategory    "AIRPLANE"|"HELICOPTER"|"GROUND_UNIT"|"SHIP"|"STRUCTURE"
---@field typeName        string          -- Unit:getTypeName() / getDesc().typeName
---@field position        { x:number, y:number, z:number } -- meters, world coordinates
---@field velocity        { x:number, y:number, z:number } -- m/s, Object:getVelocity()
---@field groundSpeedKmh  number          -- horizontal speed in km/h
---@field altitudeM       number          -- meters MSL (position.y)
---@field headingDeg      number          -- heading in degrees (0..360)
---@field inAir           boolean         -- Unit:inAir()
---@field rangeKm         number          -- distance from ATC radar in km
---@field bearingDeg      number          -- azimuth from ATC radar in degrees
---@field detection       {               -- valid only for air-traffic (radar-based) queries
---@field   radar         boolean
---@field   visual        boolean
---@field   optic         boolean
---@field }
---@field lastSeenTimeSec number          -- model time seconds (timer.getTime())
```

Notes:

* `unitCategory` maps directly to `Unit.Category` values exposed via `unit:getDesc().category`
  (see [https://wiki.hoggitworld.com/view/DCS_Class_Unit](https://wiki.hoggitworld.com/view/DCS_Class_Unit) and
  [https://wiki.hoggitworld.com/view/DCS_func_getDesc](https://wiki.hoggitworld.com/view/DCS_func_getDesc)). ([wiki.hoggitworld.com][1])
* `coalition` is derived from `Unit:getCoalition()` (via Coalition APIs).

### 2.2. `ATCWaypoint`

Represents a single waypoint in a mission route. Uses DCS-native waypoint type and turn method.

```lua
---@class ATCWaypoint
---@field id            string|number     -- Client-level identifier
---@field position      { x:number, y:number, z:number } -- meters, world coordinates
---@field altitudeM     number           -- meters MSL
---@field altitudeType  "BARO"|"RADIO"   -- maps to AI.Task.AltitudeType
---@field speedKmh      number           -- km/h (converted to m/s for DCS)
---@field type          "TAKEOFF"
---|                          "TAKEOFF_PARKING"
---|                          "TAKEOFF_PARKING_HOT"
---|                          "TURNING_POINT"
---|                          "LAND"      -- maps to AI.Task.WaypointType
---@field turnMethod    "FLY_OVER_POINT"|"FIN_POINT" -- AI.Task.TurnMethod
---@field airbaseName   string|nil       -- required if type is LAND or takeoff from airbase
```

DCS mapping for `type` and `turnMethod` is based on the mission task structure and AI waypoint definitions:
[https://wiki.hoggitworld.com/view/DCS_task_mission](https://wiki.hoggitworld.com/view/DCS_task_mission). ([wiki.hoggitworld.com][9])

---

## 3. Detection / traffic functions

### 3.1. `ATC.listAirTraffic`

```lua
--- List all air units (airplanes, helicopters, etc.) detected by the ATC radar.
--- Detection is based on Controller.getDetectedTargets with RADAR, VISUAL, and OPTIC.
--- Only units that are currently in the air are returned.
---@param atcUnit Unit
---@param opts table|nil
---  opts = {
---    coalition  = "FRIENDLY"|"HOSTILE"|"NEUTRAL"|"ALL", -- default "ALL"
---    maxRangeKm = number|nil                             -- optional radial limit in km
---  }
---@return ATCContact[]
function ATC.listAirTraffic(atcUnit, opts) end
```

**Implementation guidelines:**

1. Validate `atcUnit` using the internal `_assertRadarUnit` (§7.1).

2. Obtain controller:

   ```lua
   local ctrl = atcUnit:getController()
   ```

3. Call detection:

   ```lua
   local detected = ctrl:getDetectedTargets(
       Controller.Detection.RADAR,
       Controller.Detection.VISUAL,
       Controller.Detection.OPTIC
   )
   ```

   Reference:
   `Controller.getDetectedTargets`: [https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets](https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets). ([wiki.hoggitworld.com][6])

4. For each detected target entry:

   * Ensure the object is a `Unit`.
   * Use `unit:getDesc().category` to determine `Unit.Category`
     ([https://wiki.hoggitworld.com/view/DCS_Class_Unit](https://wiki.hoggitworld.com/view/DCS_Class_Unit)). ([wiki.hoggitworld.com][1])
   * Keep only categories `AIRPLANE` and `HELICOPTER`.
   * Require `unit:inAir() == true`.
   * Compute:

     * `position` via `Object.getPoint`.
     * `velocity` via `Object.getVelocity`.
       (Both: [https://flightcontrol-master.github.io/MOOSE_DOCS_DEVELOP/Documentation/DCS.html#Object_getPoint](https://flightcontrol-master.github.io/MOOSE_DOCS_DEVELOP/Documentation/DCS.html#Object_getPoint)). ([FlightControl][3])
     * `groundSpeedKmh` from horizontal velocity components.
     * `altitudeM` from `position.y`.
     * `headingDeg` from the velocity vector.
     * `rangeKm` and `bearingDeg` relative to `atcUnit:getPoint()`.
     * `detection.radar/visual/optic` from the detection entry’s flags.
     * `lastSeenTimeSec = timer.getTime()`
       ([https://wiki.hoggitworld.com/view/DCS_func_getTime](https://wiki.hoggitworld.com/view/DCS_func_getTime)). ([wiki.hoggitworld.com][10])

5. Apply coalition filtering relative to `atcUnit:getCoalition()` if `opts.coalition` is set.

6. Apply `maxRangeKm` filter if provided.

The REST layer can expose this as e.g.:

* `GET /atc/{radarName}/air-traffic?coalition=FRIENDLY&maxRangeKm=200`

---

### 3.2. `ATC.listGroundTraffic`

```lua
--- List air units on the ground in vicinity of the ATC unit (airfield ground traffic).
--- Uses world.searchObjects around ATC position; does not rely on detection APIs.
--- Only air units (AIRPLANE/HELICOPTER) with Unit:inAir() == false are returned.
---@param atcUnit Unit
---@param opts table
---  opts = {
---    coalition  = "FRIENDLY"|"HOSTILE"|"NEUTRAL"|"ALL",
---    maxRangeKm = number -- required; search radius in km
---  }
---@return ATCContact[]
function ATC.listGroundTraffic(atcUnit, opts) end
```

**Implementation guidelines:**

1. Validate `atcUnit`.

2. Build search volume:

   ```lua
   local center  = atcUnit:getPoint()
   local radiusM = opts.maxRangeKm * 1000

   local volume = {
     id     = world.VolumeType.SPHERE,
     params = { point = center, radius = radiusM }
   }
   ```

   `world.searchObjects`:
   [https://wiki.hoggitworld.com/view/DCS_func_searchObjects](https://wiki.hoggitworld.com/view/DCS_func_searchObjects). ([wiki.hoggitworld.com][7])

3. Invoke:

   ```lua
   world.searchObjects(
     Object.Category.UNIT,
     volume,
     function(obj, data)
       -- filter & collect units
     end,
     nil
   )
   ```

4. For each unit:

   * Use `unit:getDesc().category` to identify `Unit.Category`: only `AIRPLANE`, `HELICOPTER`.([wiki.hoggitworld.com][1])
   * Require `unit:inAir() == false`.
   * Apply coalition filter versus `atcUnit:getCoalition()`.
   * Construct `ATCContact` (detection flags may be `false` or `nil` since this function is not using radar/visual detection).
   * Compute `rangeKm`, `bearingDeg` relative to ATC same as in `listAirTraffic`.

Possible REST mapping:

* `GET /atc/{radarName}/ground-traffic?coalition=FRIENDLY&maxRangeKm=5`

---

### 3.3. `ATC.checkLineOfSight`

```lua
--- Check terrain-based line of sight (LOS) between ATC unit and a target unit.
--- Intended for air units; buildings/objects are not considered, only terrain.
---@param atcUnit    Unit
---@param targetUnit Unit
---@return table
---  {
---    hasLOS  = boolean,  -- true if terrain does not block LOS
---    rangeKm = number    -- straight-line distance in km
---  }
function ATC.checkLineOfSight(atcUnit, targetUnit) end
```

**Implementation guidelines:**

* Retrieve positions:

  ```lua
  local p1 = atcUnit:getPoint()
  local p2 = targetUnit:getPoint()
  ```

* LOS check using `land.isVisible(p1, p2)`:

  * Hoggit: [https://wiki.hoggitworld.com/view/DCS_func_isVisible](https://wiki.hoggitworld.com/view/DCS_func_isVisible)
  * Official: [https://www.digitalcombatsimulator.com/en/support/faq/1257/](https://www.digitalcombatsimulator.com/en/support/faq/1257/)

  Both state that `land.isVisible` checks only terrain intersection and ignores units/statics/objects. ([wiki.hoggitworld.com][8])

* Compute `rangeKm` from Euclidean distance between `p1` and `p2`.

REST mapping example:

* `GET /atc/{radarName}/los?targetUnit={unitName}`

---

## 4. Routing / control functions

All routing/control functions apply only to **groups on the same coalition** as the ATC unit. They operate via `Group.getByName` → `group:getController()` and DCS AI tasking. See:
[https://wiki.hoggitworld.com/view/DCS_task_mission](https://wiki.hoggitworld.com/view/DCS_task_mission) and
[https://wiki.hoggitworld.com/view/Mission_Editor%3A_AI_Tasking](https://wiki.hoggitworld.com/view/Mission_Editor%3A_AI_Tasking). ([wiki.hoggitworld.com][9])

### 4.1. `ATC.setFlightPlan`

```lua
--- Assign or replace the main mission route for a group controlled by this ATC unit.
--- Supports all DCS waypoint types and turn methods defined in ATCWaypoint.
---@param atcUnit   Unit
---@param groupName string        -- Group.getByName name
---@param waypoints ATCWaypoint[] -- ordered route
---@param options   table|nil
---  options = {
---    pushAsTask  = false,  -- false: setTask (replace mission); true: pushTask
---    keepEnroute = false   -- backend-specific behavior for enroute tasks
---  }
function ATC.setFlightPlan(atcUnit, groupName, waypoints, options) end
```

**Implementation guidelines:**

1. Validate `atcUnit`.

2. Resolve group:

   ```lua
   local group = Group.getByName(groupName)
   if not group or not group:isExist() then ... end
   ```

3. Ensure `group:getCoalition() == atcUnit:getCoalition()`.

4. Build DCS route structure following mission task definition:
   [https://wiki.hoggitworld.com/view/DCS_task_mission](https://wiki.hoggitworld.com/view/DCS_task_mission). ([wiki.hoggitworld.com][9])

   For each `ATCWaypoint`:

   * `point.x`, `point.y`, `point.z` from `position`.
   * `alt` = `altitudeM`.
   * `alt_type` from `altitudeType` (`"BARO"` / `"RADIO"`).
   * `speed` = `speedKmh / 3.6` (m/s).
   * `type` from `ATCWaypoint.type` (`TAKEOFF`, `LAND`, etc.).
   * `action` as appropriate for the waypoint type.
   * For landing/takeoff:

     * `airbaseName` must be resolved via `Airbase.getByName(...)` to set `airdromeId` / `helipadId`.

5. Wrap in a mission task:

   ```lua
   local task = {
     id = 'Mission',
     params = {
       route = {
         points = dcsRoutePoints
       }
     }
   }
   ```

6. Apply via `group:getController():setTask(task)` or `:pushTask(task)` depending on `options.pushAsTask`.
   Controller docs: [https://wiki.hoggitworld.com/view/DCS_Class_Controller](https://wiki.hoggitworld.com/view/DCS_Class_Controller). ([wiki.hoggitworld.com][2])

REST mapping example:

* `PUT /atc/{radarName}/groups/{groupName}/flightplan`

---

### 4.2. `ATC.listWaypoints`

```lua
--- Return the last flight plan that this ATC backend assigned to the group.
--- Note: DCS scripting API does not expose current route; this is backend state.
---@param atcUnit   Unit
---@param groupName string
---@return ATCWaypoint[]|nil
function ATC.listWaypoints(atcUnit, groupName) end
```

**Important**: This function returns the `ATCWaypoint[]` stored by the backend when `ATC.setFlightPlan` was last called for the `(atcUnit, groupName)` pair. There is no direct DCS API to read a group’s current mission route back from the engine.

REST mapping example:

* `GET /atc/{radarName}/groups/{groupName}/waypoints`

---

### 4.3. `ATC.vectorGroup`

```lua
--- Issue a heading/altitude/speed vector without redefining the full route.
--- Used for ATC-style instructions (e.g. "fly heading 270, maintain 5000m, 600 km/h").
---@param atcUnit   Unit
---@param groupName string
---@param vectorSpec table
---  vectorSpec = {
---    headingDeg = number,      -- heading in degrees
---    altitudeM  = number,      -- meters MSL
---    speedKmh   = number,      -- km/h
---    durationH  = number|nil   -- hours; if given, how long to maintain vector
---  }
function ATC.vectorGroup(atcUnit, groupName, vectorSpec) end
```

**Implementation guidelines:**

* Same group resolution and coalition checks as `setFlightPlan`.

* Internally, this can be implemented as one or more AI tasks and commands, e.g.:

  * Set speed to `vectorSpec.speedKmh / 3.6`.
  * Set altitude to `vectorSpec.altitudeM`.
  * Fly a specific heading for `durationH * 3600` seconds or until superseded.

* The exact AI task combination may use DCS “perform task” and “command” entries as described in the mission tasking documentation:
  [https://wiki.hoggitworld.com/view/Mission_Editor%3A_AI_Tasking](https://wiki.hoggitworld.com/view/Mission_Editor%3A_AI_Tasking). ([wiki.hoggitworld.com][11])

REST mapping example:

* `POST /atc/{radarName}/groups/{groupName}/vector`

---

## 5. Environment / airfields functions

### 5.1. `ATC.getTime`

```lua
--- Get simulation time information relevant to ATC.
---@param atcUnit Unit
---@return table
---  {
---    modelTimeSec   = number, -- timer.getTime(): time since mission start
---    missionTimeSec = number, -- timer.getAbsTime(): absolute mission time
---    startTimeSec   = number  -- timer.getTime0(): mission start time
---  }
function ATC.getTime(atcUnit) end
```

References:

* `timer.getTime`, `timer.getAbsTime`, `timer.getTime0`:
  [https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation](https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation) (timer section). ([wiki.hoggitworld.com][4])

REST mapping example:

* `GET /atc/{radarName}/time`

---

### 5.2. `ATC.getWeather`

```lua
--- Returns a weather snapshot in the vicinity of the ATC unit.
---@param atcUnit Unit
---@return table
---  {
---    position     = { x:number, y:number, z:number }, -- ATC unit position
---    temperatureC = number,
---    pressureHpa  = number,
---    wind = {
---      atGround = { speedKmh:number, directionDeg:number },
---      at2000m  = { speedKmh:number, directionDeg:number },
---      at8000m  = { speedKmh:number, directionDeg:number }
---    },
---    clouds = {
---      baseM      = number,
---      thicknessM = number,
---      density    = number     -- 0..1
---    },
---    turbulence = number       -- implementation-specific scale
---  }
function ATC.getWeather(atcUnit) end
```

**Notes:**

* DCS scripting API does not expose a fully documented weather API in the core SSE documentation; actual implementation will likely read from mission environment tables or engine-specific functions not covered here.
* The schema is defined so that the REST layer has a stable structure; the backend is responsible for populating it from whatever weather source is available.

REST mapping example:

* `GET /atc/{radarName}/weather`

---

### 5.3. `ATC.getAirbaseRunways`

```lua
--- Get airbase info plus runway geometry and current occupancy.
---@param atcUnit    Unit
---@param airbaseName string  -- Airbase.getByName name
---@return table
---  {
---    airbase = {
---      name      = string,
---      category  = "AIRDROME"|"HELIPAD"|"SHIP",
---      coalition = "BLUE"|"RED"|"NEUTRAL",
---      position  = { x:number, y:number, z:number }
---    },
---    runways = {
---      [1] = {
---        id              = string,       -- e.g. "09", "27L"
---        headingDeg      = number,      -- runway heading
---        lengthM         = number,
---        widthM          = number,
---        threshold1      = { x:number, y:number, z:number },
---        threshold2      = { x:number, y:number, z:number },
---
---        occupied        = boolean,
---        occupiedBy      = ATCContact[], -- contacts currently on runway
---        lastLandingTime = number|nil,   -- seconds (backend-tracked)
---        lastTakeoffTime = number|nil
---      },
---      ...
---    }
---  }
function ATC.getAirbaseRunways(atcUnit, airbaseName) end
```

**Implementation guidelines:**

1. Resolve airbase:

   ```lua
   local ab = Airbase.getByName(airbaseName)
   ```

   Airbase docs (category, coalition, point):
   [https://flightcontrol-master.github.io/MOOSE_DOCS_DEVELOP/Documentation/DCS.html#Airbase](https://flightcontrol-master.github.io/MOOSE_DOCS_DEVELOP/Documentation/DCS.html#Airbase)
   and DCS SSE function list:
   [https://wiki.hoggit.us/index.php?title=Category:Functions](https://wiki.hoggit.us/index.php?title=Category:Functions). ([FlightControl][3])

2. Airbase metadata:

   * `airbase.name` from `ab:getName()`.
   * `airbase.category` from `ab:getDesc()`.
   * `airbase.coalition` from `ab:getCoalition()`.
   * `airbase.position` from `ab:getPoint()`.

3. Runway geometry:

   * Geometry (threshold positions, headings, length/width) is typically not directly exposed by a single SSE function; it is usually sourced from mission data or a prebuilt database.
   * The backend maintains a mapping `{ airbaseName → list of runways }` providing `id`, `headingDeg`, `threshold1`, `threshold2`, `lengthM`, `widthM`.
   * `land.getSurfaceType(Vec2)` can help confirm RUNWAY surface around thresholds if desired:
     [https://www.digitalcombatsimulator.com/en/support/faq/1257/](https://www.digitalcombatsimulator.com/en/support/faq/1257/). ([Digital Combat Simulator][12])

4. Occupancy:

   * Use `ATC.listAirTraffic` and `ATC.listGroundTraffic` to obtain relevant aircraft.
   * Define a 3D volume around each runway (box or capsule) based on thresholds, width, and tolerance in altitude.
   * A contact `c` occupies the runway if:

     * `c.position` lies inside this volume.
     * `c.altitudeM` is within a small margin of runway elevation (using `land.getHeight(Vec2)`):
       [https://www.digitalcombatsimulator.com/en/support/faq/1257/](https://www.digitalcombatsimulator.com/en/support/faq/1257/). ([Digital Combat Simulator][12])
   * Maintain `lastLandingTime` and `lastTakeoffTime` as backend state, based on observed transitions (e.g. from `inAir == true` to `false` on runway volume, etc.).

REST mapping example:

* `GET /atc/{radarName}/airbases/{airbaseName}/runways`

---

## 6. Summary of public API

Grouped for easy mapping to REST:

### Detection / traffic

* `ATC.listAirTraffic(atcUnit, opts) -> ATCContact[]`
* `ATC.listGroundTraffic(atcUnit, opts) -> ATCContact[]`
* `ATC.checkLineOfSight(atcUnit, targetUnit) -> { hasLOS, rangeKm }`

### Routing / control

* `ATC.setFlightPlan(atcUnit, groupName, waypoints, options)`
* `ATC.listWaypoints(atcUnit, groupName) -> ATCWaypoint[]|nil`
* `ATC.vectorGroup(atcUnit, groupName, vectorSpec)`

### Environment / airfields

* `ATC.getTime(atcUnit) -> { modelTimeSec, missionTimeSec, startTimeSec }`
* `ATC.getWeather(atcUnit) -> weatherSnapshot`
* `ATC.getAirbaseRunways(atcUnit, airbaseName) -> { airbase, runways[] }`

---

## 7. Internal helpers and backend state (non-public)

### 7.1. `_assertRadarUnit`

```lua
--- Internal helper to validate that a unit is suitable as an ATC radar.
---@param atcUnit Unit
---@return Unit  -- returns the same unit if valid; error/abort otherwise
local function _assertRadarUnit(atcUnit)
  -- Implementation suggestion:
  -- - Check non-nil, isExist()
  -- - Check unit:getDesc().category is an allowed platform type
  -- - Optionally check hasSensors(Controller.Detection.RADAR) == true
end
```

This is not exposed to REST; it is used at the start of every public API function.

### 7.2. Backend state

The following pieces of state are maintained by the backend and are not part of the DCS engine:

* **Flight plans per ATC/unit group**: for `ATC.listWaypoints`.
* **Runway events**: `lastLandingTime`, `lastTakeoffTime` per runway, derived from movement of `ATCContact`s.

These state stores can be implemented as Lua tables keyed by `(atcUnitName, groupName)` or `(airbaseName, runwayId)`.

---

```
```

[1]: https://wiki.hoggitworld.com/view/DCS_Class_Unit?utm_source=chatgpt.com "DCS Class Unit"
[2]: https://wiki.hoggitworld.com/view/DCS_Class_Controller?utm_source=chatgpt.com "DCS Class Controller"
[3]: https://flightcontrol-master.github.io/MOOSE_DOCS_DEVELOP/Documentation/DCS.html?utm_source=chatgpt.com "Module DCS - GitHub Pages"
[4]: https://wiki.hoggitworld.com/view/Simulator_Scripting_Engine_Documentation?utm_source=chatgpt.com "Simulator Scripting Engine Documentation"
[5]: https://wiki.hoggitworld.com/view/DCS_func_getDesc?utm_source=chatgpt.com "DCS func getDesc"
[6]: https://wiki.hoggitworld.com/view/DCS_func_getDetectedTargets?utm_source=chatgpt.com "DCS func getDetectedTargets"
[7]: https://wiki.hoggitworld.com/view/DCS_func_searchObjects?utm_source=chatgpt.com "DCS func searchObjects - Hoggitworld.com"
[8]: https://wiki.hoggitworld.com/view/DCS_func_isVisible?utm_source=chatgpt.com "DCS func isVisible - Hoggitworld.com"
[9]: https://wiki.hoggitworld.com/view/DCS_task_mission?utm_source=chatgpt.com "DCS task mission"
[10]: https://wiki.hoggitworld.com/view/DCS_Scripting_orig_Part_1?utm_source=chatgpt.com "DCS Scripting orig Part 1"
[11]: https://wiki.hoggitworld.com/view/Mission_Editor%3A_AI_Tasking?utm_source=chatgpt.com "Mission Editor: AI Tasking - DCS World Wiki"
[12]: https://www.digitalcombatsimulator.com/en/support/faq/1257/?utm_source=chatgpt.com "Singletons"
