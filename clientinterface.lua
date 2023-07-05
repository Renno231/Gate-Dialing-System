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
local textLib = require("text")
local uuid = require("uuid")
local modem = component.modem
local gpu = component.gpu

--global variables
local GlyphsMW = {"Andromeda","Aquarius","Aries","Auriga","Bootes","Cancer","Canis Minor","Capricornus","Centaurus","Cetus","Corona Australis","Crater","Equuleus","Eridanus","Gemini","Hydra","Leo","Leo Minor","Libra","Lynx","Microscopium","Monoceros","Norma","Orion","Pegasus","Perseus","Pisces","Piscis Austrinus","Sagittarius","Scorpius","Sculptor","Scutum","Serpens Caput","Sextans","Taurus","Triangulum","Virgo"}
local GlyphsPG = {"Aaxel","Abrin","Acjesis","Aldeni","Alura","Amiwill","Arami","Avoniv","Baselai","Bydo","Ca Po","Danami","Dawnre","Ecrumig","Elenami","Gilltin","Hacemill","Hamlinto","Illume","Laylox","Lenchan","Olavii","Once El","Poco Re","Ramnon","Recktic","Robandus","Roehi","Salma","Sandovi","Setas","Sibbron","Tahnan","Zamilloz","Zeo"}
local DatabaseFile = "/gds/gateEntries.ff"
local SettingsFile = "/gds/settings.cfg"
local cmdResPrefix = "          ⤷ "
local cmdResWSpace = "            " --⤹

local screensizex, screensizey = gpu.getResolution() --80, 25 
local forceRestart = false
local isRunning, HadNoError = true, true
local lastKeyPressed = ""

local outputBuffer = {} --scrolling?
local commandBuffer = {} --todo

local lastEntry, lastTimeUsed = nil, computer.uptime()
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
    dialSpeed = 10;
    lastDataBaseEntry = nil; --string; for smart loading of previous usage
    lastNearbyEntry = nil; --  ^ same 
    defaultGateTimeout = 30;
    owner = "";
    lastUser = nil;
    powerSaving = true;
}

--predeclaring variables
local commands, databaseList, historyList, nearbyGatesList, processInput, recordToOutput

--thread handling
local threads = {} --threads.example = thread.create(function() end); threads.example:kill(); threads.example:suspend()

--utility functions

local function send(address, port, msg)
    modem.send(address, port, tostring(msg))
    --os.sleep(0.05)
end

local function gdssend(address, port, msg, cmdprefix)
    modem.send(address, port, "gdswakeup", "gds"..(cmdprefix or "")..serialization.serialize(msg))
end

local lastBroadcasted = 0
local function broadcast(port, msg)
    modem.broadcast(port, "gdswakeup", tostring(msg))
    lastBroadcasted = computer.uptime()
end

local function readSettingsFile()
    local file = io.open(SettingsFile, "r")
    if file == nil then return end
    file:close()
    local settingsOverride = dofile(SettingsFile)
    if type(settingsOverride) == "table" then
        for setting, value in pairs (settingsOverride) do
            if settings[setting]~=nil then
                if type(settings[setting]) == type(value) then
                    settings[setting] = value
                end
            end
        end
        settings.modemRange = math.min(math.max(tonumber(settings.modemRange) or 16, 16), 400)
        modem.close(settings.networkPort)
        settings.networkPort = math.min(math.max(tonumber(settings.networkPort), 1),  65535)
        modem.setStrength(settings.modemRange)
        modem.open(settings.networkPort)
    end
end
readSettingsFile()

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

local function writeSettingsFile()
    local file = io.open(SettingsFile, "w")
    --recordToOutput("settings file"..tostring(file))
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
            if (entry.Name:lower()==selector:lower() or entry.Name:sub(1, selector:len()):lower() == selector:lower()) or entry.UUID == selector then
                foundEntry = entry
                entryIndex = i
                break
            end
        end
    elseif type(selector) == "table" and type(addresstype) == "string" then
        local concatAdrs = table.concat(selector[addresstype], ", ")
        if concatAdrs~="" then
            for i, entry in ipairs (database) do
                if entry.Address[addresstype] ~= nil then
                    local concatEntry = table.concat(entry.Address[addresstype],", ")
                    if concatEntry~="" and (concatEntry:sub(1, concatAdrs:len()) == concatAdrs or concatAdrs:sub(1, concatEntry:len()) == concatEntry) then --check for POI?
                        foundEntry = entry
                        entryIndex = i
                        break
                    end
                end
            end
        end
    end
    return foundEntry, entryIndex
end

local function isValidGlyph(set, glyph)
    local isValid = false
    if type(set) == "string" then
        if set == "MW" then
            set = GlyphsMW
        elseif set == "PG" then
            set = GlyphsPG
        elseif set == "UN" then
            local glyphsplit = strsplit(glyph)
            local UNglyph = tonumber(glyphsplit[2] or "")
            if UNglyph then
                if UNglyph > 0 and UNglyph < 37 then
                    isValid = true
                end
            end
        end
    end
    if set and glyph and set~="UN" then
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

local optionEquivalence = {
    ["open"] = true,
    ["closed"] = false,
    ["close"] = false,
    ["on"] = true,
    ["off"] = false,
    ["true"] = true ,
    ["false"] = false,
}

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

--function attached later on in code
local dialButton = buttonapi.Button.new(gateOperator.pos.x+3, gateOperator.pos.x + gateOperator.size.y - 3, 1, 1, "Dial")
local scanNearbyButton = buttonapi.Button.new(dialButton.xPos+7, dialButton.yPos, 1, 1, "Scan")
local closeGateButton = buttonapi.Button.new(scanNearbyButton.xPos+7, dialButton.yPos, 1, 1, "Close")

databaseTab.func = function() 
    historyList:hide()
    databaseList:display()
    nearbyGatesList:display()
    dialButton:display()
    scanNearbyButton:display()
    closeGateButton:display()
    gateOperator:write(databaseList.pos.x-3, databaseList.pos.y-2, "|Database: "..#databaseList.entries)
    gateOperator:write(nearbyGatesList.pos.x-3, nearbyGatesList.pos.y-2, "|Nearby: "..#nearbyGatesList.entries)
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

--could use unlimited size array,  but would need to unset any unneeded info (outputBuffer[index] = nil)
--then iterate with while loop and line counting to account for blanks (bufferViewIndex = int, starting index of where draw from the buffer)
--though for security, since process IDs will be integers corresponding to outputBuffer, make a pointer to the entry which is attached to the command inside of the process table
local bufferViewLineIndex = 1
local processLookup = {} --[processID] = processTable, table.insert(outputBuffer, 1, processTable)
local function displayOutputBuffer()
    local windowWidth = math.floor(outputWindow.size.x-2)
    outputWindow:display()
    outputWindow:clear()
    local verticalheight = outputWindow.size.y
    local maxLines = math.min(verticalheight, #outputBuffer)
    local bufferIndex, currentLineIndex = 1, 1
    local windowYValue = verticalheight-currentLineIndex
    
    local function processBuffer(bufferStr)
        if bufferStr then --if bufferstr:match(cmdresponseprefix) then prefix with spaces?
            if type(bufferStr)~="string" then bufferStr = tostring(bufferStr) end
            if bufferStr:len() > windowWidth then
                local isCmdRes = bufferStr:match(cmdResPrefix)
                local currentStringHeight, totalStringHeight = 1, math.ceil(bufferStr:len() / windowWidth) --+ 1
                local success, remainderString, wrappedResult = true, bufferStr, nil 
                maxLines = math.min(verticalheight, maxLines + totalStringHeight - 1)
                repeat 
                    windowYValue = (verticalheight - totalStringHeight) + currentStringHeight - currentLineIndex
                    wrappedResult, remainderString, success = textLib.wrap((isCmdRes and currentStringHeight > 1 and cmdResWSpace or "")..remainderString, windowWidth+2, windowWidth+2)
                    if remainderString and remainderString:sub(1,1) ~= " " then
                        remainderString = " "..remainderString
                    end
                    if wrappedResult then
                        outputWindow:write(0, windowYValue, wrappedResult)
                        currentStringHeight = currentStringHeight + 1
                    end
                until not success or (currentStringHeight + currentLineIndex - 1 > maxLines)
                currentLineIndex = currentLineIndex + totalStringHeight
            else
                windowYValue = verticalheight - currentLineIndex-- + 1
                outputWindow:write(0, windowYValue, bufferStr)
                currentLineIndex = currentLineIndex + 1
            end
        end
    end
    while currentLineIndex <= maxLines do --max lines is a problem, 
        local bufferVal = outputBuffer[bufferIndex]
        local valType = type(bufferVal)
        if valType == "table" then
            local processListSize = #bufferVal.list
            if processListSize > 0 then 
                maxLines = math.min(verticalheight, maxLines + processListSize - 1) --very important -1!
                for i= processListSize, 1, -1 do
                    processBuffer(bufferVal.list[i])
                end
            end
        else
            processBuffer(bufferVal)
        end 
        bufferIndex = bufferIndex + 1
    end
end

function recordToOutput(...)
    local args = {...}
    if #args>0 then
        for index, arg in next, args do
            local argtype = type(arg)
            if #outputBuffer == settings.outputBufferSize then
                if argtype == "table" then
                    processLookup[arg.processID] = nil
                end
                outputBuffer[settings.outputBufferSize] = nil
            end
            if argtype == "table" then
                table.insert(outputBuffer, 1, arg)
                processLookup[arg.processID] = arg
            else
                if type(arg)~="string" then
                    arg = tostring(arg)
                end
                table.insert(outputBuffer, 1, arg)
            end 
        end
        displayOutputBuffer()
    end
end
--recordToOutput{processID = 'hmm', list = {"1this is a list", "2trying to read from the list", "3beep boop"}}
--output window code end
local commandDescriptions = {
    clear = "empties output buffer";
    set = "modifies GDS settings such as modem range/radius, port/channel, and default dialing speed. e.g. set speed 10. Another example, set entry entryName/index iris open/closed/toggle.";
    quit = "closes GDS";
    get = "returns information about current settings such as remaining battery, network port, wireless range, etc";
    import = "imports AGS entries from /ags/gateEntries.ff";
    add = "creates or modifies entries, entry IDCs, and entry UUIDs";
    delete = "deletes an entry by name or position";
    swap = "swaps two entries by name or position";
    move = "moves an entry by name or position to a new position";
    refresh = "refreshes GDS user interface.";
    rename = "renames an entry by name or position to the given name, new names must use _ in the place of any spaces";
    dial = "requests a given entry's computer to dial another given entry";
    close = "requests a given entry's computer to close its gate";
    scan = "scans for nearby GDS gate computers";
    sync = "not yet implimented. shares entries from one GDS client to another";
    edit = "modifies a given entry by name or position";
}

local function generateCmdPayload(command, args)
    return {command = command, processID = uuid.next(), issued = computer.uptime(), args = args or {}, user = {name = tostring(settings.lastUser)}}
end
--command processing 
commands = {
    clear = function(...) 
        outputBuffer = {}
        displayOutputBuffer()
        --return "Cleared output."
    end;
    set = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        local cmdPayload --for the iris
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
            local newspeed = tonumber(args[3])
            if newspeed then
                if newspeed < 0 then
                    newspeed = 0
                end
                returnstr = string.format("Minimum speed is 0. Dial speed set to %.1f.", newspeed)
                settings.dialSpeed = newspeed
            elseif args[3] == "normal" or args[3] == nil then
                newspeed = 10
                returnstr = "Dial speed set to "..tostring(newspeed).."."
                settings.dialSpeed = newspeed
            else
                returnstr = "Speed must be a number or 'normal' which is 10 seconds."
            end
        elseif args[2] == "psaving" or args[2] == "powersaving" then
            local newValue = args[3]
            if newValue == "true" or newValue == "on" then
                settings.powerSaving = true
            elseif newValue == "false" or newValue == "off" then
                settings.powerSaving = false
            else
                returnstr = "The third argument must be true/on or false/off."
            end
        elseif args[2] == "entry" and args[3] and args[4] == "iris" then --need to add way to use stargate as relay using offical mod API
            local foundEntry = findEntry(args[3])
            local irisValue = args[5] or "toggle"
            
            if foundEntry then
                returnstr = "Found entry "..foundEntry.Name..". "
                local equivalentOption = optionEquivalence[irisValue]
                if equivalentOption~=nil or irisValue == "toggle" then
                    returnstr = returnstr.. "Setting iris to "..irisValue..". "
                    cmdPayload = generateCmdPayload("iris") --iris payload
                    if equivalentOption~=nil then
                        cmdPayload.args.irisValue = equivalentOption
                    elseif irisValue == "toggle" then
                       cmdPayload.args.irisValue = "toggle"
                    end
                    cmdPayload.args.IDC = type(tonumber(args[6]))=="number" and tonumber(args[6]) or (foundEntry.IDCs[args[6] or settings.lastUser] or -1)
                    
                    returnstr = returnstr .. "IDC is "..tostring(cmdPayload.args.IDC)..". "
                    threads.gdsSend = thread.create(gdssend, foundEntry.UUID, settings.networkPort, cmdPayload) 
                else
                    returnstr = returnstr.."Invalid argument for iris state. Must be on/off, open/closed, true/false, or toggle."
                end
            else
                returnstr = "Entry not found. Check your spelling."
            end
        elseif args[2] then
            returnstr = "Invalid sub-command: "..tostring(args[2])
        end
        writeSettingsFile()
        return returnstr, cmdPayload
    end;
    quit = function(...)
        local args = {...}
        isRunning = false
        --[[if args[2] == "-r" then 
            forceRestart = true 
        end]]
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
        elseif args[2] == "speed" then
            returnstr = "Current dial speed is "..tostring(settings.dialSpeed)
        elseif args[2] == "psaving" or args[2] == "powersaving" then
            returnstr = "Power saving is "..tostring(settings.powerSaving and "on." or "off.")
        elseif args[2] == "idc" and args[3] then
            --unfinished
        elseif args[2] then
            returnstr = "Invalid sub-command: "..tostring(args[2])
        end
        return returnstr
    end;
    import = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] == "ags" then
            if filesystem.exists("/ags/gateEntries.ff") then
                returnstr = "Attempting to import to database... "
                local successfullEntrycount = 0
                function GateEntry(ge)
                    local existingEntry = nil
                    if ge.gateAddress ~= nil then 
                        ge.Address = ge.gateAddress 
                        ge.gateAddress = nil 
                        existingEntry = findEntry(ge.Address, "MW") or findEntry(ge.Address, "PG") or findEntry(ge.Address, "UN")
                    else
                        return
                    end
                    if existingEntry~= nil then 
                        returnstr = returnstr .. " Entry "..existingEntry.Name.." already exists, cannot import "..tostring(ge.name).."."
                        return
                    else
                        returnstr = returnstr .. " Adding new entry "..tostring(ge.name)..". "
                    end
                    ge.IDCs = {}
                    if ge.IDC ~= nil then
                        local tmpidc = tonumber(ge.IDC)
                        ge.IDC = nil
                        if tmpidc then 
                            ge.IDCs[settings.lastUser or "unknown"] = tmpidc 
                        end
                    end
                    ge.AdminOnly = nil
                    ge.fave = nil
                    ge.Type = (#ge.Address.MW>0 and "MW") or (#ge.Address.PG>0 and "PG") or (#ge.Address.UN>0 and "UN")
                    ge.UUID = "unknown";
                    if ge.name then ge.Name = ge.name ge.name = nil else ge.Name = "Unknown "..#database end
                    table.insert(database, ge)
                    databaseList:addEntry(ge.Name, nil, false)
                    successfullEntrycount = successfullEntrycount + 1
                end
                function HistoryEntry() end
                dofile("/ags/gateEntries.ff")
                writeToDatabaseFile()
                GateEntry, HistoryEntry = nil, nil
                returnstr = returnstr.." Imported "..successfullEntrycount.." "..(successfullEntrycount == 1 and "entry" or "entries").." from AGS database."
                if successfullEntrycount > 0 and databaseList.visible then
                    databaseList:display()
                end
            else
                returnstr = "Invalid file"
            end
        else 
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
                if gateType == "UN" and tonumber(glyph) then glyph = "Glyph "..glyph end
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
                    returnstr = "Successfully added entry "..newEntry.Name.."."
                end
                writeToDatabaseFile()
            else
                returnstr = "Invalid address."
            end
        elseif (args[2] == "idc" or args[2] == "IDC") and args[3] and args[4] then --needs to store it as [string] = int, since the gate receives it as an int and reads it as IDCs[int] = string
            local foundEntry = findEntry(args[3])
            local idcKey = args[5] or settings.lastUser
            if type(foundEntry)=="table" then
                local idcIsNumber = tonumber(args[4])
                foundEntry.IDCs[idcKey] = idcIsNumber and idcIsNumber or args[4]
                returnstr = 'Added IDC "'..args[4]..'" to entry '..foundEntry.Name.." with key "..idcKey
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
        else
            returnstr = "Invalid sub-command: "..tostring(args[2])
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
                if databaseList.visible then 
                    databaseList:display() 
                    nearbyGatesList:display() 
                    gateOperator:write(databaseList.pos.x-3, databaseList.pos.y-2, "|Database: "..#databaseList.entries)
                    gateOperator:write(nearbyGatesList.pos.x-3, nearbyGatesList.pos.y-2, "|Nearby: "..#nearbyGatesList.entries)
                end
            end
        else
            returnstr = "Invalid sub-command: "..tostring(args[2])
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
        else
            returnstr = "Invalid sub-command: "..tostring(args[2])
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
        else
            returnstr = "Invalid sub-command: "..tostring(args[2])
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
            local isInNearby = nearbyGatesList:getIndexFromName(gateA.Name, false)
            gateA.Name = newName
            if isInNearby then
                nearbyGatesList.entries[isInNearby] = newName
                nearbyGatesList:display()
            end
            writeToDatabaseFile()
            if databaseList.visible then 
                databaseList:display()
            end
        else
            returnstr = "Invalid sub-command: "..tostring(args[2])
        end
        return returnstr
    end;
    dial = function(...) --need to add the 4th argument as a timer to close the gate, -1 signifies as long as possible, otherwise its in seconds default = 30
        local args = {...}
        local returnstr = "Insufficient arguments."
        local cmdPayload = generateCmdPayload("dial", {speed = settings.dialSpeed, timer = tonumber(args[4])}) 
        local gateA, gateB
        if args[2] and args[3] then
            gateA = findEntry(args[2])
            gateB = findEntry(args[3])
        elseif args[2] and args[3] == nil and #nearbyGatesList.entries>0 then
            gateA = findEntry(nearbyGatesList.currententry or nearbyGatesList.entries[1])
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
                cmdPayload.args.Address = gateB.Address
                cmdPayload.args.IDC = gateB.IDCs[args[5] or settings.lastUser] or -1
                threads.gdsSend = thread.create(gdssend, gateA.UUID, settings.networkPort, cmdPayload) --maybe create an event timer for scanNearby 5-10 seconds after dialing which assumes they went through the gate
                cmdPayload.args.gateA = gateA
                cmdPayload.args.gateB = gateB
                returnstr = "Dialing from "..gateA.Name.." to "..gateB.Name.."..."
                lastEntry = gateA
            end
        else
            returnstr = "Invalid argument: "..tostring(gateA == nil and args[2] or args[3])
        end
        return returnstr, cmdPayload
    end;
    close =  function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        local cmdPayload
        local gateA = findEntry(args[2] or databaseList:getIndexFromName(nearbyGatesList.entries[nearbyGatesList.currententry])) or lastEntry -- or findEntry(nearbyGatesList.currententry) or findEntry(databaseList.currententry)
        if gateA then
            cmdPayload = generateCmdPayload("close") 
            threads.gdsSend = thread.create(gdssend, gateA.UUID, settings.networkPort, cmdPayload)
            returnstr = "Closing gate "..gateA.Name
            lastEntry = gateA
        else
            returnstr = "Unable to find entry."
        end
        return returnstr, cmdPayload
    end;
    scan = function(...)
        local args = {...}
        local cmdPayload
        local returnstr = "Scanning for nearby gates..."
        if computer.uptime()-lastBroadcasted > 1 then
            cmdPayload = generateCmdPayload("query")
            broadcast(settings.networkPort, "gds"..serialization.serialize(cmdPayload) )
            lastBroadcasted = cmdPayload.issued
        else
            returnstr = "Spam interval reached, please try again."
        end
        nearbyGatesList.entries = {}
        nearbyGatesList:display()
        return returnstr, cmdPayload
    end;
    sync = function(...)
        local args = {...}
        local returnstr = "Sync is not yet implimented." --"Insufficient arguments."
        --for address or database syncing
        return returnstr
    end;
    help = function(...)
        local args = {...}
        local returnstr
        if args[2] and commandDescriptions[args[2]:lower()] then
            returnstr = args[2]..": "..commandDescriptions[args[2]:lower()]
        else
            returnstr = "To see a commands usage do ;help followed by the command name. Available commands are "
            for commandname, desc in pairs (commandDescriptions) do
                returnstr = returnstr..commandname..", "
            end
        end
        return returnstr
    end;
    edit = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] == "entry" and args[3] and args[4] then
            local gateA, gateAIndex = findEntry(args[3])
            if gateA then
                returnstr = "Entry not found."
                args[4] = args[4]:lower()
                if (args[4] == "mw" or args[4] == "pg" or args[4] == "un") and gateA.Address[args[4]:upper()]~=nil then
                    local entrystr = "" --table.concat(gateA.Address[args[4]:upper()], " ")
                    for i, glyph in ipairs (gateA.Address[args[4]:upper()]) do 
                        entrystr = entrystr .. " " .. string.gsub(glyph, " ", "_") 
                    end
                    event.timer(0, function() 
                        cmdbar.text = ";add entry "..gateAIndex.." "..args[4]..entrystr
                        cmdbar:setCursor(16)
                        cmdbar:display()
                    end)
                    returnstr = "Editing entry "..gateA.Name
                elseif args[4]=="idc" then --5 = key
                    returnstr = "Editing entry IDC "..gateA.Name
                    event.timer(0, function() 
                        cmdbar.text = ";add idc "..gateAIndex.." "..(gateA.IDCs[args[5] or settings.lastUser] or "1234").." "..(args[5] or settings.lastUser)
                        cmdbar:setCursor(16)
                        cmdbar:display()
                    end)
                end
                --cmdbar.text  = 
            end
        end
        return returnstr
    end;
    update = function(...)
        local args = {...}
        local returnstr = "Insufficient arguments."
        if args[2] == "entry" then
            returnstr = returnstr.." Missing entry index or name."
            local gateA, gateAIndex = findEntry(args[3])
            if gateA then
                returnstr = "Requesting entry "..gateA.Name.." to update..."
                if args[4] and args[4]~="f" or args[4]~="force" or args[4]~="-f" then 
                    returnstr = returnstr.." Invalid 4th argument, try force or f or -f."
                end
                threads.gdsSend = thread.create(gdssend, gateA.UUID, settings.networkPort, {command="update", args = {force = args[4] and ((args[4] == "f" or args[4] == "force" or args[4] == "-f" ) and "force")}, user = {name = tostring(settings.lastUser)}})
            end
        --elseif args[2] then
            --update tablet
        end
    end;
}

local function setAliases(func, ...)
    local args = {...}
    if type(commands[func])=="function" then
        for i, alias in pairs (args) do
            commands[alias] = commands[func]
            commandDescriptions[alias] = commandDescriptions[func]
        end
    end
end
--command aliases
setAliases("set", "s","st")
setAliases("quit", "q", "exit")
setAliases("clear", "c", "clr", "cls")
setAliases("get", "g")
setAliases("delete", "del", "remove", "rmv")
setAliases("add", "new")
setAliases("dial", "d")
setAliases("rename", "rn")
setAliases("help", "cmds")

local lastTimeProcessed = nil
function processInput(usr, inputstr)
    local timeran = "["..os.date("%H:%M", getRealTime()).."]"
    if timeran ~= lastTimeProcessed or #outputBuffer==0 then
        lastTimeProcessed = timeran
    else
        timeran = "       "
    end
    if inputstr:sub(1,1) == settings.prefix then
        local chunks = strsplit(inputstr, settings.prefix)
        for i, chunk in next, chunks do
            local args = strsplit(chunk, " ")
            local cmdfunction = commands[args[1]]
            local outputstring = timeran.." cmd: "..chunk
            
            recordToOutput(outputstring)
            if cmdfunction then
                args[1] = nil --removing the command name
                local succ, returndata, processTable = pcall(cmdfunction, table.unpack(args)) --could do returns here and deal with the output buffer, but not really necessary
                if returndata then --if returndata == table then else do the default below
                    if processTable then
                        processTable.list = {}
                        processTable.status = "open"
                        table.insert(processTable.list, cmdResPrefix..returndata)
                        recordToOutput(processTable)
                    else
                        recordToOutput(cmdResPrefix..returndata)
                    end
                end
            else
                recordToOutput("          ⤷ invalid command.")
            end
        end
    else
        local chatstr = timeran.." "..(usr and usr..": " or "")..inputstr
        recordToOutput(chatstr)
    end
end
processInput("GDS", "Do ;help or ;cmds or check the GDS github to see commands.")
modem.open(settings.networkPort)
-- end of command processing
--depreciated for better method
--[[local function legalString(msg)
    return not (msg:match("%(") or msg:match("%)") or msg:match("os%.") or msg:match("debug%.") or msg:match("_G") or msg:match("load") or msg:match("dofile") or msg:match("io%.") or msg:match("io%[") or msg:match("loadfile") or msg:match("require") or msg:match("print") or msg:match("error") or msg:match("package%.") or msg:match("package%["))
end]]
--event listeners
local cmdResultHandler = {
    dial = function(from, processTable, msgdata, time) 
        table.insert(processTable.list, cmdResPrefix..from.Name..": "..msgdata.message)
        if type(processTable.args.IDC) == "string" and msgdata.message == "Successfully dialed." and processTable.args.gateB.UUID then                                        
            processTable.list[#processTable.list] = processTable.list[#processTable.list].." Sending custom IDC."
            local irisCmdPayload = generateCmdPayload("iris", {irisValue = "open", IDC = processTable.args.IDC, delay = 50, delayType = "ticks"}) --iris payload
            irisCmdPayload.processID = processTable.processID
            gdssend(processTable.args.gateB.UUID, settings.networkPort, irisCmdPayload) 
        end
    end,
    close = function(from, processTable, msgdata, time)
        if time-processTable.issued < 1 or #processTable.list < 3 then
            table.insert(processTable.list, cmdResPrefix..from.Name..": "..msgdata.message)
        else
            processTable.status = "closed"
        end
    end,
    iris = function(from, processTable, msgdata, time)
        if time-processTable.issued < 1 or #processTable.list < 2 then
            table.insert(processTable.list, cmdResPrefix..from.Name..": "..msgdata.message)
        else
            processTable.status = "closed"
        end
    end,
}

local restrictedKeyCodes = {[14] = true; [15] = true; [28]=true; [29]=true; [42] = true; [54] = true; [56] = true; [58] = true}
local EventListeners = {
    modem_message = event.listen("modem_message", function(_, receiver, sender, port, distance, msg, utilityMsg)
        local timeReceived = computer.uptime()
        if type(msg) ~= "string" then return end
        if msg:sub(1, 8) == "gdsgate{" and msg:sub(msg:len()) == "}" and msg:len() > 10 then --entry syncing
            local msgdata, payloadError = serialization.unserialize(msg:sub(8))
            --might need to require utilityMsg
            if msgdata==nil or payloadError or type(msgdata)~="table" then return end --print("Invalid message payload") return end
            local newGateType = msgdata.gateType
            local newAddress = msgdata.Address
            if msgdata.uuid == sender then --auto syncing
                lastReceived[sender] = lastReceived[sender] or timeReceived-6
                if timeReceived - lastReceived[sender] > 5 then
                    lastReceived[sender] = timeReceived
                    --recordToOutput("Receiving address data from.."..sender:sub(1,4).." of type "..newGateType)
                    local returnstr = "hmm"
                    local existingEntry, _ = findEntry(sender) or findEntry(newAddress, "MW") or findEntry(newAddress, "PG") or findEntry(newAddress, "UN")
                    if existingEntry then
                        returnstr = existingEntry.Name
                        if existingEntry.UUID ~= sender then
                            existingEntry.UUID = sender
                            returnstr = returnstr.." Updated UUID."
                        end
                        for glyphset, adrs in pairs (newAddress) do
                            if glyphset == "MW" or glyphset == "PG" or glyphset == "UN" then
                                if existingEntry.Address[glyphset] then --need to add check to update address
                                    if #adrs < 10 then
                                        if #adrs > #existingEntry.Address[glyphset] then
                                            existingEntry.Address[glyphset] = adrs
                                            returnstr = returnstr.." Updated "..glyphset.." Address."
                                        end
                                    else
                                        returnstr = returnstr .. " Failure to sync, too many glyphs in "..glyphset.." address: "..#adrs.."."
                                    end
                                else
                                    existingEntry.Address[glyphset] = adrs
                                    returnstr = returnstr.." Added "..glyphset.." Address."
                                end
                            else
                                returnstr = returnstr.." Invalid glyph-set: "..glyphset.."."
                            end
                        end
                        writeToDatabaseFile()
                        
                    else
                        local newEntry = {
                            Name = msgdata.Name or sender;
                            Address = newAddress;
                            IDCs = {};
                            Type = newGateType;
                            UUID = sender;
                        }
                        table.insert(database, newEntry)
                        databaseList:addEntry(newEntry.Name)
                        writeToDatabaseFile()
                        existingEntry = newEntry
                        returnstr = "Added new entry "..newEntry.Name.." from scan."
                    end
                    if nearbyGatesList:getIndexFromName(existingEntry.Name, false)==nil then 
                        nearbyGatesList:addEntry(existingEntry.Name)
                    end
                    if utilityMsg then
                        local processTable = processLookup[utilityMsg]
                        if processTable and processTable.status ~= "closed" then
                            table.insert(processTable.list, cmdResPrefix.."Nearby gate "..returnstr) --need to determine status, not sure yet 
                        end
                    end
                    displayOutputBuffer()
                    if gateOperator.currenttab == 1 then
                        gateOperator:write(databaseList.pos.x-3, databaseList.pos.y-2, "|Database: "..#databaseList.entries)
                        gateOperator:write(nearbyGatesList.pos.x-3, nearbyGatesList.pos.y-2, "|Nearby: "..#nearbyGatesList.entries)
                    end
                end
            end
        elseif msg:sub(1, 17) == "gdsCommandResult:" and timeReceived - (lastReceived["dialresult"..sender] or 0) > 0.01 then --need to make spam detection better
            local existingEntry, _ = findEntry(sender)
            if existingEntry then --and targetGate
                lastReceived["dialresult"..sender] = timeReceived
                local msgpayload = msg:sub(18)
                if msgpayload:sub(1,1) == "{" then
                    local msgdata, payloadError = serialization.unserialize(msgpayload) --{gateType, address = {MW = ..., }, uuid = modem.address}; might need to sandbox this
                    if msgdata==nil or payloadError or type(msgdata)~="table" then return end 
                    if msgdata.processID then
                        local processTable = processLookup[msgdata.processID]
                        if processTable then
                            if processTable.status ~= "closed" then
                                local resultHandleCallback = cmdResultHandler[processTable.command]
                                if resultHandleCallback then
                                    resultHandleCallback(existingEntry, processTable, msgdata, timeReceived)
                                else
                                    table.insert(processTable.list, cmdResPrefix..existingEntry.Name..": "..msgdata.message) --need to determine status, not sure yet 
                                end
                                displayOutputBuffer()
                            else
                            end
                        else

                        end
                    else --idk yet
                    end
                else
                    recordToOutput(cmdResPrefix..existingEntry.Name..": "..msgpayload) --..(existingEntry and existingEntry.Name or sender:sub(1,8)).." "
                end
            end
        end
    end),
    key_down = event.listen(
        "key_down",
        function(_, keyboardAddress, chr, code, playerName)
            lastTimeUsed = computer.uptime()
            settings.lastUser = playerName
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
                elseif key == "left" or key == "right" then
                    cmdbar:moveCursor(key == "right" and 1 or -1)
                    if cmdbar.cursorpos == cmdbar.text:len()+1 and cmdbar.cursorpos > 2 and cmdbar.text:sub(cmdbar.text:len()) ~=" " then
                        cmdbar:addText(" ")
                    end
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
            lastTimeUsed = computer.uptime()
            local status, err =
                xpcall(
                function()
                    --term.setCursor(0, 0)
                    settings.lastUser = playerName
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
                --[[local errTable = strsplit(err, "\n")
                for i,v in ipairs (errTable) do
                    print(v)
                    os.sleep(0.25)
                end]]
                print(err)
            end
        end
    ),
    scroll = event.listen("scroll", function(_, screenAddress, x, y, direction, playerName)
        lastTimeUsed = computer.uptime()
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

--doing things
dialButton.func = function() 
    if databaseList.currententry then
        local gateA = databaseList:getIndexFromName(nearbyGatesList.entries[nearbyGatesList.currententry])
        local inputstr = settings.prefix.."dial"
        if gateA then inputstr = inputstr.." "..gateA end
        inputstr = inputstr.." "..databaseList.currententry
        processInput(nil, inputstr) 
    end
end
closeGateButton.func = function() 
    processInput(nil, settings.prefix.."close")
end
scanNearbyButton.func = function() 
    scanNearbyButton.disabled = true
    processInput(nil, settings.prefix.."scan")
    event.timer(0.25, function() scanNearbyButton.disabled = false end)
    --button:hide() event.timer(0.25, function() button:display() end)
end
gateOperator:selectTab("Database")
scanNearbyButton.func() --initial scan
--main loop to keep it from returning to the terminal
while isRunning and HadNoError do
    os.sleep(0.25)
    if settings.powerSaving then
        if computer.uptime() - lastTimeUsed > 300 then
            computer.shutdown()
        end
    end
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
else
    print("Error occurred.")
end

for i,v in pairs (package.loaded) do
    if i:sub(1,3)=="gui" then
        package.loaded[i] = nil
    end
end
if forceRestart then
    require"shell".execute("/gds/clientinterface.lua")
end