local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
local tsu  = require('vim-teradata.ts-util')
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

--- Splits a raw SQL string into individual statements on ';'.
--- @param sql string
--- @return table list of trimmed, non-empty SQL strings (without trailing ';')
local function split_sql_statements(sql)
    local stmts = {}
    for part in sql:gmatch('[^;]+') do
        part = part:match('^%s*(.-)%s*$')
        if part ~= '' then
            table.insert(stmts, part)
        end
    end
    return stmts
end

local function get_visual_sql()
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    local end_pos = vim.api.nvim_buf_get_mark(0, ">")
    return table.concat(
        vim.api.nvim_buf_get_text(0, start_pos[1] - 1, start_pos[2], end_pos[1] - 1, end_pos[2], {}),
        '\n'
    )
end

local function get_node_statements(count)
    local buf = vim.api.nvim_get_current_buf()
    local current_node = vim.treesitter.get_node({ bufnr = buf })
    local stmt_node = tsu.ancestor(current_node, "statement")
    if not stmt_node then return {} end
    local nodes = tsu.collect_next_sibling_statement_nodes(stmt_node, count)
    return vim.tbl_map(function(n) return vim.treesitter.get_node_text(n, buf) end, nodes)
end

local function run_single_query(sql, operation, handle_result)
    if not config.options.current_user_index or not config.options.users[config.options.current_user_index] then
        return vim.notify('No user selected. Use :TDU to set up users.', vim.log.levels.WARN)
    end
    local current_user = config.options.users[config.options.current_user_index]
    local opts = {
        operation = operation,
        pattern = '',
    }

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
end

local function run_multiple(sqls, operation, handle_result)
    if #sqls == 0 then
        return vim.notify('No SQL statements found.', vim.log.levels.WARN)
    end
    for _, sql in ipairs(sqls) do
        run_single_query(sql, operation, handle_result)
    end
    if #sqls > 1 then
        vim.notify(#sqls .. ' queries started', vim.log.levels.INFO, { title = 'Teradata' })
    else
        -- Provide single notify
        local job_id = util.jobs_all()[#util.jobs_all()].id -- just referencing the last job we added
        vim.notify('Query started' .. (job_id and ': ' .. job_id or ''), vim.log.levels.INFO, { title = 'Teradata' })
    end
end

-- Node-based syntax check (supports count: :3TD)
function M.query_syntax(args)
    local count = (args.count and args.count > 0) and args.count or 1
    local sqls = get_node_statements(count)
    run_multiple(sqls, 'syntax', function(res)
        if res.rc == 0 then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        else
            ui.display_error(res.msg)
        end
    end)
end

-- Visual-selection syntax check (splits on ';')
function M.query_syntax_visual(args)
    local sql = get_visual_sql()
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    local sqls = split_sql_statements(sql)
    run_multiple(sqls, 'syntax', function(res)
        if res.rc == 0 then
            vim.notify('No syntax errors.', vim.log.levels.INFO, { title = 'Teradata' })
        else
            ui.display_error(res.msg)
        end
    end)
end

-- Node-based output (supports count: :3TDO)
function M.query_output(args)
    local count = (args.count and args.count > 0) and args.count or 1
    local sqls = get_node_statements(count)
    run_multiple(sqls, 'output', function(res, context)
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

-- Visual-selection output (splits on ';')
function M.query_output_visual(args)
    local sql = get_visual_sql()
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    local sqls = split_sql_statements(sql)
    run_multiple(sqls, 'output', function(res, context)
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

--- Joins multiple SQL statements into BTEQ multistatement format.
--- The ';' terminator of query N appears on the same line as the start of query N+1.
--- @param sqls table list of SQL strings (without trailing ';')
--- @return string the joined multistatement SQL
local function join_multistatement(sqls)
    if #sqls == 0 then return '' end
    if #sqls == 1 then return sqls[1] end

    local lines = {}
    for i, sql in ipairs(sqls) do
        local stmt_lines = vim.split(sql, '\n', { trimempty = true })
        if i == 1 then
            vim.list_extend(lines, stmt_lines)
        else
            -- Prepend ';' to the first line of the next statement (terminates previous query)
            local first_line = ';' .. stmt_lines[1]
            table.insert(lines, first_line)
            for j = 2, #stmt_lines do
                table.insert(lines, stmt_lines[j])
            end
        end
    end
    return table.concat(lines, '\n')
end

local function output_callback(res, context)
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
end

-- Node-based multistatement output (supports count: :3TDM)
function M.query_multistatement(args)
    local count = (args.count and args.count > 0) and args.count or 1
    local sqls = get_node_statements(count)
    if #sqls == 0 then
        return vim.notify('No SQL statements found.', vim.log.levels.WARN)
    end
    local joined = join_multistatement(sqls)
    vim.notify(
        #sqls .. ' statement(s) sent as multistatement',
        vim.log.levels.INFO, { title = 'Teradata' }
    )
    run_single_query(joined, 'output', output_callback)
end

-- Visual-selection multistatement output
function M.query_multistatement_visual(args)
    local sql = get_visual_sql()
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    local sqls = split_sql_statements(sql)
    if #sqls == 0 then
        return vim.notify('No SQL statements found.', vim.log.levels.WARN)
    end
    local joined = join_multistatement(sqls)
    vim.notify(
        #sqls .. ' statement(s) sent as multistatement',
        vim.log.levels.INFO, { title = 'Teradata' }
    )
    run_single_query(joined, 'output', output_callback)
end

return M
