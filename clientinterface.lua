for i,v in pairs (package.loaded) do
    if i:sub(1,3)=="gui" then
        package.loaded[i] = nil
    end
end
--custom libraries
local windowapi = require("guiwindow")
local buttonapi = require("guibutton")
local textboxapi = require("guitextbox")
local listapi = require("guilist")

--OC libraries
local os = require("os")
local component = require("component")
local computer = require("computer")
local keyboard = require("keyboard")
local event = require("event")
local thread = require("thread")
local term = require("term")
local unicode = require("unicode")
local serialization = require("serialization")
local filesystem = require("filesystem")
local modem = component.modem
local gpu = component.gpu

--global variables
local GlyphsMW = {"Andromeda","Aquarius","Aries","Auriga","Bootes","Cancer","Canis Minor","Capricornus","Centaurus","Cetus","Corona Australis","Crater","Equuleus","Eridanus","Gemini","Hydra","Leo","Leo Minor","Libra","Lynx","Microscopium","Monoceros","Norma","Orion","Pegasus","Perseus","Pisces","Piscis Austrinus","Sagittarius","Scorpius","Sculptor","Scutum","Serpens Caput","Sextans","Taurus","Triangulum","Virgo"}
local GlyphsPG = {"Aaxel","Abrin","Acjesis","Aldeni","Alura","Amiwill","Arami","Avoniv","Baselai","Bydo","Ca Po","Danami","Dawnre","Ecrumig","Elenami","Gilltin","Hacemill","Hamlinto","Illume","Laylox","Lenchan","Olavii","Once El","Poco Re","Ramnon","Recktic","Robandus","Roehi","Salma","Sandovi","Setas","Sibbron","Tahnan","Zamilloz","Zeo"}
local DatabaseFile = "/gds/gateEntries.ff"
local SettingsFile = "/gds/settings.cfg"

local screensizex, screensizey = gpu.getResolution() --80, 25 
local freeMemoryPercent
local forceRestart = false
local isRunning, HadNoError = true, true
local lastKeyPressed = ""

local outputBuffer = {}
local commandBuffer = {}

local lastUser = nil
local lastEntry = nil
local database = {} -- all of the addresses
local history = {}
local lastReceived = {}

local defaultPort = 160
local settings = { --add a read and save ability
    chatBlacklist = {}; --for blocking specific players
    networkPort = defaultPort;
    localChat = true;
    autoAcceptSyncRequest = false;
    modemRange = 200;
    prefix = ";";
    autoLogToDatabase = true; --for auto query
    nearbyScanRate = 10; -- in seconds, only relevant if the above is true
    outputBufferSize = 120; --need to add scrolling
    commandBufferSize = 20; -- not yet implimented
    speedDial = true;
    lastDataBaseEntry = nil; --string; for smart loading of previous usage
    lastNearbyEntry = nil; --  ^ same 
}

--predeclaring variables
local databaseList, historyList, nearbyGatesList, processInput, recordToOutput

--thread handling
local threads = {} --threads.example = thread.create(function() end); threads.example:kill(); threads.example:suspend()

--utility functions

local function send(address, port, msg)
    modem.send(address, port, tostring(msg))
    --os.sleep(0.05)
end

local function gdssend(address, port, msg, cmdprefix)
    modem.send(address, port, "gds"..(cmdprefix or "")..serialization.serialize(msg))
end

local lastBroadcasted = 0
local function broadcast(port, msg)
    modem.broadcast(port, tostring(msg))
    lastBroadcasted = computer.uptime()
    os.sleep(0.05)
end

local function scanNearby()
    if computer.uptime()-lastBroadcasted > 1 then
        broadcast(settings.networkPort, string.format('gds{command = "query", user = {name = %q}}', lastUser or "unknown"))
    end
end

local function readSettingsFile()
    local file = io.open(SettingsFile, "r")
    if file == nil then return end
    file:close()
    local settingsOverride = dofile(SettingsFile)
    if type(settingsOverride) == "table" then
        for setting, value in pairs (settingsOverride) do
            if settings[setting]~=nil then
                if type(setting[setting]) == type(value) then
                    settings[setting] = value
                end
            end
        end
        settings.modemRange = math.min(math.max(tonumber(settings.modemRange) or 16, 16), 400)
        settings.networkPort = math.min(math.max(tonumber(settings.networkPort), 1),  65535)
    end
end
readSettingsFile()

local function writeSettingsFile()
    local file = io.open(SettingsFile, "w")
    recordToOutput("settings file"..tostring(file))
    file:write("local settings = "..serialization.serialize(settings).."\n\nreturn settings")
    file:close()
end

local function readDatabaseFile()
    local file = io.open(DatabaseFile, "r")
    if file == nil then
       file = io.open(DatabaseFile, "w")
    end
    file:close()
    databaseList.entries = {}
    historyList.entries = {}
    database, history = dofile(DatabaseFile)
    if database then
        for i, entry in ipairs(database) do
            databaseList:addEntry(entry.Name, nil, false)
        end
    else
        database = {}
    end
    if history then
        for i, entry in ipairs(history) do
            historyList:addEntry(entry.Name, nil, false)
        end
    else
        history = {}
    end
end

local function writeToDatabaseFile()
    local status, value = pcall(function() return threads.databaseWrite:status() end)
    if status == true then
        while threads.databaseWrite:status() ~= "dead" do os.sleep(0.05) end
    end
    threads.databaseWrite = thread.create(function()
        local file, msg = io.open(DatabaseFile, "w")
        file:write("database = {\n")
        for i, entry in ipairs(database) do
            file:write("    "..serialization.serialize(entry)..";\n")
        end
        file:write("}\n\nhistory = {")
        for i, entry in ipairs(history) do
            file:write("    "..serialization.serialize(entry)..";\n")
        end
        file:write("}\n\nreturn database, history")
        file:close()
    end)
end

local function findEntry(selector, addresstype) --address type is optional and only used when passing a whole address
    local foundEntry = nil
    local entryIndex = nil
    if type(tonumber(selector)) == "number" then
        selector = tonumber(selector)
        if selector <= #database and selector > 0 then
            foundEntry = database[selector]
            entryIndex = selector
        end
    elseif type(selector) == "string" then
        selector = string.gsub(selector, "_", " ")
        for i, entry in ipairs (database) do
            if (entry.Name:lower()==selector:lower() or entry.Name:sub(1, selector:len()):lower() == selector:lower()) or entry.uuid == selector then
                foundEntry = entry
                entryIndex = i
                break
            end
        end
    elseif type(selector) == "table" and type(addresstype) == "string" then
        local concatAdrs = table.concat(selector[addresstype], ", ")
        for i, entry in ipairs (database) do
            if entry.Address[addresstype] ~= nil then
                local concatEntry = table.concat(entry.Address[addresstype],", ")
                if (concatEntry:sub(1, concatAdrs:len()) == concatAdrs or concatAdrs:sub(1, concatEntry:len()) == concatEntry) then --check for POI?
                    foundEntry = entry
                    entryIndex = i
                    break
                end
            end
        end
    end
    return foundEntry, entryIndex
end

local function isValidGlyph(set, glyph)
    if type(set) == "string" then
        if set == "MW" then
            set = GlyphsMW
        elseif set == "PG" then
            set = GlyphsPG
        end
    end
    local isValid = false
    if set and glyph then
        for i, gly in ipairs(set) do
            if gly:sub(1, glyph:len()):lower() == glyph:lower() then -- gly:lower():gmatch(glyph:lower())then
                isValid = gly
                break
            end
        end
    end
    return isValid
end

local function getRealTime()
    local tmpFile = io.open("/tmp/.time", "w")
    tmpFile:write()
    tmpFile:close()
    return math.floor(filesystem.lastModified("/tmp/.time") / 1000)
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
--main code
term.clear()

--gateOperator window code start
local cmdbar = textboxapi.new(1, screensizey * 0.9 + 1, screensizex - 4)
local function resetcmdbar() 
    cmdbar.text=settings.prefix
    cmdbar:moveCursor(1)
    cmdbar:display()
end

local cmdbardefaulttxt="Press ; or click on the command bar to enter commands."
cmdbar:addText(cmdbardefaulttxt)
cmdbar:display()

local gateOperator = windowapi.Window.new("GateControl", screensizex * 0.33, screensizey * 0.9, 0, 0)
gateOperator:display()
local databaseTab = gateOperator:addTab("Database", nil, nil)
local historyTab = gateOperator:addTab("History", gateOperator.size.x, nil, 1)

databaseList = listapi.List.new("Database", gateOperator.size.x*0.8,  gateOperator.size.y*(10/23), gateOperator.pos.x+3, gateOperator.pos.y+2)
nearbyGatesList = listapi.List.new("Nearby", gateOperator.size.x*0.8,  gateOperator.size.y*(5/23), gateOperator.pos.x+3, gateOperator.pos.y + databaseList.size.y + 4)
historyList = listapi.List.new("History", gateOperator.size.x*0.8,   gateOperator.size.y*0.9, gateOperator.pos.x+1, gateOperator.pos.y+1)

local dialButton = buttonapi.Button.new(gateOperator.pos.x+3, gateOperator.pos.x + gateOperator.size.y - 3, 1, 1, "Dial", function() 
    if databaseList.currententry and nearbyGatesList.currententry then
        local gateA = nearbyGatesList.entries[nearbyGatesList.currententry]
        if gateA then
            processInput(lastUser, settings.prefix.."dial "..string.gsub(gateA," ","_").." "..databaseList.currententry) 
        end
    end
end)

local scanNearbyButton = buttonapi.Button.new(dialButton.xPos+7, dialButton.yPos, 1, 1, "Scan")
scanNearbyButton.func = function() 
    scanNearbyButton.disabled = true
    recordToOutput("Scanning for nearby gates in range "..settings.modemRange..".")
    nearbyGatesList.entries = {}
    nearbyGatesList:display()
    threads.scan = thread.create(scanNearby)
    event.timer(0.25, function() scanNearbyButton.disabled = false end)
    --button:hide() event.timer(0.25, function() button:display() end)
end

local closeGateButton = buttonapi.Button.new(scanNearbyButton.xPos+7, dialButton.yPos, 1, 1, "Close")
--function attached later on in code

databaseTab.func = function() 
    gateOperator:write(databaseList.pos.x-3, databaseList.pos.y-2, "|Database: "..#databaseList.entries)
    gateOperator:write(nearbyGatesList.pos.x-3, nearbyGatesList.pos.y-2, "|Nearby: "..#nearbyGatesList.entries)
    historyList:hide()
    databaseList:display()
    nearbyGatesList:display()
    dialButton:display()
    scanNearbyButton:display()
    closeGateButton:display()
end

historyTab.func = function() 
    databaseList.visible, nearbyGatesList.visible, dialButton.visible, scanNearbyButton.visible, closeGateButton.visible = false, false, false, false, false
    gateOperator:clear()
    historyList:display()
end

readDatabaseFile()
--gateOperator window code end

--output window code begin

local outputWindow = windowapi.Window.new("Output", screensizex * 0.67 - 2, screensizey * 0.9, screensizex * 0.33 + 1, 0)
outputWindow:display()
local function displayOutputBuffer()
    outputWindow:display()
    outputWindow:clear()
    local verticalheight = outputWindow.size.y
    local iterations = math.min(verticalheight, #outputBuffer)
    local count = 0
    for i=1, iterations do
        outputWindow:write(0, verticalheight-i, outputBuffer[i])
    end
end

function recordToOutput(...)
    local args = {...}
    if #args>0 then
        local windowWidth = math.floor(outputWindow.size.x-2)
        for index, arg in next, args do
            if #outputBuffer == settings.outputBufferSize then
                outputBuffer[settings.outputBufferSize] = nil
            end
            if type(arg)~="string" then
                arg = tostring(arg)
            end
            if arg:len() > windowWidth then
                for i=1, math.floor(arg:len()/windowWidth)+1 do
                    table.insert(outputBuffer, 1, arg:sub((i-1)* windowWidth + 1, i*windowWidth))
                end
            else
                table.insert(outputBuffer, 1, arg)
            end 
        end
        displayOutputBuffer()
    end
end

--output window code end

--command processing 
local commands = {
    clear = function(...) 
        outputBuffer = {}
        displayOutputBuffer()
        --return "Cleared output."
    end;
    set = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        --for i,a in next, args do recordToOutput(i..":"..type(a).." = "..tostring(a)) end
        if args[2] == "range" or args[2] == "radius" then
            local newrange = math.min(math.max(tonumber(args[3]) or 16, 16), 400)
            settings.modemRange = newrange
            modem.setStrength(newrange)
            returnstr = "Set modem range to "..tostring(settings.modemRange) -- "modem range = modemrange"
        elseif args[2] == "port" or args[2] == "channel" then
            if tonumber(args[3]) then
                modem.close(settings.networkPort)
                settings.networkPort = math.min(math.max(tonumber(args[3]), 1),  65535)
                modem.open(settings.networkPort)
                returnstr = "Set network port to "..settings.networkPort
            elseif args[3] == nil then
                if not modem.isOpen(defaultPort) then
                    modem.close(settings.networkPort)
                    settings.networkPort = defaultPort
                    modem.open(settings.networkPort)
                    returnstr = "Set network port to default "..tostring(defaultPort)
                end
            end
        elseif args[2] == "speed" then
            if args[3] == "on" or args[3] == "true" then
                settings.speedDial = true
                returnstr = "Set speed dial to "..tostring(settings.SpeedDial)
            elseif args[3] == "off" or args[3] == "false" then
                settings.speedDial = false
                returnstr = "Set speed dial to "..tostring(settings.SpeedDial)
            elseif args[3] == nil then
                settings.speedDial = not settings.SpeedDial
                returnstr = "Toggling speed dial to "..tostring(settings.SpeedDial)
            else
                returnstr = "'"..args[3].."' is not a valid state for speed"
            end
        end
        writeSettingsFile()
        return returnstr
    end;
    quit = function(...)
        local args = {...}
        isRunning = false
        if args[2] == "-r" then 
            forceRestart = true 
        end
    end;
    get = function(...) 
        local args = {...}
        local returnstr = "Insufficient arguments."
        --for i,a in next, args do recordToOutput(i..":"..type(a).." = "..tostring(a)) end
        if args[2] == "entries" and args[3] == "count" then
            if args[3] then
                returnstr = args[3] == "count" and "Total entries = "..#databaseList.entries or "'"..tostring(args[3]).."' is not a valid argument."
            end
        elseif args[2] == "entry" then
            if tonumber(args[3]) then
                args[3] = tonumber(args[3])
                if args[3] > 0 and args[3] <= #databaseList.entries then
                    returnstr = "Entry "..args[3].." = "..databaseList.entries[args[3]] --#database[args[3]].Name 
                else
                    returnstr = "Index out of bounds."
                end
            else
                returnstr = "Argument must be of type 'number'."
            end
        elseif args[2] == "port" or args[2] == "channel" then
            returnstr = "Current network port is "..settings.networkPort
        elseif args[2] == "battery" or args[2] == "charge" or args[2] == "energy" then
            local curEnergy = computer.energy()
            local maxEnergy = computer.maxEnergy()
            returnstr = "Battery remaining: "..math.floor(curEnergy).."/"..math.floor(maxEnergy).." ("..math.floor(100*(curEnergy/maxEnergy)).."%)"
        elseif args[2] == "mem" or args[2] == "memory" then
            returnstr = "Unused memory: "..tostring(math.floor((computer.freeMemory()/computer.totalMemory())*100)).."%"
        elseif args[2] == "radius" or args[2] == "range" then
            returnstr = "Current modem range is "..settings.modemRange
        elseif args[2] then
            returnstr = "Invalid sub-command: "..tostring(args[2])
        end
        return returnstr
    end;
    add = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if (args[2] == "address" or args[2] == "adrs" or args[2]=="entry") and type(args[3]) == "string" and (args[4] == "MW" or args[4] == "UN" or args[4] == "PG" or args[4] == "mw" or args[4] == "UN" or args[4] == "pg") then
            args[3] = string.gsub(args[3], "_", " ")
            local foundEntry = findEntry(args[3])
            local entryAddress = {args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12],}
            local validAddress = true
            local gateType = args[4]:upper()
            for i, glyph in ipairs (entryAddress) do
                validAddress = isValidGlyph(gateType, string.gsub(glyph, "_", " "))
                if validAddress then 
                    entryAddress[i] = validAddress
                else
                    returnstr = "Invalid address."
                    break 
                end
            end
            if #entryAddress > 5 and validAddress then --add POI check and addition if missing
                --[[local lastGlyph = entryAddress[#entryAddress]
                if lastGlyph ~= "Point of Origin" and lastGlyph~="Glyph 17" and lastGlyph~="Subido" then
                    table.insert(entryAddress, (gateType=="MW" and "Point of Origin") or (gateType=="UN" and "Glyph 17") or (gateType=="PG" and "Subido"))
                end ]]
                if foundEntry then
                    foundEntry.Address[gateType] = entryAddress
                    returnstr = "Successfully updated "..foundEntry.Name.." "..gateType.." address."
                else
                    local newEntry = {
                        Name = args[3];
                        Address = {
                            [gateType] = entryAddress;
                        };
                        IDCs = {};
                        Type = gateType;
                        UUID = "unknown";
                    }
                    table.insert(database, newEntry)
                    databaseList:addEntry(newEntry.Name)
                    writeToDatabaseFile()
                    returnstr = "Successfully added entry "..newEntry.Name.."."
                end
            else
                returnstr = "Invalid address."
            end
        elseif (args[2] == "idc" or args[2] == "IDC") and args[3] and args[4] then
            local foundEntry = findEntry(args[3])
            if type(foundEntry)=="table" then
                foundEntry.IDCs[args[4]] = args[5] or lastUser
                returnstr = 'Added IDC "'..args[4]..'" to entry '..foundEntry.Name
                writeToDatabaseFile()
            else
                returnstr = "Invalid entry/address: "..args[3]
            end
        elseif (args[2] == "uuid" or args[2] == "UUID") and args[3] and args[4] then
            local foundEntry = findEntry(args[3])
            if type(foundEntry)=="table" then
                foundEntry.UUID = args[4]
                returnstr = 'Added UUID "'..args[4]..'" to entry '..foundEntry.Name
                writeToDatabaseFile()
            else
                returnstr = "Invalid entry/address: "..args[3]
            end
        end
        return returnstr
    end;
    delete = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] then 
            local gateA, gateAIndex = findEntry(args[2])     
            if gateA then
                returnstr = "Removing entry "..gateA.Name.." at index "..gateAIndex
                table.remove(database, gateAIndex)
                nearbyGatesList:removeEntry(gateA.Name)
                databaseList:removeEntry(gateA.Name)
                writeToDatabaseFile()
                --if databaseList.visible then 
                    databaseList:display() 
                    nearbyGatesList:display() 
                --end
            end
        end
        return returnstr
    end;
    swap = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] and args[3] then
            local gateA, gateAIndex = findEntry(args[2])
            local gateB, gateBIndex = findEntry(args[3])
            returnstr = "Invalid arguments."
            if gateAIndex and gateBIndex then
                database[gateBIndex], databaseList.entries[gateBIndex] = gateA, gateA.Name
                database[gateAIndex], databaseList.entries[gateAIndex] = gateB, gateB.Name
                if gateAIndex == databaseList.currententry then 
                    databaseList.currententry = gateBIndex 
                end
                if databaseList.visible then
                    databaseList:display()
                end
                writeToDatabaseFile()
                returnstr = "Swapped "..gateA.Name.." with "..gateB.Name
            end
        end
        return returnstr
    end;
    move = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] and args[3] then
            local gateA, gateAIndex = findEntry(args[2])
            local newIndex = tonumber(args[3])
            if type(newIndex) == "number" then 
                newIndex = math.min(math.max(tonumber(args[3]), 1),  #database)
            end
            if gateAIndex and newIndex and gateAIndex ~=newIndex then
                table.remove(database, gateAIndex)
                table.insert(database, newIndex, gateA)
                if gateAIndex == databaseList.currententry then 
                    databaseList.currententry = newIndex 
                elseif newIndex == databaseList.currententry then
                    databaseList.currententry =  databaseList.currententry + (newIndex < gateAIndex and 1 or -1)
                end
                databaseList:removeEntry(gateAIndex)
                databaseList:addEntry(gateA.Name, newIndex) --addEntry(newstr, index, refresh)
                writeToDatabaseFile()
                returnstr = "Moved "..gateA.Name.." to "..newIndex
            end
        end
        return returnstr
    end;
    refresh = function(...)
        local returnstr = "Refreshed display."
        displayOutputBuffer()
        if databaseList.visible then 
            databaseList:display()
            nearbyGatesList:display()
        end
        
        return returnstr
    end;
    rename =  function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        local gateA, gateAIndex = findEntry(args[2])
        local newName = args[3]
        if gateA and type(newName) == "string" then
            newName = string.gsub(newName, "_", " ")
            returnstr = "Renaming entry "..gateA.Name.." at index "..gateAIndex.." to "..newName
            databaseList.entries[gateAIndex] = newName
            local isInNearby = nearbyGatesList:getIndexFromName(gateA.Name) 
            gateA.Name = newName
            if isInNearby then
                returnstr = "Renamed entry in nearbylist"
                nearbyGatesList.entries[isInNearby] = newName
                nearbyGatesList:display()
            end
            writeToDatabaseFile()
            if databaseList.visible then 
                databaseList:display()
            end
        end
        return returnstr
    end;
    dial = function(...) --need to add the 4th argument as a timer to close the gate, -1 signifies as long as possible, otherwise its in seconds default = 30
        local args = {...}
        local returnstr = "Insufficient arguments."
        local cmdPayload = 'gds{command="dial",args={fast='..tostring(settings.speedDial)..', user = {name="'..tostring(lastUser)..'"}, Address='
        local gateA, gateB
        if args[2] and args[3] then
            gateA = findEntry(args[2])
            gateB = findEntry(args[3])
        elseif args[2] and args[3] == nil then
            gateA = findEntry(nearbyGatesList.currententry or 1)
            gateB = findEntry(args[2])
        elseif args[2] == nil and args[3] == nil then
            if nearbyGatesList.currententry and databaseList.currententry then
                gateA = findEntry(nearbyGatesList.currententry)
                gateB = findEntry(databaseList.currententry)
            end
        end
        if gateA and gateB then
            if gateA.UUID=="unknown" or gateA.UUID == nil then
                returnstr = "Entry missing computer address."
            else
                threads.send= thread.create(send, gateA.UUID, settings.networkPort, cmdPayload..serialization.serialize(gateB.Address):sub(1).."}}")
                returnstr = "Dialing from "..gateA.Name.." to "..gateB.Name.."..."
                lastEntry = gateA
            end
        else
            returnstr = "Invalid argument(s)."
        end
        return returnstr
    end;
    close =  function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        local gateA = findEntry(args[2]) or lastEntry -- or findEntry(nearbyGatesList.currententry) or findEntry(databaseList.currententry)
        if gateA then
            threads.send= thread.create(send, gateA.UUID, settings.networkPort, 'gds{command="close", user = {name = "'..tostring(lastUser)..'"}}')
            returnstr = "Closing gate "..gateA.Name
            lastEntry = gateA
        else
            returnstr = "Unable to find entry."
        end
        return returnstr
    end;
    scan = function(...)
        local args = {...}
        nearbyGatesList.entries = {}
        nearbyGatesList:display()
        local returnstr = "Scanning for nearby gates..."
        threads.scan = thread.create(scanNearby)
        return returnstr
    end;
    sync = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        --for address or database syncing
        return returnstr
    end;
}
local function setAliases(func, ...)
    local args = {...}
    if type(func)=="function" then
        for i, alias in pairs (args) do
            commands[alias] = func
        end
    end
end
--command aliases
setAliases(commands.set,"s","st")
setAliases(commands.quit, "q", "exit")
setAliases(commands.clear, "c", "clr", "cls")
setAliases(commands.get, "g")
setAliases(commands.delete, "del", "remove", "rmv")
setAliases(commands.add, "new")
setAliases(commands.dial, "d")
setAliases(commands.rename, "rn")

function processInput(usr, inputstr)
    local timeran = "["..os.date("%H:%M", getRealTime()).."]"
    if inputstr:sub(1,1) == settings.prefix then
        local chunks = strsplit(inputstr, settings.prefix)
        for i, chunk in next, chunks do
            local args = strsplit(chunk, " ")
            local cmdfunction = commands[args[1]]
            local outputstring = " cmd: "..chunk
            if i == 1 then 
                outputstring = timeran..outputstring 
            else
                outputstring = "       "..outputstring  
            end
            recordToOutput(outputstring)
            if cmdfunction then
                args[1] = nil --removing the command name
                local succ, returndata = pcall(cmdfunction, table.unpack(args)) --could do returns here and deal with the output buffer, but not really necessary
                if returndata then
                    recordToOutput("          => "..returndata)
                end
            else
                recordToOutput("          => invalid command.")
            end
        end
   else
        local chatstr = timeran.." "..usr..": "..inputstr
        recordToOutput(chatstr)
   end
end
processInput("GDS", "Do ;help or ;cmds to see commands.")
modem.open(settings.networkPort)
-- end of command processing

--event listeners
local restrictedKeyCodes = {[14] = true; [15] = true; [28]=true; [29]=true; [42] = true; [54] = true; [56] = true; [58] = true}
local EventListeners = {
    modem_message = event.listen("modem_message", function(_, receiver, sender, port, distance, msg)
        if type(msg) == "string" then
            if msg:sub(1, 8) == "gdsgate{" and msg:sub(msg:len()) == "}" and msg:len() > 10 then
                local msgdata = load("return "..msg:sub(8))() --{gateType, address = {MW = ..., }, uuid = modem.address}
                local newGateType = msgdata.gateType
                local newAddress = msgdata.Address
                local timeReceived = computer.uptime()
                if msgdata.uuid then
                    lastReceived[msgdata.uuid] = lastReceived[msgdata.uuid] or timeReceived-6
                    if timeReceived - lastReceived[msgdata.uuid] > 5 then
                        lastReceived[msgdata.uuid] = timeReceived
                        recordToOutput("Receiving address data from.."..msgdata.uuid.." of type "..newGateType)
                        local existingEntry, _ = findEntry(msgdata.uuid) or findEntry(newAddress, newGateType) --add additional checks?
                        if existingEntry then
                            local returnstr = "Found existing entry "..existingEntry.Name.." from scan."
                            if existingEntry.UUID ~= msgdata.uuid then
                                existingEntry.UUID = msgdata.uuid
                                returnstr = returnstr.." Updated UUID."
                            end
                            for glyphset, adrs in pairs (newAddress) do
                                if glyphset == "MW" or glyphset == "PG" or glyphset == "UN" then
                                    if existingEntry.Address[glyphset] then
                                        if #adrs < 10 then
                                            if #adrs > #existingEntry.Address[glyphset] then
                                                existingEntry.Address.MW = newAddress.MW
                                                returnstr = returnstr.." Updated MW Address."
                                            end
                                        else
                                            returnstr = returnstr .. " Failure to sync, too many glyphs: "..#adrs.."."
                                        end
                                    else
                                        existingEntry[glyphset] = adrs
                                        returnstr = returnstr.." Added "..glyphset.." Address."
                                    end
                                else
                                    returnstr = returnstr.." Invalid glyph-set: "..glyphset.."."
                                end
                            end
                            writeToDatabaseFile()
                            recordToOutput(returnstr)
                        else
                            local newEntry = {
                                Name = msgdata.Name or msgdata.uuid;
                                Address = newAddress;
                                IDCs = {};
                                Type = newGateType;
                                UUID = msgdata.uuid;
                            }
                            table.insert(database, newEntry)
                            databaseList:addEntry(newEntry.Name)
                            writeToDatabaseFile()
                            existingEntry = newEntry
                            recordToOutput("Added new entry "..newEntry.Name.." from scan.")
                        end
                        if nearbyGatesList:getIndexFromName(existingEntry.Name)==nil then 
                            nearbyGatesList:addEntry(existingEntry.Name)
                        end
                        if gateOperator.currenttab == 1 then
                            gateOperator:write(databaseList.pos.x-3, databaseList.pos.y-2, "|Database: "..#databaseList.entries)
                            gateOperator:write(nearbyGatesList.pos.x-3, nearbyGatesList.pos.y-2, "|Nearby: "..#nearbyGatesList.entries)
                        end
                    end
                end
            end
        end
    end),
    key_down = event.listen(
        "key_down",
        function(_, keyboardAddress, chr, code, playerName)
            lastUser = playerName
            local key = keyboard.keys[code]
            local uckey = unicode.char(chr)
            if key == "semicolon" and not cmdbar.selected then
                cmdbar.selected = true
                resetcmdbar()
            elseif cmdbar.selected and key then
                if key == "enter" then
                    processInput(playerName, cmdbar.text)
                    displayOutputBuffer()
                    resetcmdbar()
                elseif key == "right" then
                    cmdbar:moveCursor(1)
                elseif key == "left" then
                    cmdbar:moveCursor(-1)
                elseif key == "semicolon" then
                    cmdbar:addText(";")
                elseif key == "back" then
                    cmdbar:trim()
                elseif key == "delete" then
                    cmdbar:trim(1)
                elseif code < 129 and not restrictedKeyCodes[code] then --or tonumber(key)
                    if keyboard.isShiftDown() then
                       uckey = uckey:upper()
                    end
                    cmdbar:addText(uckey)
                end
                lastKeyPressed = key.." ("..uckey..")"
                cmdbar:display()
            end
        end
    ),
    touch = event.listen(
        "touch",
        function(_, screenAddress, x, y, button, playerName)
            local status, err =
                xpcall(
                function()
                    --term.setCursor(0, 0)
                    lastUser = playerName
                    if button == 0 then
                        for i, button in ipairs(buttonapi.Buttons) do
                            if button:touch(x, y) then
                                break
                            end
                        end
                        gateOperator:touch(x, y)
                        --local prevDisplayStart = databaseList.displaystart
                        local dbListEntry = databaseList:touch(x, y)
                        local nearbyListEntry = nearbyGatesList:touch(x, y)
                        local cmdbartouched = cmdbar:touch(x, y)
                        if cmdbartouched and cmdbar.text == cmdbardefaulttxt then 
                            resetcmdbar()
                        elseif not cmdbartouched and (cmdbar.text == settings.prefix or cmdbar.text == "") then
                            cmdbar.text = cmdbardefaulttxt
                            cmdbar:display()
                        end
                    end
                end,
                debug.traceback
            )
            --if err ~= nil then ErrorMessage = err end
            HadNoError = status
            if not HadNoError then
                term.clear()
                print(err)
            end
        end
    ),
    scroll = event.listen("scroll", function(_, screenAddress, x, y, direction, playerName)
        for i, lst in ipairs (listapi.Lists) do
            if lst:touch(x, y, true) then
                lst:scroll(-direction)
            end
        end
    end),
    interruptedEvent = event.listen(
        "interrupted",
        function()
            isRunning = false
        end
    )
}

closeGateButton.func = commands.close
gateOperator:selectTab("Database")
scanNearby() --first scan to check where things are
--main loop to keep it from returning to the terminal
while isRunning and HadNoError do
    os.sleep(0.25)
end

--program cleanup
for eventname, listener in pairs(EventListeners) do
    event.cancel(listener)
end
EventListeners = nil

for name, thread in pairs(threads) do
    thread:kill()
end
threads = nil

for i, win in ipairs(windowapi.CurrentWindows) do
    win = nil
end

for i, butt in ipairs(buttonapi.Buttons) do
    butt = nil
end

if HadNoError then
    term.clear()
end
for i,v in pairs (package.loaded) do
    if i:sub(1,3)=="gui" then
        package.loaded[i] = nil
    end
end
if forceRestart then
    dofile("/bin/gds.lua")
end