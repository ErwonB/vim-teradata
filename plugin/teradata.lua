if vim.g.loaded_teradata then return end
vim.g.loaded_teradata = 1

require('vim-teradata.ft').register()

local GLOBAL_CMDS = {
    { 'TDH',    'vim-teradata.ui',   'show_queries',          'Teradata: query history' },
    { 'TDR',    'vim-teradata.pick', 'find_query_by_content', 'Teradata: search query history by content' },
    { 'TDHelp', 'vim-teradata.ui',   'display_help',          'Teradata: quick reference' },
    { 'TDU',    'vim-teradata.ui',   'show_users',            'Teradata: connection profiles' },
    { 'TDS',    'vim-teradata.ui',   'show_settings',         'Teradata: settings' },
    { 'TDB',    'vim-teradata.ui',   'show_bookmarks',        'Teradata: bookmarks' },
    { 'TDJ',    'vim-teradata.ui',   'show_jobs',             'Teradata: job manager' },
    { 'TDRerun','vim-teradata.bteq', 'rerun_latest',          'Teradata: re-run latest query' },
    { 'TDSessions', 'vim-teradata.session', 'show',           'Teradata: list open BTEQ sessions' },
}

for _, c in ipairs(GLOBAL_CMDS) do
    vim.api.nvim_create_user_command(c[1], function(args)
        require('vim-teradata.config').ensure()
        require(c[2])[c[3]](args)
    end, { nargs = 0, desc = c[4] })
end

vim.api.nvim_create_user_command('TDExport', function(args)
    require('vim-teradata.config').ensure()
    local id = args.fargs[1]
    require('vim-teradata.export').run(id and id ~= '' and id or nil)
end, {
    nargs = '?',
    desc = 'Teradata: export the full result of a query via TPT',
    complete = function(arglead)
        local config = require('vim-teradata.config')
        config.ensure()
        local dir = require('vim-teradata.util').get_history_path('queries_dir_name')
        local ids = {}
        for _, f in ipairs(vim.fn.isdirectory(dir) == 1 and vim.fn.readdir(dir) or {}) do
            local id = f:match('^(.+)%.sql$')
            if id and vim.startswith(id, arglead) then ids[#ids + 1] = id end
        end
        table.sort(ids, function(a, b) return a > b end)
        return ids
    end,
})

vim.api.nvim_create_user_command('TDSync', function(args)
    require('vim-teradata.config').ensure()
    require('vim-teradata.util').sync_command(args)
end, {
    nargs = '*',
    range = true,
    bang = true,
    desc = 'Teradata: refresh metadata cache (full or per object)',
    complete = function(arglead, cmdline)
        return require('vim-teradata.util').sync_complete(arglead, cmdline)
    end,
})
