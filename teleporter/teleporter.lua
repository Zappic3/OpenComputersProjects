---@diagnostic disable: undefined-field, param-type-mismatch
local check_req_ok, check_req = pcall(require, "check_req")
local comp = require("component")
local event = require("event")
local term = require("term")
local sides = require("sides")
local computer = require("computer")
local shell = require("shell")
local filesystem = require("filesystem")
local unicode = require("unicode")

-- forwad declarations
local init

-- settings
local programmVersion = "2.0" -- purely cosmetic
local configFile = "/etc/teleporter.cfg"

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

-- used to check if config file has been loaded successfully
local savedSettingsKeys = {
  "useWebDataSource",
  "tpDataSourceUrl",
  "tpDataSourceFile",
  "spatialDiskName",
  "ackTokenName",
  "enderchestName",
  "spatialIoName",
  "storageSide",
  "saveDir",
  "saveFileName",
  "shouldAutostartAfterError",
  "autostartServiceName",
  "teleportDepartDelay",
  "teleportArriveDelay",
  "waitingForResponseTimeout",
  "timeSinceLastWalkForArrival",
  "timeSinceLastInteractForSleep",
  "enableSleep",
  "shouldUpdateData",
  "baseUpdateInterval",
  "maxUpdateJitter",
  "statusBarSize",
  "useListDisplayMode",
  "listMaxNameChars",
  "automaticallySwitchToList",
  "touchUiMaxRows",
  "touchUiMaxCols"
}

local function printError(msg)
  local gpu = comp.gpu
  local prev_foreground_color = gpu.getForeground()
  gpu.setForeground(0xff0000)
  print(msg)
  gpu.setForeground(prev_foreground_color)
end

local function parse_config(filename)
    local settings = {}
    for line in io.lines(filename) do
        line = line:match("^%s*(.-)%s*$")        -- trim whitespace
        if line ~= "" and not line:match("^[;#]") then  -- skip comments
            local key, value = line:match("^(.-)%s*=%s*(.+)$")
            if key then
                -- auto-convert numbers and booleans
                if value == "true" then value = true
                elseif value == "false" then value = false
                elseif tonumber(value) then value = tonumber(value)
                end
                settings[key] = value
            end
        end
    end
    return settings
end

local settings = parse_config(configFile)
local key_missing = false
for _, key in pairs(savedSettingsKeys) do
  if settings[key] == nil then
    if not key_missing then
      key_missing = true
      printError("The following settings have not loaded correctly:")
    end
    printError("- "..key)
  end
end
if key_missing then
  printError("Check '".. configFile .."' if these settings are set correctly!")
  return
end



local saveFile = settings.saveDir .. settings.saveFileName


-- check reqs
print("Startup check...")

if not check_req_ok then
  printError("Library 'check_req' not found. Try 'oppm install check_req'. For more advice visit\n'https://github.com/Zappic3/OpenComputersProjects/tree/master/teleporter'")
  return
end


local req = check_req.new()

-- modules
req:addRequire("simple_ui_lib",
  "Required library 'simple_ui_lib' is missing. Try 'oppm install simple_ui_lib'",
  nil
)
req:addRequire("json",
  "Required library 'json' is missing. Try 'oppm install json.lua'",
  nil
)

-- components
req:addComponent("gpu", "gpu", {"t2", "t3"},
"Teleporter requires at least a Graphics Card T2")
req:addComponent("screen", "screen", {"t2", "t3"},
"Teleporter requires at least a screen T2")
req:addComponent("ender_chest", "ender_chest", nil,
  "Teleporter requires an Enderchest connected via an Adapter")
req:addComponent("redstone", "redstone", nil,
  "Teleporter requires a redstone card")
  --todo make intenet card optional based on settings
req:addComponent("internet", "internet", nil,
  "Teleporter requires an internet card") 
req:addComponent("transposer", "transposer", nil,
  "Teleporter requires a transposer")

-- transposer inventory layout
req:addTransposer()
    :requireInventory(settings.enderchestName, nil, "not connected to Enderchest", nil, "enderchest_side")
    :requireInventory(settings.spatialIoName, nil, "not connected to SpatialIO", nil, "spatialio_side")
    :requireItem(settings.spatialDiskName, 1, 1, settings.storageSide, " > Expected 1x Spatial Storage Disk (".. settings.spatialDiskName ..") in container slot 1")
    :requireItem(settings.ackTokenName, 1, 2, settings.storageSide, " > Expected 1x (" .. settings.ackTokenName .. ") in container slot 2")
    :named("transposer_layout")
    :messages(
      "Transposer is missing following requirements:\n",
      "Transposer ready"
    )
    :register()

local total_success, success_data, results_data = req:check()
req:displayResults(true)

if not total_success then
  print("At least one requirement was not met. Exiting...")
  return
end

-- extract results
local ui                = results_data["simple_ui_lib"]
local json              = results_data["json"]
local transposer_layout = results_data["transposer_layout"]
local enderchestSide    = transposer_layout.sides["enderchest_side"]
local spatialIoSide     = transposer_layout.sides["spatialio_side"]

-- get proxies
local gpu = comp.gpu
local screen = comp.screen
---@diagnostic disable-next-line: undefined-field
local ender_chest = comp.ender_chest
local redstone = comp.redstone
local transposer = comp.transposer
---@diagnostic disable-next-line: undefined-field
local internet = comp.internet

-- runtime global variables
local localTeleporterId = nil
local localTeleporterName = nil
local localTeleporterFreq = nil

local nextUpdate = computer.uptime() + settings.baseUpdateInterval + math.random(0, settings.maxUpdateJitter)
local teleporterData = nil
local locationSelectorView = nil
local activeRects = {}
local currentTpsVersion = 0
local teleportinProgress = false
local tpLogPos = 1
local lastWalkTime = computer.uptime()
local lastInteractTime = computer.uptime()
local currentlySleeping = false
local lastEnderchestCheck = 0
local enderchestCheckInterval = 0.5  -- check every 500ms
local defaultPos = 99

local listSearchQuery = ""
local listFilteredTeleporters = nil
local listSearchInputYPos = settings.statusBarSize+2
local listListYStart = listSearchInputYPos+3
local listFooterSpace = 3
local listCurrentPage = 1
local listTotalPages = 1
local listSearchText = "Type to search > "

local originalUseListModeValue = nil

-- used to restart the program after configuring local teleporter
local chooseLocalTpMode = false

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
    local digit = result:sub(i, i)
    local index = tonumber(digit, 16)
    colors[i] = (index and hexToColor[index]) or "Unknown"
  end
  return colors
end

local function checkItemReqs()
  local itemReqs = check_req.new()

  itemReqs:addTransposer()
  :messages("An error occured while performing item checks. Fix them and try again:\n")
  -- token in 1. slot
  :requireItem(settings.spatialDiskName, 1, 1, settings.storageSide, " > Expected 1x Spatial Storage Disk (".. settings.spatialDiskName ..") in container slot 1")
  -- ack token in 2. slot
  :requireItem(settings.ackTokenName, 1, 2, settings.storageSide, " > Expected 1x Token (".. settings.ackTokenName ..") in container slot 2")
  -- spatial storage disk in 2. slot
  :requireItem(settings.ackTokenName, 1, 2, settings.storageSide, " > Expected 1x (" .. settings.ackTokenName .. ") in container slot 2")
  -- spatial io output slot empty
  :requireItem(nil, 0, 2, spatialIoSide, " > SpatialIO output slot needs to be empty")
  -- spatial io input slot empty
  :requireItem(nil, 0, 1, spatialIoSide, " > SpatialIO input slot needs to be empty")
  -- no ack token in enderchest (that is set to this teleporters ferquency)
  :requireItem(nil, 0, 27, enderchestSide, " > Enderchest last slot (slot 27) should be empty")
  -- no item in enderchest second slot
  :requireItem(nil, 0, 2, enderchestSide, " > Enderchest 2nd slot should be empty")
  :register()

  local itemReqSuccess = itemReqs:check()

  if not itemReqSuccess then
    itemReqs:displayResults(false)
    os.exit()
  end
end

local function centerTextXOffset(text, x_pos)
  local x = x_pos or 0
  return x - math.floor(#text / 2)
end

local function timeSinceEvent(timestamp)
  return computer.uptime() - timestamp
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
  local x_start = rect_x + 1               -- Left edge + 1 for padding

  -- Get the rectangle's colors, which were set right before this function was called
  local rect_colors = view:rectGetColors(rect_id)
  local text_color = rect_colors[2] or view.fg_color
  local rect_bg_color = rect_colors[1] or view.bg_color


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

    -- Calculate vertical starting position for the text block to be centered
    local num_lines = #lines
    local y_middle = rect_y + math.floor(rect_h / 2)
    local y_start = y_middle - math.floor((num_lines - 1) / 2)
    -- Clamp so the text block never overlaps the top or bottom border
    local y_inner_top = rect_y + 1
    local y_inner_bottom = rect_y + rect_h - 2  -- -1 for border, -1 for 0-index
    y_start = math.max(y_inner_top, math.min(y_start, y_inner_bottom - (num_lines - 1)))

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
        text_to_draw = string.sub(line, 1, max_text_width + 1)
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
  local thisTeleporterString = string.format("%s [%s, %s, %s | %s]", localTeleporterName, colors[1], colors[2], colors
    [3], tostring(localTeleporterFreq))
  local tpDataVersionString = "🗎: " .. currentTpsVersion
  local totalRightString = tpDataVersionString .. " | " .. versionString
  gpu.set(x_res - string.len(totalRightString), rect_y + 1, totalRightString)
  gpu.set(rect_x + 1, rect_y + 1, thisTeleporterString)
end

local function updateRectPositioning(view, rectCount)
  if rectCount < 1 then return end
  if rectCount < 3 then rectCount = 3 end

  local y_buffer = 1
  local x_buffer = 3
  local x_res, y_res = gpu.getResolution()
  y_res = y_res - settings.statusBarSize

  -- alternate increasing rows/cols until hitting their maximum
  local max_rows = 4
  local max_cols = 3
  -- true = next turn grows rows, false = next turn grows cols
  local grow_rows_next = true

  while max_rows * max_cols < rectCount do
    if max_rows >= settings.touchUiMaxRows and max_cols >= settings.touchUiMaxCols then
      break
    end
    if grow_rows_next then
      if max_rows < settings.touchUiMaxRows then
        max_rows = max_rows + 1
      end
    else
      if max_cols < settings.touchUiMaxCols then
        max_cols = max_cols + 1
      end
    end
    grow_rows_next = not grow_rows_next
  end

  local cols = math.min(max_cols, math.ceil(rectCount / max_rows))
  local rows_used = math.ceil(rectCount / cols)

  local y_size = math.floor((y_res - (y_buffer * (rows_used + 1))) / rows_used)
  local x_size = math.floor((x_res - (x_buffer * (cols + 1))) / cols)

  -- create sorted table to ensure correct rect order
  local sortedRects = {}
  for addr, rect in pairs(activeRects) do
    table.insert(sortedRects, rect)
  end
  table.sort(sortedRects, function(a, b)
    if locationSelectorView == nil then
      printError("locationSelectorView is nil while trying to sort rects")
      return false
    end
    local data_a = locationSelectorView:rectGetData(a)
    local data_b = locationSelectorView:rectGetData(b)
    local pos_a = data_a.pos or defaultPos
    local pos_b = data_b.pos or defaultPos
    if pos_a ~= pos_b then
      return pos_a < pos_b
    else
      return data_a.name < data_b.name
    end
  end)

  -- update rect positions
  for i, rect in ipairs(sortedRects) do
    local newPos = {}
    local current_col = math.ceil(i / rows_used)
    local current_row = i - (rows_used * (current_col - 1))
    newPos[1] = x_buffer + (x_size + x_buffer) * (current_col - 1) + 1
    newPos[2] = y_buffer + ((y_size + y_buffer) * (current_row - 1)) + 1 + settings.statusBarSize
    newPos[3] = x_size
    newPos[4] = y_size
    view:rectSetPos(rect, newPos)
  end
end

local function updateTeleporterData()
  local content = ""

  if settings.useWebDataSource then
    local handle, reason = internet.request(settings.tpDataSourceUrl)
    if not handle then
      printError("Connection failed: " .. tostring(reason))
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
  else
    local file = io.open(settings.tpDataSourceFile, "r")
    if file then
      content = file:read("*a")
      file:close()
    end
  end

  if content ~= "" then
    local status, result = pcall(json.decode, content)
    if status then
      teleporterData = result
      --print("Data updated successfully!")
    else
      printError("JSON Error: " .. tostring(result))
    end
  else
    if settings.useWebDataSource then
      printError("Error updating teleporter data: Received 0 bytes from server.\nMake sure '" .. settings.tpDataSourceUrl .. "' is the correct URL")
    else
      printError("Error updating teleporter data: issue reading the tpDataSourceFile.\nMake sure '" .. settings.tpDataSourceFile .. "' is the correct filepath")
    end
  end
end

local function to_num(val)
  if type(val) == "string" then
    -- Removes '#' or '0x' if present, then converts from base 16
    return tonumber(val:gsub("[#x]", ""), 16)
  end
  return val
end

local function refreshScreen()

  if settings.useListDisplayMode then
    if listFilteredTeleporters == nil then
      return
    end
    -- setup required values
    local x_res, y_res = gpu.getResolution()
    local maxPerColumn = y_res - listListYStart - listFooterSpace
    local colWidth = settings.listMaxNameChars + 1
    local numCols = math.floor(x_res / colWidth)
    if numCols < 1 then numCols = 1 end
    local itemsPerPage = numCols * maxPerColumn
    local totalPages = math.max(1, math.ceil(#listFilteredTeleporters / itemsPerPage))
    if listCurrentPage > totalPages then listCurrentPage = totalPages end
    listTotalPages = totalPages

    -- render query and hint
    gpu.fill(1, listSearchInputYPos, x_res, 2, " ")
    gpu.set(1, listSearchInputYPos, listSearchText .. listSearchQuery)
    if chooseLocalTpMode then
      gpu.set(1,listSearchInputYPos+1, "(Press enter or click name to configure this teleporter)")
    else
      gpu.set(1,listSearchInputYPos+1, "(Press enter or click name to teleport)")
    end
    

    -- Render the current page
    local startIndex = (listCurrentPage - 1) * itemsPerPage + 1

    for i = 0, itemsPerPage - 1 do
      local entry = listFilteredTeleporters[startIndex + i]

      local col = math.floor(i / maxPerColumn)       -- which column
      local row = i % maxPerColumn                   -- which row within that column

      local x = col * colWidth + 1
      local y = listListYStart + row

      if entry then
        local name = entry.data.name
        if #name > settings.listMaxNameChars then
            name = name:sub(1, settings.listMaxNameChars)
        end
        name = name .. string.rep(" ", colWidth - #name)

        gpu.setBackground(to_num(entry.data.bg_color) or 0x000000)
        gpu.setForeground(to_num(entry.data.fg_color) or 0xFFFFFF)
        gpu.set(x, y, name)
      else
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFFFFFF)
        gpu.set(x, y, string.rep(" ", colWidth))
      end
    end

    -- draw page count
    local pagesString = string.format("%02d / %02d", listCurrentPage, totalPages)
    local pagesXPos = math.floor(x_res/2) - math.floor(string.len(pagesString)/2)
    gpu.set(pagesXPos, (y_res-listFooterSpace)+1, pagesString)

    -- Reset colors after rendering
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
  end

  -- always draw locationSelectorView.
  -- if useListDisplayMode == true, this will only contain the header and arrow buttons
  if locationSelectorView ~= nil then
    locationSelectorView:drawScreen()
  end
end

local function teleportAway(freq, name)
  name = name or "[TELEPORTER NAME MISSING]"
  checkItemReqs() -- check reqs before teleporting
  teleportinProgress = true
  tpLogSetup()
  drawTpLog("##### TELEPORT IN PROGRESS #####", true)
  drawTpLog("##### DON'T INTERRUPT THIS DEVICE #####", true)
  local colors = decodeFreqToColor(freq)
  drawTpLog(string.format("Selected destination: %s", name))
  drawTpLog(string.format("Setting frequency to %s (%s, %s, %s)...", tostring(freq), colors[1], colors[2],
    colors[3]))
  ender_chest.setFrequency(freq)
  -- check if another teleporter is currently occupying the destination teleporter
  drawTpLog("Check if target teleporter is already occupied...")
  -- todo abort after timeout
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
  transposer.transferItem(settings.storageSide, enderchestSide, 1, 2, 27)

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
    if computer.uptime() > startedWaitingForRecieverResponse + settings.waitingForResponseTimeout then
      drawTpLog("Reciever appears to be offline, aborting...")
      drawTpLog("Retrieving reservation token...")
      transposer.transferItem(enderchestSide, settings.storageSide, 1, 27, 2)
      tpLogCleanup()
      refreshScreen()
      ender_chest.setFrequency(localTeleporterFreq)
      teleportinProgress = false
      return
    end
  end

  drawTpLog("Teleporting in:")
  for i = settings.teleportDepartDelay, 1, -1 do
    drawTpLog(tostring(i) .. "...", true)
    computer.beep(1000, 0.5)
    os.sleep(1)
  end
  computer.beep(200, 1)

  drawTpLog("Moving disk to SpatialIO Port...")
  transposer.transferItem(settings.storageSide, spatialIoSide, 1, 1, 1)
  drawTpLog("Activating SpatialIO Port...")
  redstone.setOutput(sides.bottom, 15)
  redstone.setOutput(sides.bottom, 0)
  -- check if disk is in spatial storage output
  local spatialIoOutput = transposer.getStackInSlot(spatialIoSide, 2)
  if not spatialIoOutput or not string.find(spatialIoOutput.name, settings.spatialDiskName) then
    error("No spatial storage disk in SpatialIO output slot found!")
  end
  drawTpLog("Found spatial storage disk in SpatialIO output slot...")
  -- disk in ender_chest legen
  drawTpLog("Transfering disk to enderchest...")
  transposer.transferItem(spatialIoSide, enderchestSide, 1, 2, 1)
  drawTpLog("Retreiving reservation token...")
  transposer.transferItem(enderchestSide, settings.storageSide, 1, 27, 2)
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
  transposer.transferItem(enderchestSide, settings.storageSide, 1, 1, 1)
  local colors = decodeFreqToColor(localTeleporterFreq)
  drawTpLog(string.format("Resetting frequency to %s (%s, %s, %s)...", localTeleporterFreq, colors[1], colors[2],
    colors[3]))
  ender_chest.setFrequency(localTeleporterFreq)
  drawTpLog("Teleporting sequence complete!")
  tpLogCleanup()
  refreshScreen()
  teleportinProgress = false
end

local function listApplyQuery(query)
  local query = query or ""

  if teleporterData == nil then
    return
  end

  -- Collect entries that match search query into array
  local sorted = {}
  local search = query:lower()
  for key, tp in pairs(teleporterData.tps) do
      if key ~= localTeleporterId and (search == "" or tp.name:lower():find(search, 1, true)) then
          table.insert(sorted, { key = key, data = tp })
      end
  end

  table.sort(sorted, function(a, b)
      local pos_a = a.data.pos or defaultPos
      local pos_b = b.data.pos or defaultPos

      if pos_a ~= pos_b then
         -- primary sort: pos ascending
          return pos_a < pos_b
      else
        -- secondary sort: name alphabetically
          return a.data.name < b.data.name
      end
  end)
  listFilteredTeleporters = sorted
  refreshScreen()
end

local function saveTeleporterId(string)
  if not filesystem.exists(settings.saveDir) then
    filesystem.makeDirectory(settings.saveDir)
  end
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

local function listHandleSelection(tp)
  if not tp then
    return
  end

  local id = tp.key
  local data = tp.data

  if id == nil or data == nil then
    printError("Teleporter id or data was nil:\n id: " .. id .. ", data: " .. data)
    return
  end

  if chooseLocalTpMode then
    localTeleporterId = id
    localTeleporterName = data.name
    localTeleporterFreq = data.frequency
    saveTeleporterId(localTeleporterId)
    chooseLocalTpMode = false
    currentTpsVersion = 0  -- force updateTeleporterDisplay to rebuild view
    if originalUseListModeValue ~= nil then
      settings.useListDisplayMode = originalUseListModeValue
    end
    term.clear()
    init()
    return
  end

  -- teleport
  if tp.data.frequency ~= nil then
    teleportAway(data.frequency, data.name)
  end
end

local function listHandleSearch(char, code, applyFilter)
  -- applyFilter = nil: default handling; true: always apply filter; false: dont apply filter
  if teleportinProgress == false then
    local changed = false
    if code == 28 then -- enter
      if listFilteredTeleporters ~= nil then
        local destTele = listFilteredTeleporters[1]
        if destTele ~= nil then
          listHandleSelection(destTele)
          -- clear search after teleport
          listSearchQuery = ""
          listApplyQuery(listSearchQuery)
          return
        end
      end
      computer.beep(256,0.2)
      return
    elseif code == 14 then -- backspace
      listSearchQuery = unicode.sub(listSearchQuery, 1, -2)
      changed = true
    elseif char > 31 and string.len(listSearchQuery) < 150 then --printable character (150 is an arbitrary limit)
      listSearchQuery = listSearchQuery .. unicode.char(char)
      changed = true
    end

    if applyFilter == true or (changed and applyFilter == nil) then
      local x_res, y_res = gpu.getResolution()
      -- apply new query
      listApplyQuery(listSearchQuery)
    end

  end
end

local function drawLabel(view, rect_id, data)
  local pos = view:rectGetPos(rect_id)
  gpu.set(pos[1] + 1, pos[2] + 1, data.label)
end


local function updateTeleporterDisplay()
  if teleporterData ~= nil and teleporterData.version > currentTpsVersion then
    currentTpsVersion = teleporterData.version

    -- switch to list mode
    -- (-1 to subtract the local teleporter, that is not included in the display)
    if settings.automaticallySwitchToList and settings.useListDisplayMode == false and #teleporterData.tps-1 > settings.touchUiMaxCols*settings.touchUiMaxRows then
      settings.useListDisplayMode = true
      screen.setTouchModeInverted(false)
      term.clear()
    end

    if settings.useListDisplayMode then
      local x_res, y_res = gpu.getResolution()
      locationSelectorView = ui.View.new(x_res, y_res, 0x000000, 0xffffff)

      -- add status bar (if local teleporter is available)
      if chooseLocalTpMode then
        local bar = locationSelectorView:newRect(1, 1, x_res - 1, settings.statusBarSize - 1, drawLabel)
        locationSelectorView:rectSetData(bar, {label = " Who am I?",})
      else
        locationSelectorView:newRect(1, 1, x_res - 1, settings.statusBarSize - 1, updateStatusBar)
      end
      

      -- add page change arrows
      local y_pos = y_res - listFooterSpace
      local arrowXDist = 10
      local arrowWidth = 5
      local x_center = math.floor(x_res/2)
      local leftArrow = locationSelectorView:newRect(x_center-arrowXDist-math.floor(arrowWidth/2), y_pos, arrowWidth, listFooterSpace-1, drawLabel)
      locationSelectorView:rectSetData(leftArrow, {label = " <-", button = "left"})
      local rightArrow = locationSelectorView:newRect(x_center+arrowXDist-math.floor(arrowWidth/2), y_pos, arrowWidth, listFooterSpace-1, drawLabel)
      locationSelectorView:rectSetData(rightArrow, {label = " ->", button = "right"})

      -- apply query also refreshes the screen
      listApplyQuery(listSearchQuery)
      return
    end

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

    -- add status bar
    locationSelectorView:newRect(1, 1, x_res - 1, settings.statusBarSize - 1, updateStatusBar)

    if not settings.useListDisplayMode then
      updateRectPositioning(locationSelectorView, rectCount)
    end
    if not currentlySleeping then
      locationSelectorView:redrawScreen()
    end
  end
end

local function touchListener(_, screenAdress, x, y, button, playerName) -- button: 0-rechtsklick, 1-linksklick
  if teleportinProgress == false then
      if locationSelectorView == nil then
        error("locationSelectorView is nil")
      end
      local rect = locationSelectorView:getClickRect(x, y)
      if rect ~= nil then
        local data = locationSelectorView:rectGetData(rect)
        if data ~= nil then
          if settings.useListDisplayMode then
            local prevPage = listCurrentPage
            if data.button == "left" then
              listCurrentPage = math.max(listCurrentPage-1, 1)
            elseif data.button == "right" then
              listCurrentPage = math.min(listCurrentPage+1, listTotalPages)
            end
            
            if prevPage ~= listCurrentPage then
              refreshScreen()
            end

          else
            teleportAway(data.freq, data.name)
          end
      end
    end
  end
end


local function letUserSetTeleporterId(tps)
  chooseLocalTpMode = true
  originalUseListModeValue = settings.useListDisplayMode
  settings.useListDisplayMode = true
end

local function wakeup()
  lastInteractTime = computer.uptime()
  if currentlySleeping then
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    term.clear()
    listApplyQuery("")
    currentlySleeping = false
  end
end

local function walkListener(name, screenAdress, x, y, playerName)
  lastWalkTime = computer.uptime()
  wakeup()
end

local function cleanup()
  event.ignore("walk", walkListener)
  term.setCursorBlink(true)
  screen.setTouchModeInverted(false)
  redstone.setOutput(sides.bottom, 0)
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  term.clear()
  shell.execute("rc " .. settings.autostartServiceName .. " disable") -- disable teleporter autostart
  -- reset resolution to maximum
  local w, h = gpu.maxResolution()
  gpu.setResolution(w, h)
  print("Program terminated successfully.")
end

local function recieveTeleport()
  teleportinProgress = true
  tpLogSetup()
  drawTpLog("##### TELEPORT IN PROGRESS #####", true)
  drawTpLog("##### DON'T INTERRUPT THIS DEVICE #####", true)
  drawTpLog("Sending ACK to prove we are online...")
  transposer.transferItem(settings.storageSide, enderchestSide, 1, 2, 27)
  drawTpLog("Waiting for sender to transmitt disk...")
  while true do
    local enderchestFirstSlot = transposer.getStackInSlot(enderchestSide, 1)
    if enderchestFirstSlot ~= nil and string.find(enderchestFirstSlot.name, settings.spatialDiskName) then
      drawTpLog("Disk recieved!")
      break
    end
  end
  drawTpLog("Moving Stored disk to Enderchest...")
  transposer.transferItem(settings.storageSide, enderchestSide, 1, 1, 2)
  drawTpLog("Moving recieved disk to Spatial IO...")
  transposer.transferItem(enderchestSide, spatialIoSide, 1, 1, 1)
  -- wait for the game to load
  drawTpLog("Waiting for safety reasons...")
  for i = settings.teleportArriveDelay, 1, -1 do
    if timeSinceEvent(lastWalkTime) < settings.timeSinceLastWalkForArrival then
      break
    end

    drawTpLog(tostring(i) .. "...", true)
    computer.beep(1000, 0.5)
    os.sleep(1)
  end
  -- alarm if a player is standing on teleporter
  if timeSinceEvent(lastWalkTime) < settings.timeSinceLastWalkForArrival then
    drawTpLog("STEP AWAY FROM THE TELEPORTER!", true)
    while timeSinceEvent(lastWalkTime) < settings.timeSinceLastWalkForArrival do
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
  if not spatialIoOutput or not string.find(spatialIoOutput.name, settings.spatialDiskName) then
    error("No spatial storage disk in SpatialIO output slot found!")
  end
  drawTpLog("Found spatial storage disk in SpatialIO output slot...")
  drawTpLog("Moving empty disk from SpatialIO output to Enderchest...")
  transposer.transferItem(spatialIoSide, enderchestSide, 1, 2, 1)
  drawTpLog("Moving stored disk from Enderchest to back to Storage...")
  transposer.transferItem(enderchestSide, settings.storageSide, 1, 2, 1)
  drawTpLog("Sending ACK...") -- token aus enderchest entfdernen
  transposer.transferItem(enderchestSide, settings.storageSide, 1, 27, 2)
  drawTpLog("Waiting until sender has retrieved disk...")
  while true do
    local enderchestLastSlot = transposer.getStackInSlot(enderchestSide, 1)
    if enderchestLastSlot == nil then
      drawTpLog("Sender has retrieved disk!")
      break
    end
  end
  drawTpLog("Teleporting sequence complete!")
  lastWalkTime = computer.uptime() -- ensure the computer doesnt enter sleep mode too early
  tpLogCleanup()
  if locationSelectorView then
    term.clear()
    locationSelectorView:drawScreen()
  end
  teleportinProgress = false
end


init = function()
  updateTeleporterData()
  if teleporterData == nil then
    printError("Teleporter data is nil!")
    return
  end
  localTeleporterId = loadTeleporterId()
  if localTeleporterId == nil then
    letUserSetTeleporterId(teleporterData.tps)
  else
    local localTp = teleporterData.tps[localTeleporterId]
    if localTp == nil then
      printError("local teleporter id '".. localTeleporterId .."' couldnt be found in teleporter list.\nMake sure '" .. settings.saveDir .. settings.saveFileName .. "' contains a valid teleporter id.\n(Or delete the file to view the selector again)")
      os.exit()
    end
    localTeleporterName = localTp.name
    localTeleporterFreq = localTp.frequency
  end

  if not chooseLocalTpMode then
    ender_chest.setFrequency(localTeleporterFreq) -- its important that this happens before checkItemReqs()
    checkItemReqs()
  end

  -- set resolution for sqare screens
  local x_aspect, y_apsect = screen.getAspectRatio()
  if x_aspect == y_apsect then
    local w, h = gpu.maxResolution()
    gpu.setResolution(2 * h, h)
  end

  term.setCursorBlink(false)
  if settings.useListDisplayMode then
    screen.setTouchModeInverted(false)
  else
    screen.setTouchModeInverted(true)
  end

  redstone.setWakeThreshold(10)  -- so the computer can be woken up wirelessly
  if settings.shouldAutostartAfterError then
    -- enable teleporter autostart (this is before the screen is updated, so if the service is already enabled, the error will be hidden)
    shell.execute("rc " .. settings.autostartServiceName .. " enable")
  end
  redstone.setOutput(sides.bottom, 0)
  term.clear()
  updateTeleporterDisplay()
  event.listen("walk", walkListener)
end

-- ##############################
-- startup
-- ##############################
init()
-- MAIN EVENT LOOP
local running = true
while running do
  -- event.pull() halts the script until an event (touch, key, etc.) happens
  local eventData = { event.pull(0.05) }
  local eventName = eventData[1]

  if eventName == "interrupted" then
    -- User pressed Ctrl+C
    running = false
    break
  elseif eventName == "touch" then
    if not currentlySleeping then
      -- Unpack touch data: name, screenAddress, x, y, button, playerName
      local _, addr, x, y, btn, user = table.unpack(eventData)

      local ok, err = pcall(touchListener, nil, addr, x, y, btn, user)
      if not ok then
        printError("Error in touch handler: " .. tostring(err))
      end
    end
    wakeup()
  elseif eventName == "key_down" then
    if settings.useListDisplayMode and not currentlySleeping then
      local _, addr, char, code, user = table.unpack(eventData)
      pcall(listHandleSearch, char, code, false)  -- accumulate, no filter yet

      -- drain any remaining queued key events
      while true do
        local peeked = { event.pull(0) }
        if peeked[1] == "interrupted" then
          running = false
          break
        elseif peeked[1] ~= "key_down" then
          break
        end
        local _, addr, char, code, user = table.unpack(peeked)
        pcall(listHandleSearch, char, code, false)  -- accumulate, no filter yet
      end

      -- apply filter once after all queued keys are processed
      if running then
        pcall(listHandleSearch, 0, 0, true)
      else
        break
      end
      
    end
    wakeup()
  end

  -- Check if it's time to refresh data
  local now = computer.uptime()
  if settings.shouldUpdateData and now >= nextUpdate then
    -- Attempt the update
    local ok, err = pcall(updateTeleporterData)

    if ok then
      updateTeleporterDisplay()
      -- Schedule the next update with new randomness
      nextUpdate = now + settings.baseUpdateInterval + math.random(0, settings.maxUpdateJitter)
    else
      -- If it failed, try again sooner (e.g., in 1 minute)
      nextUpdate = now + 60
      print("Update failed, retrying in 60s: " .. tostring(err))
    end
  end

  -- periodicly check if someone is teleporting to this device
  if now - lastEnderchestCheck >= enderchestCheckInterval and not chooseLocalTpMode then
    lastEnderchestCheck = now
    ender_chest.setFrequency(localTeleporterFreq)
    local lastEnderchestSlot = transposer.getStackInSlot(enderchestSide, 27)
    if lastEnderchestSlot ~= nil then
        if string.find(lastEnderchestSlot.name, settings.ackTokenName) then
            recieveTeleport()
        else
            error("Item is in the enderchests last slot that shouldn't be there")
        end
    end
  end
  -- check if device should enter sleep mode
  if settings.enableSleep and timeSinceEvent(lastInteractTime) > settings.timeSinceLastInteractForSleep and not teleportinProgress and not chooseLocalTpMode then
    currentlySleeping = true
    listSearchQuery = ""
    drawSymmetricalLoops(0x2e1447, 0x1e0c2f, 1)
  end
end

cleanup()
