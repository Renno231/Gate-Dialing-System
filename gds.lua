local shell = require("shell")
local filesystem = require("filesystem")

local args, opts = shell.parse(...)
local gdsFiles = {"/bin/gds.lua", "/gds/gatecomputer.lua","/lib/clientinterface.lua","/lib/guilist.lua","/lib/guiwindow.lua","/lib/guibutton.lua","/lib/guitextbox.lua"}

local options = "-"
for k,v in pairs(opts) do options = options..tostring(k) end
if opts.u then --update
    local gdsType = (filesystem.exists("/gds/clientinterface.lua") and "-c") or (filesystem.exists("/gds/gatecomputer.lua") and "-g")
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
elseif opts.i then --import AGS addresses

elseif opts.d then --delete, need to add detection for autorun in /home/.shrc
    for i, address in ipairs (gdsFiles) do
        if filesystem.exists(address) then
            filesystem.remove(address)
        end
    end
end
if opts.a then --autostart
    if filesystem.exists("/home/.shrc") then
        local line, foundGDSAuto = nil, false
        local file, reason = io.open("/home/.shrc")
        repeat
            local line = file["readLine"](file, false)
            if line then
                foundGDSAuto = line=="/bin/gds.lua"
            end
        until not line or foundGDSAuto
        file:close()
        if not foundGDSAuto then
            file, reason = io.open("/home/.shrc", "a")
            file:write("/bin/gds.lua")
            file:close()
            print("Created autorun for GDS.")
        else
            print("GDS is already autorun.")
        end
    else
        local file, reason = io.open("/home/.shrc", "w")
        file:write("/bin/gds.lua")
        file:close()
        print("Created autorun for GDS.")
    end
    print("To remove GDS from autorun, edit the /home/.shrc file and remove the line with /bin/gds.lua")
end
if filesystem.exists("/gds/clientinterface.lua") then
    shell.execute("/gds/clientinterface.lua")
elseif filesystem.exists("/gds/gatecomputer.lua") then
    shell.execute("/gds/gatecomputer.lua")
else
    io.stderr:write("GDS isn't installed.\n")
end
  