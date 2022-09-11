local term = require("term")
local unicode = require("unicode")
local component = require("component")
local gpu = component.gpu

local ButtonAPI = {}
ButtonAPI.Buttons = {}

local Button = {}
Button.__index = Button

local CheckBox = {}
CheckBox.__index = CheckBox

function Button.new(xPos, yPos, width, height, label, func, border)
  local self = setmetatable({}, Button)
  if xPos < 1 or xPos > term.window.width then xPos = 1 end
  if yPos < 1 or yPos > term.window.height then yPos = 1 end
  if (width-2) < unicode.len(label) then width = unicode.len(label)+2 end
  if height < 3 then height = 3 end
  if border == nil then
    self.border = true
  else
    self.border = border
  end
  self.xPos = xPos
  self.yPos = yPos
  self.width = width
  self.height = height
  self.label = label
  self.func = func
  self.visible = false
  self.disabled = false
  
  table.insert(ButtonAPI.Buttons, self)
  return self
end

function Button:display(x, y)
    if (self.width-2) < unicode.len(self.label) then self.width = unicode.len(self.label)+2 end
    if x ~= nil and y ~= nil then
        self.xPos = x
        self.yPos = y
    end
    --[[if self.parent then
        --math.min(math.max(x, lowerlimit), upperlimit);
        self.xPos = math.min(math.max(self.xPos + self.parent.pos.x, self.parent.pos.x+1), self.parent.pos.x+self.parent.size.x-1) 
        self.yPos = math.min(math.max(self.yPos + self.parent.pos.y, self.parent.pos.y+1), self.parent.pos.y+self.parent.size.y-1)  
    end]]
    if self.border then
        gpu.fill(self.xPos+1, self.yPos, self.width-2, 1, "─")
        gpu.fill(self.xPos+1, self.yPos+self.height-1, self.width-2, 1, "─")
        gpu.fill(self.xPos, self.yPos+1, 1, self.height-2, "│")
        gpu.fill(self.xPos+self.width-1, self.yPos+1, 1, self.height-2, "│")
        gpu.set(self.xPos, self.yPos, "┌")
        gpu.set(self.xPos+self.width-1, self.yPos, "┐")
        gpu.set(self.xPos, self.yPos+self.height-1, "└")
        gpu.set(self.xPos+self.width-1, self.yPos+self.height-1, "┘")
    end
    gpu.set(self.xPos+1, self.yPos+1, self.label)
    self.visible = true
end

function Button:hide()
    self.visible = false
    if self.border then
        gpu.fill(self.xPos, self.yPos, self.width, self.height, " ")
    else
        gpu.fill(self.xPos+1, self.yPos+1, self.width-2, 1, " ")
    end
end

function Button:disable(bool)
  if bool == nil then
    self.disabled = false
  else
    self.disabled = bool
  end
  if self.disabled then gpu.setForeground(0x0F0F0F) end
  if self.visible then self:display() end
  gpu.setForeground(0xFFFFFF)
end

function Button:touch(x, y)
  local wasTouched = false
  if self.visible and not self.disabled then  
    if self.border then
      if x >= self.xPos and x <= (self.xPos+self.width-1) and y >= self.yPos and y <= (self.yPos+self.height-1) then wasTouched = true end
    else
      if x >= self.xPos+1 and x <= (self.xPos+self.width-2) and y >= self.yPos+1 and y <= (self.yPos+self.height-2) then wasTouched = true end
    end
  end
  if wasTouched then
    gpu.setBackground(0x878787)
    gpu.set(self.xPos+1, self.yPos+1, self.label)
    gpu.setBackground(0x000000)
    if self.visible then gpu.set(self.xPos+1, self.yPos+1, self.label) end
    self.func()
  end
  return wasTouched
end

--checkboxes
function CheckBox.new(xPos, yPos, tbl, tblKey, func)
  local self = setmetatable({}, CheckBox)
  self.xPos = xPos
  self.yPos = yPos
  self.tbl = tbl
  self.tblKey = tblKey
  self.visible = false
  self.disabled = false
  self.isChecked = self.tbl[self.tblKey]
  self.func = func
  return self
end

function CheckBox:display(isChecked, x, y)
  if isChecked ~= nil then
    self.isChecked = isChecked
  end  
  if x ~= nil and y ~= nil then
    self.xPos = x
    self.yPos = y
  end
  gpu.set(self.xPos, self.yPos, "[ ]")
  if self.isChecked then
    gpu.setForeground(0x00FF00)
    gpu.set(self.xPos+1, self.yPos, "X")
    gpu.setForeground(0xFFFFFF)
  end
  self.visible = true
end

function CheckBox:hide()
  self.visible = false
  gpu.fill(self.xPos, self.yPos, 3, 1, " ")
end

function CheckBox:disable(bool)
  if bool == nil then
    self.disabled = false
  else
    self.disabled = bool
  end
  if self.disabled then gpu.setForeground(0x0F0F0F) end
  if self.visible then self:display() end
  gpu.setForeground(0xFFFFFF)
end

function CheckBox:touch(x, y)
  local wasTouched = false
  if self.visible and not self.disabled and x >= self.xPos and x < (self.xPos+3) and y == self.yPos then
    wasTouched = true
  end
  if wasTouched then
    if self.isChecked then
      self.isChecked = false
    elseif not self.isChecked then
      self.isChecked = true
    end
    self.tbl[self.tblKey] = self.isChecked
    self.func()
    self:display()
  end
  return wasTouched
end

ButtonAPI.Button = Button
ButtonAPI.CheckBox = CheckBox

return ButtonAPI --Button, CheckBox, Buttons
--[[
function Button:forceTouch()
  self:touch(self.xPos+1, self.yPos+1)
end]]