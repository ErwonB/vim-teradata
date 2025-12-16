local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local bookmark = require('vim-teradata.bookmark')
local M = {}

--- Post-processes and displays a query result file in a custom interactive buffer.
--- @param file_path string Path to the result file.
--- @param query_id string|nil Optional query ID for buffer naming.
function M.display_output(file_path, query_id)
    local lines = vim.fn.readfile(file_path)
    if #lines == 0 then
        vim.notify('Query returned no lines.', vim.log.levels.INFO, { title = 'Teradata' })
        return
    end

    local regex_special_chars = "|.*+?^$(){}[]\\`~"
    local separator = vim.fn.escape(config.options.sep, regex_special_chars)
    local header = vim.fn.split(lines[1], separator)
    local data = {}
    for i = 2, #lines do
        if lines[i] ~= '' then
            table.insert(data, vim.fn.split(lines[i], separator))
        end
    end

    header = vim.tbl_map(function(part) return part:gsub('^%s+', ''):gsub('%s+$', '') end, header)
    for i, row in ipairs(data) do
        data[i] = vim.tbl_map(function(part) return part:gsub('^%s+', ''):gsub('%s+$', '') end, row)
    end

    vim.cmd.set('splitbelow')
    local buffer_name = query_id and 'Teradata Result - ' .. query_id or 'Teradata Result'
    vim.cmd.split(buffer_name)
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'wipe'
    vim.bo.swapfile = false
    vim.opt_local.wrap = false
    local bufnr = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_set_var(bufnr, 'teradata_all_data', vim.deepcopy(data))
    vim.api.nvim_buf_set_var(bufnr, 'teradata_all_header', vim.deepcopy(header))
    vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', vim.deepcopy(data))
    vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_header', vim.deepcopy(header))
    vim.api.nvim_buf_set_var(bufnr, 'teradata_removed_columns', {})

    local function populate_buffer()
        vim.bo.modifiable      = true
        local displayed_header = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_header')
        local displayed_data   = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')

        if #displayed_header == 0 then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "All columns removed. Press <BS> to restore." })
            vim.bo.modifiable = false
            return
        end

        local col_widths = {}
        for i = 1, #displayed_header do
            local max_width = #displayed_header[i]
            for _, row in ipairs(displayed_data) do
                if row[i] and #row[i] > max_width then
                    max_width = #row[i]
                end
            end
            table.insert(col_widths, max_width)
        end
        vim.api.nvim_buf_set_var(bufnr, 'teradata_column_widths', col_widths)

        local buffer_lines = {}
        local visual_separator = ' | '

        local header_parts = {}
        for i, h in ipairs(displayed_header) do
            if col_widths[i] < 100 then
                table.insert(header_parts, string.format('%-' .. col_widths[i] .. 's', h))
            else
                table.insert(header_parts, util.formatString(h or '', col_widths[i]))
            end
        end
        table.insert(buffer_lines, table.concat(header_parts, visual_separator))

        local separator_parts = {}
        for _, w in ipairs(col_widths) do
            table.insert(separator_parts, string.rep('-', w))
        end
        table.insert(buffer_lines, table.concat(separator_parts, '-+-'))

        for _, row in ipairs(displayed_data) do
            local row_parts = {}
            for i, cell in ipairs(row) do
                if col_widths[i] < 100 then
                    table.insert(row_parts, string.format('%-' .. col_widths[i] .. 's', cell or ''))
                else
                    table.insert(row_parts, util.formatString(cell or '', col_widths[i]))
                end
            end
            table.insert(buffer_lines, table.concat(row_parts, visual_separator))
        end

        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local extmark = '<Enter> Filter  <-> Remove Col  <BS> Restore Col  <u> Unfilter  <Up/Down> Sort'
        table.insert(buffer_lines, '')
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ns_id,
            #buffer_lines - 1,
            0,
            { virt_text = { { extmark, "Comment" } }, virt_text_pos = "eol" }
        )

        vim.bo.modifiable = false
    end

    local function get_column_from_cursor()
        local col = vim.fn.virtcol('.') - 1
        local widths = vim.api.nvim_buf_get_var(bufnr, 'teradata_column_widths')
        if not widths then return nil end
        local current_pos = 0
        local visual_separator = ' | '
        for i, width in ipairs(widths) do
            if col >= current_pos and col < current_pos + width then
                return i
            end
            current_pos = current_pos + width + #visual_separator
        end
        return nil
    end

    vim.keymap.set('n', '<cr>', function()
        local lnum = vim.fn.line('.')
        if lnum <= 2 then return end
        local col_idx = get_column_from_cursor()
        if not col_idx then return end
        local displayed_data = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')
        local row_idx = lnum - 2
        if not displayed_data[row_idx] then return end
        local filter_value = displayed_data[row_idx][col_idx]
        local new_displayed_data = {}
        for _, row in ipairs(displayed_data) do
            if row[col_idx] and row[col_idx] == filter_value then
                table.insert(new_displayed_data, row)
            end
        end
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', new_displayed_data)
        populate_buffer()
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set('n', '-', function()
        local col_idx_to_remove = get_column_from_cursor()
        if not col_idx_to_remove then return end
        local displayed_header    = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_header')
        local displayed_data      = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')
        local removed_columns     = vim.api.nvim_buf_get_var(bufnr, 'teradata_removed_columns')

        local removed_header      = table.remove(displayed_header, col_idx_to_remove)
        local removed_column_data = {}
        for _, row in ipairs(displayed_data) do
            table.insert(removed_column_data, table.remove(row, col_idx_to_remove))
        end
        table.insert(removed_columns, {
            index = col_idx_to_remove,
            header = removed_header,
            data = removed_column_data
        })
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_header', displayed_header)
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', displayed_data)
        vim.api.nvim_buf_set_var(bufnr, 'teradata_removed_columns', removed_columns)
        populate_buffer()
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set('n', '<bs>', function()
        local removed_columns = vim.api.nvim_buf_get_var(bufnr, 'teradata_removed_columns')
        if #removed_columns == 0 then
            return vim.notify("No columns to restore.", vim.log.levels.WARN)
        end
        local col_to_restore   = table.remove(removed_columns)
        local displayed_header = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_header')
        local displayed_data   = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')

        table.insert(displayed_header, col_to_restore.index, col_to_restore.header)
        for i, row in ipairs(displayed_data) do
            table.insert(row, col_to_restore.index, col_to_restore.data[i] or '')
        end
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_header', displayed_header)
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', displayed_data)
        vim.api.nvim_buf_set_var(bufnr, 'teradata_removed_columns', removed_columns)
        populate_buffer()
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set('n', 'u', function()
        local all_data = vim.api.nvim_buf_get_var(bufnr, 'teradata_all_data')
        local displayed_data = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')
        if #displayed_data == #all_data then
            vim.notify("No filters to reset.", vim.log.levels.INFO)
            return
        end
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', vim.deepcopy(all_data))
        populate_buffer()
        vim.notify("Filters reset.", vim.log.levels.INFO)
    end, { buffer = bufnr, silent = true, nowait = true })

    local function sort_column(ascending)
        -- local lnum = vim.fn.line('.')
        -- if lnum == 2 then return end

        local col_idx = get_column_from_cursor()
        if not col_idx then return end

        local displayed_data = vim.api.nvim_buf_get_var(bufnr, 'teradata_displayed_data')

        table.sort(displayed_data, function(a, b)
            local val_a = a[col_idx] or ""
            local val_b = b[col_idx] or ""

            local num_a = tonumber(val_a)
            local num_b = tonumber(val_b)

            if num_a and num_b then
                if ascending then
                    return num_a < num_b
                else
                    return num_a > num_b
                end
            end

            if ascending then
                return val_a < val_b
            else
                return val_a > val_b
            end
        end)

        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', displayed_data)
        populate_buffer()
        local dir = ascending and "ascending" or "descending"
        vim.notify("Sorted column " .. col_idx .. " " .. dir, vim.log.levels.INFO)
    end

    vim.keymap.set('n', '<Up>', function()
        sort_column(true)
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set('n', '<Down>', function()
        sort_column(false)
    end, { buffer = bufnr, silent = true, nowait = true })

    populate_buffer()
end

--- Displays an error message from a BTEQ execution.
--- @param msg string The error message.
function M.display_error(msg)
    vim.notify(msg, vim.log.levels.ERROR, { title = 'Teradata Error' })
end

function M.display_help()
    local help_text = {
        'TD: syntax checking',
        'TDO: to get the output of the query',
        'TDH: Show query history',
        'TDR: Search query history with FZF',
        'TDU: Manage users',
        'TDB: Manage bookmarks',
        'TDBAdd: Add bookmark from visual selection',
        'TDJ: Jobs Manager',
        'TDF: Format current statement',
        'TDSync: export ddl for autocompletion',
        'TDHelp: Display this help',
    }
    vim.cmd('belowright 12split')
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
    local query_file  = util.get_history_path('queries_dir_name') .. '/' .. file_id .. '.sql'
    local result_file = util.get_history_path('resultsets_dir_name') .. '/' .. file_id .. '.csv'
    if vim.fn.filereadable(result_file) == 0 then
        vim.notify('No result file found for query ' .. file_id, vim.log.levels.WARN)
        return
    end
    vim.cmd.split(vim.fn.fnameescape(query_file))
    M.display_output(vim.fn.fnameescape(result_file))
end

function M.show_queries()
    local queries_dir = util.get_history_path('queries_dir_name')
    local files = vim.fn.glob(queries_dir .. '/*.sql', false, true)
    local query_ids = {}
    for _, file in ipairs(files) do
        local id = vim.fn.fnamemodify(file, ':t:r')
        table.insert(query_ids, id)
    end
    table.sort(query_ids, function(a, b) return a > b end)

    local line_map = {}
    local preview_winid = nil

    local function close_preview_win()
        if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
            vim.api.nvim_win_close(preview_winid, true)
        end
        preview_winid = nil
    end

    local function populate_buffer()
        local bufnr = vim.api.nvim_get_current_buf()
        local lines = {}
        line_map = {}
        local current_line = 1
        for _, id in ipairs(query_ids) do
            table.insert(lines, id)
            line_map[current_line] = id
            current_line = current_line + 1
        end
        if #lines == 0 then
            table.insert(lines, 'No queries found.')
        end
        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local extmark = '<Enter> Open Query/Result'
        vim.bo.modifiable = true
        table.insert(lines, '')
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ns_id,
            #lines - 1,
            0,
            { virt_text = { { extmark, "Comment" } }, virt_text_pos = "eol" }
        )
        vim.bo.modifiable = false
    end

    vim.cmd('belowright 10split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    local list_bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(0, 'Teradata Queries')
    populate_buffer()

    vim.keymap.set('n', '<cr>', function()
        close_preview_win()
        local lnum = vim.fn.line('.')
        local id = line_map[lnum]
        if id then
            M.open_query_result_pair(id)
            vim.api.nvim_buf_delete(list_bufnr, { force = true })
        end
    end, { buffer = true, silent = true })

    vim.cmd('setlocal updatetime=500')
    vim.api.nvim_create_autocmd('CursorHold', {
        buffer = 0,
        callback = function()
            close_preview_win()
            local lnum = vim.fn.line('.')
            local id = line_map[lnum]
            if not id then return end
            local query_file = util.get_history_path('queries_dir_name') .. '/' .. id .. '.sql'
            local content = vim.fn.readfile(query_file)
            if content then
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
                local width, height = 80, 10
                local cursor = vim.api.nvim_win_get_cursor(0)
                preview_winid = vim.api.nvim_open_win(buf, false, {
                    relative = 'win',
                    width = width,
                    height = height,
                    row = cursor[1] - 1,
                    col = cursor[2] + 10,
                    style = 'minimal',
                    border = 'rounded',
                })
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufLeave', {
        buffer = 0,
        once = true,
        callback = function()
            close_preview_win()
        end,
    })
end

-----------------------------------------------------------------------
-- Users
-----------------------------------------------------------------------
function M.show_users()
    local function populate_buffer()
        local bufnr = vim.api.nvim_get_current_buf()
        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local lines = {}
        local extmark

        if next(config.options.users) then
            local user_col_width    = #("user")
            local tdpid_col_width   = #("tdpid")
            local logmech_col_width = #("logon mechanism")
            for _, u in ipairs(config.options.users) do
                user_col_width    = math.max(user_col_width, # (u.user) + 1)
                tdpid_col_width   = math.max(tdpid_col_width, # (u.tdpid))
                logmech_col_width = math.max(logmech_col_width, # (u.log_mech))
            end

            table.insert(lines, string.format(
                "%-" .. user_col_width .. "s | %-" .. tdpid_col_width .. "s | %-" .. logmech_col_width .. "s",
                "user", "tdpid", "logon mechanism"
            ))
            table.insert(lines,
                string.rep("-", user_col_width) .. "+"
                .. string.rep("-", tdpid_col_width + 2) .. "+"
                .. string.rep("-", logmech_col_width + 2))

            for i, u in ipairs(config.options.users) do
                local prefix = (i == config.options.current_user_index) and '*' or ' '
                table.insert(lines, string.format(
                    "%s%-" .. (user_col_width - 1) .. "s | %-" .. tdpid_col_width .. "s | %-" .. logmech_col_width .. "s",
                    prefix, u.user, u.tdpid, u.log_mech
                ))
            end
        end

        if #lines == 0 then
            extmark = 'No users configured. Press "a" to add one.'
        else
            extmark = '<a> Add  <d> Delete  <Enter> Current'
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
        if index > #config.options.users or index <= 0 then
            return
        end
        config.options.current_user_index = index
        util.save_config()
        vim.notify('Selected user: ' .. config.options.users[index].user, vim.log.levels.INFO)
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
                elseif config.options.current_user_index and config.options.current_user_index > index then
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
            if not log_mech then return end
            vim.ui.input({ prompt = 'Enter tdpid:' }, function(tdpid)
                if not tdpid then return end

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

-----------------------------------------------------------------------
-- Bookmarks
-----------------------------------------------------------------------
function M.show_bookmarks()
    local original_bufnr = vim.api.nvim_get_current_buf()
    local line_map = {}
    local preview_winid = nil

    local function close_preview_win()
        if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
            vim.api.nvim_win_close(preview_winid, true)
        end
        preview_winid = nil
    end

    local function populate_buffer()
        local bufnr = vim.api.nvim_get_current_buf()
        local bookmarks = bookmark.get_all()
        local lines = {}
        line_map = {}
        local current_line = 1

        table.insert(lines, '--- Global Bookmarks ---')
        current_line = current_line + 1
        if #bookmarks.global == 0 then
            table.insert(lines, '(empty)')
            current_line = current_line + 1
        else
            for _, name in ipairs(bookmarks.global) do
                table.insert(lines, name)
                line_map[current_line] = { name = name, type = 'global' }
                current_line = current_line + 1
            end
        end

        table.insert(lines, '')
        current_line = current_line + 1

        table.insert(lines, '--- User Bookmarks ---')
        current_line = current_line + 1
        if #bookmarks.user == 0 then
            table.insert(lines, '(empty)')
            current_line = current_line + 1
        else
            for _, name in ipairs(bookmarks.user) do
                table.insert(lines, name)
                line_map[current_line] = { name = name, type = 'user' }
                current_line = current_line + 1
            end
        end

        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local extmark = '<d> Delete  <Enter> Insert (use TDBAdd to add a bookmark)'
        vim.bo.modifiable = true
        table.insert(lines, '')
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_extmark(
            bufnr, ns_id, #lines - 1, 0,
            { virt_text = { { extmark, "Comment" } }, virt_text_pos = "eol" }
        )
        vim.bo.modifiable = false
    end

    vim.cmd('belowright 10split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    vim.api.nvim_buf_set_name(0, 'Teradata Bookmarks')
    populate_buffer()

    vim.keymap.set('n', '<cr>', function()
        close_preview_win()
        local lnum = vim.fn.line('.')
        local info = line_map[lnum]
        if info then
            bookmark.insert_into_buffer(info.name, info.type, original_bufnr)
            vim.api.nvim_buf_delete(0, { force = true })
        end
    end, { buffer = true, silent = true })

    vim.keymap.set('n', 'd', function()
        close_preview_win()
        local lnum = vim.fn.line('.')
        local info = line_map[lnum]
        if info then
            vim.ui.select({ 'Yes', 'No' }, { prompt = 'Delete bookmark "' .. info.name .. '"?' }, function(choice)
                if choice == 'Yes' then
                    bookmark.delete(info.name, info.type)
                    populate_buffer()
                end
            end)
        end
    end, { buffer = true, silent = true })

    vim.cmd('setlocal updatetime=500')
    vim.api.nvim_create_autocmd('CursorHold', {
        buffer = 0,
        callback = function()
            close_preview_win()
            local lnum = vim.fn.line('.')
            local info = line_map[lnum]
            if not info then return end
            local content = bookmark.get_content(info.name, info.type)
            if content then
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
                local width, height = 80, 10
                local cursor = vim.api.nvim_win_get_cursor(0)
                preview_winid = vim.api.nvim_open_win(buf, false, {
                    relative = 'win',
                    width = width,
                    height = height,
                    row = cursor[1] - 1,
                    col = cursor[2] + 10,
                    style = 'minimal',
                    border = 'rounded',
                })
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufLeave', {
        buffer = 0,
        once = true,
        callback = function()
            close_preview_win()
        end,
    })
end

-----------------------------------------------------------------------
-- Jobs Manager
-----------------------------------------------------------------------
local function format_jobs_table(jobs)
    local w = { id = 18, op = 8, st = 9, usr = 8, rows = 6, msg = 20 }
    for _, j in ipairs(jobs) do
        w.id   = math.max(w.id, #tostring(j.id))
        w.op   = math.max(w.op, #tostring(j.operation))
        w.st   = math.max(w.st, #tostring(j.status))
        w.usr  = math.max(w.usr, #tostring(j.user or ''))
        w.rows = math.max(w.rows, #tostring(j.rows or '-'))
        w.msg  = math.max(w.msg, math.min(80, #tostring(j.message or '')))
    end

    local header = string.format(
        "%-" .. w.id .. "s | %-" .. w.op .. "s | %-" .. w.st .. "s | %-" .. w.usr .. "s | %" .. w.rows .. "s | %s",
        "job id", "operation", "status", "user", "rows", "message"
    )
    local sep = string.rep("-", #header)

    local lines, line_ids = { header, sep }, {}
    for _, j in ipairs(jobs) do
        local msg = tostring(j.message or '')
        if #msg > w.msg then msg = msg:sub(1, w.msg - 1) .. "…" end
        table.insert(lines, string.format(
            "%-" .. w.id .. "s | %-" .. w.op .. "s | %-" .. w.st .. "s | %-" .. w.usr .. "s | %" .. w.rows .. "s | %s",
            tostring(j.id),
            tostring(j.operation),
            tostring(j.status),
            tostring(j.user or ''),
            tostring(j.rows or '-'),
            msg
        ))
        table.insert(line_ids, j.id)
    end
    return lines, line_ids
end

function M.refresh_jobs_if_open()
    local bufnr = vim.fn.bufnr('Teradata Jobs')
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
            win = w; break
        end
    end
    if not win then return end
    local jobs = util.jobs_all()
    local lines, _ = format_jobs_table(jobs)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("HelperBuffer")
    local ext = '<Enter> Open  <x> Cancel  <d> Remove'
    vim.api.nvim_buf_set_extmark(bufnr, ns, #lines - 1, 0, { virt_text = { { ext, "Comment" } }, virt_text_pos = "eol" })
    vim.bo[bufnr].modifiable = false
end

function M.show_jobs()
    vim.cmd('belowright 12split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    vim.bo.swapfile = false
    vim.api.nvim_buf_set_name(0, 'Teradata Jobs')

    local line_to_id = {}

    local function populate()
        local jobs = util.jobs_all()
        local lines, ids = format_jobs_table(jobs)
        line_to_id = {}
        for i, id in ipairs(ids) do
            line_to_id[i + 2] = id -- header + sep
        end
        local ns = vim.api.nvim_create_namespace("HelperBuffer")
        local ext = '<Enter> Open  <k> Cancel  <d> Remove'
        vim.bo.modifiable = true
        table.insert(lines, '')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.api.nvim_buf_set_extmark(0, ns, #lines - 1, 0, { virt_text = { { ext, "Comment" } }, virt_text_pos = "eol" })
        vim.bo.modifiable = false
    end

    populate()

    -- <CR> open
    vim.keymap.set('n', '<cr>', function()
        local l = vim.fn.line('.')
        local id = line_to_id[l]
        if not id then return end
        local job = util.jobs_get(id)
        if not job then return end
        if job.operation == 'output' then
            if job.result_path and vim.fn.filereadable(job.result_path) == 1 then
                M.display_output(job.result_path, job.id)
            else
                vim.notify('Result not available for job ' .. job.id, vim.log.levels.WARN)
            end
        end
    end, { buffer = true, silent = true })

    -- x cancel
    vim.keymap.set('n', 'x', function()
        local l = vim.fn.line('.')
        local id = line_to_id[l]
        if not id then return end
        local job = util.jobs_get(id)
        if not job then return end
        if job.status ~= 'running' then
            return vim.notify('Job is not running.', vim.log.levels.INFO)
        end
        local ok = util.jobs_cancel(id)
        if ok then
            vim.notify('Canceled job ' .. id, vim.log.levels.INFO)
        else
            vim.notify('Unable to cancel job ' .. id, vim.log.levels.WARN)
        end
        populate()
    end, { buffer = true, silent = true })

    -- d remove
    vim.keymap.set('n', 'd', function()
        local l = vim.fn.line('.')
        local id = line_to_id[l]
        if not id then return end
        local job = util.jobs_get(id)
        if not job then return end
        if job.status == 'running' then
            return vim.notify('Job is running. Cancel it first (k).', vim.log.levels.WARN)
        end
        util.remove_files(job.query_path or '')
        util.remove_files(job.result_path or '')
        util.jobs_remove(id)
        vim.notify('Removed job ' .. id, vim.log.levels.INFO)
        populate()
    end, { buffer = true, silent = true })

    vim.cmd('setlocal updatetime=600')
    vim.api.nvim_create_autocmd('CursorHold', {
        buffer = 0,
        callback = function()
            populate()
        end,
    })
end

-----------------------------------------------------------------------
-- Configuration / Settings UI
-----------------------------------------------------------------------
function M.show_settings()
    local line_map = {}

    local function populate_buffer()
        local bufnr = vim.api.nvim_get_current_buf()
        local lines = {}
        line_map = {}
        local current_line = 1

        -- 1. Simple Integers / Strings
        table.insert(lines, '--- General Options ---')
        current_line = current_line + 1

        local retlimit = config.options.retlimit or 100
        table.insert(lines, string.format("retlimit  : %d", retlimit))
        line_map[current_line] = { type = 'retlimit' }
        current_line = current_line + 1

        local filter_db = config.options.filter_db or ""
        table.insert(lines, string.format("filter_db : %s", filter_db))
        line_map[current_line] = { type = 'filter_db' }
        current_line = current_line + 1

        table.insert(lines, '')
        current_line = current_line + 1

        -- 2. Replacements Table
        table.insert(lines, '--- Replacements ---')
        current_line = current_line + 1

        -- Sort keys for stable display
        local keys = {}
        for k, _ in pairs(config.options.replacements or {}) do
            table.insert(keys, k)
        end
        table.sort(keys)

        if #keys == 0 then
            table.insert(lines, '(no replacements defined)')
            line_map[current_line] = { type = 'empty_replacements' }
            current_line = current_line + 1
        else
            for _, k in ipairs(keys) do
                local v = config.options.replacements[k]
                table.insert(lines, string.format("%s = %s", k, v))
                line_map[current_line] = { type = 'replacement', key = k, value = v }
                current_line = current_line + 1
            end
        end

        local ns_id = vim.api.nvim_create_namespace("HelperBuffer")
        local extmark = '<Enter> Edit  <a> Add Replacement  <d> Delete Replacement'

        vim.bo.modifiable = true
        table.insert(lines, '')
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ns_id,
            #lines - 1,
            0,
            { virt_text = { { extmark, "Comment" } }, virt_text_pos = "eol" }
        )
        vim.bo.modifiable = false
    end

    vim.cmd('belowright 12split')
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'delete'
    vim.api.nvim_buf_set_name(0, 'Teradata Settings')
    populate_buffer()

    -- ACTION: Add new replacement
    vim.keymap.set('n', 'a', function()
        vim.ui.input({ prompt = 'New Replacement Key (e.g. ${DB_NAME}): ' }, function(key)
            if not key or key == '' then return end
            vim.ui.input({ prompt = 'Value for ' .. key .. ': ' }, function(val)
                if not val then return end
                if not config.options.replacements then config.options.replacements = {} end
                config.options.replacements[key] = val
                util.save_config()
                populate_buffer()
                vim.notify("Added " .. key, vim.log.levels.INFO)
            end)
        end)
    end, { buffer = true, silent = true })

    -- ACTION: Delete replacement
    vim.keymap.set('n', 'd', function()
        local lnum = vim.fn.line('.')
        local item = line_map[lnum]
        if item and item.type == 'replacement' then
            vim.ui.select({ 'Yes', 'No' }, { prompt = 'Delete replacement "' .. item.key .. '"?' }, function(choice)
                if choice == 'Yes' then
                    config.options.replacements[item.key] = nil
                    util.save_config()
                    populate_buffer()
                end
            end)
        else
            vim.notify("Cursor is not on a replacement.", vim.log.levels.WARN)
        end
    end, { buffer = true, silent = true })

    -- ACTION: Edit existing value
    vim.keymap.set('n', '<cr>', function()
        local lnum = vim.fn.line('.')
        local item = line_map[lnum]

        if not item then return end

        if item.type == 'retlimit' then
            local current = config.options.retlimit or 100
            vim.ui.input({ prompt = 'Set Result Row Limit: ', default = tostring(current) }, function(input)
                if not input then return end
                local num = tonumber(input)
                if num then
                    config.options.retlimit = num
                    util.save_config()
                    populate_buffer()
                else
                    vim.notify("Invalid number", vim.log.levels.ERROR)
                end
            end)
        elseif item.type == 'filter_db' then
            local current = config.options.filter_db or ""
            vim.ui.input({ prompt = 'Set Filter DB: ', default = current }, function(input)
                if input then
                    config.options.filter_db = input
                    util.save_config()
                    populate_buffer()
                end
            end)
        elseif item.type == 'replacement' then
            vim.ui.input({ prompt = 'Edit Value for ' .. item.key .. ': ', default = item.value }, function(input)
                if input then
                    config.options.replacements[item.key] = input
                    util.save_config()
                    populate_buffer()
                end
            end)
        end
    end, { buffer = true, silent = true })
end

return M
