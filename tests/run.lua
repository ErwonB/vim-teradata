-- Ensure repo root is on runtimepath and package.path
vim.opt.rtp:prepend('.')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        io.stdout:write("  ✓ " .. name .. "\n")
        passed = passed + 1
    else
        io.stdout:write("  ✗ " .. name .. "\n    " .. tostring(err) .. "\n")
        failed = failed + 1
    end
end

_G.test = test

local files = {
    'tests/split_test.lua',
    'tests/format_test.lua',
    'tests/config_test.lua',
    'tests/visual_test.lua',
    'tests/jobs_test.lua',
    'tests/completion_test.lua',
    'tests/depl_test.lua',
}

io.stdout:write("Running vim-teradata test suite...\n")

for _, file in ipairs(files) do
    io.stdout:write("\n[" .. file .. "]\n")
    local ok, err = pcall(dofile, file)
    if not ok then
        io.stdout:write("  Failed loading " .. file .. ": " .. tostring(err) .. "\n")
        failed = failed + 1
    end
end

io.stdout:write(string.format("\nFinished: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
else
    vim.cmd("qall!")
end
