local component = require("component")
local gpu = component.gpu

local ListAPI = {}
ListAPI.Lists = {}

local List = {}
List.__index = List

function List.new(name, sizex, sizey, posx, posy, parent)
    local newlist = setmetatable({}, List)
    newlist.parent = parent
    newlist.name = tostring(name) or "List"
    
    sizex, sizey = sizex or 5, sizey or 5
    newlist.size = {x = math.max(math.floor(sizex+0.5), 5); y = math.max(math.floor(sizey+0.5), 5)}
    newlist.pos = {x = (math.floor(posx+0.5) or 0)+1, y = (math.floor(posy+0.5) or 0)+1}

    newlist.backgroundcolor = 0x000000
    
    --t.borders = 
    newlist.visible = false
    newlist.active = true

    newlist.entries = {}
    newlist.currententry = nil
    newlist.displaystart = 1

    table.insert(ListAPI.Lists, newlist)
    return newlist
end

function List:addEntry(newstr, index, refresh)
    local added = false
    if newstr and self.active then
        --newstr = newstr:sub(1, self.size.x)
        if index==nil then
            table.insert(self.entries, newstr)
            added = true
        elseif type(index) == "number" then
            table.insert(self.entries, index, newstr)
            added = true
        end
    end
    if (refresh==nil or refresh == true) and self.active then
        self:display()
    end
    return added
end

function List:removeEntry(selector)
    if self.active then
        if type(selector) == "string" then
            local found = self:getIndexFromName(selector)
            if found then
                selector = found
                table.remove(self.entries, found)
            end
        elseif type(selector) == "number" then
            selector = math.floor(selector)
            if selector > 0 and selector <= #self.entries then
                table.remove(self.entries, selector)
            end
        elseif type(selector) == "nil" then
            selector = #self.entries
            table.remove(self.entries, selector)
        end
    end
    if type(selector) == "number" then
        return selector
    end
end

function List:getIndexFromName(name)
    if type(name)~="string" then return end
    local foundIndex = nil
    name = name:lower()
    for i, entry in ipairs (self.entries) do
        if entry:lower()==name or entry:sub(1, name:len()):lower() == name or name:sub(1, entry:len()) == entry:lower() then
            foundIndex = i
            break
        end
    end
    return foundIndex
end

function List:selectEntry(selector)
    if self.active then
        if type(selector) == "string" then
            local found = getIndexFromName(selector)
            if found then
                self.currententry = found
                self:display()
            end
        elseif type(selector) == "number" then
            selector = math.min(math.max(math.floor(selector), 1), #self.entries)
            self.currententry = selector
            self:display()
        end
    end
    return self.currententry
end

function List:unselect(selector)
    if self.active then
        if type(selector) == "string" then
            local found = getIndexFromName(selector)
            if found then
                self.currententry = nil
                self:display()
            end
        elseif type(selector) == "number" then
            selector = math.min(math.max(math.floor(selector), 1), #self.entries)
            if self.currententry == selector then 
                self.currententry = nil
                self:display()
            end
        elseif type(selector) == "nil" then
            self.currententry = nil
            self:display()
        end
    end
end

function List:lock()
    self.active = false
end

function List:unlock()
    self.active = true
end

function List:clear()
    if self.active then
        self.entries = {}
        self.currententry = nil
        self:display()
    end
end

function List:scroll(direction)
    if self.active then
        direction = math.min(math.max(math.floor(direction) or 1, -1), 1)
        if direction == 0 then direction = 1 end
        local newdisplaystart = math.min(math.max(self.displaystart+direction, 1), #self.entries)
        if #self.entries - newdisplaystart > self.size.y - 2 then
            self.displaystart = newdisplaystart
            self:display()
        end
    end
    return self.displaystart
end

function List:display()
    if #self.entries > 0 and self.active then
        self.visible = true
        local startx = self.pos.x
        local starty = self.pos.y
        local previousBackground = gpu.getBackground()
        gpu.setBackground(0x000000)
        gpu.fill(startx, starty, self.size.x+1, self.size.y, " ")
        local listiterator = 0
        for i = self.displaystart, self.displaystart+math.min(#self.entries-self.displaystart, self.size.y-1) do
            if i == self.currententry then gpu.setBackground(0x878787) else gpu.setBackground(0x000000) end
            gpu.set(startx, starty+listiterator, (i..": "..self.entries[i]):sub(1, self.size.x)) --..startx.." "..starty.." "..self.size.x.." "..self.size.y
            listiterator = listiterator + 1
        end
        gpu.setBackground(previousBackground)
    end
end

function List:hide()
    if self.active and self.visible then
        self.visible = false
        gpu.fill(self.pos.x, self.pos.y, self.size.x+1, self.size.y, " ")
    end
end

function List:touch(x, y, softtouch)
    local wasTouched = x >= self.pos.x and x < self.pos.x + self.size.x and y >= self.pos.y and y < self.pos.y + self.size.y
    if self.active and self.visible and wasTouched and (softtouch == false or softtouch == nil)  then
        local verticaldifference = y-self.pos.y
        self:selectEntry(self.displaystart+verticaldifference)
    end
    return wasTouched
end

ListAPI.List = List
return ListAPI