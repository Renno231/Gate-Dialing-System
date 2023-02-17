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

local modem
local stargate
local dhd 
local isRunning, HadNoError = true, true
local gateType

local SettingsFile = "/gds/settings.cfg"
local settings = {
    allowedList = {};
    IDCs = {};
    listeningPorts = {160};
    networkAdminPassword = false;
    networkAdminUUID = false;
    isPrivate = false;
    autoSyncToIncoming = true;
}

local canSpeedDial = true
local mustWaitUntilIdle = false
local commandLog = {} --table.insert(commandLog, sender.." "..self.command)
local threads = {} --threads.example = thread.create(function() end); threads.example:kill(); threads.example:suspend()
local lastReceived = {} -- for wireless messages
local gateStatus = "idle"
local lastSuccessfulDial = nil
local jsgVersion
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
    gateType = stargate.getGateType():sub(1,1)
    gateType = (gateType == "M" and "MW") or (gateType == "P" and "PG") or (gateType == "U" and "UN")
    
    gatedataTable = "gdsgate"..serialization.serialize({
        gateType = gateType;
        Address = {
            MW = stargate.stargateAddress.MILKYWAY;
            PG = stargate.stargateAddress.PEGASUS;
            UN = stargate.stargateAddress.UNIVERSE;
        };
        uuid = modem.address
    })
    jsgVersion, _ = tonumber(stargate.getJSGVersion():sub(-8):gsub("[.]",""))
    mustWaitUntilIdle = jsgVersion > 41103
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

local function waitUntilIdle(step)
    repeat 
        os.sleep(step)
    until stargate.getGateStatus() == "idle"
end

local function sendIDC(code, timeout)
    stargate.sendIrisCode(code)
    local _, _, caller, msg = event.pull(1, "code_respond")
    local pulls = 1
    timeout = timeout -1
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

print("Starting gate dialer program.")
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

local EventListeners = {
    --stargate_spin_chevron_engaged = event.listen("stargate_spin_chevron_engaged", function(_, _, caller, num, lock, glyph) end),

    --stargate_dhd_chevron_engaged = event.listen("stargate_dhd_chevron_engaged", function(_, _, caller, num, lock, glyph) end),

    stargate_incoming_wormhole = event.listen("stargate_incoming_wormhole", function(_, _, caller, dialedAddressSize) 
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
                local validPayload, msgdata = pcall(load("return "..msg:sub(4))) --{comman = cmd; args = {}; user = {name=username; uuid = uuid}}; might need to wrap this in something like pcall
                if not msgdata or not validPayload or type(msgdata)~="table" then print("Invalid message payload") return end
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
                        if currentDialedAddress~="[]" and gateStatus~="open" then 
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
                                hasEngagedGate = stargate.engageGate()
                                print("Engaging stargate: "..tostring(hasEngagedGate))
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
                                waitUntilIdle()
                            end
                        end
                        print("Glyph starting index = "..tostring(glyphStart))
                        if stargate.getGateStatus() == "idle" then
                            local speedDial = (args.speed and args.speed < 1 or false) and canSpeedDial
                            local delayTime = (args.speed or 0) / totalGlyphs + 1
                            local engageResult, errormsg, dialStart = false, "", computer.uptime()
                            print("Valid address.")
                            print("canSpeedDial = "..tostring(canSpeedDial)..". args.speed = "..tostring(args.speed))
                            for i = glyphStart, totalGlyphs do
                                print("> Glyph "..i)
                                if speedDial then
                                    if gateType~="MW" then
                                        waitUntilIdle(0.5)
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
                                    waitUntilIdle(0.5)
                                    stargate.engageSymbol(newAddress[i])
                                end
                                if i == totalGlyphs then
                                    if speedDial and gateType == "MW" then
                                        
                                        waitUntilIdle()
                                        print("Pressing big red button.")
                                        _, engageResult, errormsg = dhd.pressBRB()
                                        if engageResult~="dhd_engage" then 
                                            print("BRB = "..engageResult)
                                        end
                                    else
                                        repeat 
                                            currentDialedAddress = stargate.dialedAddress
                                            os.sleep()
                                        until string.gsub(currentDialedAddress:sub(currentDialedAddress:len()-lastGlyph:len()), "]", "") == lastGlyph and stargate.getGateStatus() == "idle"
                                        engageResult = stargate.engageGate()
                                        if engageResult == "stargate_engage" then
                                            print("Stargate engaged: true")
                                        end
                                    end
                                end
                                if mustWaitUntilIdle or args.speed == nil then
                                    waitUntilIdle()
                                else
                                    os.sleep(delayTime)
                                end
                            end
                            print("Finished dialing protocol. Time elapsed: "..(computer.uptime() - dialStart))
                            if engageResult == "stargate_engage" or engageResult == "dhd_engage" then
                                send(sender, port, "gdsCommandResult: Successfully dialed. "..(args.IDC~=-1 and "Sent IDC." or ""))
                                if type(args.IDC)=="number" then
                                    repeat 
                                        os.sleep()
                                    until gateStatus == "open"
                                    local sentCount, msg = 0, "Gate did not respond to IDC."
                                    repeat
                                        if sentCount > 0 then 
                                            if sentCount == 1 then 
                                                print("Bad response, sending IDC again.")
                                            end
                                            os.sleep(1)
                                        end
                                        
                                        msg = sendIDC(args.IDC, 10)
                                        sentCount = sentCount + 1
                                        if sentCount == 5 then
                                            send(sender, port, "gdsCommandResult: Still waiting for response...")
                                        end
                                    until (msg ~= "Iris is busy!" and not msg:match("Code accepted")) or sentCount == 10 -- or msg == ""
                                    print("IDC Response: "..msg.." took "..sentCount.." tries.")
                                    waitTicks(15)
                                    send(sender, port, "gdsCommandResult: "..msg)
                                end
                            else
                                waitTicks(15)
                                send(sender, port, "gdsCommandResult: Dialing error: "..errormsg)
                            end
                            
                        else
                            print("Address check failed. Error: "..addressCheck)
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
                        elseif stargate.dialedAddress~="[]" then
                            stargate.abortDialing()
                            returnstr="Aborting dialing..."
                        end
                        print(returnstr)
                        waitTicks(5)
                        send(sender, port, "gdsCommandResult: " .. returnstr)
                    end
                elseif command == "iris" then
                    --todo
                elseif command == "query" then
                    lastReceived[userprocessKey] = lastReceived[userprocessKey] or currentTime-6
                    if currentTime - lastReceived[userprocessKey] > 5 then
                        lastReceived[userprocessKey] = currentTime
                        threads.query = thread.create(send, sender, port, gatedataTable)
                    end
                elseif command == "update" then
                    if settings.networkAdminPassword~=nil and settings.networkAdminPassword == args.networkPassword then
                        local incomingFileHeap = {...}
                    else
                        send(sender, port, "gdsCommandResult: Insufficient network permissions. Password is invalid or password is not set.")
                    end
                end
            end
        end
    end),
      
    received_code = event.listen("received_code", function(_, _, _, code)
        if threads.IDCHandler then threads.IDCHandler:kill() end --could add a check to see if the partial address dialed matches the current one and continue from there
        threads.IDCHandler = thread.create(function() 
            code = math.floor(code)
            print("IDC receieved.. "..tostring(settings.IDCs[code]))
            local hasIris = tostring(stargate.getIrisType())
            if hasIris~="NULL" then 
                if settings.IDCs[code] then
                    print("IDC Valid:"..(code).." : "..settings.IDCs[code])
                    repeat 
                        os.sleep()
                    until gateStatus == "open"
                    if stargate.getIrisState() == "CLOSED" then
                        stargate.toggleIris()
                        --stargate.sendMessageToIncoming("IDC Accepted! Opening iris...")
                        repeat 
                            os.sleep()
                        until stargate.getIrisState() == "OPENED"
                    end
                    print("Iris is open.")
                    waitTicks(20)
                    stargate.sendMessageToIncoming("Gate is open!")
                    if settings.autoSyncToIncoming then 
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
                repeat 
                    os.sleep()
                until gateStatus == "open"
                waitTicks(20)
                stargate.sendMessageToIncoming("Gate is open!")
                if settings.autoSyncToIncoming then 
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