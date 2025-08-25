-- lua/teradata/init.lua
local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local bteq = require('vim-teradata.bteq')
local ui = require('vim-teradata.ui')
local fzf = require('vim-teradata.fzf')

local M = {}

--- Parses arguments and executes the main logic.
--- @param args table The arguments from the user command.
local function run(args)
    local opts = {
        user = config.options.user,
        tdpid = config.options.tdpid,
        operation = 'syntax',
        pattern = '',
        sample = config.options.default_sample_size,
    }

    -- Parse command-line arguments
    local cmd_args = vim.fn.split(args.args or '')
    local i = 1
    while i <= #cmd_args do
        local arg = cmd_args[i]
        if arg == '-o' and i + 1 <= #cmd_args then
            opts.operation = cmd_args[i + 1]
            i = i + 2
        elseif arg == '-p' and i + 1 <= #cmd_args then
            opts.pattern = cmd_args[i + 1]
            i = i + 2
        elseif arg == '-s' and i + 1 <= #cmd_args then
            opts.sample = cmd_args[i + 1]
            i = i + 2
        else
            return vim.notify('Unknown or incomplete option: ' .. arg, vim.log.levels.ERROR)
        end
    end

    local sql
    if args.range > 0 then
        local start_pos = vim.api.nvim_buf_get_mark(0, "<")
        local end_pos = vim.api.nvim_buf_get_mark(0, ">")
        sql = table.concat(vim.api.nvim_buf_get_text(0, start_pos[1] - 1, start_pos[2], end_pos[1] - 1, end_pos[2], {}),
            '\n')
    else
        sql = vim.fn.getreg('"')
    end

    if opts.operation == 'help' then
        return ui.display_help()
    end

    local valid_ops = { output = true, explain = true, sample = true }
    if (not sql or sql:match('^%s*$')) and valid_ops[opts.operation] then
        return vim.notify('No SQL query provided in selection or register.', vim.log.levels.WARN)
    end

    local clean_sql = util.replace_env_vars(sql)
    if not clean_sql:find(';') then
        clean_sql = clean_sql .. ';'
    end

    if opts.operation == 'syntax' or opts.operation == 'explain' then
        local parts = {}
        for part in clean_sql:gmatch("[^;]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then
                table.insert(parts, "explain " .. part)
            end
        end
        clean_sql = table.concat(parts, " ; ")
    elseif opts.operation == 'sample' then
        local parts = {}
        for part in clean_sql:gmatch("[^;]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then
                table.insert(parts, part .. " sample " .. opts.sample)
            end
        end
        clean_sql = table.concat(parts, "; ")
    end


    local bteq_data = bteq.build_script(clean_sql, opts.user, opts.tdpid, opts)
    local script_path = util.get_temp_path('bteq_script_name')
    vim.fn.writefile(bteq_data.script, script_path)

    local res = bteq.execute()

    if res.rc == 0 then
        if opts.operation == 'syntax' then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        elseif opts.operation == 'explain' or opts.operation == 'table' or opts.operation == 'field' then
            ui.display_output(util.get_temp_path('bteq_output_name'))
        elseif opts.operation == 'output' then
            local result_path = util.get_history_path('resultsets_dir_name') .. '/' .. bteq_data.context.query_num
            if vim.fn.getfsize(result_path) > 0 then
                ui.display_output(result_path)
                local log_content = vim.fn.readfile(res.log_path)
                local actual_lines = util.extract_rows_found(log_content)
                if actual_lines and actual_lines > config.options.retlimit then
                    vim.notify(
                        string.format('%d actual lines, only %d displayed', actual_lines, config.options.retlimit),
                        vim.log.levels.WARN)
                end
            else
                vim.notify('Query returned no lines.', vim.log.levels.INFO, { title = 'Teradata' })
            end
        end
    else
        ui.display_error(res.msg, res.log_path)
    end

    if opts.operation == 'explain' or opts.operation == 'table' or opts.operation == 'field' then
        util.remove_files(script_path, res.log_path)
    else
        util.remove_files(script_path, util.get_temp_path('bteq_output_name'), res.log_path)
    end
end

--- Sets up the plugin, creating commands.
function M.setup(user_config)
    config.setup(user_config)

    -- :TD command
    vim.api.nvim_create_user_command('TD', run, {
        nargs = '*',
        range = true,
        bang = true,
    })

    -- :TDO command (shortcut for output)
    vim.api.nvim_create_user_command('TDO', function(args)
        args.args = '-o output ' .. (args.args or '')
        run(args)
    end, {
        nargs = '*',
        range = true,
        bang = true,
    })

    -- :TDH command (history)
    vim.api.nvim_create_user_command('TDH', ui.show_queries, { nargs = 0 })

    -- :TDR command (search history)
    vim.api.nvim_create_user_command('TDR', fzf.find_query_by_content, { nargs = 0 })
end

return M
