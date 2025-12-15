local M = {}
-- Default configuration values
local tpt_script = vim.api.nvim_get_runtime_file("lua/vim-teradata/sql-autocomplete/tpt/export_db.tpt", true)
M.defaults = {
    -- Connection parameters moved to users list
    ft = { "sql", "teradata" },
    -- Path configuration
    -- Uses standard Neovim data directories
    history_dir = vim.fn.stdpath('data') .. '/teradata',
    bookmarks_dir = vim.fn.stdpath('data') .. '/teradata/bookmarks',
    data_dir = vim.fn.stdpath('data') .. '/teradata/sql-autocomplete',
    data_completion_dir = 'data',

    -- History and Bookmark subdirectories
    queries_dir_name = 'queries',
    resultsets_dir_name = 'resultsets',
    global_bookmarks_dir_name = 'global',
    user_bookmarks_dir_name = 'user',

    -- tpt_script
    tpt_script = tpt_script[1],

    -- pattern to filter result from database autocompletion
    filter_db = nil,

    -- Query settings
    retlimit = 100,
    -- Replacements for variables in queries, e.g. replacements = {['${MY_DB}'] = 'MY_ACTUAL_DB'}
    replacements = {},
    -- csv separator for result query file
    sep = "~",
    -- Users list
    users = {},
    current_user_index = nil,
}
M.options = {}
--- Merges user-provided configuration with the defaults.
--- @param opts table | nil User configuration table.
function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
    -- Create necessary directories
    local paths = {
        M.options.history_dir,
        M.options.history_dir .. '/' .. M.options.queries_dir_name,
        M.options.history_dir .. '/' .. M.options.resultsets_dir_name,
        M.options.bookmarks_dir,
        M.options.bookmarks_dir .. '/' .. M.options.global_bookmarks_dir_name,
        M.options.bookmarks_dir .. '/' .. M.options.user_bookmarks_dir_name,
        M.options.data_dir,
        M.options.data_dir .. '/' .. M.options.data_completion_dir,
    }
    for _, path in ipairs(paths) do
        if vim.fn.isdirectory(path) == 0 then
            vim.fn.mkdir(path, 'p')
        end
    end
    -- Load saved config if exists, otherwise initialize from provided
    local config_file = M.options.history_dir .. '/users.json'
    if vim.fn.filereadable(config_file) == 0 and #M.options.users > 0 then
        M.options.current_user_index = 1
        require('vim-teradata.util').save_config()
    else
        require('vim-teradata.util').load_config()
    end
end

return M
