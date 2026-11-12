local config = require('vim-teradata.config')
local util   = require('vim-teradata.util')

local M = {}

-- false: TPT appends to the file that already holds the header (OpenMode = WriteAppend).
-- true: TPT writes <id>.csv.part and the plugin builds <id>.csv from header + part file.
local USE_PART_FILE = false

local run_counter = 0

local function opts() return config.ensure().export end

local function exports_dir()
    return util.get_history_path('exports_dir_name')
end

local function fwd(path) return (path:gsub('\\', '/')) end

local function fmt_int(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

local function fmt_duration(sec)
    sec = math.max(0, math.floor(sec))
    if sec < 60 then return ('%ds'):format(sec) end
    if sec < 3600 then return ('%dm %ds'):format(math.floor(sec / 60), sec % 60) end
    return ('%dh %dm'):format(math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function user_label(u)
    return ('%s@%s (%s)'):format(u.user, u.tdpid, u.log_mech)
end

--- Shortens `s` to at most `max` characters, replacing the middle with 'ÔÇª'.
---@param s string
---@param max integer
---@return string
function M._truncate_middle(s, max)
    local len = vim.fn.strchars(s)
    if len <= max or max < 3 then return s end
    local keep = max - 1
    local head = math.ceil(keep / 2)
    return vim.fn.strcharpart(s, 0, head) .. 'ÔÇª' .. vim.fn.strcharpart(s, len - (keep - head))
end

---@param lines string[]
---@return integer|nil
function M._parse_rows(lines)
    local found
    for _, line in ipairs(lines or {}) do
        local n = line:match('Total Rows Exported:%s*([%d,]+)') or line:match('Rows Exported:%s*([%d,]+)')
        if n then
            n = tonumber((n:gsub(',', '')))
            if line:find('FILE_WRITER', 1, true) then return n end
            found = n
        end
    end
    return found
end

---@param lines string[]
---@return string|nil
function M._parse_job_id(lines)
    for _, line in ipairs(lines or {}) do
        local id = line:match('Job id is (%S+)')
        if id then return (id:gsub('[,;%.]+$', '')) end
    end
end

---@param lines string[]
---@return string[]
function M._error_text(lines)
    local hits = {}
    for _, line in ipairs(lines or {}) do
        if line:match('[Ee]rror') or line:match('TPT%d+') or line:find('Failure', 1, true)
            or line:find('Teradata Database error', 1, true) then
            hits[#hits + 1] = line
        end
    end
    if #hits == 0 then
        for _, line in ipairs(lines or {}) do
            if not line:match('^%s*$') then hits[#hits + 1] = line end
        end
        return vim.list_slice(hits, math.max(1, #hits - 9))
    end
    return vim.list_slice(hits, 1, 10)
end

--- Accepts one SELECT (SEL / WITH / LOCKING ... SELECT) and nothing else.
---@param sql string
---@return boolean ok, string|nil err
function M._validate_statement(sql)
    local stmts = {}
    for _, s in ipairs(util.split_statements(sql or '')) do
        if util.strip_leading_noise(s) ~= '' then stmts[#stmts + 1] = s end
    end
    if #stmts == 0 then return false, 'The query is empty.' end
    if #stmts > 1 then return false, 'Only a single SELECT can be exported.' end
    local head = util.strip_leading_noise(stmts[1]):lower()
    local ok = head:match('^select%f[%W]') or head:match('^sel%f[%W]') or head:match('^with%f[%W]')
    if not ok and (head:match('^lock%f[%W]') or head:match('^locking%f[%W]')) then
        ok = head:find('%f[%w]sel%f[%W]') or head:find('%f[%w]select%f[%W]')
    end
    if not ok then return false, 'Only a single SELECT can be exported.' end
    return true
end

--- Applies the configured replacements, validates and returns the statement
--- sent to TPT (leading comments dropped, exactly one trailing ';').
---@param raw string
---@return string|nil sql, string|nil err
function M._prepare_sql(raw)
    local sql = util.replace_env_vars(raw)
    local ok, err = M._validate_statement(sql)
    if not ok then return nil, err end
    local stmt
    for _, s in ipairs(util.split_statements(sql)) do
        if util.strip_leading_noise(s) ~= '' then stmt = s end
    end
    stmt = util.strip_leading_noise(stmt):gsub('[%s;]+$', '')
    -- a trailing line comment would swallow the terminator
    local last = stmt:match('[^\n]*$')
    return stmt .. (last:find('--', 1, true) and '\n;' or ';')
end

--- Splits leading LOCK/LOCKING modifiers (access locks only) from the statement body.
---@param sql string
---@return string|nil lock, string|nil body_or_reason
local function split_lock(sql)
    local lock = {}
    local rest = sql
    while rest:lower():match('^lock') do
        local l = rest:lower()
        local _, e = l:find('^lock%a*%s+.-%f[%a]access%f[%A]%s*')
        if not e then return nil, 'unsupported LOCK modifier' end
        local _, e2 = l:find('^nowait%f[%A]%s*', e + 1)
        e = e2 or e
        local part = rest:sub(1, e)
        if part:lower():find('%f[%w]sel%f[%W]') or part:lower():find('%f[%w]select%f[%W]') then
            return nil, 'unsupported LOCK modifier'
        end
        lock[#lock + 1] = vim.trim(part)
        rest = rest:sub(e + 1)
    end
    return table.concat(lock, ' '), rest
end

--- Wraps the statement so every column is TRIM(...), i.e. VARCHAR (EXPORT route).
---@param sql string prepared statement
---@param ncols integer|nil
---@return string|nil wrapped, string|nil reason
function M._wrap_select(sql, ncols)
    if not ncols or ncols < 1 then return nil, 'column count unknown' end
    local lock, body = split_lock((sql:gsub('^%s+', '')))
    if not lock then return nil, body end
    body = body:gsub('[%s;]+$', '')
    local terms, names = {}, {}
    for i = 1, ncols do
        terms[i] = ('TRIM(t.c%d) AS c%d'):format(i, i)
        names[i] = 'c' .. i
    end
    return (lock ~= '' and (lock .. '\n') or '')
        .. 'SELECT ' .. table.concat(terms, ', ')
        .. '\nFROM (\n' .. body .. '\n) AS t (' .. table.concat(names, ', ') .. ');'
end

local NESTED = { subquery = true, window_specification = true, cte = true, common_table_expression = true }

--- true/false, or nil + reason when the parser is unavailable.
local function has_top_level_order_by(sql)
    local ok, parser = pcall(vim.treesitter.get_string_parser, sql, 'teradata')
    if not ok or not parser then return nil, 'SQL parser unavailable' end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then return nil, 'SQL parser unavailable' end
    local function walk(node, nested)
        local t = node:type()
        if t == 'order_by' and not nested then return true end
        nested = nested or NESTED[t] or false
        for child in node:iter_children() do
            if walk(child, nested) then return true end
        end
        return false
    end
    return walk(trees[1]:root(), false)
end

--- Route W (wrapped EXPORT) when the query can be wrapped, else R (SELECTOR, report mode).
---@param sql string prepared statement
---@param ncols integer|nil
---@param operator string|nil 'auto' | 'export' | 'selector'
---@return string|nil route, string|nil reason_or_err
function M._choose_route(sql, ncols, operator)
    operator = operator or 'auto'
    if operator == 'selector' then return 'R' end
    local reason
    local lock, body = split_lock((sql or ''):gsub('^%s+', ''))
    if not ncols or ncols < 1 then
        reason = 'no column header for the query'
    elseif not lock then
        reason = body
    elseif body:lower():match('^with%f[%W]') then
        reason = 'WITH queries cannot be wrapped'
    else
        local top, perr = has_top_level_order_by(body)
        if top == nil then
            reason = perr
        elseif top then
            reason = 'top-level ORDER BY cannot be wrapped'
        end
    end
    if not reason then return 'W' end
    if operator == 'export' then
        return nil, ("export.operator = 'export' cannot export this query: %s. Use 'auto' or 'selector'."):format(reason)
    end
    return 'R', reason
end

--- Reason (first matching line) when a failed route-W run is worth retrying in report mode.
---@param lines string[]
---@return string|nil
function M._should_retry(lines)
    for _, line in ipairs(lines or {}) do
        local l = line:lower()
        local hit = line:find('TPT12108', 1, true) or line:find('TPT02639', 1, true)
        if not hit then
            local typed = l:find('data type', 1, true) or l:find('datatype', 1, true)
            for _, code in ipairs({ '3532', '3533', '5407', '3706' }) do
                if typed and line:find('%f[%d]' .. code .. '%f[%D]') then hit = true end
            end
            if typed and l:find('trim', 1, true) or (l:find('invalid', 1, true) and l:find('trim', 1, true)) then
                hit = true
            end
        end
        if hit then return vim.trim(line) end
    end
end

--- Unique per run: TPT keeps checkpoint files per job name and would try to
--- restart an earlier failed run with the same name.
---@param id string
---@return string
function M._job_name(id)
    run_counter = run_counter + 1
    return ('VTD_EXP_%s_%d'):format((tostring(id):upper():gsub('[^A-Z0-9]', '_')), run_counter)
end

---@param vars { user: table, data_path: string, file_name: string, sep: string, max_sessions: integer|nil, select_stmt: string, operator: string|nil }
---@return string[]|nil lines, string|nil err
function M._jobvars_text(vars)
    local u = vars.user
    local ok, err = config.validate_user(u)
    if not ok then return nil, 'Invalid user: ' .. err end
    for _, k in ipairs({ 'data_path', 'file_name' }) do
        if type(vars[k]) ~= 'string' or vars[k] == '' or vars[k]:find("'", 1, true) then
            return nil, ("%s must not be empty or contain a single quote: %s"):format(k, tostring(vars[k]))
        end
    end
    local sep = vars.sep
    if type(sep) ~= 'string' or sep == '' or sep:find("[\r\n']") then
        return nil, "The separator ('sep') must not contain a single quote or a newline for exports."
    end
    local function q(s) return "'" .. s:gsub("'", "''") .. "'" end
    local lines = {
        ('user         = %s,'):format(q(u.user)),
        ('logon_mech   = %s,'):format(q(u.log_mech)),
        ('tdpid        = %s,'):format(q(u.tdpid)),
        ('data_path    = %s,'):format(q(fwd(vars.data_path))),
        ('file_name    = %s,'):format(q(vars.file_name)),
        ('delimiter    = %s,'):format(q(sep)),
    }
    if (vars.operator or 'export') == 'export' then
        lines[#lines + 1] = ('max_sessions = %d,'):format(vars.max_sessions or 4)
    end
    lines[#lines + 1] = ('select_stmt  = %s'):format(q(vars.select_stmt))
    return vim.split(table.concat(lines, '\n'), '\n', { plain = true })
end

--- avg = (size - header line - newline) / preview rows; estimate = avg * rows.
---@return number|nil estimate_bytes, number|nil avg_row_bytes
function M._estimate(preview_size, header_len, preview_rows, rows_found)
    if not preview_size or preview_size < 0 or not preview_rows or preview_rows <= 0 then return nil, nil end
    local avg = math.max(0, preview_size - (header_len or 0) - 1) / preview_rows
    if not rows_found then return nil, avg end
    return avg * rows_found, avg
end

local function find_running(id)
    for _, j in ipairs(util.jobs_all()) do
        if j.operation == 'export' and j.source_id == id and j.status == 'running' then return j end
    end
end

--- True when the statement reads a volatile / session-only table that TPT's own sessions cannot see.
local function session_state_reason(sql, session_buf)
    local words = {}
    for w in sql:gmatch('[%w_$#]+') do words[w:upper()] = true end
    for w in pairs(words) do
        local ok, hit = pcall(util.get_session_table, w)
        if ok and hit then return ('it reads the session table %s'):format(w) end
    end
    if session_buf and vim.api.nvim_buf_is_valid(session_buf) then
        local ok, created = pcall(function()
            return require('vim-teradata.diagnostics').collect_buffer_created_tables(session_buf)
        end)
        if ok and type(created) == 'table' then
            for name, def in pairs(created) do
                if (type(def) ~= 'table' or def.volatile) and words[tostring(name):upper()] then
                    return ('it reads the volatile table %s'):format(type(def) == 'table' and def.name or name)
                end
            end
        end
    end
end

---@param id string|number
---@return table|nil ctx, string|nil err
function M.prepare(id)
    config.ensure()
    id = tostring(id)
    local qpath = util.get_history_path('queries_dir_name') .. '/' .. id .. '.sql'
    if vim.fn.filereadable(qpath) == 0 then
        return nil, ('No history entry for %s.'):format(id)
    end
    local sql, err = M._prepare_sql(table.concat(vim.fn.readfile(qpath), '\n'))
    if not sql then return nil, err end

    local qc = require('vim-teradata.bteq').query_context(id)
    local current = util.get_current_user()
    local user = qc and qc.user or current
    if not user then return nil, 'No user selected. Use :TDU to set up users.' end
    local valid, uerr = config.validate_user(user)
    if not valid then return nil, 'Invalid user: ' .. uerr end

    local o = opts()
    local rpath = util.get_history_path('resultsets_dir_name') .. '/' .. id .. '.csv'
    local sep = config.options.sep
    local header, preview_rows, preview_size
    if vim.fn.filereadable(rpath) == 1 then
        local first = vim.fn.readfile(rpath, '', 1)[1]
        if first and first ~= '' then
            local cols = vim.split((first:gsub('\r$', '')), sep, { plain = true })
            header = table.concat(vim.tbl_map(vim.trim, cols), sep)
            preview_size = vim.fn.getfsize(rpath)
            preview_rows = math.max(0, #vim.fn.readfile(rpath) - 1)
        end
    end

    local target = exports_dir() .. '/' .. id .. '.csv'
    local target_stat = vim.uv.fs_stat(target)
    local rows_found = qc and qc.rows_found or nil
    local estimate, avg = M._estimate(preview_size, header and #header, preview_rows, rows_found)

    local free
    local okfs, st = pcall(vim.uv.fs_statfs, exports_dir())
    if okfs and type(st) == 'table' and st.bavail and st.bsize then free = st.bavail * st.bsize end

    local ncols = header and #vim.split(header, sep, { plain = true }) or nil
    local route, route_reason = M._choose_route(sql, ncols, o.operator)
    if not route then return nil, route_reason end
    local select_stmt = sql
    if route == 'W' then
        select_stmt, route_reason = M._wrap_select(sql, ncols)
        if not select_stmt then
            if o.operator == 'export' then return nil, route_reason end
            route, select_stmt = 'R', sql
        end
    end

    local ctx = {
        id = id,
        sql = sql,
        route = route,
        route_reason = route_reason,
        select_stmt = select_stmt,
        ncols = ncols,
        user = user,
        user_label = user_label(user),
        current_user = current,
        session_buf = qc and qc.session_buf or nil,
        rows_found = rows_found,
        preview_rows = preview_rows,
        retlimit = config.options.retlimit,
        target_path = target,
        target_exists = target_stat ~= nil,
        target_mtime = target_stat and target_stat.mtime.sec or nil,
        target_size = target_stat and target_stat.size or nil,
        estimate_bytes = estimate,
        avg_row_bytes = avg,
        free_bytes = free,
        header = header,
        has_header = header ~= nil,
        operator = route == 'R' and 'selector' or 'export',
        max_sessions = o.max_sessions,
        blocked_by_session = false,
        warnings = {},
    }

    if ctx.session_buf then
        local reason = session_state_reason(sql, ctx.session_buf)
        if reason then
            ctx.blocked_by_session = true
            ctx.blocked_reason = ('TPT opens its own sessions and cannot see session state: %s.'):format(reason)
        end
        table.insert(ctx.warnings, 'This query ran in a persistent BTEQ session: TPT opens its own '
            .. 'sessions and cannot see volatile tables, SET QUERY_BAND or other session state.')
    end
    if estimate and free and estimate > free * 0.8 then
        table.insert(ctx.warnings, ('Estimated size exceeds 80 %% of free disk space (%s)'):format(util.human_bytes(free)))
    end
    if current and (current.user ~= user.user or current.tdpid ~= user.tdpid) then
        table.insert(ctx.warnings, ('Runs as %s, the current user is %s'):format(user.user, current.user))
    end
    return ctx
end

local function wrap(text, width)
    local out, cur = {}, ''
    for word in text:gmatch('%S+') do
        if cur ~= '' and #cur + 1 + #word > width then
            out[#out + 1] = cur
            cur = word
        else
            cur = cur == '' and word or (cur .. ' ' .. word)
        end
    end
    if cur ~= '' then out[#out + 1] = cur end
    return out
end

---@param ctx table
---@param max_width integer|nil widest line allowed (default: editor width - 6)
---@return { [1]: string, [2]: string|nil }[]
function M.dialog_lines(ctx, max_width)
    max_width = max_width or (vim.o.columns - 6)
    local lines = {}
    local function add(label, text, hl)
        lines[#lines + 1] = { (' %-10s%s'):format(label, text), hl }
    end

    add('Query', ctx.id)
    add('User', ctx.user_label)
    if ctx.rows_found then
        local shown = ctx.preview_rows or ctx.retlimit
        add('Rows', ('%s   (grid shows %d)'):format(fmt_int(ctx.rows_found), math.min(shown, ctx.rows_found)))
        if ctx.rows_found <= ctx.retlimit then add('', 'Grid already shows every row') end
    else
        add('Rows', 'unknown (history entry without a row count)')
    end
    if ctx.estimate_bytes then
        add('Estimate', ('~%s     (Ôëê%d B/row from the preview)'):format(
            util.human_bytes(ctx.estimate_bytes), math.floor(ctx.avg_row_bytes + 0.5)))
    end
    add('Target', M._truncate_middle(ctx.target_path, math.max(20, max_width - 12)))
    if ctx.target_exists then
        add('', ('Overwrites the existing export (%s, %s)'):format(
            os.date('%Y-%m-%d %H:%M', ctx.target_mtime), util.human_bytes(ctx.target_size or 0)))
    end
    if ctx.route == 'R' or (ctx.route == nil and ctx.operator == 'selector') then
        add('Operator', 'TPT SELECTOR, report mode, single session'
            .. (ctx.route_reason and (' (' .. ctx.route_reason .. ')') or ''))
    else
        add('Operator', ('TPT EXPORT, up to %d sessions (columns cast to text)'):format(ctx.max_sessions))
    end
    add('Notes', 'NULLs are written as empty fields')
    add('', 'The exported grid is read-only (no editing)')
    for _, w in ipairs(ctx.warnings or {}) do
        for i, part in ipairs(wrap(w, math.max(30, math.min(70, max_width - 4)))) do
            lines[#lines + 1] = { (i == 1 and ' ÔÜá ' or '   ') .. part, 'WarningMsg' }
        end
    end
    return lines
end

local function resolve_tool(name)
    local p = vim.fn.exepath(name)
    return p ~= '' and p or nil
end

--- Best effort: stop leftover TPT processes, then drop the job's checkpoint files.
local function kill_tpt_job(job_name)
    local kill, rmcp = resolve_tool('twbkill'), resolve_tool('twbrmcp')
    local function rm()
        if rmcp then pcall(vim.system, { rmcp, job_name }, { text = true }, function() end) end
    end
    if kill then
        if not pcall(vim.system, { kill, job_name }, { text = true }, rm) then rm() end
    else
        rm()
    end
end

--- Builds `target` from the header plus the part file, 1 MiB at a time.
---@return boolean ok, string|nil err
local function concat_part(part, target, header)
    local src, err = vim.uv.fs_open(part, 'r', 438)
    if not src then return false, err end
    local dst, err2 = vim.uv.fs_open(target, 'w', 420)
    if not dst then
        vim.uv.fs_close(src)
        return false, err2
    end
    local ok = true
    if header then ok = vim.uv.fs_write(dst, header .. '\n', -1) ~= nil end
    while ok do
        local chunk = vim.uv.fs_read(src, 1048576, -1)
        if not chunk or chunk == '' then break end
        ok = vim.uv.fs_write(dst, chunk, -1) ~= nil
    end
    vim.uv.fs_close(src)
    vim.uv.fs_close(dst)
    return ok, ok and nil or 'write failed'
end

local function fail(ctx, export_job_id, job_name, lines, message, extra)
    util.jobs_update(export_job_id, { status = 'error', message = message, finished_at = os.time() })
    local out = {}
    if extra then vim.list_extend(out, extra) end
    vim.list_extend(out, lines)
    local tpt_id = M._parse_job_id(lines)
    if tpt_id then out[#out + 1] = ("Details: tlogview -j %s -f '*' -g"):format(tpt_id) end
    local log = table.concat(lines, '\n'):lower()
    if (log:find('%f[%a][bc]?lob%f[%A]') or log:find('large object', 1, true)) and ctx.operator ~= 'selector' then
        out[#out + 1] = "LOB columns are not supported by the EXPORT operator: set export.operator = 'selector'."
    end
    if #out == 0 then out[1] = 'TPT export failed.' end
    require('vim-teradata.ui').display_error(table.concat(out, '\n'))
end

---@param ctx table result of M.prepare
---@return string|nil export_job_id
function M.start(ctx)
    local o = opts()
    local title = { title = 'Teradata' }
    local id = ctx.id
    if find_running(id) then
        return vim.notify(('An export of %s is already running.'):format(id), vim.log.levels.WARN, title)
    end
    if vim.fn.executable('tbuild') == 0 and vim.fn.executable(util.tbuild_bin()) == 0 then
        return vim.notify('tbuild (Teradata Parallel Transporter) is not installed or not in your PATH.',
            vim.log.levels.ERROR, title)
    end
    local script = config.get_tpt_export_script(ctx.route)
    if not script or vim.fn.filereadable(script) == 0 then
        return vim.notify('TPT export script not found.', vim.log.levels.ERROR, title)
    end

    local dir = exports_dir()
    vim.fn.mkdir(dir, 'p', 448)
    local target = ctx.target_path
    local tpt_file = target .. (USE_PART_FILE and '.part' or '')
    local jobvars_path = dir .. '/' .. id .. '.jobvars'

    -- Writes header + job variables for one run; the same job can run twice (retry in report mode).
    local function prepare_run(route, select_stmt)
        local rscript = config.get_tpt_export_script(route)
        if not rscript or vim.fn.filereadable(rscript) == 0 then
            return nil, 'TPT export script not found.'
        end
        local lines, err = M._jobvars_text({
            user = ctx.user,
            data_path = dir,
            file_name = vim.fs.basename(tpt_file),
            sep = config.options.sep,
            max_sessions = ctx.max_sessions,
            select_stmt = select_stmt,
            operator = route == 'R' and 'selector' or 'export',
        })
        if not lines then return nil, err end
        util.remove_files(target, target .. '.part')
        if not USE_PART_FILE and ctx.has_header then
            if vim.fn.writefile({ ctx.header }, target) ~= 0 then return nil, 'Cannot write ' .. target end
        end
        if vim.fn.writefile(lines, jobvars_path) ~= 0 then
            util.remove_files(target)
            return nil, 'Cannot write ' .. jobvars_path
        end
        pcall(vim.uv.fs_chmod, jobvars_path, 384)
        return rscript
    end

    local route = ctx.route or 'W'
    local select_stmt = ctx.select_stmt or ctx.sql
    local run_script, perr = prepare_run(route, select_stmt)
    if not run_script then return vim.notify(perr, vim.log.levels.ERROR, title) end
    script = run_script

    local job_name = M._job_name(id)
    local export_job_id = ('%s#export%d'):format(id, run_counter)
    local started = os.time()
    local timeout = o.timeout_ms
    if not timeout or timeout <= 0 then timeout = nil end
    local retried = false

    util.jobs_add({
        id          = export_job_id,
        source_id   = id,
        operation   = 'export',
        status      = 'running',
        user        = ctx.user.user,
        rows        = nil,
        rows_total  = ctx.rows_found,
        message     = 'TPT running',
        result_path = target,
        query_path  = nil, -- `d` in :TDJ deletes query_path; the history .sql must survive
        tpt_job     = job_name,
        has_header  = ctx.has_header,
        started_at  = started,
    })

    local function cleanup()
        util.remove_files(jobvars_path, target .. '.part')
    end

    local spawn

    local function on_exit(result)
        vim.schedule(function()
            local ui = require('vim-teradata.ui')
            local job = util.jobs_get(export_job_id)
            if not job or job.status == 'canceled' then
                kill_tpt_job(job_name)
                cleanup()
                util.remove_files(target)
                ui.refresh_jobs_if_open()
                return
            end

            local out = vim.split((result.stdout or '') .. '\n' .. (result.stderr or ''), '\r?\n')
            local rc = result.code
            cleanup()
            if rc == 0 or rc == 4 then
                if USE_PART_FILE then
                    local ok, cerr = concat_part(tpt_file, target, ctx.has_header and ctx.header or nil)
                    util.remove_files(tpt_file)
                    if not ok then
                        util.remove_files(target)
                        fail(ctx, export_job_id, job_name, { tostring(cerr) }, 'Cannot build ' .. target)
                        return ui.refresh_jobs_if_open()
                    end
                end
                local rows = M._parse_rows(out)
                local size = vim.fn.getfsize(target)
                util.jobs_update(export_job_id, {
                    status = 'ok',
                    rows = rows,
                    rows_total = rows or ctx.rows_found,
                    message = rc == 0 and 'TPT ok' or 'TPT warning (rc 4)',
                    finished_at = os.time(),
                })
                local what = rows and (fmt_int(rows) .. ' rows ÔåÆ ') or ''
                local msg = ('Export done: %s%s (%s, %s)'):format(
                    what, target, util.human_bytes(math.max(size, 0)), fmt_duration(os.time() - started))
                if rc == 4 then
                    vim.notify(msg .. ' - TPT finished with warnings (rc 4)', vim.log.levels.WARN, title)
                else
                    vim.notify(msg, vim.log.levels.INFO, title)
                end
                if rows and ctx.rows_found and rows ~= ctx.rows_found then
                    vim.notify(('Exported %s rows, preview reported %s (data changed between runs?)'):format(
                        fmt_int(rows), fmt_int(ctx.rows_found)), vim.log.levels.WARN, title)
                end
            else
                util.remove_files(target, tpt_file)
                local errs = M._error_text(out)
                local reason = rc ~= 124 and route == 'W' and not retried and M._should_retry(out) or nil
                if reason then
                    retried = true
                    route = 'R'
                    ctx.route, ctx.operator = 'R', 'selector'
                    job_name = M._job_name(id)
                    local rscript, rerr = prepare_run('R', ctx.sql)
                    if rscript then
                        script = rscript
                        util.jobs_update(export_job_id, { message = 'TPT retry (report mode)', tpt_job = job_name })
                        local okspawn, serr = spawn()
                        if okspawn then
                            vim.notify('Retrying in report mode (SELECTOR): ' .. reason, vim.log.levels.WARN, title)
                            return ui.refresh_jobs_if_open()
                        end
                        rerr = serr
                    end
                    cleanup()
                    util.remove_files(target)
                    fail(ctx, export_job_id, job_name, { tostring(rerr) }, 'Failed to start')
                elseif rc == 124 then
                    kill_tpt_job(job_name)
                    fail(ctx, export_job_id, job_name, errs, 'Timed out', { 'The TPT export timed out.' })
                else
                    local last = (errs[#errs] or 'Error'):gsub('^%s+', '')
                    fail(ctx, export_job_id, job_name, errs, last)
                end
            end
            ui.refresh_jobs_if_open()
        end)
    end

    function spawn()
        local cmd = { util.tbuild_bin(), '-f', script, '-v', jobvars_path, job_name }
        local spawned, handle = pcall(vim.system, cmd, { text = true, timeout = timeout }, on_exit)
        if not spawned then return false, handle end
        util.jobs_update(export_job_id, { handle = handle })
        return true
    end

    local spawned, serr = spawn()
    if not spawned then
        cleanup()
        util.remove_files(target)
        util.jobs_update(export_job_id, { status = 'error', message = 'Failed to start', finished_at = os.time() })
        vim.notify('Export failed to start: ' .. tostring(serr), vim.log.levels.ERROR, title)
        return
    end
    vim.notify(('Export started: %s ÔåÆ %s'):format(id, target), vim.log.levels.INFO, title)
    return export_job_id
end

--- Fallback for queries that read session state: runs the SELECT through BTEQ
--- inside the session that executed it, without ever loading the result in a grid.
---@param ctx table result of M.prepare
---@return string|nil export_job_id
function M.start_bteq(ctx)
    local title = { title = 'Teradata' }
    local id = ctx.id
    if find_running(id) then
        return vim.notify(('An export of %s is already running.'):format(id), vim.log.levels.WARN, title)
    end
    local dir = exports_dir()
    vim.fn.mkdir(dir, 'p', 448)
    local target = ctx.target_path
    util.remove_files(target)

    run_counter = run_counter + 1
    local export_job_id = ('%s#export%d'):format(id, run_counter)
    local started = os.time()
    util.jobs_add({
        id          = export_job_id,
        source_id   = id,
        operation   = 'export',
        status      = 'running',
        user        = ctx.user.user,
        session     = ctx.session_buf,
        rows        = nil,
        rows_total  = ctx.rows_found,
        message     = 'BTEQ export',
        result_path = target,
        query_path  = nil,
        has_header  = true,
        started_at  = started,
    })

    local function on_done(res)
        local ui = require('vim-teradata.ui')
        local job = util.jobs_get(export_job_id)
        if not job or job.status == 'canceled' then
            util.remove_files(target)
            return ui.refresh_jobs_if_open()
        end
        if res.rc == 0 then
            local rows = util.extract_rows_found(res.log_content)
            local size = vim.fn.getfsize(target)
            util.jobs_update(export_job_id, {
                status = 'ok',
                rows = rows,
                rows_total = rows or ctx.rows_found,
                message = 'BTEQ ok',
                finished_at = os.time(),
            })
            local what = rows and (fmt_int(rows) .. ' rows ÔåÆ ') or ''
            vim.notify(('Export done: %s%s (%s, %s)'):format(
                what, target, util.human_bytes(math.max(size, 0)), fmt_duration(os.time() - started)),
                vim.log.levels.INFO, title)
            if rows and ctx.rows_found and rows ~= ctx.rows_found then
                vim.notify(('Exported %s rows, preview reported %s (data changed between runs?)'):format(
                    fmt_int(rows), fmt_int(ctx.rows_found)), vim.log.levels.WARN, title)
            end
        else
            util.remove_files(target)
            local last = (res.msg or ''):gsub('%s+$', '')
            util.jobs_update(export_job_id, {
                status = 'error',
                message = #last > 0 and last:match('[^\n]*$') or 'Error',
                finished_at = os.time(),
            })
            local out = {}
            if #last > 0 then out[1] = last end
            ui.display_error(#out > 0 and table.concat(out, '\n') or 'BTEQ export failed.')
        end
        ui.refresh_jobs_if_open()
    end

    local handle, err = require('vim-teradata.bteq').export_in_session(ctx.session_buf, ctx.sql, target, on_done)
    if not handle then
        util.jobs_update(export_job_id, { status = 'error', message = 'Failed to start', finished_at = os.time() })
        return vim.notify('Export failed to start: ' .. tostring(err), vim.log.levels.ERROR, title)
    end
    util.jobs_update(export_job_id, { handle = handle })
    vim.notify(('Export started (BTEQ session): %s ÔåÆ %s'):format(id, target), vim.log.levels.INFO, title)
    return export_job_id
end

---@param id string|nil defaults to the latest output query
function M.run(id)
    config.ensure()
    local title = { title = 'Teradata' }
    if not opts().enabled then
        return vim.notify('Full export is disabled (export.enabled = false).', vim.log.levels.WARN, title)
    end
    if not id or id == '' then
        id = require('vim-teradata.bteq').latest_id()
        if not id then
            return vim.notify('No query has been run yet.', vim.log.levels.WARN, title)
        end
    end
    id = tostring(id)
    if find_running(id) then
        return vim.notify(('An export of %s is already running.'):format(id), vim.log.levels.WARN, title)
    end

    local ctx, err = M.prepare(id)
    if not ctx then return vim.notify(err, vim.log.levels.ERROR, title) end
    if ctx.blocked_by_session then
        local lines = M.dialog_lines(ctx)
        lines[#lines + 1] = { ' ÔÜá ' .. ctx.blocked_reason, 'WarningMsg' }
        return require('vim-teradata.ui').confirm_box({
            title = ' Full export via TPT ',
            lines = lines,
            footer = ' [b] Export with BTEQ inside the session (slower)   [n / q / Esc] Cancel ',
            keys = { b = function() M.start_bteq(ctx) end },
        })
    end

    if opts().confirm then
        require('vim-teradata.ui').confirm_box({
            title = ' Full export via TPT ',
            lines = M.dialog_lines(ctx),
            on_confirm = function() M.start(ctx) end,
        })
    else
        M.start(ctx)
    end
end

return M
