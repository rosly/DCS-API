# Smart ATC HTTP REST Server for DCS Server Hooks  
**Design & Implementation Reference (`REST_design.md`)**

Author: Internal design for Smart ATC project  
Target: DCS dedicated server (no client-side mods required)


---

## 1. Scope and Goals

The purpose of this document is to define the architecture and implementation strategy for a **small HTTP REST server running inside DCS** on the **server side only**, using the **Sim Control / Hooks (“userhooks”) Lua environment**.

The REST server will:

- Expose a **whitelisted set of mission scripting functions** as HTTP endpoints (read + write actions on the simulation).
- Run entirely in the **server’s Saved Games tree**, with no files or config required on clients.
- Bridge from the **Hooks / userhooks** environment to the **Mission Scripting Environment (MSE)** where the actual ATC logic lives.
- Be suitable as a backend for an external **LLM-based ATC agent** (plus STT/TTS via SRS or similar).

This document is both **architectural** and **implementation-focused**. It is intended as a reference so that someone familiar with Lua and DCS scripting can implement the system from scratch without needing the original chat history.


---

## 2. Relevant DCS Lua Environments

DCS World uses several isolated Lua interpreters (“states”). Only a subset is relevant to this design.

### 2.1 States we care about

For context on DCS Lua environments, see the DCS FAQ on the Lua environment and the Sim Control API documentation (`Doc/Sim_ControlAPI.html` or `Sim_ControlAPI.md`) in the DCS installation.  
- DCS FAQ – Lua environment: https://www.digitalcombatsimulator.com/en/support/faq/1253/  
- Sim Control API: `<DCS_INSTALL>/Doc/Sim_ControlAPI.html` (or `Sim_ControlAPI.md` from that folder)

The most important Lua states for this design:

| Name / label         | Description                                                                                          | How we use it                          |
|----------------------|------------------------------------------------------------------------------------------------------|----------------------------------------|
| **userhooks / gui**  | “Sim Control” / Hooks environment used for `Saved Games/.../Scripts/Hooks/*.lua`. Full OS access.   | **Our HTTP server lives here.**        |
| **mission**          | Mission trigger/control state (`a_*`/`c_*` functions, `a_do_script`, `a_do_file`).                   | Entry point into the Mission Scripting Environment. |
| **Mission Scripting Environment (MSE)** | Actual mission scripting sandbox where DO SCRIPT / DO SCRIPT FILE code runs.           | Where **ATC mission logic** runs.      |
| **export**           | Export.lua environment.                                                                              | Optional; not required for core design.|

Other states (`config`, `server`, `scripting`, etc.) exist but are not required for the minimal setup.


### 2.2 Data and control flow between environments

We use **two official cross-environment mechanisms**:

1. **`net.dostring_in(state, code)`** (Sim Control API)  
   - Callable from environments listed in `net.allow_unsafe_api` in `autoexec.cfg`.
   - Can run `code` in another state listed in `net.allow_dostring_in` and **return multiple values**.  
   - Example from ED forums / docs (simplified):

     ```lua
     local a, b, c = net.dostring_in("mission", "return 1, 2, 3")
     ```

2. **`a_do_script(code)` / `a_do_file(path)`** (Mission Control API)  
   - Available in the **`mission` state**.  
   - Executes `code`/file in the **Mission Scripting Environment** (MSE), i.e. where mission DO SCRIPT runs.  
   - Since recent DCS versions, supports **return values**:

     ```lua
     local a, b, c = a_do_script("return 1, 2, 3")
     ```

We combine these two hops:

```text
HTTP client
  ↓
Hooks (userhooks)  -- net.dostring_in("mission", ...) -->
  mission          -- a_do_script("...") -->
  Mission Scripting Environment (MSE)
````

The mission scripting side exposes a narrow table of functions (`ATC_API`) that can be called from Hooks via this chain.

---

## 3. High-Level Architecture

### 3.1 Components

1. **Smart ATC HTTP Server (Hooks / userhooks)**

   * Location: `Saved Games\DCS.openbeta_server\Scripts\Hooks\SmartATC.lua` (or similar).
   * Uses **LuaSocket** (or equivalent) to run a small HTTP server.
   * Uses `Sim.setUserCallbacks()` to integrate with DCS simulation callbacks (`onSimulationStart`, `onSimulationFrame`, etc.).
   * Interprets HTTP requests, checks against a whitelist of allowed API methods, and bridges to mission using `net.dostring_in("mission", ...)`.

2. **Mission-side ATC API (Mission Scripting Environment)**

   * Lua module loaded into the MSE via DO SCRIPT FILE in the mission or via `a_do_file` from the mission state.

   * Defines a small public surface:

     ```lua
     ATC_API = {
         listTraffic      = function(args) ... end,
         getRunwayState   = function(args) ... end,
         pushLandingTask  = function(args) ... end,
         ...
     }
     ```

   * Wraps SIM operations (`world`, `Unit`, `Group`, `Controller`, etc.) to **read and write** mission state.

3. **External ATC/LLM service**

   * Runs outside DCS (Python/Go/Node/whatever).
   * Talks to the HTTP REST server on the DCS server (localhost or restricted IP).
   * Handles speech recognition (e.g. via SRS or separate STT), LLM inference, and sends commands back to DCS via REST.

### 3.2 Example call flow

Example: LLM wants to list all observed traffic and then assign a landing task.

1. External ATC → DCS:

   ```text
   GET  /atc/traffic
   ```

2. SmartATC (Hooks):

   * Parses request.
   * Maps `/atc/traffic` to call `ATC_API.listTraffic({ ... })`.
   * Executes:

     ```lua
     local json_result, err = call_mission("listTraffic", {})
     ```

3. Hooks → mission (via `net.dostring_in`):

   ```lua
   net.dostring_in("mission", [[
       return a_do_script([[
           return ATC_API.dispatch("listTraffic", "{}")
       ]])
   ]])
   ```

4. Mission → MSE (via `a_do_script`):

   * Inside MSE, `ATC_API.dispatch` decodes JSON args, runs `ATC_API.listTraffic`, encodes result as JSON string, returns it.

5. JSON string returns back up through `a_do_script` → `net.dostring_in` → SmartATC HTTP server, which forwards it as HTTP response.

6. External ATC sends a command:

   ```text
   POST /atc/landing-task
   { "groupName": "TU-95-1", "runwayId": 3 }
   ```

   * SmartATC maps to `ATC_API.pushLandingTask(args)`.
   * Same bridge path.
   * Mission-side `ATC.assignLanding()` pushes proper DCS task(s) to the group.

---

## 4. DCS File Layout and Configuration

### 4.1 File layout (server side)

Recommended layout in server’s Saved Games:

```text
Saved Games\
  DCS.openbeta_server\
    Config\
      autoexec.cfg
    Scripts\
      Hooks\
        SmartATC.lua                <-- main hook / HTTP server entrypoint
    Mods\
      Services\
        SmartATC\
          lua\
            smartatc_http.lua       <-- HTTP server implementation (optional split)
            smartatc_bridge.lua     <-- net.dostring_in / a_do_script bridge helpers
            smartatc_config.lua     <-- config (port, bind address, allowed methods)
          mission\
            smartatc_atc_api.lua    <-- mission-side ATC_API module (for MSE)
```

Only `SmartATC.lua` under `Scripts\Hooks` *must* exist; everything else can be organized as you prefer, loaded via `dofile`.

Example `SmartATC.lua` stub:

```lua
local lfs = require("lfs")
local write_dir = lfs.writedir()
dofile(write_dir .. "Mods/Services/SmartATC/lua/smartatc_http.lua")
```

### 4.2 `autoexec.cfg` configuration

To allow a **Hooks** script to execute code in the **mission** state, Sim Control API requires an `autoexec.cfg` in the server profile:

`Saved Games\DCS.openbeta_server\Config\autoexec.cfg`:

```lua
if not net then net = {} end

-- States that may use unsafe APIs (file I/O, net.dostring_in, etc.)
net.allow_unsafe_api = {
  "userhooks",   -- our SmartATC hook
}

-- States that may be targeted by net.dostring_in("state", ...)
net.allow_dostring_in = {
  "mission",     -- we only need to jump into the mission state
}
```

This mirrors what other server tools (LotAtc, etc.) do for server-side control.

### 4.3 Mission integration of ATC API

Two options:

1. **Explicit mission inclusion (simple & safe)**
   Mission author adds a DO SCRIPT FILE trigger that loads the ATC API module into the MSE:

   ```lua
   -- in mission trigger: DO SCRIPT FILE
   dofile(lfs.writedir() .. "Mods/Services/SmartATC/mission/smartatc_atc_api.lua")
   ```

   After this, `ATC_API` is available in mission scripting environment.

2. **Automatic mission injection (more intrusive)**
   From the `mission` state, the server hook could call `a_do_file` to inject the ATC API when the mission starts. That requires a small piece of code executed in the `mission` state (e.g. via `net.dostring_in("mission", "a_do_file(...)")`). This is more “transparent” to mission authors but slightly more complex and may conflict with mission policies.

Design assumption for this document: **Option 1** (mission authors opt in by including the ATC API file).

---

## 5. HTTP Server Design in Hooks

The HTTP server will live entirely in the **Hooks / userhooks** environment and be driven by `Sim.setUserCallbacks()` + `onSimulationFrame()`.

Two established examples with similar goals:

* **WebConsole.lua** – Actium’s browser-based Lua console for all scripting environments, providing an HTTP server plus interactive console and JSON-serialized return values.

  * Forum thread: [https://forum.dcs.world/topic/369255-webconsolelua-simple-browser-based-lua-console-for-all-scripting-environments-http-api/](https://forum.dcs.world/topic/369255-webconsolelua-simple-browser-based-lua-console-for-all-scripting-environments-http-api/)
  * Source (MIT): [https://gist.github.com/TylerDurden120/67093e7e0af92272b767287fe5f6edc7](https://gist.github.com/TylerDurden120/67093e7e0af92272b767287fe5f6edc7)

* **dcs-fiddle-server.lua** – DCS Fiddle HTTP server that executes Lua snippets in DCS and returns results, used by DCS Fiddle web console / DCS Lua Runner.

  * Project: [https://github.com/JonathanTurnock/dcsfiddle](https://github.com/JonathanTurnock/dcsfiddle)
  * Docs: [https://dcsfiddle.pages.dev/docs](https://dcsfiddle.pages.dev/docs)
  * Script path (typical installation): `Saved Games\DCS\Scripts\Hooks\dcs-fiddle-server.lua`

We follow the same general patterns but specialize them for a **fixed REST API** instead of executing arbitrary Lua.

### 5.1 Design goals

* **Non-blocking**: No blocking reads or sleeps in the main loop; must not stall DCS.
* **Small surface**: Only expose a whitelisted set of ATC methods, no generic eval.
* **Local by default**: Bind to `127.0.0.1` by default; allow configuration to open up if needed.
* **Stateless HTTP**: Each request is self-contained; no persistent Lua session per client required (unlike WebConsole).
* **Text-based JSON**: Responses are always `application/json` with UTF-8 text.

### 5.2 Lessons from WebConsole.lua

From WebConsole.lua’s description and source (MIT-licensed):

* Uses `socket = require("socket")` and `socket.bind()` to open a TCP listener.
* Sets the listener to non-blocking mode: `server:settimeout(0)`.
* In an update loop (driven by DCS callbacks), calls `server:accept()` and, if a client connects, reads the HTTP request with `client:receive("*l")` line-by-line.
* Parses the **request line** and **headers** manually, then optionally the body.
* Decodes request parameters (e.g. `?code=...`), compiles and executes them using `load()` in a chosen environment, then serializes return values to JSON.
* Returns a minimal HTTP response: status line, headers, empty line, body.

We will reuse the **non-blocking TCP + minimal HTTP parsing pattern**, but replace the “execute arbitrary Lua” bit with a **dispatch to specific ATC API functions** via the mission bridge.

### 5.3 Lessons from dcs-fiddle-server.lua

From dcs-fiddle docs and the related tooling (DCS Lua Runner MCP, tslua-dcs repo):

* The server script is installed in `Saved Games\DCS\Scripts\Hooks`, confirming this is the right environment for a generic HTTP server inside DCS.
* It uses HTTP endpoints to send Lua code strings to DCS and get results back, much like WebConsole but tailored to DCS Fiddle.
* Some setups require **desanitizing `MissionScripting.lua`** to allow `os`, `io`, `lfs`, and `require` inside mission scripts. DCS Fiddle uses this to run more complex code in the mission environment.

We deliberately **avoid** relying on desanitizing `MissionScripting.lua` for security; our HTTP server remains in Hooks, which already has OS access by design, and the mission scripting environment remains sandboxed.

### 5.4 HTTP server skeleton in Hooks

Below is a **fresh skeleton** (not copied from WebConsole or DCS Fiddle) that implements the minimal HTTP behavior we need.

**Initialization (SmartATC HTTP server)**

```lua
-- File: Saved Games/.../Mods/Services/SmartATC/lua/smartatc_http.lua
local socket = require("socket")
local lfs    = require("lfs")

local config = {
    host = "127.0.0.1",
    port = 5011,
}

local server = nil

-- Map of route -> handler function (see section 8)
local routes = {}

-- Forward declaration
local poll_http

local function log(msg)
    -- prefix to make grepping DCS.log easier
    env.info("[SmartATC] " .. msg)
end

local function init_http_server()
    server = assert(socket.bind(config.host, config.port))
    server:settimeout(0)  -- non-blocking
    log(string.format("HTTP server listening on %s:%d", config.host, config.port))
end
```

**DCS callback integration**

```lua
local callbacks = {}

function callbacks.onSimulationStart()
    log("Simulation started")
    init_http_server()
end

function callbacks.onSimulationStop()
    log("Simulation stopped")
    if server then
        server:close()
        server = nil
    end
end

function callbacks.onSimulationFrame()
    if server then
        poll_http()
    end
end

Sim.setUserCallbacks(callbacks)
```

**HTTP request parsing / routing (simplified)**

```lua
-- Helper: send an HTTP response with JSON body
local function send_response(client, status, body, content_type)
    content_type = content_type or "application/json"
    body = body or ""

    local status_line = "HTTP/1.1 " .. status
    local headers = {
        status_line,
        "Content-Type: " .. content_type,
        "Content-Length: " .. tostring(#body),
        "Connection: close",
        "",
        "",
    }
    client:send(table.concat(headers, "\r\n") .. body)
end

local function parse_request_line(line)
    -- Example: "GET /atc/traffic?filter=airborne HTTP/1.1"
    local method, path, proto = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
    return method, path, proto
end

local function split_path_and_query(url_path)
    local path, qs = url_path:match("^([^?]+)%??(.*)$")
    return path or "/", qs or ""
end

local function parse_query(qs)
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

local function route_request(method, url_path, headers, body)
    local path, qs = split_path_and_query(url_path)
    local query = parse_query(qs)

    local route = routes[method .. " " .. path]
    if not route then
        return "404 Not Found", '{"error":"no such endpoint"}'
    end

    -- Call route handler; it returns (status, body)
    local ok, status, response_body = pcall(route, {
        method  = method,
        path    = path,
        query   = query,
        headers = headers,
        body    = body,
    })

    if not ok then
        return "500 Internal Server Error",
               string.format('{"error":"%s"}', tostring(status))
    end

    return status or "200 OK", response_body or "{}"
end

poll_http = function()
    local client = server:accept()
    if not client then
        return
    end
    client:settimeout(0)

    -- Read request line
    local line, err = client:receive("*l")
    if not line then
        client:close()
        return
    end

    local method, url_path = parse_request_line(line)
    if not method then
        send_response(client, "400 Bad Request", '{"error":"bad request line"}')
        client:close()
        return
    end

    -- Read headers
    local headers = {}
    while true do
        local hline = client:receive("*l")
        if not hline or hline == "" then break end
        local k, v = hline:match("^([^:]+):%s*(.*)$")
        if k then
            headers[string.lower(k)] = v
        end
    end

    -- Read body if Content-Length is present
    local body = ""
    local cl = tonumber(headers["content-length"] or "0", 10)
    if cl and cl > 0 then
        body = client:receive(cl) or ""
    end

    local status, response_body = route_request(method, url_path, headers, body)
    send_response(client, status, response_body)

    client:close()
end
```

The **`routes` table** is populated later (section 8) with handler functions that talk to the mission via the bridge module.

---

## 6. Mission-Side ATC API (`ATC_API`)

The mission scripting environment (MSE) will host the ATC logic and the whitelisted API that the HTTP server can call.

### 6.1 Mission ATC API module

File: `Saved Games\DCS.openbeta_server\Mods\Services\SmartATC\mission\smartatc_atc_api.lua`
(Loaded into a mission via DO SCRIPT FILE.)

Design goals:

* Keep **all DCS object and task logic** here: `world`, `coalition`, `Unit`, `Group`, `Controller`, etc.
* Expose a **small, documented function set** in `ATC_API`.
* Use JSON as a wire format between mission and Hooks.

Example structure:

```lua
-- Mission Scripting Environment
-- smartatc_atc_api.lua

ATC_API = ATC_API or {}

local json = {}

-- Option A: use a bundled JSON library (dkjson, lunajson, etc.)
-- Option B: use DCS-provided net.json2lua/lua2json if available here.
-- For now, assume we have json.encode / json.decode.

ATC_API.methods = {}

-- Example: list traffic
ATC_API.methods.listTraffic = function(args)
    -- args is a Lua table, decoded from JSON
    -- TODO: implement actual ATC.listTraffic() using your ATC module
    local traffic = ATC.listTraffic(args)
    return traffic  -- will be JSON-encoded by dispatcher
end

-- Example: push landing task
ATC_API.methods.pushLandingTask = function(args)
    -- args = { groupName = "...", runwayId = 3 }
    local ok, err = ATC.assignLanding(args.groupName, args.runwayId)
    return { ok = ok, err = err }
end

function ATC_API.dispatch(methodName, argsJson)
    local m = ATC_API.methods[methodName]
    if not m then
        return json.encode({ error = "unknown method "..tostring(methodName) })
    end

    local args = nil
    if argsJson and argsJson ~= "" then
        args = json.decode(argsJson)
    end
    -- Ensure args is a table even if null
    if args == nil then args = {} end

    local ok, result = pcall(m, args)
    if not ok then
        return json.encode({ error = tostring(result) })
    end

    return json.encode(result or {})
end
```

**Note on JSON library**:

* If the mission scripting environment has no `net.json2lua` / `net.lua2json`, embed a small JSON implementation (e.g. dkjson) **inside this file** or as a `dofile()` from MSE.
* The important part is that **`ATC_API.dispatch` always returns a JSON string**, so the Hooks layer can treat it opaquely.

### 6.2 Responsibilities split

* `ATC` module (mission-side): understands DCS units, coalitions, airfields, routes, etc.
* `ATC_API` (mission-side): adapts `ATC` functions to JSON-in/JSON-out semantics.
* `SmartATC HTTP` (Hooks): knows nothing about `ATC`; only about `ATC_API.dispatch`.

---

## 7. Bridge: Hooks ↔ Mission ↔ Mission Scripting

The bridge is responsible for:

1. Being callable from Hooks with `(methodName, argsTable)`
2. Serializing args to JSON
3. Executing `ATC_API.dispatch(methodName, argsJson)` in the mission scripting environment
4. Returning JSON string to Hooks

### 7.1 Bridge helper module

File: `Saved Games\DCS.openbeta_server\Mods\Services\SmartATC/lua/smartatc_bridge.lua`

```lua
-- Runs in Hooks / userhooks environment
local M = {}

-- Use Sim Control API's JSON helpers if available here
-- (net.lua2json / net.json2lua), else embed JSON library.
local function encode_json(lua_value)
    if net and net.lua2json then
        return net.lua2json(lua_value)
    end
    -- TODO: fallback to embedded JSON
    error("JSON encoder not available")
end

local function decode_json(json_str)
    if net and net.json2lua then
        return net.json2lua(json_str)
    end
    -- TODO: fallback
    error("JSON decoder not available")
end

-- Core bridge function:
--   methodName: string, e.g. "listTraffic"
--   argsTable: Lua table (or nil)
-- Returns:
--   json_result (string) or nil, err (string)
function M.call_mission(methodName, argsTable)
    local argsJson = "{}"
    if argsTable ~= nil then
        argsJson = encode_json(argsTable)
    end

    -- Build Lua code to run in the 'mission' state
    -- This code calls a_do_script, which runs in MSE:
    local code = string.format([==[
        return a_do_script([=[
            if not ATC_API or not ATC_API.dispatch then
                return [[{"error":"ATC_API not loaded"}]]
            end
            return ATC_API.dispatch(%q, %q)
        ]=])
    ]==], methodName, argsJson)

    -- Execute in 'mission' state
    local ok, result = net.dostring_in("mission", code)

    if not ok then
        -- 'result' contains error string from mission side
        return nil, tostring(result)
    end

    -- 'result' is expected to be a JSON string
    return tostring(result), nil
end

return M
```

Notes:

* We construct the string carefully to avoid quoting issues: outer `[==[ ... ]==]` and inner `[=[ ... ]=]`.
* We **do not** let HTTP clients inject code strings; they only choose the `methodName` from a whitelist and pass JSON arguments.
* If `ATC_API` is missing, we return a structured error.

### 7.2 Usage from the HTTP server

In `smartatc_http.lua` we can now do:

```lua
local bridge = dofile(lfs.writedir() .. "Mods/Services/SmartATC/lua/smartatc_bridge.lua")

routes["GET /atc/traffic"] = function(req)
    local args = {
        -- map query parameters into args table as needed
        onlyAirborne = req.query.onlyAirborne == "1",
    }

    local json_result, err = bridge.call_mission("listTraffic", args)
    if not json_result then
        return "500 Internal Server Error",
               string.format('{"error":"%s"}', err or "unknown") )
    end

    return "200 OK", json_result
end

routes["POST /atc/landing-task"] = function(req)
    local args = decode_json(req.body or "{}")
    local json_result, err = bridge.call_mission("pushLandingTask", args)
    if not json_result then
        return "500 Internal Server Error",
               string.format('{"error":"%s"}', err or "unknown")
    end
    return "200 OK", json_result
end
```

At this point, the HTTP server remains completely ignorant of DCS internals beyond calling `bridge.call_mission`.

---

## 8. REST API Surface Design

The API surface can evolve, but a reasonable starting point for Smart ATC looks like this:

### 8.1 Example endpoints

All responses are `application/json`. Some endpoints:

* **Traffic & situational awareness**

  * `GET /atc/traffic`

    * Query params: `coalition=red|blue|all`, `onlyAirborne=0|1`, `maxDistanceKm`, etc.
    * Calls `ATC_API.methods.listTraffic`.
    * Returns list of traffic objects (filtered).

  * `GET /atc/airfields`

    * Returns known airfields, states (open/closed), runway usage, pattern info, etc.

  * `GET /atc/runway-state`

    * Query: `airbaseName` or numeric ID.
    * Returns current runway direction, wind, active pattern(s).

* **Control / tasking**

  * `POST /atc/landing-task`

    * Body: `{ "groupName": "TU-95-1", "runwayId": 3 }`.
    * Calls `ATC_API.methods.pushLandingTask`.
    * Returns `{ "ok": true }` or `{ "ok": false, "err": "..." }`.

  * `POST /atc/route-task`

    * Body: waypoints, altitudes, restrictions.
    * Server translates to DCS `Controller:setTask` calls.

* **Diagnostics**

  * `GET /atc/ping` → `{"ok": true}`
  * `GET /atc/version` → version info of SmartATC + ATC API.

The exact schema and fields should match the internal ATC module design (not repeated here), but the pattern is always:

```text
HTTP endpoint → SmartATC route handler → bridge.call_mission(methodName, argsTable)
             → ATC_API.methods[methodName](args) → JSON result
```

### 8.2 Request/response semantics

* **GET**: read-only operations. No side effects beyond logging.
* **POST**: operations that **change sim state** (tasking, pattern changes, etc.).
* **Status codes**:

  * `200 OK` – successful operation, even if `ok=false` in JSON.
  * `400 Bad Request` – invalid JSON, missing parameters.
  * `404 Not Found` – unknown endpoint.
  * `500 Internal Server Error` – Lua error in mission or Hooks code.

---

## 9. Security, Robustness, and Performance

### 9.1 Network security

* Bind to `127.0.0.1` by default (SmartATC config).
* If remote access is required, bind to a server-local IP and protect via firewall and VPN.
* Optionally implement a simple **token-based auth** (e.g. `Authorization: Bearer <token>`) and check it in every handler.

### 9.2 Scripting sandbox and `net.allow_unsafe_api`

* Only **userhooks** environment should be allowed to use unsafe APIs (file I/O, sockets, etc.).
* Mission scripting environment **remains sandboxed**. It can only be reached via `a_do_script` from the mission state, which is called indirectly via `net.dostring_in("mission", ...)` from Hooks.
* Do **not** add `"scripting"` (i.e. mission scripting) to `net.allow_unsafe_api` unless you fully accept that any mission file loaded can access the OS.

### 9.3 Whitelisted methods only

* `ATC_API.methods` should be the **only entry point** from HTTP into mission logic.
* Never evaluate arbitrary Lua strings coming from HTTP; pass only JSON-decoded tables to known functions.
* Consider implementing versioned APIs (`/v1/atc/...`) if you expect changes.

### 9.4 Robustness and error handling

* Wrap all route handlers and mission calls in `pcall` and return JSON error objects on failure.
* Log failures via `env.info("[SmartATC] error: ...")` for offline debugging.
* Validate arguments before passing to ATC functions (e.g. ensure `groupName` exists).

### 9.5 Performance considerations

* HTTP server uses **non-blocking** I/O via `server:settimeout(0)` and `client:settimeout(0)`.
* Avoid long-running operations inside `onSimulationFrame()`; if any call might be heavy, consider:

  * Queueing requests and processing chunks over multiple frames.
  * Limiting maximum requests per frame.
* If the external LLM backend sends many requests, consider implementing **rate limiting** or batching in the external service instead.

---

## 10. Deployment and Testing

### 10.1 Basic deployment steps

1. Place `SmartATC.lua` in `Saved Games\DCS.openbeta_server\Scripts\Hooks`.
2. Place the rest of the SmartATC files under `Saved Games\DCS.openbeta_server\Mods\Services\SmartATC\...` as described.
3. Configure `autoexec.cfg` in `Saved Games\DCS.openbeta_server\Config` with the `net.allow_unsafe_api` / `net.allow_dostring_in` entries.
4. Add a DO SCRIPT FILE trigger in test mission(s) to load `smartatc_atc_api.lua` into the MSE.
5. Restart the DCS server and inspect `DCS.log` for `[SmartATC]` messages.

### 10.2 Quick manual tests

Using `curl` on the server machine:

```bash
curl http://127.0.0.1:5011/atc/ping
curl http://127.0.0.1:5011/atc/traffic
curl -X POST http://127.0.0.1:5011/atc/landing-task \
     -H "Content-Type: application/json" \
     -d '{"groupName":"TestGroup-1","runwayId":3}'
```

Verify that:

* You get JSON responses.
* Errors (e.g. missing ATC_API) are reported as structured JSON with HTTP 500.
* When ATC_API is loaded and ATC module is implemented, traffic data and tasks behave as expected in the sim.

---

## 11. References and Further Reading

### 11.1 Official / semi-official docs

* **DCS Sim Control API** (Sim.setUserCallbacks, Sim/net/Export APIs)

  * HTML: `<DCS_INSTALL>/Doc/Sim_ControlAPI.html`
  * Markdown (if extracted): `Sim_ControlAPI.md`

* **DCS Lua environment FAQ**

  * [https://www.digitalcombatsimulator.com/en/support/faq/1253/](https://www.digitalcombatsimulator.com/en/support/faq/1253/)

* **Changes to `net.dostring_in()` behavior** (returns values, security model)

  * [https://forum.dcs.world/topic/376636-changes-to-the-behaviour-of-netdostring_in/](https://forum.dcs.world/topic/376636-changes-to-the-behaviour-of-netdostring_in/)

### 11.2 WebConsole.lua

* Forum thread:
  [https://forum.dcs.world/topic/369255-webconsolelua-simple-browser-based-lua-console-for-all-scripting-environments-http-api/](https://forum.dcs.world/topic/369255-webconsolelua-simple-browser-based-lua-console-for-all-scripting-environments-http-api/)

* Source (MIT license):
  [https://gist.github.com/TylerDurden120/67093e7e0af92272b767287fe5f6edc7](https://gist.github.com/TylerDurden120/67093e7e0af92272b767287fe5f6edc7)

Useful for:

* Example of a pure-Lua HTTP server running in DCS Hooks.
* JSON-based return value handling.
* Robustness patterns for parsing HTTP requests.

### 11.3 DCS Fiddle server

* Project:
  [https://github.com/JonathanTurnock/dcsfiddle](https://github.com/JonathanTurnock/dcsfiddle)

* Docs:
  [https://dcsfiddle.pages.dev/docs](https://dcsfiddle.pages.dev/docs)

Useful for:

* Another reference implementation of a DCS HTTP server (installed under `Saved Games\DCS\Scripts\Hooks`).
* Example architecture for “send Lua code to DCS over HTTP and return results”.
* Context for related tooling such as DCS Lua Runner MCP.

### 11.4 Example tools using similar patterns

* **DCS-BIOS Lua Console** – shows how to execute Lua code in `gui`, `export`, and `mission` states from an external UI:
  [https://dcs-bios.readthedocs.io/en/latest/lua-console.html](https://dcs-bios.readthedocs.io/en/latest/lua-console.html)

* **LotAtc server config for new DCS API security model** – example `autoexec.cfg` entries for `net.allow_unsafe_api` and `net.allow_dostring_in`:
  [https://www.lotatc.com/news/2025/07/23/Last-DCS-fix.html](https://www.lotatc.com/news/2025/07/23/Last-DCS-fix.html)

---

## 12. Summary

This design puts a **small, controlled HTTP server** into the DCS **server’s Hooks (userhooks) environment**, uses **`net.dostring_in("mission", ...)`** plus **`a_do_script`** to reach the mission scripting environment, and exposes a **whitelisted ATC API** (`ATC_API`) to external tools via JSON over HTTP.

Key properties:

* **Server-side only**: no client mods, no per-player setup.
* **Sandbox-preserving**: mission scripting environment retains its usual restrictions; unsafe APIs are only enabled in Hooks.
* **LLM-friendly**: external agents can inspect traffic and push tasks via a clean JSON REST API.
* **Extensible**: new ATC functions = new entries in `ATC_API.methods` and `routes[...]` without changing the cross-environment plumbing.

This single document captures the architecture and the main implementation patterns, and should be sufficient for an experienced Lua/DCS developer to build and extend the Smart ATC REST server.

```

You can now copy-paste that into `REST_design.md` locally and version it with the rest of the project.
::contentReference[oaicite:0]{index=0}
```
