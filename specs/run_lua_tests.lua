package.path = table.concat({
  "src/?.lua",
  "specs/?.lua",
  package.path
}, ";")

local tests = {
  require "scene_manager_test"
}

local total = 0
for _, suite in ipairs(tests) do
  for name, test in pairs(suite) do
    total = total + 1
    local ok, err = pcall(test)
    if not ok then
      io.stderr:write(string.format("FAILED %s: %s\n", name, tostring(err)))
      os.exit(1)
    end
  end
end

print(string.format("%d Lua tests passed", total))
