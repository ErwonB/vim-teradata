local depl = require('vim-teradata.depl_sql_regions')

test("restrict_sql_regions on non-teradata buffer runs safely", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Host language code",
        "======== SQL ========",
        "SELECT 1 FROM tab;",
    })
    -- Without teradata treesitter parser loaded, it should return gracefully without errors
    depl.restrict_sql_regions(buf)
    depl.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
end)
