local config = require('vim-teradata.config')
local M = {}

-- cache.db[key]      -> { DB_NAME = true, ... }                      (data.lua of that catalog)
-- cache.tb[key][DB]  -> { is_table = {...}, TABLE = { cols... } }    (<DB>.lua of that catalog)
local Schema = {
    cache = { db = {}, tb = {} }
}

-- catalog keys with a sync in flight (prevents two concurrent syncs of the same machine)
local syncing = {}
-- catalog keys already hinted about "no metadata yet" (one hint per key per session)
local warned_missing = {}

local function sanitize_key(s)
    return (tostring(s):gsub('[^%w_%-]', '_'):lower())
end

--- Stable, filesystem-safe id of the metadata catalog a user maps to.
--- Defaults to the tdpid; `user.catalog` overrides it. Sanitized keys never contain '.',
--- so they can never collide with the "<key>.new" staging directory.
--- @param user table|nil defaults to the active user
--- @return string|nil
function M.catalog_key(user)
    user = user or M.get_current_user()
    if not user then return nil end
    local raw = user.catalog
    if type(raw) ~= 'string' or raw == '' then raw = user.tdpid end
    if type(raw) ~= 'string' or raw == '' then return nil end
    return sanitize_key(raw)
end

--- Root directory holding one sub-directory per catalog.
--- @return string
function M.catalog_root()
    return config.options.data_dir .. '/' .. config.options.data_completion_dir
end

--- Key and directory of the active user's catalog (nil, nil when no usable user).
--- Cheap on purpose: called on every completion/diagnostic lookup.
--- @return string|nil key, string|nil dir
local function active_catalog()
    local key = M.catalog_key()
    if not key then return nil, nil end
    return key, M.catalog_root() .. '/' .. key
end

--- True when a synced catalog exists for `user` (defaults to the active user).
--- @return boolean
function M.has_catalog(user)
    local key = M.catalog_key(user)
    return key ~= nil and vim.fn.filereadable(M.catalog_root() .. '/' .. key .. '/data.lua') == 1
end

--- Contents of meta.lua ({ synced_at = <epoch>, tdpid = <string>, user = <string> }) or nil.
--- @return table|nil
function M.catalog_meta(user)
    local key = M.catalog_key(user)
    if not key then return nil end
    local ok, meta = pcall(dofile, M.catalog_root() .. '/' .. key .. '/meta.lua')
    return (ok and type(meta) == 'table') and meta or nil
end

--- One-time (per key, per session) hint when the active user's machine was never synced.
function M.warn_if_no_catalog()
    local key = active_catalog()
    if not key or warned_missing[key] or M.has_catalog() then return end
    warned_missing[key] = true
    local u = M.get_current_user()
    vim.notify(('[vim-teradata] No metadata for %s yet. Run :TDSync.'):format(u and u.tdpid or key),
        vim.log.levels.INFO)
end

--- Pre-catalog versions wrote data.lua/<DB>.lua directly in the root. They are never read
--- anymore; remove them once a sync has succeeded.
local function purge_legacy_flat_catalog()
    for _, f in ipairs(vim.fn.glob(M.catalog_root() .. '/*.lua', false, true)) do
        vim.fn.delete(f)
    end
end

--- Safely removes one or more files.
--- @param ... string One or more file paths to delete.
function M.remove_files(...)
    for _, file in ipairs({ ... }) do
        if file and file ~= '' and vim.fn.filereadable(file) == 1 then
            vim.fn.delete(file)
        end
    end
end

--- Splits SQL on top-level ';' ignoring ';' inside '...', "...", -- comments and /* */ comments.
--- Limitation: BEGIN...END bodies of stored procedures contain top-level ';'; for those
--- callers should prefer tree-sitter statement nodes.
---@param sql string
---@return string[]
function M.split_statements(sql)
    local stmts, start, i, n = {}, 1, 1, #sql
    local function push(stop)
        local s = sql:sub(start, stop):match('^%s*(.-)%s*$')
        if s ~= '' then stmts[#stmts + 1] = s end
    end
    while i <= n do
        local c, two = sql:sub(i, i), sql:sub(i, i + 1)
        if c == "'" or c == '"' then
            i = i + 1
            while i <= n do
                if sql:sub(i, i) == c then
                    if sql:sub(i + 1, i + 1) == c then i = i + 2 else break end
                else
                    i = i + 1
                end
            end
        elseif two == '--' then
            i = sql:find('\n', i, true) or n
        elseif two == '/*' then
            local _, e = sql:find('*/', i + 2, true)
            i = e or n
        elseif c == ';' then
            push(i - 1)
            start = i + 1
        end
        i = i + 1
    end
    push(n)
    return stmts
end

local _cache = {}
--- Cached loader keyed by file mtime+size.
function M.cached_read(path, loader)
    local st = vim.uv.fs_stat(path)
    if not st then return nil end
    local key = ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
    local c = _cache[path]
    if c and c.key == key then return c.value end
    local v = loader(path)
    _cache[path] = { key = key, value = v }
    return v
end

--- Run `handler(item)` over `items` in slices, yielding to the event loop between slices.
local function process_in_chunks(items, step, handler, done)
    local i = 1
    local function tick()
        local stop = math.min(i + step - 1, #items)
        for k = i, stop do handler(items[k]) end
        i = stop + 1
        if i <= #items then vim.schedule(tick) else done() end
    end
    tick()
end

--- Splits a temporary CSV file into per-database files and generates a summary file.
--- Output is written to a staging directory ("<catalog_dir>.new") that replaces `catalog_dir`
--- only once everything was written successfully.
--- @param input_filename string  CSV produced by TPT for this catalog
--- @param catalog_dir string     final destination: <root>/<key>
--- @param user table             connection used for the sync (recorded in meta.lua)
--- @param on_done fun(ok: boolean)|nil
--- @return nil
local function split_data_db_file_to_lua(input_filename, catalog_dir, user, on_done)
    local data_files_dir = catalog_dir .. ".new" -- staging
    local summary_filename = data_files_dir .. "/data.lua"

    vim.fn.delete(data_files_dir, "rf") -- leftover of a crashed sync
    vim.fn.mkdir(data_files_dir, "p")

    local input_file = io.open(input_filename, "r")
    if not input_file then
        vim.fn.delete(data_files_dir, "rf")
        if on_done then on_done(false) end
        return vim.notify("Error: Could not open the input file: " .. input_filename, vim.log.levels.ERROR)
    end

    local lines = {}
    for raw in input_file:lines() do
        lines[#lines + 1] = raw
    end
    input_file:close()

    -- Helpers
    local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    local function escape_lua_string(s)
        s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
        return s
    end
    local function add_unique(list, value)
        for _, v in ipairs(list) do if v == value then return end end
        table.insert(list, value)
    end
    local function sorted_keys(tbl)
        local keys = {}
        for k in pairs(tbl) do table.insert(keys, k) end
        table.sort(keys)
        return keys
    end

    -- Accumulators
    local per_db = {}     -- db -> table -> {columns}
    local unique_dbs = {} -- db -> true

    -- Parse lines
    process_in_chunks(lines, 5000, function(raw)
        local line = trim(raw or "")
        if line ~= "" then
            local parts = {}
            for token in line:gmatch("([^,]+)") do
                table.insert(parts, trim(token))
            end
            if #parts >= 3 then
                local db, tbl, col = parts[1], parts[2], parts[3]
                per_db[db] = per_db[db] or {}
                per_db[db][tbl] = per_db[db][tbl] or {}
                add_unique(per_db[db][tbl], col)
                unique_dbs[db] = true
            else
                vim.notify("Warning: Malformed line: " .. line, vim.log.levels.WARN)
            end
        end
    end, function()
        -- Write per-db files
        for db_name, tables in pairs(per_db) do
            local db_filename = data_files_dir .. "/" .. db_name .. ".lua"
            local is_table = {}
            table.insert(is_table, "is_table = {")
            local f = io.open(db_filename, "w")
            if f then
                f:write("-- Auto-generated. Do not edit.\n")
                f:write("return {\n")
                for _, tname in ipairs(sorted_keys(tables)) do
                    table.insert(is_table, string.format('  ["%s"] = true,', escape_lua_string(tname)))
                    local cols = tables[tname]
                    table.sort(cols)
                    f:write(string.format('  ["%s"] = {', escape_lua_string(tname)))
                    for i, c in ipairs(cols) do
                        f:write(string.format(' "%s"%s', escape_lua_string(c), i < #cols and "," or ""))
                    end
                    f:write(" },\n")
                end
                table.insert(is_table, "}")
                f:write(table.concat(is_table, "\n"))
                f:write("}\n")
                f:close()
            else
                vim.notify("Error: Could not write file: " .. db_filename, vim.log.levels.ERROR)
            end
        end

        local function fail(msg)
            vim.fn.delete(data_files_dir, "rf") -- keep the previous catalog untouched
            vim.notify(msg, vim.log.levels.ERROR)
            if on_done then on_done(false) end
        end

        -- An empty export (bad filter_db, no rights on dbc.columnsv...) must not wipe a good catalog.
        if next(unique_dbs) == nil then
            return fail("TDSync: export contained no rows; keeping the previous metadata.")
        end

        -- Write summary file
        local summary_file = io.open(summary_filename, "w")
        if not summary_file then
            return fail("Error: Could not write summary file: " .. summary_filename)
        end
        summary_file:write("-- Auto-generated. Do not edit.\n")
        summary_file:write("return {\n")
        for _, db_name in ipairs(sorted_keys(unique_dbs)) do
            summary_file:write(string.format('  ["%s"] = true,\n', escape_lua_string(db_name)))
        end
        summary_file:write("}\n")
        summary_file:close()

        -- Write meta file (used by :checkhealth and anything showing "last synced")
        local meta_file = io.open(data_files_dir .. "/meta.lua", "w")
        if meta_file then
            meta_file:write("-- Auto-generated. Do not edit.\n")
            meta_file:write(string.format("return { synced_at = %d, tdpid = %q, user = %q }\n",
                os.time(), user.tdpid or "", user.user or ""))
            meta_file:close()
        end

        -- Swap staging -> final. Deleting first drops databases that no longer exist on the server.
        vim.fn.delete(catalog_dir, "rf")
        if not vim.uv.fs_rename(data_files_dir, catalog_dir) then
            return fail("Error: Could not move the new catalog into place: " .. catalog_dir)
        end

        if on_done then on_done(true) end
    end)
end

local function load_databases(key, summary_file)
    Schema.cache.db[key] = M.cached_read(summary_file, dofile)
end

--- Return true if db_name is in the db file, false otherwise
--- @return boolean db_name is present.
function M.is_a_db(db_name)
    local key, dir = active_catalog()
    if not key then return false end
    local summary_file = dir .. "/data.lua"
    if vim.fn.filereadable(summary_file) == 0 then return false end
    -- always go through cached_read: it only reloads when mtime/size changed, so a re-sync is picked up
    load_databases(key, summary_file)
    return (Schema.cache.db[key] or {})[db_name:upper()]
end

--- Retrieves a list of available databases from a summary CSV file.
--- @return table | nil A list of database names.
function M.get_databases()
    local key, dir = active_catalog()
    if not key then return nil end
    local summary_file = dir .. "/data.lua"
    if vim.fn.filereadable(summary_file) == 0 then
        M.warn_if_no_catalog()
        return nil
    end
    load_databases(key, summary_file)

    local filter_db = config.options.filter_db
    local databases = {}
    local want_all = (filter_db == nil) or (filter_db == "")
    local needle = ""
    if not want_all then
        needle = filter_db:upper()
    end

    for db_name, _ in pairs(Schema.cache.db[key] or {}) do
        if want_all then
            table.insert(databases, db_name)
        else
            if string.find(db_name:upper(), needle, 1, true) then
                table.insert(databases, db_name)
            end
        end
    end

    return databases
end

local function load_tables(key, db_file, db)
    Schema.cache.tb[key] = Schema.cache.tb[key] or {}
    Schema.cache.tb[key][db] = M.cached_read(db_file, dofile)
end

--- Return true if db_name is a the db files, false otherwise
--- @return boolean database + tablename is present.
function M.is_a_table(database, tablename)
    local key, dir = active_catalog()
    if not key then return false end
    local db = database:gsub("%s+", ""):upper()
    local tb = tablename:gsub("%s+", ""):upper()
    local db_file = dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return false end

    load_tables(key, db_file, db)
    local t = Schema.cache.tb[key][db]
    return t and t.is_table and t.is_table[tb]
end

--- Retrieves a list of unique tables from a database-specific CSV file.
--- @param database string The name of the database.
--- @return table | nil A list of table names.
function M.get_tables(database)
    local key, dir = active_catalog()
    if not key then return nil end
    local db = database:gsub("%s+", ""):upper()
    local db_file = dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return nil end

    load_tables(key, db_file, db)

    local tables = {}
    for tb, _ in pairs((Schema.cache.tb[key][db] and Schema.cache.tb[key][db].is_table) or {}) do
        table.insert(tables, tb)
    end
    return tables
end

--- @return boolean col exists
function M.is_a_column(database, tablename, columnname)
    local key, dir = active_catalog()
    if not key then return false end
    local db = database:gsub("%s+", ""):upper()
    local tb = tablename:gsub("%s+", ""):upper()
    local col = columnname:gsub("%s+", ""):upper()
    local db_file = dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return false end

    load_tables(key, db_file, db)
    for _, c in ipairs((Schema.cache.tb[key][db] and Schema.cache.tb[key][db][tb]) or {}) do
        if c:upper() == col then
            return true
        end
    end
    return false
end

function M.get_columns(table_db_tb)
    local key, dir = active_catalog()
    if not key then return {} end
    local seen = {}
    local acc = {}
    for _, item in ipairs(table_db_tb or {}) do
        if item and item.db_name and item.tb_name then
            local db_file = dir .. "/" .. item.db_name .. ".lua"

            if vim.fn.filereadable(db_file) == 0 then goto continue end

            load_tables(key, db_file, item.db_name)

            for _, col in ipairs((Schema.cache.tb[key][item.db_name] and Schema.cache.tb[key][item.db_name][item.tb_name]) or {}) do
                if col ~= "" and not seen[col] then
                    seen[col] = true
                    table.insert(acc, col)
                end
            end
        end
        ::continue::
    end

    return acc
end

--- Runs a Teradata export script and processes the resulting data into structured files.
--- @return nil
function M.export_db_data()
    local current_user = M.get_current_user()
    if not current_user then
        return vim.notify('No Teradata user selected. Use :TDU.', vim.log.levels.WARN)
    end
    local tpt_script = require('vim-teradata.config').get_tpt_script()
    if not tpt_script then
        return vim.notify('TPT export script not found on runtimepath.', vim.log.levels.ERROR)
    end
    local data_tmp = config.options.data_dir
    if data_tmp:find("'", 1, true) then
        return vim.notify("data_dir must not contain a single quote.", vim.log.levels.ERROR)
    end
    local ok, msg = M.check_executables({ 'tbuild' })
    if not ok then return vim.notify(msg, vim.log.levels.ERROR) end

    local key = M.catalog_key(current_user)
    if not key then
        return vim.notify('Selected user has no tdpid; cannot determine its metadata catalog.', vim.log.levels.ERROR)
    end
    if syncing[key] then
        return vim.notify('TDSync already running for ' .. current_user.tdpid, vim.log.levels.WARN)
    end
    local catalog_dir = M.catalog_root() .. '/' .. key
    -- per-catalog scratch dir: the TPT job writes data_tmp.csv into `data_path` (see assumption A1)
    local tmp_dir = data_tmp .. '/_sync/' .. key
    vim.fn.mkdir(tmp_dir, 'p')

    local tbuild_bin = 'tbuild'
    if vim.fn.has('win32') == 1 then
        -- On Windows, tbuild.exe relaunches itself from argv[0], so a bare name
        -- ends up as "tbuild.EXEexe". Pass the full path with a lowercase .exe.
        local resolved = vim.fn.exepath('tbuild')
        if resolved ~= '' then
            tbuild_bin = resolved:gsub('%.EXE$', '.exe')
        end
    end

    local tbuild_command = {
    tbuild_bin, '-f', tpt_script, '-u',
        string.format("user='%s', logon_mech='%s', tdpid='%s', data_path='%s'",
            current_user.user, current_user.log_mech, current_user.tdpid, tmp_dir),
    }

    local data_tmp_file = tmp_dir .. "/data_tmp.csv"
    M.remove_files(data_tmp_file)

    local function on_exit(result)
        vim.schedule(function()
            if result.code ~= 0 then
                syncing[key] = nil
                M.remove_files(data_tmp_file)
                vim.notify("TDSync failed: " .. (result.stderr or result.stdout or "unknown error"), vim.log.levels.ERROR)
                return
            end

            split_data_db_file_to_lua(data_tmp_file, catalog_dir, current_user, function(ok_split)
                syncing[key] = nil
                M.remove_files(data_tmp_file)
                if not ok_split then return end -- the splitter already reported the error

                purge_legacy_flat_catalog()
                warned_missing[key] = nil
                vim.notify(("TDSync: %s completed successfully"):format(current_user.tdpid), vim.log.levels.INFO)

                -- the user may have switched machine while this sync was running:
                -- only refresh diagnostics if the catalog just rebuilt is the active one
                if M.catalog_key() == key then
                    local okd, diag = pcall(require, 'vim-teradata.diagnostics')
                    if okd and diag.invalidate_all then
                        diag.invalidate_all()
                    end
                end
            end)
        end)
    end

    syncing[key] = true
    vim.notify(("TDSync: Syncing %s... (this may take a while)"):format(current_user.tdpid), vim.log.levels.INFO)
    local spawned, err = pcall(vim.system, tbuild_command, { text = true }, on_exit)
    if not spawned then
        syncing[key] = nil
        vim.notify("TDSync failed to start: " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- Gets the full path for a history directory.
--- @param name string The name of the history directory (e.g., 'queries_dir_name').
--- @return string The full, absolute path.
function M.get_history_path(name)
    return config.options.history_dir .. '/' .. config.options[name]
end

--- Extracts the number of rows found from a BTEQ log file.
--- @param log_content table The content of the log file.
--- @return number | nil The number of rows found, or nil if not found.
function M.extract_rows_found(log_content)
    for _, line in ipairs(log_content) do
        local num = line:match('^ %*%*%* Query completed%.%s+(%d+) rows found%.')
        if num then
            return tonumber(num)
        end
    end
    return nil
end

--- Extracts the per-statement "N rows changed" counts from a BTEQ log.
--- @param log_content table list of log lines
--- @return table list of numbers, in statement order
function M.extract_rows_changed(log_content)
    local counts = {}
    for _, line in ipairs(log_content or {}) do
        local n = line:match('%*%*%*%s+Update completed%.%s+(%d+)%s+rows? changed')
            or line:match('%*%*%*%s+Update completed%.%s+One row changed') and '1'
        if n then table.insert(counts, tonumber(n)) end
    end
    return counts
end

--- Replaces placeholder variables in an SQL string.
--- @param sql string The SQL query.
--- @return string The SQL query with variables replaced.
function M.replace_env_vars(sql)
    local clean_sql = sql
    for key, value in pairs(config.options.replacements) do
        clean_sql = vim.fn.substitute(clean_sql, key, value, 'g')
    end
    return clean_sql
end

--- Checks if required external commands are executable.
--- @param commands table A list of command names to check (e.g., {'rg', 'bat'}).
--- @return boolean, string True if all exist, otherwise false and an error message.
function M.check_executables(commands)
    for _, cmd in ipairs(commands) do
        if vim.fn.executable(cmd) == 0 then
            return false, string.format('Error: %s is not installed or not in your PATH.', cmd)
        end
    end
    return true, ""
end

function M.get_current_user()
    if not config.options.current_user_index or not config.options.users[config.options.current_user_index] then
        return nil
    end
    return config.options.users[config.options.current_user_index]
end

function M.load_config()
    local file = config.options.history_dir .. '/users.json'
    if vim.fn.filereadable(file) == 1 then
        local ok, data = pcall(function()
            local content = vim.fn.readfile(file)
            return vim.fn.json_decode(table.concat(content, '\n'))
        end)
        if ok and type(data) == 'table' then
            local existing = {}
            for _, u in ipairs(config.options.users or {}) do
                if u.user and u.tdpid and u.log_mech then
                    existing[u.user .. '\0' .. u.tdpid .. '\0' .. u.log_mech] = u
                end
            end
            config.options.users = data.users or {}
            for _, u in ipairs(config.options.users) do
                local match = existing[u.user .. '\0' .. u.tdpid .. '\0' .. u.log_mech]
                if match and match.catalog and not u.catalog then
                    u.catalog = match.catalog
                end
            end
            config.options.current_user_index = data.current_user_index
        end
    end
end

function M.save_config()
    local file = config.options.history_dir .. '/users.json'
    local data = {
        users = config.options.users,
        current_user_index = config.options.current_user_index,
    }
    vim.fn.writefile({ vim.fn.json_encode(data) }, file)
end

function M.prune_history()
    local max = config.options.history_max
    if not max or max <= 0 then return end
    local keep = {}
    for _, j in ipairs(M.jobs_all()) do
        if j.status == 'running' then
            if j.query_path then keep[vim.fs.basename(j.query_path)] = true end
            if j.result_path then keep[vim.fs.basename(j.result_path)] = true end
        end
    end
    for _, name in ipairs({ 'queries_dir_name', 'resultsets_dir_name' }) do
        local dir = M.get_history_path(name)
        local files = vim.fn.readdir(dir)
        table.sort(files) -- ids start with a timestamp: lexical == chronological
        for i = 1, #files - max do
            if not keep[files[i]] then vim.uv.fs_unlink(dir .. '/' .. files[i]) end
        end
    end
end

function M.formatString(s, width)
    local len = #s
    if len >= width then
        return s
    end
    local padding = string.rep(' ', width - len)
    return padding .. s
end

--- Generates a unique query ID based on timestamp and a sequence/clock suffix.
--- @return string The unique ID.
local _seq = 0
function M.get_unique_query_id()
    _seq = _seq + 1
    local us = math.floor(vim.uv.hrtime() / 1000)
    return ('%s%02d%02d'):format(os.date('%Y%m%d%H%M%S_'), us % 100, _seq % 100)
end

-----------------------------------------------------------------------
-- In-memory Jobs Registry
-----------------------------------------------------------------------
local _jobs = {}

function M.jobs_add(job)
    _jobs[job.id] = job
    return job.id
end

function M.jobs_update(id, fields)
    local j = _jobs[id]
    if not j then return end
    for k, v in pairs(fields) do
        j[k] = v
    end
end

function M.jobs_get(id)
    return _jobs[id]
end

function M.jobs_all()
    local arr = {}
    for _, j in pairs(_jobs) do
        table.insert(arr, j)
    end
    table.sort(arr, function(a, b)
        return (a.started_at or 0) > (b.started_at or 0)
    end)
    return arr
end

function M.jobs_remove(id)
    local j = _jobs[id]
    _jobs[id] = nil
    return j
end

function M.jobs_cancel(id)
    local j = _jobs[id]
    if not j or j.status ~= 'running' or not j.handle then return false end
    -- Mark first so the exit callback sees 'canceled' and skips result handling.
    j.status = 'canceled'
    j.finished_at = os.time()
    j.message = 'Canceled'
    local ok = pcall(function() j.handle:kill(15) end) -- SIGTERM
    if not ok then
        j.status, j.finished_at, j.message = 'running', nil, 'Started'
    end
    return ok
end

return M
