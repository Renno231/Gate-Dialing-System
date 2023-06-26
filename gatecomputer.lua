--gate computer
local component = require("component")
local computer = require("computer")
local event = require("event")
local os = require("os")
local term = require("term")
local thread = require("thread")
local serialization = require("serialization")
local unicode = require("unicode")
local filesystem = require("filesystem")
local sides = require("sides")

local modem, stargate, dhd 
local isRunning, HadNoError = true, true
local gateType

local SettingsFile = "/gds/settings.cfg"
local settings = {
    allowedList = {};
    IDCs = {};
    gitPullHistory = {};
    listeningPorts = {160};
    networkAdminPassword = false;
    networkAdminUUID = false;
    isPrivate = false;
    autoSyncToIncoming = true;
    runInBackground = true;
    showPrints = false;
    kawooshAvoidance = true;
    autoGitUpdate = true;
}
local _print = print
local function print(...)
    if settings.showPrints and not settings.runInBackground then
        _print(...)
    end
end
local canSpeedDial = true
local mustwaitUntilState = false
local commandLog = {} --table.insert(commandLog, sender.." "..self.command)
local threads = {} --threads.example = thread.create(function() end); threads.example:kill(); threads.example:suspend()
local lastReceived = {} -- for wireless messages
local gateStatus, irisStatus = "idle", nil
local lastSuccessfulDial = nil
local jsgVersion, irisType
term.clear()

if component.isAvailable("modem") then
    modem = component.modem
    print("Wireless modem UUID: "..modem.address)
    for i, port in ipairs (settings.listeningPorts) do
        modem.open(port)
        print("Opened port "..port)
    end
    modem.setStrength(400)
    modem.setWakeMessage("gdswakeup")
else
    print("Wireless modem not connected.")
    os.exit()
end

if component.isAvailable("redstone") then
    component.redstone.setWakeThreshold(1)
    print("Set redstone wake threshold to "..(component.redstone.getWakeThreshold()))
end

local gatedataTable
if component.isAvailable("stargate") then
    stargate = component.stargate
    irisType = tostring(stargate.getIrisType())
    irisStatus = stargate.getIrisState()
    gateType = stargate.getGateType():sub(1,1)
    gateType = (gateType == "M" and "MW") or (gateType == "P" and "PG") or (gateType == "U" and "UN")
    gateStatus = stargate.getGateStatus()
    gatedataTable = "gdsgate"..serialization.serialize({
        gateType = gateType;
        Address = {
            MW = stargate.stargateAddress.MILKYWAY;
            PG = stargate.stargateAddress.PEGASUS;
            UN = stargate.stargateAddress.UNIVERSE;
        };
        uuid = modem.address
    })
    jsgVersion, _ = stargate.getJSGVersion():sub(-8):gsub("[.]","")
    jsgVersion = tonumber(jsgVersion)
    mustwaitUntilState = jsgVersion > 41105
else
    print("Stargate not connected")
    os.exit()
end

if component.isAvailable("dhd") and gateType~="UN" then 
    dhd = component.dhd
    print("DHD found. Speed dialing is available.")
else
    print("DHD not connected. Speed dialing is unavailable.")
    canSpeedDial = false
end

local function writeSettingsFile()
    local file = io.open(SettingsFile, "w")
    --recordToOutput("settings file"..tostring(file))
    file:write("local settings = "..serialization.serialize(settings).."\n\nreturn settings")
    file:close()
end

local function readSettingsFile()
    local file = io.open(SettingsFile, "r")
    if file == nil then
        writeSettingsFile() 
        return 
    end
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
        --[[settings.modemRange = math.min(math.max(tonumber(settings.modemRange) or 16, 16), 400)
        modem.close(settings.networkPort)
        settings.networkPort = math.min(math.max(tonumber(settings.networkPort), 1),  65535)
        modem.setStrength(settings.modemRange)]]
    end
end
readSettingsFile()
writeSettingsFile()
local function checkTime()
    local f = io.open("/tmp/timecheck","w")
    f:write("test")
    f:close()
    return filesystem.lastModified("/tmp/timecheck")
end

local function checkTPS(waitDelay)
    waitDelay = waitDelay or 1
    local realTimeOld = checkTime()
    os.sleep(waitDelay)
    return math.min(math.floor((20 * waitDelay * 1000) / (checkTime() - realTimeOld)), 20)
end

local function waitTicks(ticks)
    ticks = ticks or 20
    os.sleep(ticks/checkTPS(0.1) - 0.1)
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
    local internet = component.isAvailable"internet" and require("internet")
    if not internet then 
        print("No internet card detected, cannot download "..filePath.." to "..directory) 
        return false, "No internet card detected."
    end
    print("Downloading..."..filePath)
    --response = internet.request("https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/gatecomputes.lua")
    --idk why this code is behaving differently in here... doesn't make any sense at all
    local downloaded, response = pcall(internet.request, "https://raw.githubusercontent.com/Renno231/Gate-Dialing-System/main/"..filePath)
    if not downloaded then
        print(response())
        return false, response
    end
    
    local fileName = strsplit(filePath,"/")
    local success, err = pcall(function()
        fileName = fileName[#fileName]
        local absolutePath = (directory or "")..fileName
        if type(directory)=="string" and directory~="" then
            if not filesystem.isDirectory(directory) then
                filesystem.makeDirectory(directory)
            end
        end
        local file, fileErr = io.open(absolutePath, "w")
        if file == nil then error(fileErr) end
        for chunk in response do
            file:write(chunk)
        end
        file:close()
    end)
    if not success then
        print("Unable to download"..tostring(fileName))
        print(err)
    else
        err = "Downloaded file."
    end
    return success, err
end

local function gitUpdate(file, dir, forceupdate)
    if type(file) ~="string" or type(dir) ~="string" then return false, "Incorrect arguments "..tostring(file)..", "..tostring(dir) end
    if not component.isAvailable("internet") then return false, "Internet card not found" end
    --if internet card, then request github info and pull update, return results, and reboot
    if settings.gitPullHistory == nil then
        settings.gitPullHistory = {} 
    end
    local succ, response = pcall(component.internet.request, "https://api.github.com/repos/Renno231/Gate-Dialing-System/commits?path="..file.."&page=1&per_page=1") --, nil, {["user-agent"]="Wget/OpenComputers"}) 
    
    if not succ then return false, response() end
    local ready, reason
    repeat
        ready, reason = response.finishConnect()
    until ready or reason
    if (not ready) then
        return nil, reason
    end
    local read
    repeat
        read = response.read() 
    until read~="" --print(i, type(read), read) end
    
    checkTime()
    local commitdate = strsplit(read, '",\"')[20] --the date
    
    if not commitdate then 
        print("Commit date missing from data. \n",read)
        return false, "Commit date missing from data."
    end
    local absolutePath = dir..file
    commitdate = {commitdate:sub(1,4), commitdate:sub(6,7), commitdate:sub(9,10), commitdate:sub(12,13), commitdate:sub(15,16)}
    local lastmodified = settings.gitPullHistory[absolutePath] or os.date("%Y/%m/%d/%H/%M", filesystem.lastModified(absolutePath)/1000)
    lastmodified = strsplit(lastmodified, "//")
    local yearDiff = lastmodified[1] - commitdate[1]
    local shouldUpdate = yearDiff < 0 --year check is easiest
    --year check first, then month, then convert days and hours into minutes, add to minutes for total, then compare
    if yearDiff == 0 then --after year check
        local monthDiff = lastmodified[2] - commitdate[2]
        shouldUpdate = monthDiff < 0 --month check
        if monthDiff == 0 then --minutes in the month
            shouldUpdate = ((lastmodified[3] * 3600) + (lastmodified[4] * 60) + lastmodified[5] ) - ((commitdate[3] * 3600) + (commitdate[4] * 60) + commitdate[5]) < 0
        end
    end
    if forceupdate then shouldUpdate = forceupdate end
    if shouldUpdate then
        local succ, err = downloadFile(file, dir)
        if succ then --file has been updated, so lastModified has changed to now
            settings.gitPullHistory[absolutePath] = os.date("%Y/%m/%d/%H/%M", filesystem.lastModified(absolutePath)/1000)
            writeSettingsFile()
        end
        return succ, err
    else
        return false, "Gate computer already up to date." --maybe include how long since it was updated?
    end
end

local function waitUntilState(state, step)
    state = state or "idle"
    step = step or 0
    repeat 
        os.sleep(step)
        gateStatus = stargate.getGateStatus()
    until gateStatus == state
end

local function waitForIris(desiredstate, step, shouldyield) --normal iris is 3 seconds, shield is 0.5?
    desiredstate = desiredstate or "OPENED"
    step = step or 0
    irisStatus = stargate.getIrisState()
    local succ, err
    if irisStatus == desiredstate or tostring(stargate.getIrisType()) == "NULL" then 
        return true
    end
    if irisStatus:match("ING") then --already moving
        repeat
            irisStatus = stargate.getIrisState()
            os.sleep(step)
        until not irisStatus:match("ING") --till not moving
    end
    if desiredstate~=irisStatus then
        succ, err = stargate.toggleIris()
        if not succ then 
            return succ, err 
        end
        if shouldyield or shouldyield == nil then
            repeat 
                irisType = tostring(stargate.getIrisType())
                os.sleep(step)
                irisStatus = stargate.getIrisState()
            until irisStatus == desiredstate or irisType == "NULL"
        end
        return true
    end
end

local function sendIDC(code, timeout)
    stargate.sendIrisCode(code)
    local _, _, caller, msg = event.pull(2, "code_respond")
    local pulls = 1
    timeout = timeout-- -1
    
    print("Response message", msg)
    if not msg or msg:sub(1, -4)=="Waiting on computer..." then
        print("Waiting for code response...")
        repeat 
            --os.sleep()
            _, _, caller, msg = event.pull(1, "code_respond")
            pulls = pulls + 1
        until (msg and msg:sub(1, -4)~="Waiting on computer...") or pulls > timeout
    end
    return (pulls > timeout or msg==nil) and "No IDC response." or msg:sub(1, -4) 
end

do --like waking up with your front door open, doesn't work very well yet
    if gateStatus == "open" and irisType~="NULL" and settings.lastWormhole == "incoming" and (settings.lastReceivedIDC and not settings.IDCs[settings.lastReceivedIDC] or settings.lastReceivedIDC == nil) then
        print("Security threat detected. Closing iris.")
        stargate.sendMessageToIncoming("Iris closed. Resend IDC.")
        waitForIris("CLOSED", 0, false)
    end
end

print("Starting gate dialer program. To disable printouts, enable headless mode in the settings file.")
--send(sadd, 100, {gate.getGateType(), state, gate.dialedAddress, serial.serialize(gate.stargateAddress)})
local function send(address, port, msg)
    os.sleep(math.min(math.random()/5, 0.2))
    modem.send(address, port, tostring(msg))
end

local function broadcast(port, msg)
    os.sleep(math.min(math.random()/5, 0.2))
    modem.broadcast(port, tostring(msg))
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
--depreciated in favor of serialization.unserialize
--local function legalString(msg)
--    return not (msg:match("%(") or msg:match("%)") or msg:match("os%.") or msg:match("debug%.") or msg:match("_G") or msg:match("load") or msg:match("dofile") or msg:match("io%.") or msg:match("io%[") or msg:match("loadfile") or msg:match("require") or msg:match("print") or msg:match("error") or msg:match("package%.") or msg:match("package%["))
--end

local EventListeners = {
    --stargate_spin_chevron_engaged = event.listen("stargate_spin_chevron_engaged", function(_, _, caller, num, lock, glyph) end),

    --stargate_dhd_chevron_engaged = event.listen("stargate_dhd_chevron_engaged", function(_, _, caller, num, lock, glyph) end),

    stargate_incoming_wormhole = event.listen("stargate_incoming_wormhole", function(_, _, caller, dialedAddressSize) 
        settings.lastWormhole = "incoming"
        writeSettingsFile()
        if stargate.getIrisState() == "OPENED" then
            stargate.toggleIris()
            print("Incoming wormhole.")
        end
    end),

    --stargate_open = event.listen("stargate_open", function(_, _, caller, isInitiating) 
        
    --end),

    stargate_wormhole_stabilized = event.listen("stargate_wormhole_stabilized", function(_, _, caller, isInitiating) 
        gateStatus = "open"
    end),

    stargate_close = event.listen("stargate_close", function(_, _, caller, reason) 
        if stargate.getIrisState() == "CLOSED" then
            stargate.toggleIris()
        end
    end),

    stargate_wormhole_closed_fully = event.listen("stargate_wormhole_closed_fully", function(_, _, caller, isInitiating) 
        gateStatus = "closed"
    end),

    stargate_failed = event.listen("stargate_failed", function(_, _, caller, reason) 
    
    end),

    modem_message = event.listen("modem_message", function(_, receiver, sender, port, distance, wakeup, msg, ...)
        if type(msg) == "string" then
            local currentTime = computer.uptime()
            if msg:sub(1, 4) == "gds{" and msg:sub(msg:len()) == "}" and msg:len() > 10 then -- maybe send "username:{}" ?
                print("Receiving instructions...")
                local msgdata, payloadError = serialization.unserialize(msg:sub(4)) --{comman = cmd; args = {}; user = {name=username; uuid = uuid}}; might need to wrap this in something like pcall
                print( msgdata)
                if msgdata==nil or payloadError or type(msgdata)~="table" then print("Invalid message payload") return end
                local command = msgdata.command
                local args, user = msgdata.args, msgdata.user
                local userprocessKey = command..sender --useful for tracking actions by a specific user instead of total interaction by a specific user
                local canProcess = false
                print("User: ",user)
                if type(user) == "table" then
                    if type(user.name) == "string" then
                        if settings.isPrivate then
                            canProcess = settings.allowedList[user.name]
                        else
                            canProcess = true
                        end
                    end
                end
                if not canProcess then 
                    print("Cannot process command.")
                    return 
                end
                print("Processing command: "..command)
                --os.sleep(0.1) --seems like its needed?
                if command == "dial" then
                    lastReceived[userprocessKey] = lastReceived[userprocessKey] or currentTime-2
                    if currentTime - lastReceived[userprocessKey] < 1 then
                        return
                    else
                        lastReceived[userprocessKey] = currentTime
                    end
                    if threads.dialing then threads.dialing:kill() end --could add a check to see if the partial address dialed matches the current one and continue from there
                    threads.dialing = thread.create(function() 
                        -- put this in a new thread
                        print("Attempting to dial address...\nCurrent gate type is "..gateType)
                        local newAddress = args.Address[gateType]
                        local newAddressStr = serialization.serialize(newAddress) --should be able to use table.concat
                        newAddressStr = "["..newAddressStr:sub(2, newAddressStr:len()-1).."]"
                        if not newAddress then
                            print("Invalid address")
                            send(sender, port, "gdsCommandResult: Missing gate type for entry.")
                            os.exit()
                        else
                            print("Found address")
                        end
                        local lastGlyph = newAddress[#newAddress]
                        if lastGlyph ~= "Point of Origin" and lastGlyph~="Glyph 17" and lastGlyph~="Subido" then
                            lastGlyph = (gateType=="MW" and "Point of Origin") or (gateType=="UN" and "Glyph 17") or (gateType=="PG" and "Subido")
                            table.insert(newAddress, lastGlyph)
                            print("Address missing POI, adding POI...")
                        end 
                        print("Checking if address exists...")
                        local addressCheck = stargate.getEnergyRequiredToDial(table.unpack(newAddress))
                        gateStatus = stargate.getGateStatus()
                        local glyphStart, hasEngagedGate = 1, false
                        local currentDialedAddress = stargate.dialedAddress
                        local totalGlyphs = #newAddress
                        if type(addressCheck) == "table"  then --not enough power
                            if not addressCheck.canOpen then
                                print("Not enough power to dial")
                                send(sender, port, "gdsCommandResult: Insufficient power to dial. Requires "..addressCheck.open.." RF to open and "..addressCheck.keepAlive.." RF/t to maintain.")
                                os.exit()
                            end
                            if totalGlyphs > 7 then
                                for check = 1, totalGlyphs-7 do
                                    local newCheckAddress = {}
                                    for i=1, totalGlyphs-2 do
                                        table.insert(newCheckAddress, newAddress[i])
                                    end
                                    table.insert(newCheckAddress, lastGlyph) --poi
                                    
                                    local newCheck = stargate.getEnergyRequiredToDial(table.unpack(newCheckAddress))
                                    if type(newCheck) == "table" then
                                        newAddress = newCheckAddress
                                        totalGlyphs = #newAddress
                                        newAddressStr = serialization.serialize(newAddress)
                                        newAddressStr = "["..newAddressStr:sub(2, newAddressStr:len()-1).."]"
                                        print("Found shorter address: "..#newAddress)
                                    --else
                                    --    print("Shortest address is "..totalGlyphs.." glyphs.")
                                    --    break
                                    end
                                end
                            end
                        else
                            send(sender, port, "gdsCommandResult: Address check failed.")
                            print("Address check failed.")
                            os.exit()
                        end
                        if gateStatus == "open" and settings.lastWormhole == "incoming" then
                            print("Gate is open, must wait until incoming wormhole closes.")
                            waitUntilState("idle")
                        end
                        if currentDialedAddress and currentDialedAddress~="[]" and gateStatus~="open" then 
                            print("Performing address matching optimization...")
                            local matchAddress = string.gsub(currentDialedAddress,"]","")
                            local currentAddress = newAddressStr:gsub(',"',", "):gsub('"',""):sub(1, matchAddress:len())
                            if currentAddress == matchAddress then
                                print("Partial address match")
                                local glyphsSplit = strsplit(currentDialedAddress:sub(2, currentDialedAddress:len()-1), ",")
                                for i,v in ipairs (glyphsSplit) do
                                    if v:sub(1,1) == " " then v = v:sub(2) end
                                    --print("split",i,"|"..v.."|")
                                    --print(glyphStart, newAddress[i], v)
                                    if newAddress[i] == v then
                                        glyphStart = i + 1
                                    else
                                        glyphStart = 1
                                        --print("broke")
                                        break
                                    end
                                end
                            end
                            print("Glyph Start:", glyphStart)
                            if glyphStart > #newAddress then
                                local hasClosed, err
                                if settings.kawooshAvoidance and stargate.getIrisType ~="NULL" then
                                    hasClosed, err = waitForIris("CLOSED")
                                    if err then
                                        print("Iris malfunction, cannot avoid kawoosh:", err)
                                    end
                                end
                                hasEngagedGate = stargate.engageGate()
                                print("Engaging stargate: "..tostring(hasEngagedGate), hasEngagedGate and irisType~="NULL")
                                if irisType~="NULL" then
                                    if hasEngagedGate then
                                        repeat os.sleep(0.1) until gateStatus =="open"
                                        waitTicks(20)
                                    end
                                    waitForIris("OPENED", 0)
                                end
                            end
                        end
                        print("Gate Status: "..gateStatus)
                        if not hasEngagedGate then
                            if gateStatus == "open" then 
                                stargate.disengageGate()
                                print("Resetting address...")
                            elseif currentDialedAddress~="[]" and glyphStart==1 then --gateStatus == "dialing" and 
                                stargate.abortDialing()
                                print("Aborting dialing...")
                                os.sleep(2.5)
                            end
                            if gateStatus~="idle" then
                                print("Waiting for gate to finish actions...")
                                waitUntilState()
                            end
                        end
                        gateStatus = stargate.getGateStatus()
                        local speedDial = (args.speed and args.speed < 25 or false) and canSpeedDial
                        local delayTime = (args.speed or 0) / (totalGlyphs + 1)
                        local engageResult, errormsg, dialStart = false, "", computer.uptime()
                        if gateStatus == "idle" and not hasEngagedGate then
                            print("Glyph starting index = "..tostring(glyphStart))              
                            print("Valid address.")
                            print("canSpeedDial = "..tostring(canSpeedDial)..". args.speed = "..tostring(args.speed).." | mustwaitUntilState = "..tostring(mustwaitUntilState))
                            irisType = tostring(stargate.getIrisType())
                            local irisCloseTime = ((irisType:match("IRIS_") and 3) or (irisType == "SHIELD" and 1) or 1)
                            local irisToggleGlyph = math.max(glyphStart, totalGlyphs -  math.ceil(irisCloseTime / (delayTime > 0 and delayTime or 1)))
                            for i = glyphStart, totalGlyphs do
                                print("> Glyph "..i)
                                local hasClosed, err
                                if settings.kawooshAvoidance and (i == irisToggleGlyph or (args.speed < irisCloseTime and not mustwaitUntilState) ) and irisType~="NULL" then
                                    hasClosed, err = waitForIris("CLOSED", 0, (args.speed < irisCloseTime and not mustwaitUntilState) )
                                    if err then
                                        print("Iris malfunction, cannot avoid kawoosh:", err)
                                    end
                                end
                                if speedDial then
                                    if mustwaitUntilState then
                                        waitUntilState(nil, 0.2)
                                    end
                                    _, engageResult, errormsg = dhd.pressButton(newAddress[i])
                                    if engageResult ~= "dhd_pressed" then
                                        if engageResult == "dhd_not_connected" then
                                            computer.pushSignal("stargate_failed","",true,engageResult)
                                        end
                                        print("DHD: "..engageResult,"Err: "..errormsg)
                                        return -- exit dialing thread
                                    end
                                else
                                    waitUntilState(nil, 0.5)
                                    stargate.engageSymbol(newAddress[i])
                                end
                                if (mustwaitUntilState or args.speed == nil) and args.speed~=0 then
                                    waitUntilState()
                                else
                                    os.sleep(delayTime)
                                end
                                if i == totalGlyphs then
                                    if speedDial and gateType == "MW" then
                                        waitUntilState()
                                        print("Pressing big red button.")
                                        _, engageResult, errormsg = dhd.pressBRB()
                                        if engageResult~="dhd_engage" then 
                                            print("BRB = "..engageResult)
                                        end
                                    else
                                        repeat 
                                            currentDialedAddress = stargate.dialedAddress
                                            os.sleep()
                                            gateStatus = stargate.getGateStatus()
                                        until string.gsub(currentDialedAddress:sub(currentDialedAddress:len()-lastGlyph:len()), "]", "") == lastGlyph and gateStatus == "idle"
                                        engageResult = stargate.engageGate()
                                        if engageResult == "stargate_engage" then
                                            print("Stargate engaged: true")
                                        end
                                    end
                                end
                            end
                        end
                        --print("Finished dialing protocol. Time elapsed: "..(computer.uptime() - dialStart))
                        irisStatus = stargate.getIrisState()
                        if settings.kawooshAvoidance and irisType~="NULL" and irisStatus == "CLOSED" then
                            thread.create(function() 
                                if not engageResult:match("fail") then 
                                    repeat os.sleep(0.1) until gateStatus =="open"
                                    waitTicks(20)
                                end
                                waitForIris("OPENED", 0)
                            end)
                        end
                        if engageResult == "stargate_engage" or engageResult == "dhd_engage" or hasEngagedGate then
                            print("Commencing IDC procedure.")
                            settings.lastWormhole = "outgoing"
                            writeSettingsFile()
                            broadcast(settings.listeningPorts[1], "gdswakeup")
                            send(sender, port, "gdsCommandResult: Successfully dialed. "..(args.IDC~=-1 and "Sent IDC." or ""))
                            
                            if type(args.IDC)=="number" then
                                waitUntilState("open")
                                os.sleep(1)
                                local sentCount, msg = 0, "Gate did not respond to IDC."
                                local validMessage = false
                                local noResponseCount = 0
                                repeat
                                    if sentCount > 0 then 
                                        if sentCount == 1 then 
                                            print("Bad response, sending IDC again.")
                                        end
                                        os.sleep(1)
                                    end
                                    
                                    msg = sendIDC(args.IDC, 3)
                                    validMessage = (msg ~= "Iris is busy!" and not msg:match("Code accepted"))
                                    if msg == "No IDC response." and noResponseCount < 5 then
                                        validMessage = false
                                        noResponseCount = noResponseCount + 1
                                    end
                                    if msg == "Iris closed. Resend IDC." then --retry since the PC just turned on
                                        sentCount = 0
                                        validMessage = false
                                        noResponseCount = 0
                                        send(sender, port, "gdsCommandResult: Detected security measure. Resending IDC.")
                                    end
                                    sentCount = sentCount + 1
                                    if sentCount == 5 and not validMessage then
                                        send(sender, port, "gdsCommandResult: Awaiting response...")
                                    end
                                until validMessage or sentCount == 10 -- or msg == ""
                                print("IDC Response: "..msg.." took "..sentCount.." tries.")
                                waitTicks(5)
                                send(sender, port, "gdsCommandResult: "..msg)
                            end
                        else
                            waitTicks(5)
                            send(sender, port, "gdsCommandResult: Dialing error: "..errormsg)
                        end
                    end)
                elseif command == "close" then
                    lastReceived[userprocessKey] = lastReceived[userprocessKey] or currentTime-3
                    if currentTime - lastReceived[userprocessKey] > 2 then
                        lastReceived[userprocessKey] = currentTime
                        local returnstr
                        gateStatus = stargate.getGateStatus()
                        if gateStatus == "open" then 
                            stargate.disengageGate()
                            returnstr="Clearing address..."
                        end
                        if threads.dialing and threads.dialing:status()=="running" then 
                            threads.dialing:kill()
                            returnstr="Killed dialing thread."
                            local hasClosed, err
                            if irisType~="NULL" then
                                hasClosed, err = waitForIris("OPENED", 0, false)
                                if err then
                                    print("Iris malfunction, cannot avoid kawoosh:", err)
                                end
                            end
                        elseif stargate.dialedAddress~="[]" then
                            stargate.abortDialing()
                            returnstr="Aborting dialing..."
                            
                        end
                        
                        print(returnstr)
                        waitTicks(5)
                        send(sender, port, "gdsCommandResult: " .. returnstr)
                    end
                elseif command == "iris" then
                    lastReceived[userprocessKey] = lastReceived[userprocessKey] or currentTime-2
                    if currentTime - lastReceived[userprocessKey] > 1 then
                        lastReceived[userprocessKey] = currentTime
                        if threads.iris then threads.iris:kill() end
                        irisType = tostring(stargate.getIrisType())
                    
                        local totalIDCs = 0
                        for i,v in pairs (settings.IDCs) do
                            totalIDCs = totalIDCs + 1
                        end
                        local validIDC = args.IDC and settings.IDCs[args.IDC]
                        if totalIDCs == 0 or validIDC then
                             
                            print("Iris access authorized.")
                            irisStatus = stargate.getIrisState()
                            local succ, err
                            if validIDC and irisType=="NULL" then
                                send(sender, port, "gdsCommandResult: Iris not detected.")
                            end
                            if irisType~="NULL" then
                                threads.iris = thread.create(function()
                                    if args.irisValue == "toggle" then --need to rewrite and simplify this (probably migrate this logic to clientinterface)
                                        local newstate = irisStatus:match("OPEN") and "CLOSED" or "OPENED"
                                        succ, err = waitForIris(newstate)
                                    elseif args.irisValue then
                                        succ, err = waitForIris("OPENED")
                                    elseif args.irisValue == false then
                                        succ, err = waitForIris("CLOSED")
                                    end
                                    irisStatus = stargate.getIrisState()
                                    print("Iris state is",irisStatus)
                                    send(sender, port, "gdsCommandResult: " .. (succ and ("Iris state set to "..irisStatus) or ("Iris error:"..(err and err or " unknown bug."))))
                                end)
                            end
                        else
                            send(sender, port, "gdsCommandResult: Invalid IDC.")
                            --if stargate.getIrisState() == "OPENED" then --might need to wait to make sure no one is coming through if that's possible, or wait extra long if they have sent the wrong code before
                            --    stargate.toggleIris()
                            --end
                        end
                    end
                elseif command == "query" then
                    lastReceived[userprocessKey] = lastReceived[userprocessKey] or currentTime-6
                    if currentTime - lastReceived[userprocessKey] > 5 then
                        lastReceived[userprocessKey] = currentTime
                        threads.query = thread.create(send, sender, port, gatedataTable)
                    end
                elseif command == "update" then
                    lastReceived[command] = lastReceived[command] or currentTime-35
                    if currentTime - lastReceived[command] > 30 then --and not already updating
                        if not args.force then
                            print("Waiting for threads to finish execution before updating..")
                            thread.waitForAll(threads)
                        end
                        print("Starting update thread..")
                        threads.update = thread.create(function() 
                            if settings.networkAdminPassword~=nil and settings.networkAdminPassword == args.networkPassword then
                                --unfinished
                                --local incomingFileHeap = {...}
                            else
                                --make sure theres no important threads running, but override if force is provided
                                local succ, err = gitUpdate("gatecomputer.lua","/gds/", args.force) --need to work in option for force
                                print("Attempting to update..")
                                local returnstr = "gdsCommandResult: " .. (succ and "Successfully updated gatecomputer." or ("Update failed: "..err))
                                send(sender, port, returnstr )
                                print(succ and "Successfully updated gatecomputer." or ("Update failed: "..err))
                                if succ then --and finds autostart, else report back that computer needs manual reboot for update to take effect
                                    os.sleep(5)
                                    computer.shutdown(true)
                                else
                                    --inform tablet of status?
                                end
                            end
                        end)
                    end
                elseif command == "kawooshavoidance" then
                    --toggle kawoosh avoidance
                    if type(args.kawooshValue) == "boolean" then
                        settings.kawooshAvoidance = args.kawooshValue
                        writeSettingsFile()
                        send(sender, port, "gdsCommandResult: kawooshAvoidance set to "..tostring(settings.kawooshAvoidance))
                    end
                end
            end
        end
    end),
      
    received_code = event.listen("received_code", function(_, _, _, code)
        if threads.IDCHandler then threads.IDCHandler:kill() end --could add a check to see if the partial address dialed matches the current one and continue from there
        threads.IDCHandler = thread.create(function() 
            code = math.floor(code)
            settings.lastReceivedIDC = code
            writeSettingsFile()
            local plr = settings.IDCs[code]
            print("IDC receieved..", code, tostring(plr))
            irisType = tostring(stargate.getIrisType())
            if irisType~="NULL" then 
                if plr then
                    print("IDC Valid: "..(code).." | "..plr)
                    waitUntilState("open")
                    local hasOpened, err = waitForIris("OPENED", 0, false)
                    if err then 
                        print("IRIS MALFUNCTION:",err,"\nConsider setting Stargate to OC mode.") 
                        stargate.sendMessageToIncoming("Iris is jammed.")
                        os.exit()
                    end
                    while irisStatus~="OPENED" do
                        irisStatus = stargate.getIrisState()
                        print("IRIS STATUS", irisStatus)
                        stargate.sendMessageToIncoming("Iris is busy!")
                        os.sleep(0.25) 
                    end
                    print("Iris is open. Welcome", plr)
                    stargate.sendMessageToIncoming("Gate is open!")
                    if settings.autoSyncToIncoming and not settings.isPrivate then 
                        threads.autosync = thread.create(broadcast, settings.listeningPorts[1], gatedataTable)
                    end
                else
                    waitTicks(20)
                    stargate.sendMessageToIncoming("Invalid IDC.")
                    if stargate.getIrisState() == "OPENED" then
                        stargate.toggleIris()
                    end
                end
            else
                waitUntilState("open")
                waitTicks(20)
                stargate.sendMessageToIncoming("Gate is open!")
                if settings.autoSyncToIncoming and not settings.isPrivate then 
                    threads.autosync = thread.create(broadcast, settings.listeningPorts[1], gatedataTable)
                end
            end
            threads.IDCHandler:kill()
        end)
    end),
    --[[stargate_traveler = event.listen("stargate_traveler", function(...)--address, caller, inbound, isPlayer, entityClass)
        print(...)
    end),]]
    
    --[[code_respond = event.listen("code_respond", function(...)--_, _, caller, msg) --the message from the destination computer
        --msg = string.sub(msg, 1, -3)
        print(...)--caller, msg)
    end),]]

    interruptedEvent = event.listen(
        "interrupted",
        function()
            isRunning = false
        end
    )
}

if settings.autoGitUpdate then
    local function autoPull(forceupdate) 
        local succ, err = gitUpdate("gatecomputer.lua","/gds/",forceupdate) 
        print("autoGitUpdate:",succ,err)
        if succ then --check for autostart
            print("Rebooting..")
            os.sleep(5)
            computer.shutdown(true) 
        end 
    end
    autoPull()
    EventListeners.gitAutoUpdate = event.timer(60 * 60, autoPull, math.huge)
end

if not settings.runInBackground then
    while isRunning and HadNoError do
        os.sleep(0.1)
    end

    for eventname, listener in pairs(EventListeners) do
        event.cancel(listener)
    end
    EventListeners = nil

    for name, thread in pairs(threads) do
        thread:kill()
    end
    threads = nil
end