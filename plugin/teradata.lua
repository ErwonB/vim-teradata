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
