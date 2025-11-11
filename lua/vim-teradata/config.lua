local M = {}
-- Default configuration values
M.defaults = {
    -- Connection parameters moved to users list
    ft = { "sql", "teradata" },
    -- Path configuration
    -- Uses standard Neovim cache and data directories
    history_dir = vim.fn.stdpath('data') .. '/teradata',
    bookmarks_dir = vim.fn.stdpath('data') .. '/teradata/bookmarks',

    -- History and Bookmark subdirectories
    queries_dir_name = 'queries',
    resultsets_dir_name = 'resultsets',
    global_bookmarks_dir_name = 'global',
    user_bookmarks_dir_name = 'user',

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
