-- Fake OpenComputers environment injected into package.loaded
-- so that require("component") / require("sides") return stubs.

local M = {}

-- sides constants (match OC values)
local sides = {
  north = 2, south = 3, east = 4,
  west  = 5, up    = 1, down  = 0,
}
-- reverse map too
for k, v in pairs(sides) do sides[v] = k end

-- component registry: address -> { type, proxy_table }
local registry = {}   -- [address] = { type=..., proxy=... }

local component = {}

function component.isAvailable(name)
  for _, entry in pairs(registry) do
    if entry.type == name then return true end
  end
  return false
end

function component.getPrimary(name)
  for _, entry in pairs(registry) do
    if entry.type == name then return entry.proxy end
  end
  error("component not available: " .. name)
end

function component.list(name)
  local results = {}
  for addr, entry in pairs(registry) do
    if not name or entry.type == name then
      results[addr] = entry.type
    end
  end
  return pairs(results)
end

function component.proxy(address)
  assert(registry[address], "no component at address " .. tostring(address))
  return registry[address].proxy
end

-- Helper used in tests: register a fake component
function M.register(address, type_name, proxy_table)
  registry[address] = { type = type_name, proxy = proxy_table }
end

-- Clear all registered components between tests
function M.reset()
  registry = {}
end

-- Install into package.loaded so require() picks them up
function M.install()
  package.loaded["component"] = component
  package.loaded["sides"]     = sides
end

function M.uninstall()
  package.loaded["component"] = nil
  package.loaded["sides"]     = nil
end

M.sides = sides

return M