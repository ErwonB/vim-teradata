local M = {}

local GROUP = vim.api.nvim_create_augroup('VimTeradata', { clear = false })
local attached = {}          -- bufnr -> { cmds, keys, debouncers }
local completion_registered = false

-- { name, module, function, opts, desc }  (global commands live in plugin/teradata.lua)
local BUF_CMDS = {
    { 'TD',          'vim-teradata.bteq',         'query_syntax',                { count = true }, 'Syntax-check statement(s) at cursor' },
    { 'TDO',         'vim-teradata.bteq',         'query_output',                { count = true }, 'Run statement(s) at cursor' },
    { 'TDE',         'vim-teradata.bteq',         'query_syntax_visual',         { range = true }, 'Syntax-check selection' },
    { 'TDV',         'vim-teradata.bteq',         'query_output_visual',         { range = true }, 'Run selection' },
    { 'TDM',         'vim-teradata.bteq',         'query_multistatement',        { count = true }, 'Run statement(s) as one multistatement job' },
    { 'TDMV',        'vim-teradata.bteq',         'query_multistatement_visual', { range = true }, 'Run selection as one multistatement job' },
    { 'TDBAdd',      'vim-teradata.bookmark',     'add_from_range',              { range = true }, 'Bookmark selection' },
    { 'TDF',         'vim-teradata.td_ope',       'format_current_statement',    { count = true }, 'Format statement(s) (experimental)' },
    { 'TDFF',        'vim-teradata.td_ope',       'format_all_statements',       { nargs = 0 },    'Format whole buffer (experimental)' },
    { 'TDCodeAction','vim-teradata.code_actions', 'run',                         { nargs = 0 },    'Teradata code actions' },
}

local function describe(func_name, node_type)
    local d = (func_name:gsub('_', ' '))
    d = d:gsub('^%l', string.upper)
    return node_type and (d .. ' surrounding ' .. node_type) or (d .. ' node')
end

local function attach_commands(bufnr, st)
    for _, c in ipairs(BUF_CMDS) do
        vim.api.nvim_buf_create_user_command(bufnr, c[1], function(args)
            require(c[2])[c[3]](args)
        end, vim.tbl_extend('force', c[4], { desc = c[5] }))
        st.cmds[#st.cmds + 1] = c[1]
    end
end

local function attach_keymaps(bufnr, st)
    local ope = require('vim-teradata.td_ope')
    for key, action in pairs(require('vim-teradata.config').options.keymaps or {}) do
        local func_name, args
        if type(action) == 'string' then
            func_name, args = action, {}
        elseif type(action) == 'table' then
            func_name, args = action[1], action[2] or {}
        end
        if func_name then
            vim.keymap.set('n', key, function()
                local fn = ope[func_name]
                if type(fn) == 'function' then
                    fn(args[1], args[2], args[3])
                else
                    vim.notify('Teradata OPE function "' .. func_name .. '" not found.', vim.log.levels.WARN)
                end
            end, { desc = describe(func_name, args[1]), buffer = bufnr })
            st.keys[#st.keys + 1] = { 'n', key }
        end
    end

    -- Re-run the latest query. Deliberately not '.': that stays Vim's repeat.
    local rerun_key = (require('vim-teradata.config').options.rerun_keymaps or {}).sql
    if rerun_key and rerun_key ~= '' then
        vim.keymap.set('n', rerun_key, function()
            require('vim-teradata.bteq').rerun_latest()
        end, { desc = 'Teradata: re-run latest query', buffer = bufnr, silent = true })
        st.keys[#st.keys + 1] = { 'n', rerun_key }
    end
end

local function attach_diagnostics(bufnr, st)
    local opts = require('vim-teradata.config').options.diagnostics or {}
    if opts.enabled == false then return end
    local diag = require('vim-teradata.diagnostics')
    if opts.config then vim.diagnostic.config(opts.config, diag.NAMESPACE) end

    local run = function()
        if vim.api.nvim_buf_is_valid(bufnr) then diag.update_diagnostics(bufnr) end
    end
    local deb = require('vim-teradata.debounce').new(opts.debounce_ms or 150, run)
    st.debouncers[#st.debouncers + 1] = deb

    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
        group = GROUP, buffer = bufnr, callback = run, desc = 'vim-teradata: diagnostics',
    })
    vim.api.nvim_create_autocmd('TextChanged', {
        group = GROUP, buffer = bufnr, callback = deb.call, desc = 'vim-teradata: diagnostics (debounced)',
    })
end

local function attach_depl(bufnr, st)
    local regions = require('vim-teradata.depl_sql_regions')
    local run = function()
        if vim.api.nvim_buf_is_valid(bufnr) then regions.restrict_sql_regions(bufnr) end
    end
    local deb = require('vim-teradata.debounce').new(150, run)
    st.debouncers[#st.debouncers + 1] = deb
    run()
    vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
        group = GROUP, buffer = bufnr, callback = run, desc = 'vim-teradata: depl SQL regions',
    })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = GROUP, buffer = bufnr, callback = deb.call, desc = 'vim-teradata: depl SQL regions (debounced)',
    })
end

local function attach_completion(bufnr)
    if not completion_registered then
        local integ = require('vim-teradata.sql-autocomplete.integrations')
        completion_registered = integ.register_blink() or integ.register_cmp()
    end
    vim.bo[bufnr].omnifunc = "v:lua.require'vim-teradata.sql-autocomplete.completion'.omnifunc"
    vim.keymap.set('i', '<C-x><C-u>', function()
        require('vim-teradata.sql-autocomplete.completion').trigger_completion()
    end, { buffer = bufnr, silent = true, desc = 'Teradata: completion picker' })
end

---@param bufnr integer
function M.attach(bufnr)
    if not require('vim-teradata.compat').check() then return end
    require('vim-teradata.config').ensure()
    if attached[bufnr] then return end

    local st = { cmds = {}, keys = {}, debouncers = {} }
    attached[bufnr] = st

    pcall(vim.treesitter.start, bufnr)
    -- Only *.depl -> SQL + region restriction
    if vim.api.nvim_buf_get_name(bufnr):match('%.depl$') then attach_depl(bufnr, st) end
    attach_diagnostics(bufnr, st)
    -- Node-based, visual-selection and multistatement commands
    attach_commands(bufnr, st)
    -- Autocomplete provider + keymaps for code editing
    attach_completion(bufnr)
    attach_keymaps(bufnr, st)
    st.keys[#st.keys + 1] = { 'i', '<C-x><C-u>' }

    vim.api.nvim_create_autocmd('BufWipeout', {
        group = GROUP, buffer = bufnr, once = true,
        callback = function() M.detach(bufnr) end,
        desc = 'vim-teradata: cleanup',
    })
end

---@param bufnr integer|nil
function M.detach(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local st = attached[bufnr]
    if not st then return end
    attached[bufnr] = nil

    for _, d in ipairs(st.debouncers) do d.close() end
    pcall(vim.api.nvim_clear_autocmds, { group = GROUP, buffer = bufnr })
    for _, name in ipairs(st.cmds) do pcall(vim.api.nvim_buf_del_user_command, bufnr, name) end
    for _, k in ipairs(st.keys) do pcall(vim.keymap.del, k[1], k[2], { buffer = bufnr }) end

    local ok, diag = pcall(require, 'vim-teradata.diagnostics')
    if ok then
        pcall(vim.diagnostic.reset, diag.NAMESPACE, bufnr)
        diag.forget(bufnr)
    end
    pcall(function() require('vim-teradata.depl_sql_regions').forget(bufnr) end)
end

return M
