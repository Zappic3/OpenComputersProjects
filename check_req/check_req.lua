---@class Req
---@field requirements table
---@field success_data table
local Req = {}
Req.__index = Req

local detectors = nil

local function getDetectors()
  if detectors then return detectors end  -- already initialized, reuse

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
      if d.deflate        then return true, "t2" end
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
          return true, tier  -- tier is accepted
        end
      end
      return false, tier  -- found but wrong tier
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