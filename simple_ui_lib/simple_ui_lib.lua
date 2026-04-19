local component = require("component")
local gpu = component.gpu

NO_CHANGE = "__no_change__"
math.randomseed(os.time())

-- Skins
Skins = {}
Skins.DEFAULT = {
    SINGLE = "□",
    SMALL_VERTICAL_BODY = "║",
    SMALL_VERTIKAL_TOP = "─",
    SMALL_VERTIKAL_BOTTOM = "─",
    SMALL_HORIZONTAL_BODY = "═",
    SMALL_HORIZONTAL_LEFT = "│",
    SMALL_HORIZONTAL_RIGHT = "│",
    TOP_LINE = "─",
    BOTTOM_LINE = "─",
    LEFT_LINE = "│",
    RIGHT_LINE = "│",
    CORNER_TOP_LEFT = "┌",
    CORNER_TOP_RIGHT = "┐",
    CORNER_BOTTOM_LEFT = "└",
    CORNER_BOTTOM_RIGHT = "┘",
    BACKGROUND = " "
  }

function SkinFromDefault(t)
  setmetatable(t, { __index = Skins.DEFAULT })
  return t
end

Skins.DOUBLE = SkinFromDefault({
  TOP_LINE = "═",
  BOTTOM_LINE = "═",
  LEFT_LINE = "║",
  RIGHT_LINE = "║",
  CORNER_TOP_LEFT = "╔",
  CORNER_TOP_RIGHT = "╗",
  CORNER_BOTTOM_LEFT = "╚",
  CORNER_BOTTOM_RIGHT = "╝",
})

-- currenty broken
Skins.BLOCKY = SkinFromDefault({
  SINGLE = "🬎",
  TOP_LINE = "🬋",
  BOTTOM_LINE = "🬋",
  LEFT_LINE = "🬓",
  RIGHT_LINE = "🬓",
  CORNER_TOP_LEFT = "🬚",
  CORNER_TOP_RIGHT = "🬩 ",
  CORNER_BOTTOM_LEFT = "🬱",
  CORNER_BOTTOM_RIGHT = "🬍",
})

Skins.CHECKERBOARD = SkinFromDefault({
  SINGLE = "🮕",
  TOP_LINE = "🮕",
  BOTTOM_LINE = "🮕",
  LEFT_LINE = "🮕",
  RIGHT_LINE = "🮕",
  CORNER_TOP_LEFT = "",
  CORNER_TOP_RIGHT = "",
  CORNER_BOTTOM_LEFT = "",
  CORNER_BOTTOM_RIGHT = "",
  BACKGROUND = "░"
})

Skins.NONE = "NONE"

-- rest of the library
local function randomHexDigit()
  return string.format("%x", math.random(0, 15))
end

local function generateRandomId(length)
  local id = {}
  for i = 1, length do
      id[i] = randomHexDigit()
  end
  return table.concat(id)
end

local function clamp(value, min, max)
  if value < min then
    return min
  elseif value > max then
    return max
  else
    return value
  end
end

local View = {}
View.__index = View

local Rect = {}
Rect.__index = Rect

function View.new(x_res, y_res, bg_color, fg_color)
  local self = setmetatable({}, View)
  self.rects = {}
  self.order = {}
  self.x_res = x_res
  self.y_res = y_res
  self.bg_color = bg_color or 0x000000 -- defaults to black
  self.fg_color = fg_color or 0xffffff -- defaults to white

  return self
end

function View:drawRect(rect, x1, y1, x2, y2, active_skin)
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  
  if active_skin ~= Skins.NONE then
    local skin = active_skin or Skins.DEFAULT

    -- set correct color
    local bg_color = rect.bg_color or self.bg_color
    local fg_color = rect.fg_color or self.fg_color
    gpu.setBackground(rect.border_bg_color or bg_color)
    gpu.setForeground(rect.border_fg_color or fg_color)

    local x_dist = x2 - x1
    local y_dist = y2 - y1

    -- single cell
    if x_dist == 0 and y_dist == 0 then
      gpu.set(x1, y1, skin.SINGLE)
      return

    -- vertical line
    elseif x_dist == 0 then
      if y_dist > 2 then
        gpu.fill(x1, y1+1, 1, y_dist-1, skin.SMALL_VERTICAL_BODY)
      end
      gpu.set(x1, y1, skin.SMALL_VERTIKAL_TOP)
      gpu.set(x2, y2, skin.SMALL_VERTIKAL_BOTTOM)
      return

    -- horizontal line
    elseif y_dist == 0 then
      if x_dist > 2 then
        gpu.fill(x1+1, y1, x_dist-1, 1, skin.SMALL_HORIZONTAL_BODY)
      end
      gpu.set(x1, y1, skin.SMALL_HORIZONTAL_LEFT)
      gpu.set(x2, y2, skin.SMALL_HORIZONTAL_RIGHT)
      return
    end

    -- top and bottom
    if x_dist > 1 then
      gpu.fill(x1+1, y1, x_dist-1, 1, skin.TOP_LINE)
      gpu.fill(x1+1, y2, x_dist-1, 1, skin.BOTTOM_LINE)
    end

    -- left and right
    if y_dist > 1 then
      gpu.fill(x1, y1+1, 1, y_dist-1, skin.LEFT_LINE)
      gpu.fill(x2, y1+1, 1, y_dist-1, skin.RIGHT_LINE)
    end

    -- corners
    gpu.set(x1, y1, skin.CORNER_TOP_LEFT)
    gpu.set(x2, y1, skin.CORNER_TOP_RIGHT)
    gpu.set(x1, y2, skin.CORNER_BOTTOM_LEFT)
    gpu.set(x2, y2, skin.CORNER_BOTTOM_RIGHT)
  end
end

local emptydraw = function(x, y, w, h)
end

function Rect.new(x, y, w, h, draw, bg_color, fg_color, border_bg_color, border_fg_color, skin)
  local self = setmetatable({}, Rect)
  self.x = x
  self.y = y
  self.w = w
  self.h = h
  self.data = nil
  if type(draw) == "table" then
    self.draw = draw
  elseif type(draw) == "function" then
    self.draw = {draw}
  elseif draw == nil then
    self.draw = {emptydraw}
  else
    error("Invalid 'draw' parameter: must be function, table of functions, or nil")
  end
  self.bg_color = bg_color
  self.fg_color = fg_color
  self.border_bg_color = border_bg_color
  self.border_fg_color = border_fg_color
  self.skin = skin or Skins.DEFAULT

  return self
end

function Rect:setData(data)
  self.data = data
end

function Rect:mergeData(data)
  if self.data == nil then
    self.data = data
  else
    for k,v in pairs(data) do self.data[k] = v end
  end
end

function Rect:getData()
  return self.data
end

function Rect:getCenter()
  local x_center = math.floor(self.x + self.w / 2)
  local y_center = math.floor(self.y + self.h / 2)
  return x_center, y_center
end

function View:newRect(x, y, w, h, draw, bg_color, fg_color, border_bg_color, border_fg_color, skin)
  local newRect = Rect.new(x, y, w, h, draw, bg_color, fg_color, border_bg_color, border_fg_color, skin)
  local rect_id = generateRandomId(16)
  -- prevent id collision
  while self.rects[rect_id] ~= nil do
      rect_id = generateRandomId(16)
  end
  self.rects[rect_id] = newRect
  table.insert(self.order, 1, rect_id)
  return rect_id
end

function View:removeRect(id)
  if self.rects[id] == nil then
    return false
  else
    self.rects[id] = nil
    -- Also remove from order
    for i, v in ipairs(self.order) do
      if v == id then
        table.remove(self.order, i)
        break
      end
    end
    return true
  end
end

function View:getClickRect(x,y)
  for i, id  in pairs(self.order) do
    local rect = self.rects[id]
    if x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h then
      return id
    end
  end
  return nil
end

function View:clearScreen(x1_pos, y1_pos, x2_pos, y2_pos, bg_color, fg_color, skin)
  local x1 = clamp(x1_pos or 1, 1, self.x_res)
  local y1 = clamp(y1_pos or 1, 1, self.y_res)
  local x2 = clamp(x2_pos or self.x_res, 1, self.x_res)
  local y2 = clamp(y2_pos or self.y_res, 1, self.y_res)

  local used_skin = skin or Skins.DEFAULT

  gpu.setBackground(bg_color or self.bg_color)
  gpu.setForeground(fg_color or self.fg_color)
  gpu.fill(x1, y1, x2 - x1 + 1, y2 - y1 + 1, used_skin.BACKGROUND)
end

--draws screen. does not clear screen before drawing
function View:drawScreen()
  local removed_ids = {}
  for i = #self.order, 1, -1 do
    local rect_id = self.order[i]
    local current_rect = self.rects[rect_id]
    local x2 = current_rect.x + current_rect.w
    local y2 = current_rect.y + current_rect.h

    self:clearScreen(current_rect.x, current_rect.y, x2, y2, current_rect.bg_color, current_rect.fg_color, current_rect.skin)
    self:drawRect(current_rect, current_rect.x, current_rect.y, x2, y2, current_rect.skin)
    -- invoke all special draw functions
    gpu.setBackground(current_rect.bg_color or self.bg_color)
    gpu.setForeground(current_rect.fg_color or self.fg_color)
    for i, f in ipairs(current_rect.draw) do
      f(self, rect_id, current_rect:getData())
    end
  end
  -- reset colors
  gpu.setBackground(self.bg_color)
  gpu.setForeground(self.fg_color)
end

-- moves rect to the top of the render order 
function View:moveToTop(value)
    local index = nil
    -- Find the index of the value
    for i, v in ipairs(self.order) do
        if v == value then
            index = i
            break
        end
    end

    -- If not found or already at front, do nothing
    if not index or index == 1 then
        return
    end

    table.remove(self.order, index)
    table.insert(self.order, 1, value)
end

function View:getAllRects()
  local new = {}
    for k, v in pairs(self.order) do
        new[k] = v
    end
    return new
end

-- rect manipulation
local function setIfChanged(current, newVal, allowNil)
  local a_nil = allowNil or false
  if (newVal ~= nil or a_nil == true) and newVal ~= NO_CHANGE then
    return newVal
  else
    return current
  end
end

function View:rectGetColors(id)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  return {selected_rec.bg_color, selected_rec.fg_color, selected_rec.border_bg_color, selected_rec.border_fg_color}
end

function View:rectSetColors(id, colors)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  selected_rec.bg_color = setIfChanged(selected_rec.bg_color, colors[1], true)
  selected_rec.fg_color = setIfChanged(selected_rec.fg_color, colors[2], true)
  selected_rec.border_bg_color = setIfChanged(selected_rec.border_bg_color, colors[3], true)
  selected_rec.border_fg_color = setIfChanged(selected_rec.border_fg_color, colors[4], true)
end

function View:rectGetCenter(id)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  return selected_rec:getCenter()
end

function View:rectGetPos(id)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  return {selected_rec.x, selected_rec.y, selected_rec.w, selected_rec.h}
end

function View:rectSetPos(id, pos)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  selected_rec.x = setIfChanged(selected_rec.x, pos[1])
  selected_rec.y = setIfChanged(selected_rec.y, pos[2])
  selected_rec.w = setIfChanged(selected_rec.w, pos[3])
  selected_rec.h = setIfChanged(selected_rec.h, pos[4])
end

function View:rectSetData(id, data, mergeData)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end

  if mergeData then
    selected_rec:mergeData(data)
  else
    selected_rec:setData(data)
  end
end

function View:rectGetData(id)
  local selected_rec = self.rects[id]
  if selected_rec == nil then
    error("Invalid 'View:rectSetPos' parameter: must be valid rect id")
    return nil
  end
  return selected_rec:getData()
end

-- clears screen and then draws all elements
function View:redrawScreen()
  self:clearScreen()
  self:drawScreen()
end

-- unrelated helper functions
function View:cleanupScreen()
  self:clearScreen(1,1, self.x_res, self.y_res, 0x000000, 0xffffff)
end

function GenerateRandomColor()
  local r = math.random(0, 255)
  local g = math.random(0, 255)
  local b = math.random(0, 255)
  return (r << 16) + (g << 8) + b
end

-- export objects
return {
  View = View,
}

