local bteq = require('vim-teradata.bteq')
local ui = require('vim-teradata.ui')
local picker = require('vim-teradata.pick')
local bookmark = require('vim-teradata.bookmark')
local ope = require('vim-teradata.td_ope')
local code_actions = require('vim-teradata.code_actions')
local util = require('vim-teradata.util')
local config = require('vim-teradata.config')

local function register_td_provider()
    local ok, blink = pcall(require, 'blink.cmp')
    if not ok then return end

    local blink_config = require('blink.cmp.config')
    local provider_lib = require('blink.cmp.sources.lib.provider')
    local sources_lib = require('blink.cmp.sources.lib')

    local id = 'td_sql_completion'
    local cfg = {
        name = 'TD SQL Completion',
        module = 'vim-teradata.sql-autocomplete.blink',
        score_offset = 0,
    }

    blink_config.sources.providers[id] = cfg

    local default = blink_config.sources.default or {}
    if not vim.tbl_contains(default, id) then
        table.insert(default, id)
    end
    blink_config.sources.default = default

    sources_lib.providers[id] = provider_lib.new(id, cfg)

    if blink.reload then blink.reload(id) end
    return true
end

local function register_cmp_provider()
    local ok, cmp = pcall(require, 'cmp')
    if not ok then return false end

    local source = require('vim-teradata.sql-autocomplete.cmp').new()
    cmp.register_source('td_sql_completion', source)
    return true
end

local bufnr = vim.api.nvim_get_current_buf()

-- 1. Normal teradata files -> SQL Treesitter highlighting
vim.treesitter.language.register("sql", "teradata")
pcall(vim.treesitter.start, bufnr)

-- 2. Only *.depl -> SQL + region restriction
if vim.fn.expand("%:e") == "depl" then
    local function restrict()
        require('vim-teradata.depl_sql_regions').restrict_sql_regions(bufnr)
    end

    restrict()

    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "TextChanged", "TextChangedI" }, {
        buffer = bufnr,
        callback = restrict,
        desc = "Update depl SQL regions on change",
        group = vim.api.nvim_create_augroup("DeplRegionUpdate_" .. bufnr, { clear = true }),
    })
end

-- 3. Diagnostics
local diag_group = vim.api.nvim_create_augroup("VimTeradataDiagnostics_" .. bufnr, { clear = true })
vim.api.nvim_create_autocmd({ "TextChanged", "BufEnter", "BufWritePost" }, {
    buffer = bufnr,
    group = diag_group,
    callback = function()
        require('vim-teradata.diagnostics').update_diagnostics(bufnr)
    end,
})


-- Node-based commands (support :nTD / :nTDO count syntax)
vim.api.nvim_buf_create_user_command(bufnr, 'TD',  bteq.query_syntax,        { count = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDO', bteq.query_output,        { count = true })
-- Visual-selection commands (split on ';')
vim.api.nvim_buf_create_user_command(bufnr, 'TDE', bteq.query_syntax_visual, { range = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDV', bteq.query_output_visual, { range = true })
-- Multistatement commands (single BTEQ job, multiple queries joined)
vim.api.nvim_buf_create_user_command(bufnr, 'TDM',  bteq.query_multistatement,        { count = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDMV', bteq.query_multistatement_visual, { range = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDH', ui.show_queries, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDR', picker.find_query_by_content, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDHelp', ui.display_help, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDU', ui.show_users, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDS', ui.show_settings, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDB', ui.show_bookmarks, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDBAdd', bookmark.add_from_range, { range = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDJ', ui.show_jobs, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDF', ope.format_current_statement, { count = true })
vim.api.nvim_buf_create_user_command(bufnr, 'TDFF', ope.format_all_statements, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDSync', util.export_db_data, { nargs = 0 })
vim.api.nvim_buf_create_user_command(bufnr, 'TDCodeAction', code_actions.run, { nargs = 0 })

-- Setup Autocomplete Provider
local registered = register_td_provider()
if not registered then
    register_cmp_provider()
end

vim.api.nvim_buf_set_keymap(bufnr, 'i', '<C-x><C-u>',
    '<cmd>lua require("vim-teradata.sql-autocomplete.completion").trigger_completion()<CR>', {
        noremap = true,
        silent = true
    })

-- Setup Keymaps for code editing
for key, action in pairs(config.options.keymaps) do
    local func_name
    local args = {}
    local description = ""

    if type(action) == 'string' then
        func_name = action
        description = func_name:gsub('_', ' '):gsub('(%a)', string.upper, 1) .. " node"
    elseif type(action) == 'table' then
        func_name = action[1]
        args = action[2] or {}
        description = func_name:gsub('_', ' '):gsub('(%a)', string.upper, 1) ..
            " surrounding " .. (args[1] or "node")
    end

    local keymap_func = function()
        local success, func = pcall(function() return ope[func_name] end)
        if success and type(func) == 'function' then
            func(args[1], args[2], args[3])
        else
            vim.notify('Teradata OPE function "' .. func_name .. '" not found.', vim.log.levels.WARN)
        end
    end

    vim.keymap.set('n', key, keymap_func, { desc = description, buffer = bufnr })
end
