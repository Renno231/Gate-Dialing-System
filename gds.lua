local shell = require("shell")
local filesystem = require("filesystem")
local component = require("component")
local args, opts = shell.parse(...)
local gdsFiles = {"/bin/gds.lua", "/gds/gatecomputer.lua","/lib/clientinterface.lua","/lib/guilist.lua","/lib/guiwindow.lua","/lib/guibutton.lua","/lib/guitextbox.lua"}

local gdsType = (filesystem.exists("/gds/clientinterface.lua") and "-c") or (filesystem.exists("/gds/gatecomputer.lua") and "-g")
local optionsString = "-"
for k,v in pairs(opts) do optionsString = optionsString..tostring(k) end

if args[1] == "update" then --update
    if not component.isAvailable("internet") then
        print("Internet card is required to update.") --plans to change this in the future
        os.exit(false)
    elseif gdsType then
        if filesystem.exists("/home/installer.lua") then
            print("Running GDS installer...")
            shell.execute("/home/installer.lua "..gdsType)
        else
            local downloadedInstaller = shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
            if downloadedInstaller then
                print("Downloaded installer...\nRunning GDS installer...")
                shell.execute("/home/installer.lua "..gdsType)
            else
                print("Failed to download installer", downloadedInstaller)
                os.exit()
            end
        end
    else
        print("GDS installation not detected.")
        os.exit(false)
    end
end
if (opts.c or opts.g) then
    if not filesystem.exists("/home/installer.lua") then
        shell.execute("wget -f https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/installer.lua")
    end
    shell.execute("/home/installer.lua "..optionsString)
    gdsType = (filesystem.exists("/gds/clientinterface.lua") and "-c") or (filesystem.exists("/gds/gatecomputer.lua") and "-g")
end
if args[1] == "uninstall" then --delete
    print("Uninstalling GDS...")
    for i, address in ipairs (gdsFiles) do
        if filesystem.exists(address) then
            filesystem.remove(address)
            print("     > Removed",address)
        end
    end
    if filesystem.exists("/etc/rc.d/gds.lua") then
        filesystem.remove("/etc/rc.d/gds.lua")
        shell.execute("rc gds disable")
        print("     > Removed autostart.")
    end
    print("Uninstalled Gate Dialing System files.")
    os.exit()
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

if gdsType and args[1] == "floppy" then
    local transfer = require("tools/transfer")
    if args[2] == nil then
        io.write([[Usage: gds floppy <to>
        <to> = the first 3 characters of a floppy disks uuid. e.g. "gds floppy 7c6"
        Note: After the floppy has been setup, to use the floppy for GDS installation you MUST set the floppy to READONLY. 
              This can be done by right clicking the air with the floppy to open the floppy disk menu.]])
        os.exit()
    end
    --do a check to see if the drive is blank
    local floppyPath = "/mnt/"..args[2]
    if filesystem.exists(floppyPath) then
        if filesystem.list(floppyPath)() ~= nil then
            print("Provided directory is not empty, do you wish to continue? (Could cause data loss)\n[Y/n]")
            if not ((io.read() or "n") .. "y"):match("^%s*[Yy]") then
                print("Cancelled GDS floppy installation.")
                os.exit()
            end
        end
        --check if its read only
    else
        print("Floppy not found at "..floppyPath)
        os.exit()
    end
    local success = transfer.batch({"/", floppyPath}, {cmd="cp",r=true,u=true,P=true,v=true,skip={"/mnt","/dev","/usr","/home"}})
    if success then
        local function writeFile(path, str)
            if not path then return "No path." end
            if not str then return "No source." end
            if (not path and str) then return end
            local file = io.open(path, "w")
            if not file then return "No file." end
            file:write(str)
            file:close()
            return true
        end
        local function replaceLine(path, lines)
            if not path then return "Must provide file" end
            if not filesystem.exists(path) then return "File not found." end
            if not lines then return "Must specify lines to replace" end
            local file = io.open(path, "r")
            if not file then return "Unable to read file "..path end
            local bfr, read, line = "", nil, 1
            repeat
                read = file:read()
                local replacement = lines[line]
                if read or replacement then bfr = bfr .. tostring(replacement or read) .. "\n" end
                line = line + 1
            until not read
            bfr = bfr:sub(1, bfr:len()-1)
            file:close()
            file = io.open(path, "w")
            file:write(bfr)
            file:close()
        end
        
        filesystem.makeDirectory(floppyPath.."/home")
        replaceLine(floppyPath.."/lib/core/install_basics.lua", {[212] = "",[213] = "",[214] = "",[215] = "",[216] = "",})
        shell.execute("label "..floppyPath.." GDSInstaller")
        if filesystem.exists(floppyPath.."/etc/rc.d/gds.lua") then
            print("/etc/rc.cfg:", writeFile(floppyPath.."/etc/rc.cfg", 'enabled = {}') )
        end
        local customAuto = 'local component = require("component") if not component.isAvailable("keyboard") or not component.isAvailable("screen") then dofile("/bin/install.lua") end'
        print("Autorun:", writeFile(floppyPath.."/autorun.lua", customAuto))
        local customInstaller = 
[==[local options = _ENV.install
local filesystem, computer, transfer, devfs = require("filesystem"), require("computer"), require("tools/transfer"), require("devfs")
if computer.freeMemory() < 50000 then print("Low memory, collecting garbage") os.sleep(1) end
require("term").clear()
if filesystem.list(options.to)() ~= nil then
    io.write("Installation destination "..options.to.." is not empty, do you wish to continue? [Y/n]\n")
    if not ((io.read() or "n") .. "y"):match("^%s*[Yy]") then
        io.write("Installation cancelled\n")
        os.exit()
    end
end
--check if options.to is empty with filesystem.list(), if not, prompt user input with a beep
print("Running custom GDS installer.")
local copied = transfer.batch({options.from, options.to}, {cmd="cp",r=true,u=true,P=true,v=true,skip={"/mnt","/dev","/.install","/autorun.lua","/.prop","/usr/man","/usr/misc"}})
if copied ~= 0 then computer.beep(125, 2) print("File installation failed.") os.exit() else computer.beep() print("Primary files copied.") end
local proxy, reason = devfs.getDevice(options.to)
local succ, err = pcall(devfs.setDeviceLabel, proxy, "GateComputer")
if not succ then print("Failed to label drive: "..err) else print("Labeled gate computer drive.") end
computer.setBootAddress(options.to)
if computer.getBootAddress() == options.to then print("Boot address set to " .. options.to) else print("Failed to set boot address.") end
filesystem.makeDirectory("/home")
if filesystem.exists(options.to.."/etc/rc.cfg") then
    local file = io.open(options.to.."/etc/rc.cfg", "w") file:write('enabled = {"gds"}') file:close()
end
local function replaceLine(path, lines)
    if not path then return "Must provide file" end
    if not filesystem.exists(path) then return "File not found." end
    if not lines then return "Must specify lines to replace" end
    local file = io.open(path, "r")
    if not file then return "Unable to read file "..path end
    local bfr, read, line = "", nil, 1
    repeat
        read = file:read()
        local replacement = lines[line]
        if read or replacement then bfr = bfr .. tostring(replacement or read) .. "\n" end
        line = line + 1
    until not read
    bfr = bfr:sub(1, bfr:len()-1)
    file:close()
    file = io.open(path, "w")
    file:write(bfr)
    file:close()
    return true
end
local repaired = replaceLine(options.to.."/lib/core/install_basics.lua", {[212]=[[io.write("Install " .. source_display .. special_target .. "? [Y/n] ")]],[213] = [[if not ((io.read() or "n") .. "y"):match("^%s*[Yy]") then]],[214] = [[io.write("Installation cancelled\n")]],[215] = "os.exit()",[216] = "end"})        
print((repaired==true and "Repaired" or "Failed to repair").." /lib/core/install_basics.lua")
print("Installation completed.\nRemove GDS installation floppy to continue.")
for i=1,2 do computer.beep() end
local _n, floppyRemoved = false
local floppyUUID = filesystem.get(options.from).address
repeat 
    _n, floppyRemoved = require("event").pull(math.huge, "component_removed")
    floppyRemoved = floppyRemoved == floppyUUID
until floppyRemoved
computer.beep()
computer.shutdown(true)]==]
        local installerFile = writeFile(floppyPath.."/.install", customInstaller)
        print(".install:", installerFile) 
        print(installerFile == true and "Finished GDS installation floppy. Don't forget to set to read only (right click the air)." or "GDS floppy setup failed:"..installerFile)
    else

    end
    os.exit()
end

if #args == 0 then
    if gdsType then
        shell.execute("/gds/"..(gdsType=="-c" and "clientinterface" or "gatecomputer")..".lua")
    else
        print([["GDS not installed. Usage:\n
        Options
         -g: gate computer
         -c: client interface
         -a: autostart
        Arguments
         update
         uninstall
         floppy <to> (do "gds floppy" for more information)
        "]])
    end
end