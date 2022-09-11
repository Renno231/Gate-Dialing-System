local shell = require("shell")
local filesystem = require("filesystem")

local args, opts = shell.parse(...)

local options = "-"
for k,v in pairs(opts) do options = options..tostring(k) end
if opts.u then --update
    shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
    dofile("/home/installer.lua")
end
if filesystem.exists("/gds/clientinterface.lua") then
    shell.execute("/gds/clientinterface.lua")
elseif filesystem.exists("/gds/gatecomputer.lua") then
    shell.execute("/gds/gatecomputer.lua")
else
    io.stderr:write("GDS isn't installed.\n")
end
  