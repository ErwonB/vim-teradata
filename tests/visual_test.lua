local bteq = require('vim-teradata.bteq')

test("get_range_sql with args line1 and line2 and range=2", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "SELECT 1 FROM tab;",
        "SELECT 2 FROM tab;",
        "SELECT 3 FROM tab;",
    })
    vim.api.nvim_set_current_buf(buf)

    local sql = bteq._get_range_sql({ line1 = 1, line2 = 2, range = 2 })
    assert(sql ~= nil, "sql should not be nil")
    assert(sql:find("SELECT 1"), "expected SELECT 1")
    assert(sql:find("SELECT 2"), "expected SELECT 2")
    assert(not sql:find("SELECT 3"), "did not expect SELECT 3")

    vim.api.nvim_buf_delete(buf, { force = true })
end)
