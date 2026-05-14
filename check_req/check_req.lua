---@class Req
---@field requirements table
---@field success_data table
local Req = {}
Req.__index = Req

---@class TransposerReq
---@field _parent Req
---@field _inventories table
---@field _tanks table
---@field _items table
---@field _fluids table
---@field _req_name string|nil
---@field _fail_msg string|nil
---@field _succ_msg string|nil
local TransposerReq = {}
TransposerReq.__index = TransposerReq

local detectors = nil

local function getDetectors()
  if detectors then return detectors end -- already initialized, reuse

  -- component is only referenced HERE, when getDetectors is first called
  local component = require("component")
  detectors = {
    ["redstone"] = function()
      if not component.isAvailable("redstone") then
        return false, nil
      end
      local r = component.getPrimary("redstone")
      if r.getBundledInput then
        return true, "t2"
      end
      return true, "t1"
    end,

    ["data"] = function()
      if not component.isAvailable("data") then
        return false, nil
      end
      local d = component.getPrimary("data")
      if d.generateKeyPair then return true, "t3" end
      if d.deflate then return true, "t2" end
      return true, "t1"
    end,
  }

  return detectors
end

-- for simple components, just return true with no tier
local function defaultDetector(component, component_name)
  return component.isAvailable(component_name), nil
end

local function assertInstance(self)
  assert(getmetatable(self) == Req, "method must be called on a Req instance (use ':' not '.')")
end

---Creates a new Req instance.
---@return Req
function Req.new()
  local self = setmetatable({}, Req)
  self.requirements = {}
  self.success_data = {}
  return self
end

local function formatIfPossible(main_str, insert_str)
  local success, result = pcall(string.format, main_str, insert_str)
  if success then
    return result
  end
  return main_str
end

--- Adds a component requirement with optional tier filtering.
--- @param component_name string The component to check for
--- @param req_name string|nil Key to store result under, defaults to component_name
--- @param accepted_tiers string[]|nil List of accepted tiers e.g. {"t2", "t3"}, nil accepts any
--- @param fail_msg string|nil Custom message on failure
--- @param succ_msg string|nil Custom message on success
function Req:addComponent(component_name, req_name, accepted_tiers, fail_msg, succ_msg)
  assertInstance(self)
  assert(component_name ~= nil, "component_name must be defined")
  req_name = req_name or component_name

  -- accepted_tiers is optional, nil means any tier is accepted
  local task = function()
    local component = require("component")
    local detector = getDetectors()[component_name] or function()
      return defaultDetector(component, component_name)
    end

    local found, tier = detector()

    if not found then
      return false, nil
    end

    -- if specific tiers are required, check against the list
    if accepted_tiers then
      for _, accepted in ipairs(accepted_tiers) do
        if accepted == tier then
          return true, tier -- tier is accepted
        end
      end
      return false, tier -- found but wrong tier
    end

    return true, tier
  end

  table.insert(self.requirements, {
    req      = task,
    req_name = req_name,
    fail_msg = formatIfPossible(fail_msg or "Missing required component '%s'", req_name),
    succ_msg = formatIfPossible(succ_msg or "Found component '%s'", req_name),
  })
end

--- Adds a single module requirement.
--- @param module_name string The name of the module to require
--- @param fail_msg string|nil Custom message on failure, supports %s for module name
--- @param succ_msg string|nil Custom message on success, supports %s for module name
function Req:addRequire(module_name, fail_msg, succ_msg)
  assertInstance(self)
  fail_msg = formatIfPossible(fail_msg or "Missing required module '%s'", module_name)
  succ_msg = formatIfPossible(succ_msg or "Found required module '%s'", module_name)

  local req = function()
    return pcall(require, module_name)
  end
  table.insert(self.requirements,
    {
      ["req"] = req,
      ["fail_msg"] = fail_msg,
      ["succ_msg"] = succ_msg,
      ["req_name"] = module_name
    })
end

--- Adds multiple module requirements with shared messages.
--- @param fail_msg string|nil Custom message on failure
--- @param succ_msg string|nil Custom message on success
--- @param ... string Module names to require (at least one)
function Req:addRequires(fail_msg, succ_msg, ...)
  assertInstance(self)
  local modules = { ... }
  assert(#modules > 0, "addRequires expects at least one module name")

  for _, module_name in ipairs(modules) do
    self:addRequire(module_name, fail_msg, succ_msg)
  end
end

--- Adds a single function requirement.
--- @param func function The name of the module to require
--- @param func_args table|nil Arguments that are passed to func
--- @param req_name string|nil Key to store result under, defaults to "Function"
--- @param fail_msg string|nil Custom message on failure, supports %s for function name
--- @param succ_msg string|nil Custom message on success, supports %s for function name
function Req:addFunc(func, func_args, req_name, fail_msg, succ_msg)
  assertInstance(self)
  req_name = req_name or "Function"
  fail_msg = formatIfPossible(fail_msg or "Missing required function '%s'", req_name)
  succ_msg = formatIfPossible(succ_msg or "Found required function '%s'", req_name)

  local req = function()
    return pcall(func, table.unpack(func_args or {}))
  end
  table.insert(self.requirements, {
    ["req"] = req,
    ["fail_msg"] = fail_msg,
    ["succ_msg"] = succ_msg,
    ["req_name"] = req_name
  })
end

local function resolveSides(side)
  if side == nil then
    local sides = require("sides")
    return { sides.north, sides.south, sides.east, sides.west, sides.up, sides.down }
  elseif type(side) == "number" then
    return { side }
  elseif type(side) == "table" then
    return side
  end
end

local function checkAmount(actual, condition)
  if type(condition) == "number" then
    return actual == condition
  end
  if condition.min and actual < condition.min then return false end
  if condition.max and actual > condition.max then return false end
  return true
end

local function checkTransposer(transposer, conditions)
  local sideMap = {}

  -- check inventories: ALL tank conditions must match
  if #conditions.inventories > 0 then
    for _, inv in ipairs(conditions.inventories) do
      local sidesToCheck = resolveSides(inv.sides)
      local found = false
      for _, side in ipairs(sidesToCheck) do
        local ok, name = pcall(transposer.getInventoryName, side)
        if ok and name == inv.name then
          if inv.side_key then
            sideMap[inv.side_key] = side
          end
          found = true
          break
        end
      end
      -- if no side of the transposer has the inventory, return
      if not found then return false, nil end
    end
  end

  -- check tanks: ALL tank conditions must match
  for _, tank in ipairs(conditions.tanks) do
    local sidesToCheck = resolveSides(tank.sides)
    local found = false
    for _, side in ipairs(sidesToCheck) do
      local ok, info = pcall(transposer.getTankInfo, side)
      if ok and info and #info > 0 then
        found = true
        break
      end
    end
    if not found then return false, nil end
  end

  -- check items: ALL item conditions must match, each searches independently
  for _, item in ipairs(conditions.items) do
    local sidesToCheck = resolveSides(item.sides)
    local found = false
    for _, side in ipairs(sidesToCheck) do
      local ok, size = pcall(transposer.getInventorySize, side)
      if ok and size then
        local slotsToCheck = item.slot and { item.slot } or (function()
          local t = {}
          for i = 1, size do t[i] = i end
          return t
        end)()
        for _, slot in ipairs(slotsToCheck) do
          local ok2, stack = pcall(transposer.getStackInSlot, side, slot)
          if ok2 and stack and stack.name == item.name then
            if item.amount == nil or checkAmount(stack.size, item.amount) then
              found = true
              break
            end
          end
        end
      end
      -- skip remaining sides if target items have already been found
      if found then break end
    end
    if not found then return false, nil end
  end

  -- check fluids: ALL fluid conditions must match, each searches independently
  for _, fluid in ipairs(conditions.fluids) do
    local sidesToCheck = resolveSides(fluid.sides)
    local found = false
    for _, side in ipairs(sidesToCheck) do
      local ok, tanks = pcall(transposer.getTankInfo, side)
      if ok and tanks then
        local tanksToCheck = fluid.tank and { fluid.tank } or (function()
          local t = {}
          for i = 1, #tanks do t[i] = i end
          return t
        end)()
        for _, tankIdx in ipairs(tanksToCheck) do
          local ok2, fluidInfo = pcall(transposer.getFluidInTank, side, tankIdx)
          if ok2 and fluidInfo and fluidInfo.name == fluid.name then
            if fluid.amount == nil or checkAmount(fluidInfo.amount, fluid.amount) then
              found = true
              break
            end
          end
        end
      end
      if found then break end
    end
    if not found then return false, nil end
  end

  return true, sideMap
end

--- @param parent Req
function TransposerReq.new(parent)
  local self        = setmetatable({}, TransposerReq)
  self._parent      = parent
  self._inventories = {}
  self._tanks       = {}
  self._items       = {}
  self._fluids      = {}
  self._req_name    = nil
  self._fail_msg    = nil
  self._succ_msg    = nil
  return self
end

--- Require an inventory by name, optionally on specific side(s).
--- Succeeds if ANY of the added inventory conditions are found.
--- @param inventory_name string
--- @param sides integer|table|nil Single side, list of sides, or nil for any
--- @param side_key string|nil Key to store the found side under in results
--- @return TransposerReq
function TransposerReq:requireInventory(inventory_name, sides, side_key)
  table.insert(self._inventories, { name = inventory_name, sides = sides, side_key = side_key })
  return self
end

--- Require a tank to be present on specific side(s).
--- @param side integer|table|nil Single side, list of sides, or nil for any
--- @return TransposerReq
function TransposerReq:requireTank(side)
  table.insert(self._tanks, { sides = side })
  return self
end

--- Require an item to be present in an inventory.
--- @param item_name string
--- @param amount integer|table|nil Exact number, {min=x, max=y}, or nil for any amount
--- @param slot integer|nil Required slot, nil means any slot
--- @param side integer|table|nil Single side, list of sides, or nil for any
--- @return TransposerReq
function TransposerReq:requireItem(item_name, amount, slot, side)
  table.insert(self._items, { name = item_name, amount = amount, slot = slot, sides = side })
  return self
end

--- Require a fluid to be present in a tank.
--- @param fluid_name string
--- @param amount integer|table|nil Exact number, {min=x, max=y}, or nil for any amount
--- @param side integer|table|nil Single side, list of sides, or nil for any
--- @param tank integer|nil Specific tank index on the side, nil means any tank
--- @return TransposerReq
function TransposerReq:requireFluid(fluid_name, amount, side, tank)
  table.insert(self._fluids, { name = fluid_name, amount = amount, sides = side, tank = tank })
  return self
end

--- Sets the req_name used to store the result in results_data after check().
--- @param req_name string
--- @return TransposerReq
function TransposerReq:named(req_name)
  self._req_name = req_name
  return self
end

--- Sets custom success and failure messages.
--- @param fail_msg string|nil
--- @param succ_msg string|nil
--- @return TransposerReq
function TransposerReq:messages(fail_msg, succ_msg)
  self._fail_msg = fail_msg
  self._succ_msg = succ_msg
  return self
end

--- Finalizes the builder and adds the requirement to the parent Req.
--- @return Req
function TransposerReq:register()
  local conditions = {
    inventories = self._inventories,
    tanks       = self._tanks,
    items       = self._items,
    fluids      = self._fluids,
  }

  local req_name = self._req_name or "transposer"
  local fail_msg = self._fail_msg or "No matching transposer found"
  local succ_msg = self._succ_msg or "Found matching transposer"

  local task = function()
    local component = require("component")
    if not component.isAvailable("transposer") then
      return false, nil
    end

    for address, _ in component.list("transposer") do
      local transposer = component.proxy(address)
      local success, sideMap = checkTransposer(transposer, conditions)
      if success then
        return true, { address = address, sides = sideMap }
      end
    end

    return false, nil
  end

  table.insert(self._parent.requirements, {
    req      = task,
    req_name = req_name,
    fail_msg = fail_msg,
    succ_msg = succ_msg,
  })

  return self._parent
end

function TransposerReq:registerDebug(showInventories, showItems, showFluids)
  -- default all to true if not specified
  showInventories = showInventories ~= false
  showItems       = showItems ~= false
  showFluids      = showFluids ~= false

  local component = require("component")
  local sides     = require("sides")

  local sideNames = {
    [sides.north] = "north",
    [sides.south] = "south",
    [sides.east]  = "east",
    [sides.west]  = "west",
    [sides.up]    = "up",
    [sides.down]  = "down",
  }

  if not component.isAvailable("transposer") then
    print("DEBUG: No transposer found")
    return self
  end

  for address, _ in component.list("transposer") do
    print("DEBUG: Found transposer: " .. address)
    local transposer = component.proxy(address)

    for _, side in ipairs({ sides.north, sides.south, sides.east, sides.west, sides.up, sides.down }) do
      local sideName = sideNames[side] or tostring(side)

      -- inventories
      if showInventories then
        local ok, name = pcall(transposer.getInventoryName, side)
        if ok and name then
          print(string.format("  [%s] inventory: %s", sideName, name))

          -- items inside inventory
          if showItems then
            local okSize, size = pcall(transposer.getInventorySize, side)
            if okSize and size then
              for slot = 1, size do
                local okStack, stack = pcall(transposer.getStackInSlot, side, slot)
                if okStack and stack then
                  for k, v in pairs(stack) do
                    print(string.format("      %s = %s", tostring(k), tostring(v)))
                  end
                end
              end
            end
          end
        else
          print(string.format("  [%s] inventory: none", sideName))
        end
      end

      -- tanks
      if showFluids then
        local okTank, tanks = pcall(transposer.getTankInfo, side)
        if okTank and tanks and #tanks > 0 then
          for tankIdx, tank in ipairs(tanks) do
            local okFluid, fluid = pcall(transposer.getFluidInTank, side, tankIdx)
            if okFluid and fluid and fluid.name then
              print(string.format("  [%s] tank %d: %s %dmb / %dmb",
                sideName,
                tankIdx,
                fluid.name,
                fluid.amount or 0,
                tank.capacity or 0
              ))
            else
              print(string.format("  [%s] tank %d: empty (capacity: %dmb)",
                sideName,
                tankIdx,
                tank.capacity or 0
              ))
            end
          end
        end
      end
    end
  end

  return self
end

--- Creates a new TransposerReq builder attached to this Req instance.
--- @return TransposerReq
function Req:addTransposer()
  assertInstance(self)
  return TransposerReq.new(self)
end

--- Runs all queued requirements and stores results.
--- @return boolean total_success True if all requirements passed
--- @return table success_data Array of {success: boolean, message: string} per requirement
--- @return table results_data Map of req_name -> result value for each requirement
function Req:check()
  assertInstance(self)
  local new_success_data = {}
  local results_data = {}
  local total_success = true

  for _, data in ipairs(self.requirements) do
    local req = data["req"]
    local success, result = req()

    -- save results for later visualization
    table.insert(new_success_data, {
      ["success"] = success,
      ["message"] = success and data["succ_msg"] or data["fail_msg"]
    })

    -- save return values for later use
    if data["req_name"] then
      results_data[data["req_name"]] = result
    end

    if not success then
      total_success = false
    end
  end
  self.success_data = new_success_data
  return total_success, new_success_data, results_data
end

--- Displays check results to the terminal, using colors if a GPU is available.
--- @param show_success boolean Whether to also print successful checks
function Req:displayResults(show_success)
  assertInstance(self)
  assert(#self.success_data > 0, "displayResults called before check()")
  -- get gpu while avoiding possible errors
  local gpu = nil
  local prev_foreground_color = 0xffffff

  local success, comp = pcall(require, "component")
  if success then
    if comp.isAvailable("gpu") then
      gpu = comp.gpu
      prev_foreground_color = gpu.getForeground()
    end
  end


  if show_success then
    if gpu then
      pcall(gpu.setForeground, 0x00ff00)
    end

    for _, data in ipairs(self.success_data) do
      if data["success"] then
        print(data["message"])
      end
    end
  end

  if gpu then
    pcall(gpu.setForeground, 0xff0000)
  end
  for _, data in ipairs(self.success_data) do
    if not data["success"] then
      print(data["message"])
    end
  end

  if gpu then
    pcall(gpu.setForeground, prev_foreground_color)
  end
end

return Req
