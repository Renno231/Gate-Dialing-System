local component = require("component")
local gpu = component.gpu

local TextBox = {}
TextBox.__index = TextBox

function TextBox.new(posx, posy, width)
    local newbox = setmetatable({}, TextBox)
    newbox.active = true
    newbox.visible = false
    newbox.selected = false
    newbox.cursorpos = 1
    newbox.width = math.max(5, math.floor(width+0.5) or 5)
    newbox.pos = {x = (math.floor(posx+0.5) or 0)+1, y = (math.floor(posy+0.5) or 0)+1}
    newbox.text = ""

    return newbox
end

function TextBox:getInput()
    return self.text
end

function TextBox:moveCursor(offset)
    if type(offset) == "number" then
        self.cursorpos = math.min(math.max(self.cursorpos + offset, 1), self.text:len()+1)
    end
end

function TextBox:setCursor(newpos)
    if type(newpos) == "number" then
        self.cursorpos = math.min(math.max(newpos, 1), self.text:len()+1)
    end
end

function TextBox:addText(txt)
    if txt then
        txt = tostring(txt)
        local index = self.cursorpos
        if index >= self.text:len() then
            self.text = self.text..txt
        else
            self.text = self.text:sub(1, index-1)..txt..self.text:sub(index)
        end
        self:moveCursor(txt:len())
    end
end

function TextBox:trim(direction) -- 
    if direction == nil then direction = -1 end
    local currentlength = self.text:len()
    if currentlength > 0 and (direction==-1 or direction == 1) and self.cursorpos+direction > 0 then
        if self.cursorpos > currentlength then -- on the end
            if direction == -1 then
                self.text = self.text:sub(1, currentlength+direction)
            end
        else
            if direction == -1 then
                self.text = self.text:sub(1, self.cursorpos+direction*2)..self.text:sub(self.cursorpos)
                self:moveCursor(-1)
            elseif direction == 1 then
                self.text = self.text:sub(1, self.cursorpos-direction)..self.text:sub(self.cursorpos+direction)
            end
        end
    end
end

function TextBox:display()
    local previousForeground = gpu.getForeground()
    local previousBackground = gpu.getBackground()
    self.visible = true
    --set background
    gpu.setBackground(0x333333)
    gpu.fill(self.pos.x, self.pos.y, self.pos.x + self.width, 1, " ")
    
    --gpu.setForeground(0x333333)
    local currentlength = self.text:len()
    if self.cursorpos >= currentlength and currentlength>self.width then
        gpu.set(self.pos.x, self.pos.y, 
            self.text:sub(math.max(currentlength-self.width, 0))
        ) 
    elseif self.cursorpos < currentlength and currentlength>self.width then --not perfect, needs refinement
        local startpos = math.max(1, currentlength-(self.width+(currentlength-self.cursorpos)))
        gpu.set(self.pos.x, self.pos.y, 
            self.text:sub(startpos, startpos + self.width) -- math.max(self.width+2, currentlength-(currentlength-self.cursorpos))) --math.max(currentlength-self.width, 0))
        ) 
    elseif currentlength <= self.width then
        gpu.set(self.pos.x, self.pos.y, 
            self.text
        )
    end
    --gpu.setForeground(previousForeground)
    if self.selected then --needs fixing 
        gpu.setBackground(0xA0A0A0)
        gpu.set(self.pos.x+math.max(1, (self.cursorpos%self.width)-1), self.pos.y, " ")
    end
    gpu.setBackground(previousBackground)

    --gpu.setForeground(previousForeground)
end

function TextBox:touch(x, y, softtouch)
    local wasTouched = x >= self.pos.x and x <= self.pos.x + self.width and y == self.pos.y
    if self.visible and self.active and wasTouched and (softtouch == false or softtouch == nil) then
        self.selected = true
        if self.text:len() > self.width then
            self:moveCursor()
        else
            self:setCursor(x)
        end
    else
        self.selected = false
    end
    return wasTouched
end

function TextBox:clear()
    self.text = ""
    self:setCursor(1)
    self:display()
end

return TextBox