local config = require('vim-teradata.config')
local util = require('vim-teradata.util')

local M = {}

--- Opens a file in a new split window.
--- @param file_path string Path to the file.
--- @param filetype string | nil Optional filetype to set.
local function open_in_split(file_path, filetype)
    vim.cmd.set('splitbelow')
    vim.cmd.split(vim.fn.fnameescape(file_path))
    if filetype then
        vim.bo.filetype = filetype
    end
end

--- Post-processes and displays a query result file using csv.vim.
--- @param file_path string Path to the result file.
function M.display_output(file_path)
    local lines = vim.fn.readfile(file_path)
    local new_lines = {}
    for _, line in ipairs(lines) do
        local parts = vim.fn.split(line, '@')
        local trimmed_parts = vim.tbl_map(function(part)
            return part:gsub('%s+$', '')
        end, parts)
        table.insert(new_lines, table.concat(trimmed_parts, '@'))
    end
    vim.fn.writefile(new_lines, file_path)

    open_in_split(file_path, 'csv')

    vim.fn.call('csv#ArrangeCol', { 1, vim.fn.line('$'), 1, -1 })

    vim.cmd('write')
    vim.cmd('setlocal nomodified')
end

--- Displays an error message from a BTEQ execution.
--- @param msg string The error message.
--- @param log_path string The path to the log file for more details.
function M.display_error(msg, log_path)
    if config.options.bteq_open_log_when_error then
        vim.cmd.vsplit(vim.fn.fnameescape(log_path))
    else
        vim.notify(msg, vim.log.levels.ERROR, { title = 'Teradata Error' })
    end
end

--- Displays the help message in a new buffer.
function M.display_help()
    local help_text = {
        'TD: syntax checking',
        'TDO: to get the output of the query',
        'TDH: Show query history',
        'TDR: Search query history with FZF',
        'TDU: Manage users',
        'TDHelp: Display this help',
    }

    vim.cmd('belowright 10split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'wipe'
    vim.bo.swapfile = false
    vim.api.nvim_buf_set_lines(0, 0, -1, false, help_text)
    vim.bo.modifiable = false
end

--- Opens a query and its corresponding result file.
--- @param file_id string The numeric ID of the query.
function M.open_query_result_pair(file_id)
    local query_file = util.get_history_path('queries_dir_name') .. '/' .. file_id
    local result_file = util.get_history_path('resultsets_dir_name') .. '/' .. file_id

    -- Close existing history buffers to prevent clutter
    local buflisted = vim.api.nvim_list_bufs()
    for _, buf in ipairs(buflisted) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local buf_name = vim.api.nvim_buf_get_name(buf)
            if buf_name:find(config.options.history_dir, 1, true) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end

    vim.cmd.edit(vim.fn.fnameescape(query_file))
    if vim.fn.filereadable(result_file) == 1 then
        open_in_split(result_file, 'csv')
        vim.cmd.wincmd('p')
    end
end

--- Shows a browsable list of past queries.
function M.show_queries()
    local queries_dir = util.get_history_path('queries_dir_name')
    local files = vim.fn.glob(queries_dir .. '/*', false, true)

    -- Sort files by modification time (newest first)
    table.sort(files, function(f1, f2)
        return vim.fn.getftime(f1) > vim.fn.getftime(f2)
    end)

    local basenames = vim.tbl_map(function(f)
        return vim.fn.fnamemodify(f, ':t')
    end, files)

    vim.cmd('belowright 10split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    vim.api.nvim_buf_set_name(0, 'Teradata Queries')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, basenames)
    vim.bo.modifiable = false

    vim.keymap.set('n', '<cr>', function()
        M.open_query_result_pair(vim.fn.getline('.'))
    end, { buffer = true, silent = true })

    vim.cmd('setlocal updatetime=500')
    vim.api.nvim_create_autocmd('CursorHold', {
        buffer = 0,
        callback = function()
            local file_id = vim.fn.getline('.')
            local query_file = util.get_history_path('queries_dir_name') .. '/' .. file_id

            if vim.fn.filereadable(query_file) == 1 then
                local buf = vim.api.nvim_create_buf(false, true)
                local lines = vim.fn.readfile(query_file)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

                local width = 80
                local height = 10

                local cursor = vim.api.nvim_win_get_cursor(0)
                local row = cursor[1]
                local col = cursor[2]

                vim.api.nvim_open_win(buf, false, {
                    relative = 'win',
                    width = width,
                    height = height,
                    row = row - 1,
                    col = col + 10,
                    style = 'minimal',
                    border = 'rounded',
                })
            end
        end,
    })
end

--- Shows a management window for users.
function M.show_users()
    local function populate_buffer()
        local bufnr = vim.api.nvim_get_current_buf()
        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local lines = {}
        local extmark

        if next(config.options.users) then
            local user_col_width = #("user")
            local tdpid_col_width = #("tdpid")
            local logmech_col_width = #("logon mechanism")

            for _, u in ipairs(config.options.users) do
                user_col_width = math.max(user_col_width, #(u.user) + 1)
                tdpid_col_width = math.max(tdpid_col_width, #(u.tdpid))
                logmech_col_width = math.max(logmech_col_width, #(u.log_mech))
            end

            table.insert(lines, string.format(
                "%-" .. user_col_width .. "s| %-" .. tdpid_col_width .. "s| %-" .. logmech_col_width .. "s",
                "user", "tdpid", "logon mechanism"
            ))

            table.insert(lines, string.rep("-", user_col_width) .. "+"
                .. string.rep("-", tdpid_col_width + 1) .. "+"
                .. string.rep("-", logmech_col_width + 1))

            for i, u in ipairs(config.options.users) do
                local prefix = (i == config.options.current_user_index) and '*' or ' '
                table.insert(lines, string.format(
                    "%s%-" .. (user_col_width - 1) .. "s| %-" .. tdpid_col_width .. "s| %-" .. logmech_col_width .. "s",
                    prefix, u.user, u.tdpid, u.log_mech
                ))
            end
        end

        if #lines == 0 then
            extmark = 'No users configured. Press "a" to add one.'
        else
            extmark = '<a> Add    <d> Delete    <Enter> Current'
        end
        vim.bo.modifiable = true
        table.insert(lines, '')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ns_id,
            #lines - 1,
            0,
            {
                virt_text = { { extmark, "Comment" } },
                virt_text_pos = "eol",
                priority = 100,
            }
        )
        vim.bo.modifiable = false
    end

    vim.cmd('belowright 10split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    vim.api.nvim_buf_set_name(0, 'Teradata Users')
    populate_buffer()

    vim.keymap.set('n', '<cr>', function()
        local index = vim.fn.line('.') - 2
        if index > #config.options.users then
            return
        end
        config.options.current_user_index = index
        util.save_config()
        vim.notify(
            'Selected user: ' .. config.options.users[index].user,
            vim.log.levels.INFO
        )
        populate_buffer()
    end, { buffer = true, silent = true })

    vim.keymap.set('n', 'd', function()
        local index = vim.fn.line('.') - 2
        if index > #config.options.users or index <= 0 then
            return
        end
        vim.ui.select({ 'Yes', 'No' }, { prompt = 'Delete this user?' }, function(choice)
            if choice == 'Yes' then
                table.remove(config.options.users, index)
                if config.options.current_user_index == index then
                    config.options.current_user_index = #config.options.users > 0 and 1 or nil
                elseif config.options.current_user_index > index then
                    config.options.current_user_index = config.options.current_user_index - 1
                end
                util.save_config()
                populate_buffer()
            end
        end)
    end, { buffer = true, silent = true })

    vim.keymap.set('n', 'a', function()
        if vim.fn.exists('*fzf#run') == 0 then
            return vim.notify('Error: fzf.vim plugin not found.', vim.log.levels.ERROR)
        end
        local ok, msg = util.check_executables({ 'tdwallet' })
        if not ok then
            return vim.notify(msg, vim.log.levels.ERROR)
        end

        vim.ui.input({ prompt = 'Enter log_mech (default TD2):', default = 'TD2' }, function(log_mech)
            if not log_mech then
                return
            end
            vim.ui.input({ prompt = 'Enter tdpid:' }, function(tdpid)
                if not tdpid then
                    return
                end

                local wallet_output = vim.fn.system('tdwallet list')
                local wallet_users = vim.fn.split(wallet_output, '\n')
                wallet_users = vim.tbl_filter(function(u)
                    return u ~= '' and not u:match('list is empty')
                end, wallet_users)

                if #wallet_users == 0 then
                    return vim.notify('No wallet items available.', vim.log.levels.WARN)
                end

                vim.fn['fzf#run']({
                    source = wallet_users,
                    window = {
                        width = 0.5,
                        height = 0.4,
                    },
                    sink = function(selected)
                        local user = selected
                        table.insert(config.options.users, { log_mech = log_mech, user = user, tdpid = tdpid })
                        if not config.options.current_user_index then
                            config.options.current_user_index = #config.options.users
                        end
                        util.save_config()
                        populate_buffer()
                    end,
                    options = '--prompt="Select Wallet User> "',
                })
            end)
        end)
    end, { buffer = true, silent = true })
end

return M
