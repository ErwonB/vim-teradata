vim.api.nvim_create_autocmd({ "BufNewFile", "BufRead" }, {
    pattern = { "*.sql", "*.tpt", "*.bteq", "*.depl" },
    callback = function()
        vim.bo.filetype = "teradata"
    end,
})


vim.api.nvim_create_autocmd("FileType", {
    pattern = "teradata",
    callback = function(args)
        vim.treesitter.language.register("sql", "teradata")
        pcall(vim.treesitter.start, args.buf)

        local function apply_regions()
            require('vim-teradata.depl_sql_regions').restrict_sql_regions(args.buf)
        end

        apply_regions()

        vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
            buffer = args.buf,
            callback = apply_regions,
            desc = 'Restrict SQL TS to marked regions in teradata buffers',
        })
    end,
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
