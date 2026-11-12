local config = require('vim-teradata.config')
local util   = require('vim-teradata.util')
local tsu    = require('vim-teradata.ts-util')
local ui     = require('vim-teradata.ui')
local session = require('vim-teradata.session')

local M      = {}

--- query id -> bufnr of the session that produced the result
--- (used by re-runs and by grid edits started from a result buffer)
--- @type table<string, integer>
local result_session = {}

--- query id -> { user = <user obj>, session_buf = int|nil, rows_found = int|nil, retlimit_applied = bool }
--- (what a full export needs to know about the query that produced a preview)
--- @type table<string, table>
local query_ctx = {}

local output_callback_with

--- Context recorded for output query `id` (nil for ids from older history).
--- @param id string|nil
--- @return table|nil
function M.query_context(id)
    return id and query_ctx[tostring(id)] or nil
end


local function sq(s)
    return "'" .. (s:gsub("'", "''")) .. "'"
end

--- Builds the common BTEQ logon header.
--- @param user string The username.
--- @param tdpid string The Teradata server ID.
--- @param log_mech string The log mechanism.
--- @return table The list of BTEQ header commands.
local function build_header(user, tdpid, log_mech)
    return {
        -- SESSION CHARSET applies to the NEXT logon: it must precede .logon,
        -- otherwise the session runs with the client's default charset.
        ".set session charset 'UTF8'",
        '.logmech ' .. log_mech,
        '.logon ' .. tdpid .. '/' .. user .. ',$tdwallet(' .. user .. ');',
    }
end

--- Session-wide settings. Sent once per one-shot job, or once when a
--- persistent session is opened.
--- @return string[]
local function settings_lines()
    return {
        '.set titledashes off',
        '.set separator ' .. sq(config.options.sep),
        '.set null ' .. sq(config.options.null_token or 'NULL'),
        '.set WIDTH 1048575',
    }
end

--- Per-request lines.
--- @param sql string
--- @param options table { operation = string, skip_retlimit = boolean }
--- @param output_path string export file
--- @return string[] body  lines up to and including the SQL terminator
--- @return string[] post  lines to run after the request (closes the export)
local function request_lines(sql, options, output_path)
    local body = {}
    if options.operation == 'output' and not options.skip_retlimit then
        body[#body + 1] = '.set retlimit ' .. config.options.retlimit .. ' 2048'
        body[#body + 1] = '.set retcancel on'
    else
        -- EXPLAIN / syntax: no row limit. RETLIMIT is sticky inside a
        -- persistent session, so it is always set explicitly (0 = no limit).
        body[#body + 1] = '.set retlimit 0 2048'
        body[#body + 1] = '.set retcancel off'
    end
    body[#body + 1] = '.EXPORT FILE = ' .. sq(output_path) .. ';'
    vim.list_extend(body, vim.split(sql, '\n'))
    -- A lone ';' after an already terminated statement is an empty request
    -- that would reset ERRORCODE, hiding the failure from the session's check.
    if not sql:match(';%s*$') then
        body[#body + 1] = ';'
    end
    return body, { '.EXPORT RESET' }
end

--- Builds a complete one-shot BTEQ script (logon .. logoff).
--- @return table { script = string[] }
local function build_script(sql, user_obj, options, output_path)
    local script = build_header(user_obj.user, user_obj.tdpid, user_obj.log_mech)
    vim.list_extend(script, settings_lines())
    local body, post = request_lines(sql, options, output_path)
    vim.list_extend(script, body)
    vim.list_extend(script, post)
    vim.list_extend(script, { '.LOGOFF', '.EXIT' })
    return { script = script }
end

--- Starts an asynchronous BTEQ job.
--- @param script_lines table The script lines to send to BTEQ.
--- @param on_done function The callback function(res).
local function start_job(script_lines, on_done)
    local timeout = config.options.timeout_ms
    if not timeout or timeout <= 0 then timeout = nil end -- 0/nil = no timeout
    return vim.system({ 'bteq' }, {
        stdin = table.concat(script_lines, '\n'),
        text = true,
        timeout = timeout,
    }, function(result)
        local res = {
            rc = result.code,
            msg = result.stderr or '',
            log_content = vim.split(result.stdout or '', '\n', { trimempty = true }),
            timed_out = (result.code == 124),
        }
        if res.timed_out and res.msg == '' then res.msg = 'BTEQ timed out' end
        on_done(res)
    end)
end

--- SQL text for a `{ range = true }` user command.
---@param args table|nil user-command args (line1/line2/range)
---@return string|nil
local function get_range_sql(args)
    if not (args and args.range == 2) then return nil end
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if s[2] == args.line1 and e[2] == args.line2 then
        -- invoked from a visual selection: honour charwise/linewise/blockwise
        local mode = vim.fn.visualmode()
        if mode ~= '' then
            return table.concat(vim.fn.getregion(s, e, { type = mode }), '\n')
        end
    end
    -- explicit range (:5,10TDV): whole lines
    return table.concat(vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false), '\n')
end

local function get_node_statements(count)
    local buf = vim.api.nvim_get_current_buf()
    local okn, current_node = pcall(vim.treesitter.get_node, { bufnr = buf })
    if not okn or not current_node then
        vim.notify('Teradata parser not available for this buffer.', vim.log.levels.WARN)
        return {}
    end
    local stmt_node = tsu.ancestor(current_node, "statement")
    if not stmt_node then return {} end
    local nodes = tsu.collect_next_sibling_statement_nodes(stmt_node, count)
    return vim.tbl_map(function(n) return vim.treesitter.get_node_text(n, buf) end, nodes)
end

-- The most recent 'output' job, as submitted to BTEQ. Written by
-- run_single_query, replayed by M.rerun_latest(). Only 'output' jobs are
-- tracked: a syntax check has no result set to refresh.
--- @type table|nil  { sql = string, id = string }
local last_run = nil

--- Id of the most recent output query.
--- @return string|nil
function M.latest_id()
    return last_run and last_run.id
end
--- Returns true when `id` is the id of the most recent output query.
--- @param id string|nil
--- @return boolean
function M.is_latest_query(id)
    return last_run ~= nil and id ~= nil and tostring(id) == last_run.id
end

--- Finds the window that currently displays the result buffer of query `id`.
--- Windows of the current tabpage win over windows of other tabpages.
--- @param id string|nil
--- @return integer|nil winid
local function find_result_win(id)
    if not id then return nil end
    local grid = require('vim-teradata.grid_state')
    local function scan(wins)
        for _, win in ipairs(wins) do
            local buf = vim.api.nvim_win_get_buf(win)
            local buf_id = grid.get(buf, 'query_id')
            if buf_id and tostring(buf_id) == tostring(id) then
                return win
            end
        end
    end
    return scan(vim.api.nvim_tabpage_list_wins(0)) or scan(vim.api.nvim_list_wins())
end

local strip_leading_noise = util.strip_leading_noise

--- True when a single statement is an EXPLAIN request (case-insensitive).
--- @param stmt string
--- @return boolean
local function is_explain(stmt)
    local head = strip_leading_noise(stmt):sub(1, 16):lower()
    return head:match('^explain%f[%W]') ~= nil
end

--- True when at least one statement of `sql` is an EXPLAIN request.
--- EXPLAIN output is plan text: truncating it by `retlimit` would hide the
--- end of the plan, so retlimit is not applied to such jobs.
--- @param sql string
--- @return boolean
local function has_explain(sql)
    local parts = util.split_statements(sql)
    if not parts or #parts == 0 then parts = { sql } end
    for _, part in ipairs(parts) do
        if is_explain(part) then return true end
    end
    return false
end

--- @param exec_opts table|nil { session_buf = integer }  buffer whose session
---        runs the query; defaults to the current buffer. Pass -1 to force a
---        one-shot job.
local function run_single_query(sql, operation, handle_result, exec_opts)
    local session_buf = (exec_opts and exec_opts.session_buf) or vim.api.nvim_get_current_buf()
    local sess = session.get(session_buf)

    local current_user
    if sess then
        current_user = sess.user -- a session keeps the user it was opened with
    else
        if not config.options.current_user_index or not config.options.users[config.options.current_user_index] then
            return vim.notify('No user selected. Use :TDU to set up users.', vim.log.levels.WARN)
        end
        current_user = config.options.users[config.options.current_user_index]
    end
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
        for _, part in ipairs(util.split_statements(clean_sql)) do
            parts[#parts + 1] = 'explain ' .. part
        end
        clean_sql = table.concat(parts, ' ; ')
    end

    -- Do not truncate EXPLAIN plans with retlimit (only relevant for 'output')
    opts.skip_retlimit = (operation == 'output') and has_explain(clean_sql) or false

    local output_path
    local context = {}
    local id = util.get_unique_query_id()
    local query_path

    if operation == 'output' then
        query_path = util.get_history_path('queries_dir_name') .. '/' .. id .. '.sql'
        output_path = util.get_history_path('resultsets_dir_name') .. '/' .. id .. '.csv'
        vim.fn.writefile(vim.split(sql, '\n'), query_path)
        context = {
            query_id = id,
            result_path = output_path,
            retlimit_applied = not opts.skip_retlimit,
        }
        -- Keep the raw SQL, not clean_sql: a re-run must go through the same
        -- replacement / terminator handling as the original submission.
        last_run = { sql = sql, id = id, session_buf = sess and session_buf or nil }
        if sess then result_session[id] = session_buf end
        query_ctx[id] = {
            user = current_user,
            session_buf = sess and session_buf or nil,
            rows_found = nil,
            retlimit_applied = not opts.skip_retlimit,
        }
    else
        output_path = vim.fn.tempname()
    end

    -- Register job
    util.jobs_add({
        id          = id,
        operation   = operation,
        status      = 'running',
        user        = current_user.user,
        session     = sess and session_buf or nil,
        rows        = nil,
        message     = sess and 'Queued' or 'Started',
        result_path = (operation == 'output') and output_path or nil,
        query_path  = query_path,
        started_at  = os.time(),
        finished_at = nil,
        handle      = nil,
    })

    local function on_done(res)
        vim.schedule(function()
            local job = util.jobs_get(id)
            if not job or job.status == 'canceled' then
                util.remove_files(output_path) -- partial export
                ui.refresh_jobs_if_open()
                return                         -- no result handling, no error popup
            end

            local status = (res.rc == 0) and 'ok' or 'error'
            local rows = nil
            if operation == 'output' then
                rows = util.extract_rows_found(res.log_content)
                if query_ctx[id] then query_ctx[id].rows_found = rows end
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
    end

    local handle
    if sess then
        local body, post = request_lines(clean_sql, opts, output_path)
        handle = sess:submit(body, post, on_done, function()
            util.jobs_update(id, { message = 'Running' })
        end)
    else
        local bteq_data = build_script(clean_sql, current_user, opts, output_path)
        handle = start_job(bteq_data.script, on_done)
    end

    util.jobs_update(id, { handle = handle })
    return id
end

--- Runs an already prepared SELECT in the persistent session of `session_buf`
--- with no row limit, writing the BTEQ export to `output_path`. It is a side
--- channel: no history entry, `last_run` and the per-query context are untouched.
--- @param session_buf integer
--- @param sql string
--- @param output_path string
--- @param on_done fun(res: table)  called on the main loop
--- @return table|nil handle, string|nil err
function M.export_in_session(session_buf, sql, output_path, on_done)
    local sess = session_buf and session.get(session_buf)
    if not sess then return nil, 'The BTEQ session of this query is no longer open.' end
    local body, post = request_lines(sql, { operation = 'output', skip_retlimit = true }, output_path)
    local handle = sess:submit(body, post, function(res) vim.schedule(function() on_done(res) end) end)
    return handle
end

local function run_multiple(sqls, operation, handle_result)
    if #sqls == 0 then
        return vim.notify('No SQL statements found.', vim.log.levels.WARN)
    end
    if not util.get_current_user() and not session.get(vim.api.nvim_get_current_buf()) then
        return vim.notify('No user selected. Use :TDU to set up users.', vim.log.levels.WARN)
    end
    local ids = {}
    for _, sql in ipairs(sqls) do
        local id = run_single_query(sql, operation, handle_result)
        if id then ids[#ids + 1] = id end
    end
    if #ids > 1 then
        vim.notify(#ids .. ' queries started', vim.log.levels.INFO, { title = 'Teradata' })
    elseif #ids == 1 then
        vim.notify('Query started: ' .. ids[1], vim.log.levels.INFO, { title = 'Teradata' })
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

-- Node-based output (supports count: :3TDO)
function M.query_output(args)
    local count = (args.count and args.count > 0) and args.count or 1
    local sqls = get_node_statements(count)
    run_multiple(sqls, 'output', function(res, context)
        output_callback_with(res, context)
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

--- @param display_opts table|nil forwarded to ui.display_output,
---                      e.g. { reuse_win = 1001 }
function output_callback_with(res, context, display_opts)
    if res.rc == 0 then
        local result_path = context.result_path
        if vim.fn.getfsize(result_path) > 0 then
            ui.display_output(result_path, context.query_id, display_opts)
            local actual_lines = util.extract_rows_found(res.log_content)
            if context.retlimit_applied
                and actual_lines and actual_lines > config.options.retlimit then
                local msg = string.format('%d actual lines, only %d displayed.', actual_lines, config.options.retlimit)
                local ex = config.options.export or {}
                if ex.enabled ~= false then
                    local key = ex.keymap
                    if type(key) == 'string' and key ~= '' then
                        msg = msg .. string.format(' Press %s in the grid (or :TDExport) for the full result.', key)
                    else
                        msg = msg .. ' Use :TDExport for the full result.'
                    end
                end
                vim.notify(msg, vim.log.levels.WARN)
            end
        else
            vim.notify('Query returned no lines.', vim.log.levels.INFO, { title = 'Teradata' })
        end
    else
        ui.display_error(res.msg)
    end
end

local function output_callback(res, context)
    output_callback_with(res, context)
end

--- Re-runs the SQL of the latest output query as a brand new BTEQ job, so it
--- gets its own history id and its own line in the job manager.
--- @param opts table|nil { reuse_win = integer }  window whose result buffer
---             is replaced by the new grid. Optional: when it is absent or
---             stale, the window still showing the previous result of this
---             same query is used, so `g.` from a SQL buffer refreshes the
---             grid on screen instead of stacking another split.
function M.rerun_latest(opts)
    if not last_run then
        return vim.notify('No query has been run yet.', vim.log.levels.WARN, { title = 'Teradata' })
    end

    local reuse_win = opts and opts.reuse_win or nil
    -- Captured now: run_single_query overwrites last_run with the id of the job
    -- it is about to start, so by callback time last_run.id is the NEW result.
    local prev_id = last_run.id

    -- -1 forces a one-shot job (the current buffer may be a result buffer, or
    -- a SQL buffer whose session did not run the original query).
    local exec_opts = { session_buf = -1 }
    if last_run.session_buf then
        if session.get(last_run.session_buf) then
            exec_opts.session_buf = last_run.session_buf
        else
            vim.notify('The BTEQ session of this query is closed; re-running it in a new BTEQ job.',
                vim.log.levels.WARN, { title = 'Teradata' })
        end
    end

    run_single_query(last_run.sql, 'output', function(res, context)
        local target = reuse_win
        if not target or not vim.api.nvim_win_is_valid(target) then
            target = find_result_win(prev_id)
        end
        output_callback_with(res, context, { reuse_win = target })
    end, exec_opts)
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
    local sql = get_range_sql(args)
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    local sqls = util.split_statements(sql)
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

-- Visual-selection output
function M.query_output_visual(args)
    local sql = get_range_sql(args)
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    vim.notify('Selection sent as single BTEQ job', vim.log.levels.INFO, { title = 'Teradata' })
    run_single_query(sql, 'output', output_callback)
end

-- Visual-selection syntax check
function M.query_syntax_visual(args)
    local sql = get_range_sql(args)
    if not sql or sql:match('^%s*$') then
        return vim.notify('No SQL in selection.', vim.log.levels.WARN)
    end
    vim.notify('Selection sent as single BTEQ job', vim.log.levels.INFO, { title = 'Teradata' })
    run_single_query(sql, 'syntax', output_callback)
end

--- :TDSession [open|close|restart|status]   /   :TDSession!  (= close)
--- @param args table user-command args
function M.session_command(args)
    local buf = vim.api.nvim_get_current_buf()
    local action = args.bang and 'close' or ((args.fargs or {})[1] or 'open')
    local title = { title = 'Teradata' }

    if action == 'close' then
        if session.close(buf) then
            vim.notify('BTEQ session closed.', vim.log.levels.INFO, title)
        else
            vim.notify('No BTEQ session attached to this buffer.', vim.log.levels.INFO, title)
        end
        return
    end

    if action == 'status' then
        local d = session.describe(buf)
        vim.notify(d and ('BTEQ session: ' .. d) or 'No BTEQ session attached to this buffer.',
            vim.log.levels.INFO, title)
        return
    end

    if action ~= 'open' and action ~= 'restart' then
        return vim.notify('Usage: :TDSession [open|close|restart|status]', vim.log.levels.WARN, title)
    end

    if action == 'restart' then session.close(buf) end
    local existing = session.describe(buf)
    if existing then
        return vim.notify('BTEQ session already open: ' .. existing, vim.log.levels.INFO, title)
    end

    local user = util.get_current_user()
    if not user then
        return vim.notify('No user selected. Use :TDU to set up users.', vim.log.levels.WARN, title)
    end

    vim.notify('Opening BTEQ session for ' .. user.user .. '@' .. user.tdpid .. 'ÔÇª',
        vim.log.levels.INFO, title)
    session.open(buf, user, {
        logon = build_header(user.user, user.tdpid, user.log_mech),
        settings = settings_lines(),
        on_ready = function()
            vim.notify('BTEQ session ready (' .. user.user .. '@' .. user.tdpid .. ').',
                vim.log.levels.INFO, title)
        end,
    })
end

--- bufnr of the session that produced result `query_id`, if any.
function M.session_buf_for(query_id)
    return query_id and result_session[tostring(query_id)] or nil
end

--- Runs a list of UPDATE statements inside one transaction, stopping at the
--- first failure. Runs in the session that produced the edited result when it
--- is still open, otherwise in a one-shot BTEQ job.
--- @param statements string[] statements WITHOUT trailing ';'
--- @param on_done fun(res: table, counts: table)  counts[i] = rows changed by statement i
--- @param opts table|nil { query_id = string }  id of the edited result
function M.run_updates(statements, on_done, opts)
    if #statements == 0 then return end

    local sbuf = M.session_buf_for(opts and opts.query_id)
    local sess = sbuf and session.get(sbuf) or nil
    if sbuf and not sess then
        vim.notify('The BTEQ session of this result is closed; updates run in a new BTEQ job.',
            vim.log.levels.INFO, { title = 'Teradata' })
    end

    local current_user = sess and sess.user or util.get_current_user()
    if not current_user then
        return vim.notify('No Teradata user configured.', vim.log.levels.ERROR)
    end

    local id = util.get_unique_query_id()
    local abort_label = 'VTD_ABORT_' .. id:gsub('%W', '_')

    local stmts = { 'BT;' }
    for _, stmt in ipairs(statements) do
        vim.list_extend(stmts, vim.split(util.replace_env_vars(stmt), '\n'))
        table.insert(stmts, ';')
        -- stop at the first failure: after it the transaction is already
        -- rolled back and later statements would auto-commit one by one
        table.insert(stmts, sess
            and ('.IF ERRORCODE <> 0 THEN .GOTO ' .. abort_label)
            or '.IF ERRORCODE <> 0 THEN .QUIT 8')
    end
    table.insert(stmts, 'ET;')

    util.jobs_add({
        id = id, operation = 'update', status = 'running',
        user = current_user.user, session = sess and sbuf or nil,
        message = sess and 'Queued' or 'Started',
        started_at = os.time(),
    })

    local function on_job_done(res)
        vim.schedule(function()
            local job = util.jobs_get(id)
            if not job or job.status == 'canceled' then
                ui.refresh_jobs_if_open()
                return
            end
            local counts = util.extract_rows_changed(res.log_content)
            local msg = (res.rc == 0) and 'OK'
                or (res.timed_out and 'Timed out' or ((res.msg or ''):match('[^\n]*$') or 'Error'))
            util.jobs_update(id, {
                status = (res.rc == 0) and 'ok' or 'error',
                rows = counts[1],
                message = msg,
                finished_at = os.time(),
            })
            ui.refresh_jobs_if_open()
            on_done(res, counts)
        end)
    end

    local handle
    if sess then
        table.insert(stmts, '.LABEL ' .. abort_label)
        handle = sess:submit(stmts, {}, on_job_done, function()
            util.jobs_update(id, { message = 'Running' })
        end)
    else
        local body = build_header(current_user.user, current_user.tdpid, current_user.log_mech)
        vim.list_extend(body, {
            '.set titledashes off',
            '.set errorlevel severity 8 exitcode 8',
        })
        vim.list_extend(body, stmts)
        vim.list_extend(body, { '.LOGOFF', '.EXIT' })
        handle = start_job(body, on_job_done)
    end
    util.jobs_update(id, { handle = handle })
end

M._get_range_sql = get_range_sql
-- exposed for tests and internal callers
M._build_script = build_script
M._request_lines = request_lines
M._run_single_query = run_single_query

return M
