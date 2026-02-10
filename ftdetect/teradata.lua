vim.api.nvim_create_autocmd({ "BufNewFile", "BufRead" }, {
    pattern = { "*.sql", "*.tpt", "*.bteq", "*.depl" },
    callback = function()
        vim.bo.filetype = "teradata"
    end,
})


-- Normal teradata files → just SQL highlighting
vim.api.nvim_create_autocmd("FileType", {
    pattern = "teradata",
    callback = function(ev)
        vim.treesitter.language.register("sql", "teradata")
        pcall(vim.treesitter.start, ev.buf)
    end,
})

-- Only *.depl → SQL + region restriction
vim.api.nvim_create_autocmd("FileType", {
    pattern = "teradata",
    callback = function(ev)
        -- Quick exit if not .depl
        if vim.fn.expand("%:e") ~= "depl" then
            return
        end

        local function restrict()
            require('vim-teradata.depl_sql_regions').restrict_sql_regions(ev.buf)
        end

        restrict()

        vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "TextChanged", "TextChangedI" }, {
            buffer = ev.buf,
            callback = restrict,
            desc = "Update depl SQL regions on change",
            group = vim.api.nvim_create_augroup("DeplRegionUpdate", {}),
        })
    end,
    -- Make sure this runs after the generic teradata handler
    nested = true,
})

local group = vim.api.nvim_create_augroup("VimTeradataDiagnostics", { clear = true })
vim.api.nvim_create_autocmd({ "TextChanged", "BufEnter", "BufWritePost" }, {
    group = group,
    callback = function()
        if vim.bo.filetype == "teradata" then
            require('vim-teradata.diagnostics').update_diagnostics(0)
        end
    end,
})
