---BEGIN-ATCSERVER-MISSION-SCRIPTING-HELPER---
-- insert this block into %DCS_INSTALL%/Scripts/MissionScripting.lua above:
-- --Sanitize Mission Scripting environment

if http == nil then _G.http = {} end

-- http.a_do_scriturn() requires io.open() and lfs.tempdir(). however, these
-- functions are sanitized below for security reasons and not available within
-- the mission scripting environment. disabling the sanitization renders DCS
-- vulernable to exploits, including the execution of arbitrary code with the
-- permissions of the user account that runs DCS.
-- instead of disabling sanitization, create locals that contain the required
-- function (or its static return value). these locals go out of scope at the
-- end of this file, but are captured by http.a_do_scriturn(), because Lua
-- is lexically scoped: https://www.lua.org/pil/6.1.html

local _open = io.open
local _temp = lfs.tempdir() .. "ATCServer.a_do_script.tmp"

-- pcall() wrapper that serializes return value or error message into file as
-- a workaround for a_do_script() lacking return value pass-thru.
function http.a_do_scriturn(func, maxdepth)
    local file, err = _open(_temp, "w")
    if file == nil then
        log.write("MissionScripting.lua", log.ERROR, string.format("ATCServer: error opening %q: %s", _temp, err))
        return
    end

    local success, result_or_errmsg = pcall(func)
    if success then
        file:write(result_or_errmsg)
    else
        file:write('{"ok":false,"function":"a_do_scriturn","error":"%s"}', tostring(result_or_errmsg))
    end
    file:close()
end
---END-ATCSERVER-MISSION-SCRIPTING-HELPER---