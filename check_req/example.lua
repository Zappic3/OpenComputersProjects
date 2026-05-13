local req_lib = require("check_req")

local req = req_lib.new()

-- test some standard modules
req:addRequires(nil, nil, "serialization", "filesystem", "computer")

-- test a module that likely doesn't exist
req:addRequire("nonexistent_module")

-- test a simple component (no tier needed)
req:addComponent("gpu", "gpu")

-- test redstone, requiring at least T2
req:addComponent("redstone", "redstone", {"t2"},
    "Redstone card T2 required but not found",
    "Redstone card T2 found"
)

-- test data card, accepting T2 or T3
req:addComponent("data", "data", {"t2", "t3"},
    "Data card T2 or T3 required but not found",
    "Data card (T2 or T3) found"
)

-- run all checks
local total_success, success_data, results_data = req:check()

-- display results, showing both successes and failures
req:displayResults(true)

-- summary
if total_success then
    print("All requirements met, continuing...")
else
    print("Some requirements missing, aborting.")
    os.exit()
end