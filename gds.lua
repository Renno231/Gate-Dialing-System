local shell = require("shell")
local filesystem = require("filesystem")

local args, opts = shell.parse(...)
local gdsFiles = {"/bin/gds.lua", "/gds/gatecomputer.lua","/lib/clientinterface.lua","/lib/guilist.lua","/lib/guiwindow.lua","/lib/guibutton.lua","/lib/guitextbox.lua","/autorun.lua"}
    
local options = "-"
for k,v in pairs(opts) do options = options..tostring(k) end
if opts.u then --update
    local gdsType = (filesystem.exists("/gds/clientinterface.lua") and "-c") or (filesystem.exists("/gds/gatecomputer.lua") and "-g")
    if gdsType then
        for i, address in ipairs (gdsFiles) do
            if filesystem.exists(address) then
                print("Removed "..address..": "..tostring(filesystem.remove(address)))
            end
        end
        print(shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua"))
        shell.execute("/home/installer.lua "..gdsType)
    else
        print("Installation not detected.")
        os.exit(false)
    end
elseif (opts.c or opts.g) then
    if not filesystem.exists("/home/installer.lua") then
        shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
    end
    shell.execute("/home/installer.lua "..options)
elseif opts.i then --install AGS addresses

elseif opts.d then --delete
    for i, address in ipairs (gdsFiles) do
        if filesystem.exists(address) then
            filesystem.remove(address)
        end
    end
end
if opts.a then --autostart

end
if filesystem.exists("/gds/clientinterface.lua") then
    shell.execute("/gds/clientinterface.lua")
elseif filesystem.exists("/gds/gatecomputer.lua") then
    shell.execute("/gds/gatecomputer.lua")
else
    io.stderr:write("GDS isn't installed.\n")
end
  