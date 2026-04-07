local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local ui = require('vim-teradata.ui')

local M = {}
--- Builds the common BTEQ logon header.
--- @param user string The username.
--- @param tdpid string The Teradata server ID.
--- @param log_mech string The log mechanism.
--- @return table The list of BTEQ header commands.
local function build_header(user, tdpid, log_mech)
    return {
        '.logmech ' .. log_mech,
        '.logon ' .. tdpid .. '/' .. user .. ',$tdwallet(' .. user .. ');',
    }
end
--- Builds a BTEQ script for a given operation.
--- @param sql string The SQL query.
--- @param user_obj table The user object containing user, tdpid, log_mech.
--- @param options table Additional options like operation type, pattern, etc.
--- @param output_path string The path for the export file.
--- @return table A table containing the BTEQ script (as a list of strings).
local function build_script(sql, user_obj, options, output_path)
    local body = build_header(user_obj.user, user_obj.tdpid, user_obj.log_mech)
    vim.list_extend(body, {
        '.set titledashes off',
        '.set session charset \'UTF8\'',
        '.set separator \'' .. config.options.sep .. '\'',
        '.EXPORT FILE = ' .. output_path .. ';',
        '.set WIDTH 1048575',
    })
    if options.operation == 'output' then
        vim.list_extend(body, {
            '.set retlimit ' .. config.options.retlimit .. ' 2048',
        })
    end
    vim.list_extend(body, vim.fn.split(sql, '\n'))
    vim.list_extend(body, { ';', '.LOGOFF', '.EXIT' })
    return { script = body }
end

--- Starts an asynchronous BTEQ job.
--- @param script_lines table The script lines to send to BTEQ.
--- @param on_done function The callback function(res).
local function start_job(script_lines, on_done)
    vim.system({ 'bteq' }, {
        stdin = table.concat(script_lines, '\n'),
        text = true,
    }, function(result)
        local log_content = vim.split(result.stdout or '', '\n', { trimempty = true })
        local res = {
            rc = result.code,
            msg = result.stderr or '',
            log_content = log_content,
        }
        on_done(res)
    end)
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

    local bteq_data = build_script(clean_sql, current_user, opts, output_path)
    local handle = start_job(bteq_data.script, function(res)
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

function M.query_syntax(args)
    run_query(args, 'syntax', function(res)
        if res.rc == 0 then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        else
            ui.display_error(res.msg)
        end
    end)
end

function M.query_output(args)
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

return M
