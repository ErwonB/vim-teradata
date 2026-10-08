local config = require('vim-teradata.config')
local M = {}

local Schema = {
    cache = {}
}

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
--- @param on_done function|nil
--- @return nil
local function split_data_db_file_to_lua(on_done)
    local input_filename = config.options.data_dir .. "/data_tmp.csv"
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local summary_filename = data_files_dir .. "/data.lua"

    -- Ensure output directory exists
    local function ensure_dir(path)
        if vim.fn.isdirectory(path) == 0 then
            vim.fn.mkdir(path, "p")
        end
    end
    ensure_dir(data_files_dir)

    local input_file = io.open(input_filename, "r")
    if not input_file then
        if on_done then on_done() end
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

        -- Write summary file
        local summary_file = io.open(summary_filename, "w")
        if summary_file then
            summary_file:write("-- Auto-generated. Do not edit.\n")
            summary_file:write("return {\n")
            for _, db_name in ipairs(sorted_keys(unique_dbs)) do
                summary_file:write(string.format('  ["%s"] = true,\n', escape_lua_string(db_name)))
            end
            summary_file:write("}\n")
            summary_file:close()
        else
            vim.notify("Error: Could not write summary file: " .. summary_filename, vim.log.levels.ERROR)
        end

        if on_done then on_done() end
    end)
end

local function load_databases(summary_file)
    Schema.cache.db = M.cached_read(summary_file, dofile)
end

--- Return true if db_name is in the db file, false otherwise
--- @return boolean db_name is present.
function M.is_a_db(db_name)
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local summary_file = data_files_dir .. "/data.lua"
    if vim.fn.filereadable(summary_file) == 0 then return false end
    if not Schema.cache.db then
        load_databases(summary_file)
    end
    return Schema.cache.db[db_name:upper()]
end

--- Retrieves a list of available databases from a summary CSV file.
--- @return table | nil A list of database names.
function M.get_databases()
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local summary_file = data_files_dir .. "/data.lua"
    if vim.fn.filereadable(summary_file) == 0 then return nil end
    if not Schema.cache.db then
        load_databases(summary_file)
    end

    local filter_db = config.options.filter_db
    local databases = {}
    local want_all = (filter_db == nil) or (filter_db == "")
    local needle = ""
    if not want_all then
        needle = filter_db:upper()
    end

    for db_name, _ in pairs(Schema.cache.db or {}) do
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

local function load_tables(db_file, db)
    if not Schema.cache.tb then
        Schema.cache.tb = {}
    end
    Schema.cache.tb[db] = M.cached_read(db_file, dofile)
end

--- Return true if db_name is a the db files, false otherwise
--- @return boolean database + tablename is present.
function M.is_a_table(database, tablename)
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local db = database:gsub("%s+", ""):upper()
    local tb = tablename:gsub("%s+", ""):upper()
    local db_file = data_files_dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return false end

    load_tables(db_file, db)
    return Schema.cache.tb[db] and Schema.cache.tb[db].is_table and Schema.cache.tb[db].is_table[tb]
end

--- Retrieves a list of unique tables from a database-specific CSV file.
--- @param database string The name of the database.
--- @return table | nil A list of table names.
function M.get_tables(database)
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local db = database:gsub("%s+", ""):upper()
    local db_file = data_files_dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return nil end

    load_tables(db_file, db)

    local tables = {}
    for tb, _ in pairs((Schema.cache.tb[db] and Schema.cache.tb[db].is_table) or {}) do
        table.insert(tables, tb)
    end
    return tables
end

--- @return boolean col exists
function M.is_a_column(database, tablename, columnname)
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local db = database:gsub("%s+", ""):upper()
    local tb = tablename:gsub("%s+", ""):upper()
    local col = columnname:gsub("%s+", ""):upper()
    local db_file = data_files_dir .. "/" .. db .. ".lua"

    if vim.fn.filereadable(db_file) == 0 then return false end

    load_tables(db_file, db)
    for _, c in ipairs((Schema.cache.tb[db] and Schema.cache.tb[db][tb]) or {}) do
        if c:upper() == col then
            return true
        end
    end
    return false
end

function M.get_columns(table_db_tb)
    local data_files_dir = config.options.data_dir .. "/" .. config.options.data_completion_dir
    local seen = {}
    local acc = {}
    for _, item in ipairs(table_db_tb or {}) do
        if item and item.db_name and item.tb_name then
            local db_file = data_files_dir .. "/" .. item.db_name .. ".lua"

            if vim.fn.filereadable(db_file) == 0 then goto continue end

            load_tables(db_file, item.db_name)

            for _, col in ipairs((Schema.cache.tb[item.db_name] and Schema.cache.tb[item.db_name][item.tb_name]) or {}) do
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

    local tbuild_command = {
        'tbuild', '-f', tpt_script, '-u',
        string.format("user='%s', logon_mech='%s', tdpid='%s', data_path='%s'",
            current_user.user, current_user.log_mech, current_user.tdpid, data_tmp),
    }

    local data_tmp_file = data_tmp .. "/data_tmp.csv"
    M.remove_files(data_tmp_file)

    vim.notify("TDSync: Syncing databases... (this may take a while)", vim.log.levels.INFO)

    vim.system(tbuild_command, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                vim.notify("TDSync failed: " .. (result.stderr or result.stdout or "unknown error"), vim.log.levels.ERROR)
                return
            end

            split_data_db_file_to_lua(function()
                M.remove_files(data_tmp_file)
                vim.notify("TDSync: Completed successfully", vim.log.levels.INFO)
                local okd, diag = pcall(require, 'vim-teradata.diagnostics')
                if okd and diag.invalidate_all then
                    diag.invalidate_all()
                end
            end)
        end)
    end)
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
            config.options.users = data.users or {}
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
