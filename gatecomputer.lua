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

local isPrivate = false --determines whether or not the sender username is checked against the allowed list
local networkAdminUUID = nil --defaults to the first wireless card that interacts if not set in installation
local networkAdminPassword = "password" --
local allowedList = {} -- [player uuid] = true
local IDCs = {} --[IDC] = true
local canSpeedDial = true
local currentAddress = {}
local listeningPorts = {160}
local commandLog = {} --table.insert(commandLog, sender.." "..self.command)
local threads = {} --threads.example = thread.create(function() end); threads.example:kill(); threads.example:suspend()
local lastReceived = {} -- for wireless messages

term.clear()
if component.isAvailable("modem") then
    modem = component.modem
    print("Wireless modem UUID: "..modem.address)
    for i, port in ipairs (listeningPorts) do
        modem.open(port)
        print("Opened port "..port)
    end
else
    print("Wireless modem not connected.")
    os.exit()
end

if component.isAvailable("stargate") then
    stargate = component.stargate
    gateType = stargate.getGateType()
    if gateType:sub(1,1) == "M" then 
        gateType = "MW"
    elseif gateType:sub(1,1) == "P" then 
        gateType = "PG"
    elseif gateType:sub(1,1) == "U" then 
        gateType = "UN"
    end
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

print("Starting gate dialer program.")
--send(sadd, 100, {gate.getGateType(), state, gate.dialedAddress, serial.serialize(gate.stargateAddress)})
local function send(address, port, msg)
    modem.send(address, port, tostring(msg))
    os.sleep(0.05)
end

local function broadcast(port, msg)
    modem.broadcast(port, tostring(msg))
    os.sleep(0.05)
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
    
    end),

    stargate_open = event.listen("stargate_open", function(_, _, caller, isInitiating) 
    
    end),

    stargate_wormhole_stabilized = event.listen("stargate_wormhole_stabilized", function(_, _, caller, isInitiating) 
    
    end),

    stargate_close = event.listen("stargate_close", function(_, _, caller, reason) 
    
    end),

    stargate_wormhole_closed_fully = event.listen("stargate_wormhole_closed_fully", function(_, _, caller, isInitiating) 
    
    end),

    stargate_failed = event.listen("stargate_failed", function(_, _, caller, reason) 
    
    end),

    modem_message = event.listen("modem_message", function(_, receiver, sender, port, distance, msg)
        if type(msg) == "string" then
            local currentTime = computer.uptime()
            if msg:sub(1, 4) == "gds{" and msg:sub(msg:len()) == "}" and msg:len() > 10 then -- maybe send "username:{}" ?
                print("Receiving instructions..."..msg:sub(4))
                local msgdata = load("return "..msg:sub(4))() --{comman = cmd; args = {}; user = {name=username; uuid = uuid}}
                local command = msgdata.command
                local args = msgdata.args
                local user = msgdata.user
                local userprocessKey = command..sender --useful for tracking actions by a specific user instead of total interaction by a specific user
                local canProcess = true
                if isPrivate then
                    if type(user) == "table" then
                        if type(user.name) == "string" then
                            canProcess = allowedList[user.name]
                        else
                            canProcess = false
                        end
                    else
                        canProcess = false
                    end
                end
                if canProcess then
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
                                print("Invalid address: "..newAddressStr)
                                os.exit()
                            else
                                print("Found address: "..newAddressStr)
                            end
                            local lastGlyph = newAddress[#newAddress]
                            if lastGlyph ~= "Point of Origin" and lastGlyph~="Glyph 17" and lastGlyph~="Subido" then
                                lastGlyph = (gateType=="MW" and "Point of Origin") or (gateType=="UN" and "Glyph 17") or (gateType=="PG" and "Subido")
                                table.insert(newAddress, lastGlyph)
                                print("Address missing POI, adding POI...")
                            end 
                            print("Checking if address exists...")
                            local addressCheck = stargate.getEnergyRequiredToDial(table.unpack(newAddress))
                            local gateStatus = stargate.getGateStatus()
                            local glyphStart, hasEngagedGate = 1, false
                            local currentDialedAddress = stargate.dialedAddress
                            local totalGlyphs = #newAddress
                            if totalGlyphs > 7 and type(addressCheck) == "table" then --see if it can be done with less glyphs
                                for check = 1, totalGlyphs-7 do
                                    local newCheckAddress = {}
                                    for i=1, totalGlyphs-2 do
                                        table.insert(newCheckAddress, newAddress[i])
                                    end
                                    table.insert(newCheckAddress, lastGlyph) --poi
                                    print("Checking address: "..table.concat(newCheckAddress,", "))
                                    local newCheck = stargate.getEnergyRequiredToDial(table.unpack(newCheckAddress))
                                    if type(newCheck) == "table" then
                                        newAddress = newCheckAddress
                                        totalGlyphs = #newAddress
                                        print("Found shorter address:"..#newAddress)
                                    --else
                                    --    print("Shortest address is "..totalGlyphs.." glyphs.")
                                    --    break
                                    end
                                end
                            end
                            if currentDialedAddress~="[]" then --check if currently dialed glyphs match the new address
                                if newAddressStr:sub(1, currentDialedAddress:len()-1) == string.gsub(currentDialedAddress,"]","") then
                                    print("Partial address match")
                                    local glyphsSplit = strsplit(currentDialedAddress:sub(2, currentDialedAddress:len()-1), ",")
                                    for i,v in ipairs (glyphsSplit) do
                                        if v:sub(1,1) == " " then v = v:sub(2) end
                                        print("split",i,"|"..v.."|")
                                        if newAddress[i] == v then
                                            glyphStart = i + 1
                                        else
                                            glyphStart = 1
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
                                    repeat 
                                        os.sleep()
                                    until stargate.getGateStatus() == "idle"
                                end
                            end
                            print("Glyph starting index = "..tostring(glyphStart))
                            if type(addressCheck)=="table" and stargate.getGateStatus() == "idle" then
                                local speedDial = (args.fast or false) and canSpeedDial
                                local successfullyDialed, dialStart = false, computer.uptime()
                                print("Valid address.")
                                print("canSpeedDial = "..tostring(canSpeedDial)..". args.fast = "..tostring(args.fast))
                                for i=glyphStart, totalGlyphs do
                                    print("> Glyph "..i..": "..newAddress[i])
                                    if speedDial then
                                        if gateType~="MW" then
                                            repeat 
                                                os.sleep(0.5)
                                            until stargate.getGateStatus() == "idle"
                                        end
                                        local _, result, errormsg = dhd.pressButton(newAddress[i])
                                        if result ~= "dhd_pressed" then
                                            if result == "dhd_not_connected" then
                                                computer.pushSignal("stargate_failed","",true,result)
                                            end
                                            print("DHD: "..result,"Err: "..errormsg)
                                            return -- exit dialing thread
                                        end
                                    else
                                        repeat 
                                            os.sleep(0.5)
                                        until stargate.getGateStatus() == "idle"
                                        stargate.engageSymbol(newAddress[i])
                                    end
                                    if i == totalGlyphs then
                                        if speedDial and gateType == "MW" then
                                            repeat 
                                                os.sleep()
                                            until stargate.getGateStatus() == "idle"
                                            print("Pressing big red button.")
                                            local _, result, errormsg = dhd.pressBRB()
                                            if result~="dhd_engage" then 
                                                print("BRB = "..result)
                                            end
                                        else
                                            repeat 
                                                currentDialedAddress = stargate.dialedAddress
                                                os.sleep()
                                            until string.gsub(currentDialedAddress:sub(currentDialedAddress:len()-lastGlyph:len()), "]", "") == lastGlyph and stargate.getGateStatus() == "idle"
                                            print("Stargate engaged: "..tostring(stargate.engageGate()=="stargate_engage"))
                                        end
                                    end
                                    os.sleep()
                                end
                                print("Finished dialing. Time elapsed: "..(computer.uptime() - dialStart))
                            else
                                print("Address check failed. Error: "..addressCheck)
                            end
                            
                        end)
                    elseif command == "close" then
                        lastReceived[sender] = lastReceived[sender] or currentTime-3
                        if currentTime - lastReceived[sender] > 2 then
                            lastReceived[sender] = currentTime
                            local gateStatus = stargate.getGateStatus()
                            if gateStatus == "open" then 
                                stargate.disengageGate()
                                print("Resetting address...")
                            elseif gateStatus == "dialing" then
                                stargate.abortDialing()
                                print("Aborting dialing...")
                            end
                        end
                    elseif command == "iris" then
                        --todo
                    elseif command == "query" then
                        lastReceived[sender] = lastReceived[sender] or currentTime-6
                        if currentTime - lastReceived[sender] > 5 then
                            lastReceived[sender] = currentTime
                            local returntbl = "gdsgate"..serialization.serialize({
                                gateType = gateType;
                                Address = {
                                    MW = stargate.stargateAddress.MILKYWAY;
                                    PG = stargate.stargateAddress.PEGASUS;
                                    UN = stargate.stargateAddress.UNIVERSE;
                                };
                                uuid = modem.address
                            })
                            threads.send= thread.create(send, sender, port, returntbl)
                            print(returntbl)
                        end
                    elseif command == "" then
                    end
                else
                    print("Cannot process command.")
                end
            end
        end
    end),
      
    received_code = event.listen("received_code", function(_, _, _, code)
      --[[if IDC == code then
        if sg.getIrisState() == "CLOSED" then
          sg.toggleIris()
          sg.sendMessageToIncoming("IDC Accepted!")
        else
          if IrisType == "SHIELD" then
            sg.sendMessageToIncoming("Shield is Off!")
          else
            sg.sendMessageToIncoming("Iris is Open!")
          end
        end
      elseif IDC ~= code and sg.getIrisState() == "CLOSED" then
        sg.sendMessageToIncoming("IDC is Incorrect!")
      end
    end),
    
    code_respond = event.listen("code_respond", function(_, _, caller, msg)
      msg = string.sub(msg, 1, -3)
      alert(msg, 2)
      OutgoingIDC = nil
      ]]
    end),
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