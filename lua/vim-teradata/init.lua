local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local bteq = require('vim-teradata.bteq')
local ui = require('vim-teradata.ui')
local fzf = require('vim-teradata.fzf')
local bookmark = require('vim-teradata.bookmark')
local ope = require('vim-teradata.td_ope')

local M = {}

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
end

local function run_query(args, operation, handle_result)
    if not config.options.current_user_index or not config.options.users[config.options.current_user_index] then
        return vim.notify('No user selected. Use :TDU to set up users.', vim.log.levels.WARN)
    end
    local current_user = config.options.users[config.options.current_user_index]
    local opts = {
        operation = operation,
        pattern = '',
    }

    local sql
    if args.range > 0 then
        local start_pos = vim.api.nvim_buf_get_mark(0, "<")
        local end_pos = vim.api.nvim_buf_get_mark(0, ">")
        sql = table.concat(
            vim.api.nvim_buf_get_text(0, start_pos[1] - 1, start_pos[2], end_pos[1] - 1, end_pos[2], {}),
            '\n'
        )
    else
        local buf = vim.api.nvim_get_current_buf()
        local current_node = vim.treesitter.get_node({ bufnr = buf })
        local stmt_node = util.find_node_by_type(current_node, "statement")
        if stmt_node then
            sql = vim.treesitter.get_node_text(stmt_node, buf)
        end
    end
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL query provided in selection or register.', vim.log.levels.WARN)
    end

    local clean_sql = util.replace_env_vars(sql)
    if not clean_sql:find(';') then
        clean_sql = clean_sql .. ';'
    end

    if operation == 'syntax' then
        local parts = {}
        for part in clean_sql:gmatch("[^;]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then
                table.insert(parts, "explain " .. part)
            end
        end
        clean_sql = table.concat(parts, " ; ")
    end

    local output_path
    local context = {}
    local id = util.get_unique_query_id()
    local query_path

    if operation == 'output' then
        query_path = util.get_history_path('queries_dir_name') .. '/' .. id .. '.sql'
        output_path = util.get_history_path('resultsets_dir_name') .. '/' .. id .. '.csv'
        vim.fn.writefile(vim.split(sql, '\n'), query_path)
        context = { query_id = id, result_path = output_path }
    else
        output_path = vim.fn.tempname()
    end

    -- Register job
    util.jobs_add({
        id          = id,
        operation   = operation,
        status      = 'running',
        user        = current_user.user,
        rows        = nil,
        message     = 'Started',
        result_path = (operation == 'output') and output_path or nil,
        query_path  = query_path,
        started_at  = os.time(),
        finished_at = nil,
        handle      = nil,
    })

    local bteq_data = bteq.build_script(clean_sql, current_user, opts, output_path)
    local handle = bteq.start_job(bteq_data.script, function(res)
        vim.schedule(function()
            local status = (res.rc == 0) and 'ok' or 'error'
            local rows = nil
            if operation == 'output' then
                rows = util.extract_rows_found(res.log_content)
            end

            local message
            if status == 'ok' then
                message = (operation == 'syntax') and 'Syntax OK' or 'OK'
            else
                local last = (res.msg or ''):gsub('%s+$', '')
                last = (#last > 0) and last:match("[^\n]*$") or 'Error'
                message = last
            end

            if operation == 'syntax' then
                local combined = table.concat(res.log_content or {}, '\n')
                if res.msg and #res.msg > 0 then
                    combined = combined .. '\n' .. res.msg
                end
            end

            util.jobs_update(id, {
                status = status,
                rows = rows,
                message = message,
                finished_at = os.time(),
            })

            handle_result(res, context)

            if operation ~= 'output' then
                util.remove_files(output_path)
            end

            ui.refresh_jobs_if_open()
        end)
    end)

    util.jobs_update(id, { handle = handle })

    vim.notify('Query started' .. (id and ': ' .. id or ''), vim.log.levels.INFO, { title = 'Teradata' })
end

local function query_syntax(args)
    run_query(args, 'syntax', function(res)
        if res.rc == 0 then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        else
            ui.display_error(res.msg)
        end
    end)
end

local function query_output(args)
    run_query(args, 'output', function(res, context)
        if res.rc == 0 then
            local result_path = context.result_path
            if vim.fn.getfsize(result_path) > 0 then
                ui.display_output(result_path, context.query_id)
                local actual_lines = util.extract_rows_found(res.log_content)
                if actual_lines and actual_lines > config.options.retlimit then
                    vim.notify(
                        string.format('%d actual lines, only %d displayed', actual_lines, config.options.retlimit),
                        vim.log.levels.WARN
                    )
                end
            else
                vim.notify('Query returned no lines.', vim.log.levels.INFO, { title = 'Teradata' })
            end
        else
            ui.display_error(res.msg)
        end
    end)
end

function M.setup(user_config)
    config.setup(user_config)
    vim.api.nvim_create_autocmd("FileType", {
        pattern = config.options.ft,
        callback = function()
            vim.api.nvim_create_user_command('TD', query_syntax, {
                nargs = '*',
                range = true,
                bang = true,
            })
            vim.api.nvim_create_user_command('TDO', query_output, {
                nargs = '*',
                range = true,
                bang = true,
            })
            -- :TDH command (history)
            vim.api.nvim_create_user_command('TDH', ui.show_queries, { nargs = 0 })
            -- :TDR command (search history)
            vim.api.nvim_create_user_command('TDR', fzf.find_query_by_content, { nargs = 0 })
            -- :TDHelp display help
            vim.api.nvim_create_user_command('TDHelp', ui.display_help, { nargs = 0 })
            -- :TDU user management
            vim.api.nvim_create_user_command('TDU', ui.show_users, { nargs = 0 })
            -- :TDS Settings management
            vim.api.nvim_create_user_command('TDS', ui.show_settings, { nargs = 0 })
            -- :TDB bookmark management
            vim.api.nvim_create_user_command('TDB', ui.show_bookmarks, { nargs = 0 })
            -- :TDBAdd add bookmark from selection
            vim.api.nvim_create_user_command('TDBAdd', bookmark.add_from_range, { range = true })
            vim.api.nvim_create_user_command('TDJ', ui.show_jobs, { nargs = 0 })
            vim.api.nvim_create_user_command('TDF', ope.format_current_statement, { nargs = 0 })
            -- register this plugin as a blink provider
            register_td_provider()
            -- Set up a keybinding to trigger completion
            vim.api.nvim_buf_set_keymap(0, 'i', '<C-x><C-u>',
                '<cmd>lua require("vim-teradata.sql-autocomplete.completion").trigger_fzf()<CR>', {
                    noremap = true,
                    silent = true
                })

            -- Define :TDSync command
            vim.api.nvim_create_user_command('TDSync', util.export_db_data, { nargs = 0 })


            --keymapping for code editing
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

                -- Create the keymap function wrapper
                local keymap_func = function()
                    local success, func = pcall(function() return ope[func_name] end)
                    if success and type(func) == 'function' then
                        func(args[1], args[2], args[3])
                    else
                        vim.notify('Teradata OPE function "' .. func_name .. '" not found.', vim.log.levels.WARN)
                    end
                end

                -- Use 'n' mode for all OPE commands
                vim.keymap.set('n', key, keymap_func, { desc = description, buffer = true })
            end
        end
    })
end

return M
