local shell = require("shell")
local filesystem = require("filesystem")

local args, opts = shell.parse(...)
local gdsFiles = {"/bin/gds.lua", "/gds/gatecomputer.lua","/lib/clientinterface.lua","/lib/guilist.lua","/lib/guiwindow.lua","/lib/guibutton.lua","/lib/guitextbox.lua"}

local gdsType = (filesystem.exists("/gds/clientinterface.lua") and "-c") or (filesystem.exists("/gds/gatecomputer.lua") and "-g")
local options = "-"
for k,v in pairs(opts) do options = options..tostring(k) end
if opts.u then --update
    if gdsType then
        if filesystem.exists("/home/installer.lua") then
            print("Running GDS installer...")
            shell.execute("/home/installer.lua "..gdsType)
        else
            local downloadedInstaller = shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
            if downloadedInstaller then
                print("Downloaded installer...\nRunning GDS installer...")
                shell.execute("/home/installer.lua "..gdsType)
            else
                os.exit()
            end
        end
    else
        print("Installation not detected.")
        os.exit(false)
    end
elseif (opts.c or opts.g) then
    if not filesystem.exists("/home/installer.lua") then
        shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
    end
    shell.execute("/home/installer.lua "..options)
elseif opts.d then --delete, need to add detection for autorun in /home/.shrc
    for i, address in ipairs (gdsFiles) do
        if filesystem.exists(address) then
            filesystem.remove(address)
            print("removed",address)
        end
    end
    if filesystem.exists("/etc/rc.d/gds.lua") then
        filesystem.remove("/etc/rc.d/gds.lua")
        shell.execute("rc gds disable")
        print("removed autostart")
    end
    print("uninstalled GDS files.")
end
if opts.a and gdsType then --autostart, include the shell.execute("install gds") to auto update GDS from floppy if its present
    local autorunFile = [[function start(msg)
local shell = require("shell") 
    do 
        shell.execute("/gds/%s.lua") 
    end
end]] 
    local file = io.open("/etc/rc.d/gds.lua", "w") 
    file:write(autorunFile:format(gdsType=="-c" and "clientinterface" or "gatecomputer")) 
    file:close()
    shell.execute("rc gds enable")
end     

if #args == 0 then
    if gdsType then
        shell.execute("/gds/"..(gdsType=="-c" and "clientinterface" or "gatecomputer")..".lua")
    else
        print("GDS isn't installed.\n")
    end
end