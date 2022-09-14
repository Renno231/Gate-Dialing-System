local component = require("component")
local gpu = component.gpu

local WindowAPI = {}
WindowAPI.CurrentWindows = {}

local Window = {}
Window.__index = Window

local borders = {
    horizontal = "═";
    vertical = "║";
    corners = {
        top = {left = "╔"; right = "╗"};
        bottom = {left = "╚"; right = "╝"}
    };
    textedge = {left = "╡"; right = "╞"}
}

function Window.new(name, sizex, sizey, posx, posy, parent) --maybe add in additional settings
    local t = setmetatable({}, Window)
    t.parent = parent
    t.name = tostring(name) or "Window"
    
    sizex, sizey = sizex or 5, sizey or 5
    t.size = {x = math.max(math.floor(sizex+0.5), 5); y = math.max(math.floor(sizey+0.5), 5)}
    t.pos = {x = (math.floor(posx+0.5) or 0)+1, y = (math.floor(posy+0.5) or 0)+1}

    t.backgroundcolor = 0x000000
    
    --t.borders = 
    t.visible = true
    t.active = true

    t.subwindows = {}
    t.tabs = {}
    t.buttons = {}
    t.currenttab = nil -- index
    t.tabsumlength = 0
    t.tabsalignmentmode = 3 --1 = left, 2 = middle, 3 = right, right of position is default
    table.insert(WindowAPI.CurrentWindows, t)
    return t
end

function Window:lock()
    self.active = false
end

function Window:unlock()
    self.active = true
end

function Window:resize(x, y, redraw)
    if type(x) == "number" and type(y) == "number" then
        if x~=self.size.x or y~=self.size.y then
            self:eraseBorders()
            self.size.x = math.max(x or self.size.x, 5)
            self.size.y = math.max(y or self.size.y, 5)
            if redraw==true or redraw==nil then
                --need to account for shrinking on each axis
                self:drawBorders()
                self:refreshTabs() --erase places where there were walls and then redraw them leaving interior intact unless the interior is too small
            end
        end
    end
end
--[[
function Window:move(x, y, redraw)
    self.pos.x = x or self.pos.x
    self.pos.y = y or self.pos.y
    if redraw==true or redraw==ni then
        --do a copy operation here
        self:display()
    end
end]]

function Window:getPixelRangeFromTab(selector) --return {x = -1, y = 1} by default
    tabindex = -1
    if type(selector) == "number" then
        tabindex = selector
    elseif type(selector) == "string" then
        for i, tab in ipairs (self.tabs) do
            if tab.Name == selector then
                tabindex = i
            end
        end
    end
    if tabindex > 0 and tabindex <= #self.tabs then
        self.currenttab = tabindex
        self:refreshTabs(true)
    end
end

function Window:setDefaultTabAlignment(tabmode)
    local datatype = type(tabmode)
    if datatype == "number" then
        tabmode = math.min(math.max(tabmode, 1), 3)
        self.tabsalignmentmode = tabmode

        for i, tab in ipairs (self.tabs) do
            tab.alignmenttype = tabmode
        end
        self:refreshTabs()
    end
end

function Window:addTab(name, offset, func, alignment, highlight, textcolor, backgroundcolor) --if offset > 1 = distance from the left corner in pixels, else offset = distance in percent of the size of the window 
    local totaltabs = #self.tabs
    local nametype = type(name)
    if nametype == "nil" then 
        name = "Untitled"
    elseif nametype == "number" then
        name = tostring(name)
    end
    nametype = type(name)
    if nametype=="string" then
        if type(alignment) == "nil" then
            alignment = self.tabsalignmentmode --default alignment
        elseif type(alignment) == "number" then
            alignment = math.min(math.max(alignment, 1), 3)
        end
        if  type(offset) == "nil" then --auto offset
            offset = #self.tabs
            if offset>0 then
                for i, tab in ipairs (self.tabs) do
                    if tab.offset+tab.size >= offset then
                        offset = tab.offset + tab.size  -- the extra 1 might not be needed
                    end
                end
                --offset = offset + 1
            end
        end
        local alignmenttype = 0.5*alignment-1.5
        local position = offset
        if offset > 0 and offset < 1 then --defaults to absolute position, but if bigger than 0 and less than 1 then position is relative
            position = self.size.x * offset
        end

        if name:len() > 0 and (position + (name:len() * alignmenttype)) < self.size.x and position >= 0 then -- make sure the name is right and the tab isn't running off the window
            local newtab = {
                Name = name;
                func = func;
                color = textcolor or 0xFFFFFF;
                highlightcolor = highlight or 0x878787;
                backgroundcolor = backgroundcolor or self.backgroundcolor;
                offset = offset;
                alignmenttype = alignment;
                selected = false;
            }
            newtab.Name = newtab.Name:sub(1, 12)
            newtab.size = newtab.Name:len() + 2
            if self.tabsumlength + newtab.size < self.size.x then -- make sure all tabs can fit
                self.tabsumlength = self.tabsumlength + newtab.size -- keep track of total tab length
                if totaltabs == 0 and position > 0 then
                    self.tabsumlength = self.tabsumlength - 1 --found the little bug
                end
                self.tabs[totaltabs + 1] = newtab
                self:refreshTabs()
            end
            return newtab
        end
    end
end

function Window:refreshTabs(rerun)
    if #self.tabs > 0 then
        local screensizex, screensizez = gpu.getResolution()
        local ypos = self.pos.y
        local startx = self.pos.x
        if self.tabsonbottom==true then
            ypos = ypos + self.size.y
        end
        gpu.fill(startx+ 1, ypos, self.size.x-1, 1, borders.horizontal)
        local alignmentoffset, position --could combine the alignment variables
        local sametab, namecheckiterator
        for i, tab in ipairs (self.tabs) do -- if theres room, show the tab
            alignmentoffset = 0.5*tab.alignmenttype-1.5
            position = tab.offset
            if position > 0 and position < 1 then --defaults to absolute position, but if bigger than 0 and less than 1 then position is relative
                position = self.size.x * position
            end
            alignmentoffset = (tab.Name:len()+2) * alignmentoffset
            position = math.min(math.max(startx + position + alignmentoffset, 2), screensizex)
            
            local screengrab = ""
            for grabpos=1, tab.Name:len() do
                screengrab = screengrab .. gpu.get(position + grabpos, ypos)
            end
            --print(position, "|",gpu.get(position, ypos))
            --print("fukoff i =", i, "in bounds:", position, self.size.x, position > -1,"|", gpu.get(position, ypos)=="═")
            if position < startx + self.size.x and position > -1 and (gpu.get(position, ypos) == "═" or screengrab == tab.Name ) then --also use gpu.get to check if its one of the container characters 

                gpu.set(position, ypos, borders.textedge.left) --left bracket but not on the corner
                if self.currenttab == i then
                    gpu.setBackground(tab.highlightcolor) --maybe add in foreground color
                else
                    gpu.setBackground(self.backgroundcolor)
                end
                gpu.set(position + 1, ypos, tab.Name) -- one over from the edge
                gpu.setBackground(self.backgroundcolor)
                gpu.set(position + 1 + tab.Name:len(), ypos, borders.textedge.right) -- on the end of the tab name

            end
        end
        if type(self.currenttab) == "number" and rerun==true then
            if type(self.tabs[self.currenttab]) == "table" then
                if type(self.tabs[self.currenttab].func) == "function" then
                    self.tabs[self.currenttab].func()
                end
            end
        end
    end
end

function Window:selectTab(selector) -- string or number
    tabindex = -1
    if type(selector) == "number" then
        tabindex = selector
    elseif type(selector) == "string" then
        for i, tab in ipairs (self.tabs) do
            if tab.Name == selector then
                tabindex = i
            end
        end
    end
    if tabindex > 0 and tabindex <= #self.tabs then
        self.currenttab = tabindex
        self:refreshTabs(true)
    end
end

function Window:display()
    if self.active==true then
        self:clear()
        self:drawBorders()
        self:refreshTabs()
    end
end

function Window:write(x, y, what)
    what = tostring(what)
    if type(x) == "number" and type(y) == "number" and type(what) == "string" and self.active==true then 
        local strlength = what:len()
        x = math.min(math.max(x, 1), self.size.x-1);
        y = math.min(math.max(y, 1), self.size.y-1);
        local overlapx = (x + strlength) - self.size.x
        if (overlapx>-1) then
            what = what:sub(0, math.floor(strlength - overlapx))
        end
        --also account for vertical height by counting line ends with gsub('\n')
        gpu.set(self.pos.x + x, self.pos.y + y, what)
    end
end

function Window:fill(x, y, w, h, what)
    x, y, w, h = x or 0, y or 0, w or 1, h or 1
    x = math.min(math.max(x, self.pos.x+1), self.pos.x+self.size.x-1);
    y = math.min(math.max(y, self.pos.y+1), self.pos.y+self.size.y-1);
    w = math.min(math.max(x, self.size.x+1), self.size.x);
    h = math.min(math.max(y, self.pos.y+1), self.pos.y+self.size.y-1);
    gpu.fill(x, y, w, h, what or " ")
end

function Window:hide()

end

function Window:clear()
    gpu.setBackground(self.backgroundcolor)
    gpu.fill(self.pos.x+1, self.pos.y+1, self.size.x-1, self.size.y-1, " ") -- clear the slate
end

function Window:drawBorders()
    local vert, hor = borders.vertical, borders.horizontal
    local startx, starty = self.pos.x, self.pos.y
    local endx, endy = startx + self.size.x, starty + self.size.y
    gpu.set(self.pos.x, self.pos.y, borders.corners.top.left)
    gpu.set(self.pos.x + self.size.x, self.pos.y, borders.corners.top.right)
    gpu.set(self.pos.x, self.pos.y + self.size.y, borders.corners.bottom.left)
    gpu.set(self.pos.x + self.size.x, self.pos.y + self.size.y, borders.corners.bottom.right)

    gpu.fill(startx, starty+1, 1, self.size.y-1, vert)
    gpu.fill(endx, starty+1, 1, self.size.y-1, vert)

    gpu.fill(startx+1, self.pos.y, self.size.x-1, 1, hor)
    gpu.fill(startx+1, endy, self.size.x-1, 1, hor)
end

function Window:eraseBorders()
    local empty = " "
    local startx, starty = self.pos.x, self.pos.y
    local endx, endy = startx + self.size.x, starty + self.size.y
    gpu.set(self.pos.x, self.pos.y, empty)
    gpu.set(self.pos.x + self.size.x, self.pos.y, empty)
    gpu.set(self.pos.x, self.pos.y + self.size.y, empty)
    gpu.set(self.pos.x + self.size.x, self.pos.y + self.size.y, empty)

    gpu.fill(startx, starty+1, 1, self.size.y-1, empty)
    gpu.fill(endx, starty+1, 1, self.size.y-1, empty)

    gpu.fill(startx+1, self.pos.y, self.size.x-1, 1, empty)
    gpu.fill(startx+1, endy, self.size.x-1, 1, empty)
end

function Window:touch(x ,y, softtouch)
    local wasTouched = x >= self.pos.x and x < self.pos.x + self.size.x and y >= self.pos.y and y <= self.pos.y + self.size.y
    if self.visible and self.active and wasTouched and (softtouch == false or softtouch == nil)  then
        local screensizex, screensizez = gpu.getResolution()
        local rx, ry = x - self.pos.x, y - self.pos.y --relative offset of the window
        local startx = self.pos.x
        if y == self.pos.y then --tabs
            local foundtab = nil
            for i, tab in ipairs (self.tabs) do
                local alignmentoffset = 0.5*tab.alignmenttype-1.5
                local position = tab.offset
                if position > 0 and position < 1 then --defaults to absolute position, but if bigger than 0 and less than 1 then position is relative
                    position = self.size.x * position
                end
                alignmentoffset = (tab.Name:len()+2) * alignmentoffset
                position = math.min(math.max(startx + position + alignmentoffset, 2), screensizex)
                if x >= position and x <= position+tab.Name:len() then
                    self:selectTab(i)
                    break
                end
            end
        --else --everything else

        end
    end
    return wasTouched
end

WindowAPI.Window = Window
return WindowAPI