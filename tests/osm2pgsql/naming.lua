-- A pure-Lua module that style.lua `require`s from the working directory.
local naming = {}

function naming.shout(name)
    return name and string.upper(name)
end

return naming
