local uiSuccess, ui = pcall(require, "ui_lib")
local jsonSuccess, json = pcall(require, "json")
local comp = require("component")
local event = require("event")
local term = require("term")
local sides = require("sides")
local computer = require("computer")

-- settings
local programmName = "TeleportController"
local programmVersion = "0.8"
local tpDataSourceUrl = "https://zappic.dev/files/gtnh_teleporters.json"
local statusBarSize = 3 -- less than 3 is unusable
local teleportDepartDelay = 3
local teleportArriveDelay = 3
local timeSinceLastWalkForArrival = 10
local timeSinceLastWalkForSleep = 5 * 60
local spatialDiskName = "appliedenergistics2:item.ItemSpatialStorageCell"
local ackTokenName = "minecraft:paper"
local enderchestName = "tile.enderchest"
local spatialIoName = "tile.appliedenergistics2.BlockSpatialIOPort"
local storageName = "tile.etfuturum.barrel"
local saveFile = "teleporterId.txt"

local baseUpdateInterval = 3600 -- 1 hour in seconds
local maxUpdateJitter = 300     -- Up to 5 minutes of randomness
local waitingForResponseTimeout = 10 -- in seconds

local hexToColor = {
  [0x0] = "White",
  [0x1] = "Orange",
  [0x2] = "Magenta",
  [0x3] = "Light Blue",
  [0x4] = "Yellow",
  [0x5] = "Lime",
  [0x6] = "Pink",
  [0x7] = "Gray",
  [0x8] = "Light Gray",
  [0x9] = "Cyan",
  [0xa] = "Purple",
  [0xb] = "Blue",
  [0xc] = "Brown",
  [0xd] = "Green",
  [0xe] = "Red",
  [0xf] = "Black",
}

-- runtime global variables
local localTeleporterId = nil
local localTeleporterName = nil
local localTeleporterFreq = 2560

local nextUpdate = computer.uptime() + baseUpdateInterval + math.random(0, maxUpdateJitter)
local teleporterData = nil
local locationSelectorView = nil
local activeRects = {}
local currentTpsVersion = 0
local teleportinProgress = false
local tpLogPos = 1
local lastWalkTime = computer.uptime()
local currentlySleeping = false

-- check requisite dependencies
local unmetReqs = false
if not comp.isAvailable("ender_chest") then
  print("Teleporter requires an Enderchest connected via an Adapter")
  unmetReqs = true
end
if not comp.isAvailable("redstone") then
  print("Teleporter requires a redstone card")
  unmetReqs = true
end
if not comp.isAvailable("internet") then
  print("Teleporter requires a internet card")
  unmetReqs = true
end
if not uiSuccess then
  print("Teleporter requires the 'ui_lib' library.")
  print("Place ui_lib.lua in /lib/ directory.")
  unmetReqs = true
end
if not jsonSuccess then
  print("Teleporter requires the 'json' library.")
  print("Place json.lua in /lib/ directory.")
  print("(https://github.com/rxi/json.lua)")
  unmetReqs = true
end

if unmetReqs then
  print("At least one requirement was not met. Exiting...")
    return
end

local gpu = comp.gpu
local screen = comp.screen
local ender_chest = comp.ender_chest
local redstone = comp.redstone
local transposer = comp.transposer
local internet = comp.internet

-- set resolution for sqare screens
local x_aspect, y_apsect = screen.getAspectRatio()
if x_aspect == y_apsect then
  local w, h = gpu.maxResolution()
  gpu.setResolution(2*h, h)
end


-- check transposer connected inventories
local enderchestSide = nil
local spatialIoSide = nil
local storageSide = nil

for i = 0, 5 do
    local invName = transposer.getInventoryName(i)
    if invName == enderchestName then
      enderchestSide = i
    elseif invName == spatialIoName then
      spatialIoSide = i
    elseif invName == storageName then
      storageSide = i
    end
end

if enderchestSide == nil or spatialIoSide == nil or storageSide == nil then
  print("Transposer is not connected with Enderchest, SpatialIO Port and/or Storage (" .. storageSide .. ")")
  print("Enderchest Side: " .. tostring(enderchestSide))
  print("SpatialIO Side: " .. tostring(spatialIoSide))
  print("Storage Side: " .. tostring(storageSide))
  return
end

local function decodeFreqToColor(freq)
  -- convert ferquency to 3-digit hex number
  local hexChars = "0123456789abcdef"
  local result = ""

  for i = 1, 3 do
      local remainder = freq % 16
      local char = hexChars:sub(remainder + 1, remainder + 1)
      result = char .. result
      freq = math.floor(freq / 16)
  end

  -- get colors corresponding to each hex digit
  local colors = {}
  for i = 1, #result do
    local digit = result:sub(i,i)
    local index = tonumber(digit, 16)
    colors[i] = (index and hexToColor[index]) or "Unknown"
  end
  return colors
end

local function checkItemReqs()
  local hasError = false
  -- spatial disk in Storage
  local storageSlot1 = transposer.getStackInSlot(storageSide, 1)
  if storageSlot1 == nil or not string.find(storageSlot1.name, spatialDiskName) then
    print("No Spacial Storage Disk in Storage (1. slot).")
    hasError = true
  end
  -- spatial io output slot empty
  local spatialIoOutput = transposer.getStackInSlot(spatialIoSide, 2)
  if spatialIoOutput ~= nil then
    print("SpatialIO output slot needs to be empty.")
    hasError = true
  end
  -- spatial io input slot empty
  local spatialIoInput = transposer.getStackInSlot(spatialIoSide, 1)
  if spatialIoInput ~= nil then
    print("SpatialIO input slot needs to be empty.")
    hasError = true
  end
  -- ack token present in Storage
  local storageSlot2 = transposer.getStackInSlot(storageSide, 2)
  if storageSlot2 == nil or not string.find(storageSlot2.name, ackTokenName) then
    print("No tokens found in Storage (2. slot). Insert one item of type " .. ackTokenName .. ".")
    hasError = true
  end
  -- no ack token in enderchest (that is set to this teleporters ferquency)
  local lastEnderchestSlot = transposer.getStackInSlot(enderchestSide, 27)
  if lastEnderchestSlot ~= nil then
    print("Item found in Enderchest (slot 27) that shouldnt be there.")
    hasError = true
  end
  -- no item in enderchest second slot
  local secondEnderchestSlot = transposer.getStackInSlot(enderchestSide, 2)
  if secondEnderchestSlot ~= nil then
    print("Item found in Enderchest (slot 2) that shouldnt be there.")
    hasError = true
  end


  if hasError then
    error("At least one error occured while checking items. Fix and try again!")
  end
end

local function centerTextXOffset(text, x_pos)
  local x = x_pos or 0
  return x - math.floor(#text / 2)
end

local function timeSinceLastWalk()
  return computer.uptime() - lastWalkTime
end

local function drawTpLog(text, centered)
  local x_res, y_res = gpu.getResolution()
  local logStartY = 1 -- Starting Y position (1-based in OC)
  local logStartX = 2
  local center = math.floor(x_res / 2)
  
  -- 1. Check if we reached the bottom of the screen
  if logStartY + tpLogPos > y_res then
    -- Copy the entire screen (except the first line) up by 1
    -- Parameters: x, y, width, height, deltaX, deltaY
    gpu.copy(1, logStartY + 1, x_res, y_res - logStartY, 0, -1)
    
    -- Clear the now-duplicated bottom line before writing new text
    gpu.fill(1, y_res, x_res, 1, " ")
    
    -- Keep the position at the last line
    tpLogPos = y_res - logStartY
  end

  -- 2. Draw the text
  local stringText = tostring(text)
  local xPos = logStartX
  if centered then
    xPos = centerTextXOffset(stringText, center)
  end

  gpu.set(xPos, logStartY + tpLogPos, stringText)
  
  -- 3. Increment position for next time
  tpLogPos = tpLogPos + 1
end

local function tpLogSetup()
  gpu.setBackground(0xFF0000)
  gpu.setForeground(0xFFFFFF)
  local x, y = gpu.getResolution()
  gpu.fill(1, 1, x, y, " ")
  tpLogPos = 1
end

local function tpLogCleanup()
  drawTpLog("Returning to menu in 3 seconds.")
  os.sleep(3)
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  local x, y = gpu.getResolution()
  gpu.fill(1, 1, x, y, " ")
  tpLogPos = 1
end

local function drawSymmetricalLoops(color1, color2, thickness)
  local w, h = gpu.getResolution()
  
  -- We use the vertical height as the constraint for iterations
  local iterations = math.floor(h / 2)
  
  -- Horizontal thickness is doubled to match visual vertical thickness
  local hThickness = thickness * 2
  local vThickness = thickness

  for i = 0, iterations - 1, vThickness * 2 do
    -- 1. Outer Rectangle
    gpu.setBackground(color1)
    -- X calculations are multiplied by 2 to keep proportions
    local rectX = (i * 2) + 1
    local rectY = i + 1
    local rectW = w - (i * 4)
    local rectH = h - (i * 2)
    
    if rectW <= 0 or rectH <= 0 then break end
    gpu.fill(rectX, rectY, rectW, rectH, " ")

    -- 2. Inner "Hole" Rectangle
    local innerX = rectX + hThickness
    local innerY = rectY + vThickness
    local innerW = rectW - (hThickness * 2)
    local innerH = rectH - (vThickness * 2)

    if innerW > 0 and innerH > 0 then
      gpu.setBackground(color2)
      gpu.fill(innerX, innerY, innerW, innerH, " ")
    end
  end
end

local function drawData(view, rect_id, data)
  local rectPos = view:rectGetPos(rect_id) -- [x, y, width, height]
  local rect_x, rect_y, rect_w, rect_h = rectPos[1], rectPos[2], rectPos[3], rectPos[4]
  local x_start = rect_x + 1              -- Left edge + 1 for padding

  -- Get the rectangle's colors, which were set right before this function was called
  local rect_colors = view:rectGetColors(rect_id)
  local text_color = rect_colors[2] or view.fg_color
  local rect_bg_color = rect_colors[1] or view.bg_color

  -- Calculate vertical starting position for the text block to be centered
  local num_lines = 3
  local y_middle = rect_y + math.floor(rect_h / 2)
  local y_start = y_middle - math.floor((num_lines - 1) / 2)

  if data == nil then
    local text = "No Data!"
    -- If no data, center the text
    local x_middle, y_mid = view:rectGetCenter(rect_id)
    gpu.setForeground(text_color)
    gpu.setBackground(rect_bg_color)
    gpu.set(centerTextXOffset(text, x_middle), y_mid, text)
  else
    local lines = {}
    local nameString = string.format("%s [%s]", data.name, data.id)
    table.insert(lines, nameString)

    local freqColors = decodeFreqToColor(data.freq)
    local freqString = string.format("📡: [%s, %s, %s | %s]", freqColors[1], freqColors[2], freqColors[3], data.freq)
    table.insert(lines, freqString)

    -- Set colors for the text block
    gpu.setForeground(text_color)
    gpu.setBackground(rect_bg_color)

    -- Iterate over the lines and draw them left-aligned
    local max_text_width = rect_w - 2 -- width minus 1 character padding on left and right
    for i, line in ipairs(lines) do
      -- Calculate vertical position
      local y_pos = y_start + (i - 1)
      
      -- Trim line if it exceeds the rectangle's width
      local text_to_draw = tostring(line)
      if utf8.len(line) > max_text_width then
        text_to_draw = string.sub(line, 1, max_text_width+1)
      end
      gpu.set(x_start, y_pos, text_to_draw)
    end
  end
end

local function updateStatusBar(view, rect_id, data)
  local rectPos = view:rectGetPos(rect_id)
  local rect_x, rect_y, rect_w, rect_h = rectPos[1], rectPos[2], rectPos[3], rectPos[4]
  local x_res, y_res = gpu.getResolution()

  local versionString = "v" .. programmVersion
  local colors = decodeFreqToColor(localTeleporterFreq)
  local thisTeleporterString = string.format("%s [%s, %s, %s | %s]", localTeleporterName, colors[1], colors[2], colors[3], tostring(localTeleporterFreq))
  local tpDataVersionString = "🗎: " .. currentTpsVersion
  local totalRightString = tpDataVersionString .. " | " .. versionString
  gpu.set(x_res-string.len(totalRightString), rect_y+1, totalRightString)
  gpu.set(rect_x+1, rect_y+1, thisTeleporterString)
end

local function updateRectPositioning(view, rectCount)
  if rectCount < 1 then return end
  -- quick fix, because 1 & 2 rects look stupid / wrong
  if rectCount < 3 then rectCount = 3 end

  local max_vertcal_rects = 4
  local y_buffer = 1
  local x_buffer = 3
  local x_res, y_res = gpu.getResolution()

  y_res = y_res - statusBarSize

  local y_size = math.floor((y_res-(y_buffer*4)) / max_vertcal_rects)
  if rectCount < 5 then
    y_size = math.floor((y_res-(y_buffer*(rectCount-1))) / rectCount)
  end

  local x_rows = math.ceil(rectCount / max_vertcal_rects)
  local total_x_buffer_width = x_buffer * (x_rows - 1)
  local x_size = math.floor((x_res - total_x_buffer_width) / x_rows)

  if x_rows == 1 then
    x_size = x_size - 1
  end

  -- create sorted table to ensure correct rect order
  local sortedRects = {}
  for addr, rect in pairs(activeRects) do
      table.insert(sortedRects, rect)
  end

table.sort(sortedRects, function(a, b)
    local posA = tonumber(a.pos) or 999
    local posB = tonumber(b.pos) or 999
    
    if posA ~= posB then
        return posA < posB
    end
    -- Tie-breaker: sort by name if positions are equal
    return (a.name or "") < (b.name or "")
end)
  -- update rect positions
  for i, rect in ipairs(sortedRects) do
    local newPos = {}
    local currentRow = math.ceil(i / max_vertcal_rects)
    local current_y_rect = i - (max_vertcal_rects * (currentRow-1))

    newPos[1] = (x_size + x_buffer) * (currentRow-1) +1 -- x
    newPos[2] = ((y_size + y_buffer) * (current_y_rect-1)) +1 + statusBarSize -- y
    newPos[3] = x_size -- width
    newPos[4] = y_size -- height
    view:rectSetPos(rect, newPos)
  end
end

local function updateTeleporterData()
  local content = ""
  
  local handle, reason = internet.request(tpDataSourceUrl)
  if not handle then
    print("Connection failed: " .. tostring(reason))
    return
  end

  -- Wait briefly for the server to acknowledge the request
  os.sleep(0.5)

  -- Improved chunk reading
  while true do
    local chunk = handle.read()
    if chunk then
      content = content .. chunk
    elseif chunk == nil then
      -- nil means the stream is officially closed/finished
      break
    end
    -- Prevent the computer from "hanging" on large files
    os.sleep(0)
  end

  if content ~= "" then
    local status, result = pcall(json.decode, content)
    if status then
      teleporterData = result
      print("Data updated successfully!")
    else
      print("JSON Error: " .. tostring(result))
    end
  else
    print("Error: Received 0 bytes from server.")
  end
end

local function to_num(val)
  if type(val) == "string" then
    -- Removes '#' or '0x' if present, then converts from base 16
    return tonumber(val:gsub("[#x]", ""), 16)
  end
  return val
end

local function updateTeleporterDisplay()
  if teleporterData ~= nil and teleporterData.version > currentTpsVersion then
    -- delete old teleporters
    local x_res, y_res = gpu.getResolution()
    locationSelectorView = ui.View.new(x_res, y_res, 0x000000, 0xffffff)
    activeRects = {}
 
    -- add new teleporters
    local rectCount = 0
    for id, tp in pairs(teleporterData.tps) do
      if id ~= localTeleporterId then
        local rect = locationSelectorView:newRect(10, 10, 30, 7, drawData)
        locationSelectorView:rectSetData(rect, {
          name = tp.name,
          freq = tp.frequency,
          icon = tp.icon,
          id = id,
          pos = tp.pos or 100
        })
        
        local colors = {
          to_num(tp.bg_color) or 0x000000,
          to_num(tp.fg_color) or 0xffffff,
          to_num(tp.border_bg_color) or to_num(tp.bg_color) or 0x000000,
          to_num(tp.border_fg_color) or to_num(tp.fg_color) or 0xffffff
        }

        locationSelectorView:rectSetColors(rect, colors)
        activeRects[id] = rect
        rectCount = rectCount + 1
      end
    end

    -- update data version
    currentTpsVersion = teleporterData.version

    -- add status bar
    locationSelectorView:newRect(1,1,x_res-1, statusBarSize-1, updateStatusBar)

    updateRectPositioning(locationSelectorView, rectCount)
    locationSelectorView:drawScreen()

  end
end

-- teleport away sequence
local function touchListener(_, screenAdress, x, y, button, playerName) -- button: 0-rechtsklick, 1-linksklick
  if teleportinProgress == false then
    if locationSelectorView == nil then
      error("locationSelectorView is nil")
    end

    local rect = locationSelectorView:getClickRect(x, y)
    if rect ~= nil then
      local data = locationSelectorView:rectGetData(rect)
      if data ~= nil then
        checkItemReqs() -- check reqs before teleporting
        teleportinProgress = true
        tpLogSetup()
        drawTpLog("##### TELEPORT IN PROGRESS #####", true)
        drawTpLog("##### DON'T INTERRUPT THIS DEVICE #####", true)
        local colors = decodeFreqToColor(data.freq)
        drawTpLog(string.format("Setting frequency to %s (%s, %s, %s)...", tostring(data.freq), colors[1], colors[2], colors[3]))
        ender_chest.setFrequency(data.freq)
        -- überprüfen ob ein teleportvorgang mit dem zielteleport momentan stattfindet
        drawTpLog("Check if target teleporter is already occupied...")
        while true do
          local enderchestFirstSlot = transposer.getStackInSlot(enderchestSide, 1)
          local enderchestLastSlot = transposer.getStackInSlot(enderchestSide, 27)
          if enderchestFirstSlot == nil and enderchestLastSlot == nil then
            drawTpLog("Target teleporter is not occupied!")
            break
          end
        end
        -- reserve teleporter
        drawTpLog("Reserve target teleporter...")
        transposer.transferItem(storageSide, enderchestSide, 1, 2, 27)

        -- check if teleporter is online
        drawTpLog("Wait for reciever response...")
        local startedWaitingForRecieverResponse = computer.uptime()
        while true do
          local enderchestLastSlot = transposer.getStackInSlot(enderchestSide, 27)
          if enderchestLastSlot then
            if enderchestLastSlot.size == 2 then
              drawTpLog("Reciever is online!")
              break
            end
          end
          if computer.uptime() > startedWaitingForRecieverResponse + waitingForResponseTimeout then
            drawTpLog("Reciever appears to be offline, aborting...")
            drawTpLog("Retrieving reservation token...")
            transposer.transferItem(enderchestSide, storageSide, 1, 27, 2)
            tpLogCleanup()
            locationSelectorView:drawScreen()
            ender_chest.setFrequency(localTeleporterFreq)
            teleportinProgress = false
            return
          end

        end

        drawTpLog("Teleporting in:")
        for i = teleportDepartDelay, 1, -1 do
          drawTpLog(tostring(i) .. "...", true)
          computer.beep(1000, 0.5)
          os.sleep(1)
        end
        computer.beep(200, 1)

        drawTpLog("Moving disk to SpatialIO Port...")
        transposer.transferItem(storageSide, spatialIoSide, 1, 1, 1)
        drawTpLog("Activating SpatialIO Port...")
        redstone.setOutput(sides.bottom, 15)
        redstone.setOutput(sides.bottom, 0)
        -- check if disk is in spatial storage output
        local spatialIoOutput = transposer.getStackInSlot(spatialIoSide, 2)
        if not spatialIoOutput or not string.find(spatialIoOutput.name, spatialDiskName) then
          error("No spatial storage disk in SpatialIO output slot found!")
        end
        drawTpLog("Found spatial storage disk in SpatialIO output slot...")
        -- disk in ender_chest legen
        drawTpLog("Transfering disk to enderchest...")
        transposer.transferItem(spatialIoSide, enderchestSide, 1, 2, 1)
        drawTpLog("Retreiving reservation token...")
        transposer.transferItem(enderchestSide, storageSide, 1, 27, 2)
        drawTpLog("Waiting for reciever ACK teleport..")
        drawTpLog("(if this step takes very long, something on the reciever side may be broken)")
        while true do
          local ack = transposer.getStackInSlot(enderchestSide, 27)
          if ack == nil then
            drawTpLog("Recieved ACKed teleport")
            break
          end
        end
        drawTpLog("Transfering disk from enderchets to Storage...")
        transposer.transferItem(enderchestSide, storageSide, 1, 1, 1)
        local colors = decodeFreqToColor(localTeleporterFreq)
        drawTpLog(string.format("Resetting frequency to %s (%s, %s, %s)...", localTeleporterFreq, colors[1], colors[2], colors[3]))
        ender_chest.setFrequency(localTeleporterFreq)
        drawTpLog("Teleporting sequence complete!")
        tpLogCleanup()
        locationSelectorView:drawScreen()
        teleportinProgress = false
      end
    end
  end
end

local function saveTeleporterId(string)
  local file, reason = io.open(saveFile, "w")
  if not file then
    error("couldn't open file " .. tostring(reason))
  end
  file:write(string)
  file:close()
end

local function loadTeleporterId()
  local file = io.open(saveFile, "r")
  if not file then
    return nil -- nil if file doesnt exist
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function letUserSetTeleporterId(tps)
  -- 1. List all teleporters
  term.clear()
  print("Available Teleporters")
  local index = 1
  local teleporters = {}

  for id, tp in pairs(tps) do
    teleporters[index] = id
    print("["..index.."] ".. tp.name .. " (" ..id..")")
    index = index+1
  end

  if index == 1 then
    print("No teleporters available!")
    return
  end
  -- 2. get user input
  print("Select which teleporter this is:")
  io.write("Enter a number > ")
  local choice = tonumber(io.read())

  if not choice or not teleporters[choice] then
    error("Invalid selection.")
  end

  -- 3. set variables accordingly
  localTeleporterId = teleporters[choice]
  localTeleporterName = tps[localTeleporterId].name
  localTeleporterFreq = tps[localTeleporterId].frequency

  -- 4. save user selection
  saveTeleporterId(localTeleporterId)
end

local function walkListener(name, screenAdress, x, y, playerName)
  lastWalkTime = computer.uptime()
  if currentlySleeping then
    if locationSelectorView then
      term.clear()
      locationSelectorView:drawScreen()
    end
    currentlySleeping = false
  end
end

local function cleanup()
  event.ignore("walk", walkListener)
  term.setCursorBlink(true)
  screen.setTouchModeInverted(false)
  redstone.setOutput(sides.bottom, 0)
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  term.clear()
  print("Program terminated successfully.")
end

local function recieveTeleport()
  teleportinProgress = true
  tpLogSetup()
  drawTpLog("##### TELEPORT IN PROGRESS #####", true)
  drawTpLog("##### DON'T INTERRUPT THIS DEVICE #####", true)
  drawTpLog("Sending ACK to prove we are online...")
  transposer.transferItem(storageSide, enderchestSide, 1, 2, 27)
  drawTpLog("Waiting for sender to transmitt disk...")
  while true do
    local enderchestFirstSlot = transposer.getStackInSlot(enderchestSide, 1)
     if enderchestFirstSlot ~= nil and string.find(enderchestFirstSlot.name, spatialDiskName) then
      drawTpLog("Disk recieved!")
      break
     end
  end
  drawTpLog("Moving Stored disk to Enderchest...")
  transposer.transferItem(storageSide, enderchestSide, 1, 1, 2)
  drawTpLog("Moving recieved disk to Spatial IO...")
  transposer.transferItem(enderchestSide, spatialIoSide, 1, 1, 1)
  -- wait for the game to load
  drawTpLog("Waiting for safety reasons...")
  for i = teleportArriveDelay, 1, -1 do
    if timeSinceLastWalk() < timeSinceLastWalkForArrival then
      break
    end

    drawTpLog(tostring(i) .. "...", true)
    computer.beep(1000, 0.5)
    os.sleep(1)
  end
  -- alarm if a player is standing on teleporter
  if timeSinceLastWalk() < timeSinceLastWalkForArrival then
    drawTpLog("STEP AWAY FROM THE TELEPORTER!", true)
    while timeSinceLastWalk() < timeSinceLastWalkForArrival do
      computer.beep(2000, 0.1)
      os.sleep(0.1)
    end
  end
  computer.beep(200, 1)
  --pulse SpatialIO
  drawTpLog("Activating SpatialIO Port...")
  redstone.setOutput(sides.bottom, 15)
  redstone.setOutput(sides.bottom, 0)
  local spatialIoOutput = transposer.getStackInSlot(spatialIoSide, 2)
  if not spatialIoOutput or not string.find(spatialIoOutput.name, spatialDiskName) then
    error("No spatial storage disk in SpatialIO output slot found!")
  end
  drawTpLog("Found spatial storage disk in SpatialIO output slot...")
  drawTpLog("Moving empty disk from SpatialIO output to Enderchest...")
  transposer.transferItem(spatialIoSide, enderchestSide, 1, 2, 1)
  drawTpLog("Moving stored disk from Enderchest to back to Storage...")
  transposer.transferItem(enderchestSide, storageSide, 1, 2, 1)
  drawTpLog("Sending ACK...") -- token aus enderchest entfdernen
  transposer.transferItem(enderchestSide, storageSide, 1, 27, 2)
  drawTpLog("Waiting until sender has retrieved disk...")
  while true do
    local enderchestLastSlot = transposer.getStackInSlot(enderchestSide, 1)
    if enderchestLastSlot == nil then
      drawTpLog("Sender has retrieved disk!")
      break
    end
  end
  drawTpLog("Teleporting sequence complete!")
  lastWalkTime = computer.uptime() -- so ensure the computer doesnt enter sleep mode too early
  tpLogCleanup()
  if locationSelectorView then
    term.clear()
    locationSelectorView:drawScreen()
  end
  teleportinProgress = false
end

-- startup
updateTeleporterData()
if teleporterData == nil then
  error("Teleporter data is nil!")
end
localTeleporterId = loadTeleporterId()
if localTeleporterId == nil then
    letUserSetTeleporterId(teleporterData.tps)
else
  localTeleporterName = teleporterData.tps[localTeleporterId].name
  localTeleporterFreq = teleporterData.tps[localTeleporterId].frequency
end

ender_chest.setFrequency(localTeleporterFreq) -- its important that this happens before checkItemReqs()
checkItemReqs()
term.setCursorBlink(false)
screen.setTouchModeInverted(true)
redstone.setOutput(sides.bottom, 0)
term.clear()
updateTeleporterDisplay()
event.listen("walk", walkListener)

-- MAIN EVENT LOOP
local running = true
while running do
  -- event.pull() halts the script until an event (touch, key, etc.) happens
  local eventData = {event.pull(1)}
  local eventName = eventData[1]

  if eventName == "interrupted" then
    -- User pressed Ctrl+C
    running = false

  elseif eventName == "touch" then
    if not currentlySleeping then
      -- Unpack touch data: name, screenAddress, x, y, button, playerName
      local _, addr, x, y, btn, user = table.unpack(eventData)

      local ok, err = pcall(touchListener, nil, addr, x, y, btn, user)
      if not ok then
        print("Error in touch handler: " .. tostring(err))
      end
    end
  end

  -- Check if it's time to refresh from the internet
  local now = computer.uptime()
  if now >= nextUpdate then
    -- Attempt the update
    local ok, err = pcall(updateTeleporterData)
    
    if ok then
      updateTeleporterDisplay()
      -- Schedule the next update with new randomness
      nextUpdate = now + baseUpdateInterval + math.random(0, maxUpdateJitter)
    else
      -- If it failed, try again sooner (e.g., in 1 minute)
      nextUpdate = now + 60
      print("Update failed, retrying in 60s: " .. tostring(err))
    end
  end

  -- periodicly check if someone is teleporting to this device
  ender_chest.setFrequency(localTeleporterFreq)  
  local lastEnderchestSlot = transposer.getStackInSlot(enderchestSide, 27)
  if lastEnderchestSlot ~= nil then
    if string.find(lastEnderchestSlot.name, ackTokenName) then
      recieveTeleport()
    else
      error("Item is in enderchests last slot that shouldn't be there")
    end
  end
  -- check if device should enter sleep mode
  if timeSinceLastWalk() > timeSinceLastWalkForSleep and not teleportinProgress then
    currentlySleeping = true;
    drawSymmetricalLoops(0x2e1447, 0x1e0c2f, 1)
  end
end

cleanup()