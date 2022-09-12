--[[
Created By: Renno231
Purpose: GDS installer
]]--

local component = require("component")
local filesystem = require("filesystem")
local shell = require("shell")
local term = require("term")
local internet = nil
local hasInternet = component.isAvailable("internet")
local BranchURL = "https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/"
if hasInternet then 
    internet = require("internet") 
end

local args, opts = shell.parse(...)
if not hasInternet then
    io.stderr:write("No internet connection present. Insert an internet card to install.\n")
    os.exit(false)
end
if (opts.c==nil and opts.g==nil) or (opts.c and opts.g) then
    print("In order to install GDS you must run \n/home/installer.lua -c\nor /home/installer.lua -g\nThe -c option installs the user interface which can be used on a tablet whereas the -g option installs the gate computer program. Including an 'a' in the options will create the autorun file.")
    os.exit(false)
end

local function strsplit(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function downloadFile(filePath, directory)
    print("Downloading..."..filePath)
    local result = ""
    local response = internet.request(BranchURL..filePath)
    local fileName = strsplit(filePath,"/")
    local success, err = pcall(function()
        fileName = fileName[#fileName]
        local absolutePath = (directory or "")..fileName
        if type(directory)=="string" and directory~="" then
            if not filesystem.isDirectory(directory) then
                filesystem.makeDirectory(directory)
            end
        end
        local file, err = io.open(absolutePath, "w")
        if file == nil then error(err) end
        for chunk in response do
            file:write(chunk)
        end
        file:close()
    end)
    if not success then
        io.stderr:write("Unable to Download\n")
        io.stderr:write(err)
    end
end

-- Creates `/gds` directory, if it doesn't already exist
if not filesystem.isDirectory("/gds") then
    print("Creating \"/gds\" directory")
    local success, msg = filesystem.makeDirectory("/gds")
    if success == nil then
        io.stderr:write("Failed to created \"/gds\" directory, "..msg)
        os.exit(false)
    end
end

-- Checks for existing install, and prompt user if one is found
if filesystem.exists("/gds/clientinterface.lua") or filesystem.exists("/gds/gatecomputer.lua") then
    print("GDS is already installed, would you like to update?")
    term.setCursorBlink(true)
    io.write(" yes/no: ")
    local userInput = io.read("*l")
    if (userInput:lower()):sub(1,1) ~= "y" then
        print("Cancelling installation...")
        os.exit(true)
    end
end

print("Retrieving files...")
if (filesystem.exists("/gds/clientinterface.lua") and not filesystem.exists("/gds/gatecomputer.lua")) or opts.c~=nil then --c = controller
    --pull latest and GUI libraries
    --shell.setWorkingDirectory("/gds/")
    downloadFile("clientinterface.lua","/gds/")
    downloadFile("libraries/guilist.lua","/lib/")
    downloadFile("libraries/guiwindow.lua","/lib/")
    downloadFile("libraries/guitextbox.lua","/lib/")
    downloadFile("libraries/guibutton.lua","/lib/")
elseif (filesystem.exists("/gds/gatecomputer.lua") and not filesystem.exists("/gds/clientinterface.lua")) or opts.g~=nil then --g = gate
    --pull latest 
    --shell.setWorkingDirectory("/gds/")
    downloadFile("gatecomputer.lua","/gds/")
end
downloadFile("gds.lua","/bin/")
if opts.a then --autorun
    local file = io.open("/autorun.lua", "w") --why is this breaking things ?????
    file:write([[
local shell = require("shell")
local filesystem = require("filesystem")

if filesystem.exists("/bin/gds.lua") then
    shell.execute("/bin/gds.lua")
else
    print("GDS is not installed.\n")
end
    ]])
    file:close()
    print("Created /autorun.lua")
end

print([[
Installation complete!
Use the 'gds' system command to run the Gate Dialing System.
]])--^  add in some arguments
filesystem.remove("/home/installer.lua")