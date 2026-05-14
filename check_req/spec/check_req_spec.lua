local oc = require("mock_oc")

-- Install fakes before loading the library under test
oc.install()
local Req = require("check_req")

-- Helper: build a minimal fake transposer proxy
local function makeTransposer(inventoryMap, fluidMap, itemMap)
  -- inventoryMap: side -> name
  -- fluidMap:     side -> { {name, amount, capacity}, ... }
  -- itemMap:      side -> { slot -> {name, size} }
  inventoryMap = inventoryMap or {}
  fluidMap     = fluidMap     or {}
  itemMap      = itemMap      or {}

  return {
    getInventoryName = function(side)
      local n = inventoryMap[side]
      if n then return n else error("no inventory") end
    end,
    getInventorySize = function(side)
      local slots = itemMap[side]
      if slots then
        local max = 0
        for k in pairs(slots) do if k > max then max = k end end
        return max
      end
      error("no inventory")
    end,
    getStackInSlot = function(side, slot)
      local slots = itemMap[side] or {}
      return slots[slot]  -- nil is fine, means empty
    end,
    getTankInfo = function(side)
      local tanks = fluidMap[side]
      if tanks and #tanks > 0 then return tanks else error("no tanks") end
    end,
    getFluidInTank = function(side, tankIdx)
      local tanks = fluidMap[side] or {}
      return tanks[tankIdx]
    end,
  }
end

-- ─── Req:addComponent ────────────────────────────────────────────────

describe("Req:addComponent", function()
  before_each(function()
    oc.reset()
    oc.install()
  end)

  it("succeeds when component is available", function()
  oc.register("addr-1", "modem", {})
  local r = Req.new()
  r:addComponent("modem")
  local ok, _, results = r:check()
  assert.is_true(ok)
  -- result is the tier (nil for components without tier detection), 
  -- so just check overall success
end)

  it("fails when component is missing", function()
    local r = Req.new()
    r:addComponent("modem")
    local ok = r:check()
    assert.is_false(ok)
  end)

  it("respects accepted_tiers — passes on correct tier", function()
    -- data card tier 2 has deflate but not generateKeyPair
    oc.register("addr-d", "data", {
      deflate       = function() end,
      generateKeyPair = nil,
    })
    local r = Req.new()
    r:addComponent("data", "data", {"t2"})
    local ok = r:check()
    assert.is_true(ok)
  end)

  it("respects accepted_tiers — fails on wrong tier", function()
    oc.register("addr-d", "data", {
      deflate = function() end,
    })
    local r = Req.new()
    r:addComponent("data", "data", {"t3"})  -- need t3, have t2
    local ok = r:check()
    assert.is_false(ok)
  end)
end)

-- ─── Req:addRequire ──────────────────────────────────────────────────

describe("Req:addRequire", function()
  it("succeeds when module is loadable", function()
    -- 'string' is always available
    local r = Req.new()
    r:addRequire("string")
    local ok = r:check()
    assert.is_true(ok)
  end)

  it("fails when module is missing", function()
    local r = Req.new()
    r:addRequire("definitely.not.a.real.module.xyz")
    local ok = r:check()
    assert.is_false(ok)
  end)
end)

-- ─── Req:addFunc ─────────────────────────────────────────────────────

describe("Req:addFunc", function()
  it("succeeds when function does not error", function()
    local r = Req.new()
    r:addFunc(function() return true end, {}, "myFunc")
    local ok, _, results = r:check()
    assert.is_true(ok)
    assert.is_true(results["myFunc"])
  end)

  it("fails when function throws", function()
    local r = Req.new()
    r:addFunc(function() error("boom") end, {}, "myFunc")
    local ok = r:check()
    assert.is_false(ok)
  end)

  it("passes args to the function", function()
    local received
    local r = Req.new()
    r:addFunc(function(a, b) received = {a, b} end, {"hello", 42}, "f")
    r:check()
    assert.are.same({"hello", 42}, received)
  end)
end)

-- ─── TransposerReq ───────────────────────────────────────────────────

describe("TransposerReq", function()
  local S = oc.sides

  before_each(function()
    oc.reset()
    oc.install()
  end)

  it("fails when no transposer is present", function()
    local r = Req.new()
    r:addTransposer()
      :requireInventory("minecraft:chest")
      :register()
    local ok = r:check()
    assert.is_false(ok)
  end)

  it("succeeds when transposer has the required inventory", function()
    local proxy = makeTransposer({ [S.north] = "minecraft:chest" })
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireInventory("minecraft:chest")
      :named("my_transposer")
      :register()

    local ok, _, results = r:check()
    assert.is_true(ok)
    assert.are.equal("t-addr-1", results["my_transposer"].address)
  end)

  it("records side_key in results", function()
    local proxy = makeTransposer({ [S.north] = "minecraft:chest" })
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireInventory("minecraft:chest", nil, "chest_side")
      :named("t")
      :register()

    local ok, _, results = r:check()
    assert.is_true(ok)
    assert.are.equal(S.north, results["t"].sides["chest_side"])
  end)

  it("fails when required inventory is absent", function()
    local proxy = makeTransposer({ [S.north] = "minecraft:furnace" })
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireInventory("minecraft:chest")
      :register()
    local ok = r:check()
    assert.is_false(ok)
  end)

  it("matches required item by name", function()
    local proxy = makeTransposer(
      { [S.south] = "minecraft:chest" },
      {},
      { [S.south] = { [1] = { name = "minecraft:diamond", size = 5 } } }
    )
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireItem("minecraft:diamond")
      :named("t")
      :register()

    local ok = r:check()
    assert.is_true(ok)
  end)

  it("fails item check when amount does not match range", function()
    local proxy = makeTransposer(
      { [S.south] = "minecraft:chest" },
      {},
      { [S.south] = { [1] = { name = "minecraft:diamond", size = 2 } } }
    )
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireItem("minecraft:diamond", { min = 5 })  -- need at least 5
      :register()

    local ok = r:check()
    assert.is_false(ok)
  end)

  it("matches required fluid by name", function()
    local proxy = makeTransposer(
      {},
      { [S.east] = { { name = "minecraft:water", amount = 1000, capacity = 8000 } } }
    )
    oc.register("t-addr-1", "transposer", proxy)

    local r = Req.new()
    r:addTransposer()
      :requireFluid("minecraft:water")
      :register()

    local ok = r:check()
    assert.is_true(ok)
  end)
end)

-- ─── Req:check results_data ──────────────────────────────────────────

describe("Req:check results_data", function()
  before_each(function()
    oc.reset()
    oc.install()
  end)

  it("stores result values keyed by req_name", function()
    local r = Req.new()
    r:addFunc(function() return "hello" end, {}, "greeting")
    local _, _, results = r:check()
    assert.are.equal("hello", results["greeting"])
  end)

  it("total_success is false if any check fails", function()
    oc.register("addr-1", "modem", {})
    local r = Req.new()
    r:addComponent("modem")
    r:addComponent("gpu")   -- not registered
    local ok = r:check()
    assert.is_false(ok)
  end)
end)