---@class VimTeradata.User
---@field log_mech string  logon mechanism (TD2, LDAP, KRB5, ...)
---@field user string      wallet-backed username
---@field tdpid string     Teradata host or IP

---@class VimTeradata.Config
---@field picker 'auto'|'fzf_vim'|'fzf_lua'|'snacks'|'telescope'|'native'
---@field ft string[]                       extensions that map to the teradata filetype
---@field sql_detection 'always'|'modeline'|'never'
---@field history_dir string
---@field bookmarks_dir string
---@field data_dir string
---@field data_completion_dir string
---@field queries_dir_name string
---@field resultsets_dir_name string
---@field global_bookmarks_dir_name string
---@field user_bookmarks_dir_name string
---@field tpt_script string|nil
---@field filter_db string|nil
---@field retlimit integer
---@field replacements table<string,string>
---@field sep string
---@field edit_enabled boolean
---@field preview_updates boolean
---@field null_token string
---@field edit_keymaps table<string,string>
---@field rerun_keymaps table<string,string>
---@field keymaps table<string,string|table>
---@field timeout_ms integer|nil                      BTEQ job timeout in ms (nil/0 = none)
---@field history_max integer|nil                     max history files kept per dir (nil = unlimited)
---@field diagnostics { enabled: boolean, debounce_ms: integer }
---@field treesitter_folds boolean
---@field users VimTeradata.User[]
---@field current_user_index integer|nil

local M = {}
-- Default configuration values
M.defaults = {
    -- Picker backend: 'auto', 'fzf_vim', 'fzf_lua', 'snacks', 'telescope' or 'native'
    picker = 'auto',
    -- Connection parameters moved to users list
    ft = { 'sql', 'teradata' },
    -- how '.sql' files are treated: 'always' | 'modeline' | 'never'
    sql_detection = 'always',

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
    tpt_script = nil, -- resolved lazily, see M.get_tpt_script()
    -- pattern to filter result from database autocompletion
    filter_db = nil,

    -- Query settings
    retlimit = 100,
    -- Replacements for variables in queries, e.g. replacements = {['${MY_DB}'] = 'MY_ACTUAL_DB'}
    replacements = {},
    -- csv separator for result query file
    sep = '~',
    -- master switch for in-grid editing of query results
    edit_enabled = true,
    -- show the generated UPDATE statements in a buffer before executing them
    preview_updates = false,
    -- token BTEQ uses for NULL in exports; typing it in a cell means SQL NULL
    null_token = 'NULL',
    -- result-buffer local mappings for edit mode
    edit_keymaps = {
        toggle    = 'E',      -- enter / leave edit mode
        edit_cell = '<cr>',   -- change the cell under the cursor (also bound to <CR> in edit mode)
        set_null  = 'X',      -- set the cell under the cursor to SQL NULL
        save      = 'S',      -- generate the UPDATE statements
        cancel    = 'C',      -- discard pending changes
    },
    -- re-run the latest query; '.' echoes Vim's "repeat the last change"
    rerun_keymaps = {
        sql    = 'g.', -- teradata buffers ('.' is left to Vim's repeat)
        result = '.',  -- result buffers (nothing to repeat there, so '.' is free)
    },

    -- OPE keymaps registered in teradata buffers (none by default, see M.recommended_keymaps)
    keymaps = {},
    -- BTEQ job timeout in milliseconds; nil or 0 disables the timeout
    timeout_ms = nil,
    -- keep at most this many query/result files in history; nil disables pruning
    history_max = nil,
    diagnostics = { enabled = true, debounce_ms = 150 },
    treesitter_folds = false,

    -- Users list
    users = {},
    current_user_index = nil,
}

--- Recommended OPE keymaps (opt-in).
M.recommended_keymaps = {
    ['gcu'] = 'uncomment_node',
    ['gcq'] = { 'comment_node', { 'statement' } },
    ['gcs'] = { 'comment_node', { 'select_expression' } },
    ['gcw'] = { 'comment_node', { 'where' } },
    ['gcf'] = { 'comment_node', { 'term' } },
    ['gcb'] = { 'comment_node', { 'binary_expression' } },
    ['gdq'] = { 'delete_node', { 'statement' } },
    ['gds'] = { 'delete_node', { 'select_expression' } },
    ['gdw'] = { 'delete_node', { 'where' } },
    ['gdf'] = { 'delete_node', { 'term' } },
    ['gdb'] = { 'delete_node', { 'binary_expression' } },
    ['grs'] = { 'copy_node', { 'select_expression' } },
    ['grq'] = { 'copy_node', { 'statement' } },
    [']]']  = { 'jump_to_next', { 'statement' } },
    ['[[']  = { 'jump_to_prev', { 'statement' } },
}

M.options = {}
M._ready = false

--- A value interpolated into a BTEQ/TPT script must not contain whitespace,
--- control characters, quotes, backticks, semicolons or backslashes.
local function bad_token(s)
    return type(s) ~= 'string' or s == '' or s:find('[%c%s;\'"`\\]') ~= nil
end

---@param u any
---@return boolean ok, string|nil err
function M.validate_user(u)
    if type(u) ~= 'table' then return false, 'entry must be a table' end
    for _, k in ipairs({ 'user', 'tdpid', 'log_mech' }) do
        if bad_token(u[k]) then
            return false, ('missing or invalid field %q'):format(k)
        end
    end
    return true
end

local function validate(o)
    vim.validate('picker', o.picker, 'string')
    vim.validate('ft', o.ft, 'table')
    vim.validate('sql_detection', o.sql_detection, 'string')
    vim.validate('retlimit', o.retlimit, 'number')
    vim.validate('sep', o.sep, 'string')
    vim.validate('replacements', o.replacements, 'table')
    vim.validate('keymaps', o.keymaps, 'table')
    vim.validate('users', o.users, 'table')
    vim.validate('diagnostics', o.diagnostics, 'table')
    if not vim.tbl_contains({ 'always', 'modeline', 'never' }, o.sql_detection) then
        vim.notify("[vim-teradata] sql_detection must be 'always', 'modeline' or 'never'; using 'always'",
            vim.log.levels.WARN)
        o.sql_detection = 'always'
    end
end

--- Absolute path of the TPT export script (lazy; plugin must be on 'runtimepath').
---@return string|nil
function M.get_tpt_script()
    local o = M.options
    if o.tpt_script and o.tpt_script ~= '' then return o.tpt_script end
    return vim.api.nvim_get_runtime_file('lua/vim-teradata/sql-autocomplete/tpt/export_db.tpt', false)[1]
end

--- Merges user-provided configuration with the defaults.
---@param opts table|nil
function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
    validate(M.options)

    local valid = {}
    for i, u in ipairs(M.options.users) do
        local ok, err = M.validate_user(u)
        if ok then
            valid[#valid + 1] = u
        else
            vim.notify(('[vim-teradata] users[%d] ignored: %s'):format(i, err), vim.log.levels.WARN)
        end
    end
    M.options.users = valid

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
            vim.fn.mkdir(path, 'p', 448) -- 448 == 0o700 (history may contain sensitive SQL)
        end
    end

    local config_file = M.options.history_dir .. '/users.json'
    if vim.fn.filereadable(config_file) == 0 and #M.options.users > 0 then
        M.options.current_user_index = 1
        require('vim-teradata.util').save_config()
    else
        require('vim-teradata.util').load_config()
    end

    M._ready = true

    if M.options.history_max then
        vim.defer_fn(function() require('vim-teradata.util').prune_history() end, 2000)
    end
end

--- Make sure options exist even if the user never called setup().
---@return table options
function M.ensure()
    if not M._ready then M.setup({}) end
    return M.options
end

return M
