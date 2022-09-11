--[[
Created By: Renno231
Purpose: GDS installer
]]--

local component = require("component")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")
local term = require("term")
local gpu = component.gpu
local internet = nil
local HasInternet = component.isAvailable("internet")
local BranchURL = "https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/"
if HasInternet then 
    internet = require("internet") 
end

local args, opts = shell.parse(...)
if not HasInternet then
    io.stderr:write("No internet connection present. Insert an internet card to install.\n")
    os.exit(false)
end

local function downloadFile(fileName, directory)
    print("Downloading..."..fileName)
    local result = ""
    local response = internet.request(BranchURL..fileName)
    local success, err = pcall(function()
        local file, err = io.open((directory or "")..fileName, "w")
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
    io.write(" Yes/No: ")
    local userInput = io.read("*l")
    if (userInput:lower()):sub(1,1) ~= "y" then
        print("Cancelling installation...")
        os.exit(true)
    end
end

print("Retrieving files...")
if filesystem.exists("/gds/clientinterface.lua") then
    --pull latest and GUI libraries
    downloadFile("clientinterface.lua","/gds/")
    downloadFile("libraries/guilist.lua","/lib/")
    downloadFile("libraries/guiwindow.lua","/lib/")
    downloadFile("libraries/guitextbox.lua","/lib/")
    downloadFile("libraries/guibutton.lua","/lib/")
elseif filesystem.exists("/gds/gatecomputer.lua") then
    --pull latest 
    downloadFile("gatecomputer.lua","/gds/")
end
downloadFile("gds.lua","/bin/")
if opts.a then --autorun
    local file = io.open("/autorun.lua", "w")
    file:write([[require("shell").execute("/bin/gds.lua")]])
    file:close()
end

print([[
Installation complete!
Use the 'gds' system command to run the Gate Dialing System.
]])--^  add in some arguments

