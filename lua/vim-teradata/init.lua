local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local bteq = require('vim-teradata.bteq')
local ui = require('vim-teradata.ui')
local fzf = require('vim-teradata.fzf')

local M = {}

local function run_query(args, operation, handle_result)
    local opts = {
        user = config.options.user,
        tdpid = config.options.tdpid,
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
        sql = vim.fn.getreg('"')
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

    local bteq_data = bteq.build_script(clean_sql, opts.user, opts.tdpid, opts)
    local script_path = util.get_temp_path('bteq_script_name')
    vim.fn.writefile(bteq_data.script, script_path)

    local res = bteq.execute()

    handle_result(res, bteq_data)

    util.remove_files(script_path, util.get_temp_path('bteq_output_name'), res.log_path)
end

local function query_syntax(args)
    run_query(args, 'syntax', function(res)
        if res.rc == 0 then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        else
            ui.display_error(res.msg, res.log_path)
        end
    end)
end

local function query_output(args)
    run_query(args, 'output', function(res, bteq_data)
        if res.rc == 0 then
            local result_path = util.get_history_path('resultsets_dir_name') .. '/' .. bteq_data.context.query_num
            if vim.fn.getfsize(result_path) > 0 then
                ui.display_output(result_path)
                local log_content = vim.fn.readfile(res.log_path)
                local actual_lines = util.extract_rows_found(log_content)
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
            ui.display_error(res.msg, res.log_path)
        end
    end)
end


--- Sets up the plugin, creating commands.
function M.setup(user_config)
    config.setup(user_config)

    vim.api.nvim_create_autocmd("FileType", {
        pattern = config.options.ft,
        callback = function()
            -- :TD command
            vim.api.nvim_create_user_command('TD', query_syntax, {
                nargs = '*',
                range = true,
                bang = true,
            })

            -- :TDO command (shortcut for output)
            vim.api.nvim_create_user_command('TDO',
                query_output, {
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
        end
    })
end

return M
