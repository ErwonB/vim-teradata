local config = require('vim-teradata.config')
local M = {}

-- cache.db[key]      -> { DB_NAME = true, ... }                      (data.lua of that catalog)
-- cache.tb[key][DB]  -> { is_table = {...}, TABLE = { cols... } }    (<DB>.lua of that catalog)
local Schema = {
    cache = { db = {}, tb = {} },
    session = {}, -- [catalog_key][NAME] = { columns = {...}, source = 'buffer'|'server' }
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

--- Strips leading whitespace, `-- line` comments and `/* block */` comments.
--- @param s string
--- @return string
function M.strip_leading_noise(s)
    while true do
        local before = s
        s = s:gsub('^%s+', '')
        s = s:gsub('^%-%-[^\n]*', '')
        s = s:gsub('^/%*.-%*/', '')
        if s == before then return s end
    end
end

--- Human-readable byte size (1024-based, one decimal under 10).
--- @param n number
--- @return string
function M.human_bytes(n)
    n = tonumber(n) or 0
    local units = { 'B', 'KB', 'MB', 'GB', 'TB', 'PB' }
    local i = 1
    while n >= 1024 and i < #units do
        n = n / 1024
        i = i + 1
    end
    if i == 1 then return ('%d B'):format(n) end
    if n < 10 then return ('%.1f %s'):format(n, units[i]) end
    return ('%d %s'):format(math.floor(n + 0.5), units[i])
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

--- Replace `final` with the contents of `staging`.
--- Directory renames are fragile on Windows (AV/indexer handles, existing target), so fall
--- back to moving files one by one if the fast path fails.
--- @return boolean ok, string|nil err
local function swap_dir(staging, final)
    -- best effort: a locked file here is not fatal, the fallback below overwrites in place
    if vim.fn.isdirectory(final) == 1 then
        vim.fn.delete(final, "rf")
    end

    -- fast path (works when `final` is gone)
    local ok, err = vim.uv.fs_rename(staging, final)
    if ok then return true end

    -- fallback: file by file (rename, or copy if the rename is refused)
    vim.fn.mkdir(final, "p")
    for name, kind in vim.fs.dir(staging) do
        if kind == "file" then
            local src, dst = staging .. "/" .. name, final .. "/" .. name
            local okf, ferr = vim.uv.fs_rename(src, dst)
            if not okf then
                okf, ferr = vim.uv.fs_copyfile(src, dst)
            end
            if not okf then
                return false, ferr or err
            end
        end
    end
    vim.fn.delete(staging, "rf")
    return true
end

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

local function parse_export_line(raw, per_db, unique_dbs)
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
            if unique_dbs then unique_dbs[db] = true end
        else
            vim.notify("Warning: Malformed line: " .. line, vim.log.levels.WARN)
        end
    end
end

local function parse_export_lines(lines)
    local per_db = {}
    local unique_dbs = {}
    for _, raw in ipairs(lines or {}) do
        parse_export_line(raw, per_db, unique_dbs)
    end
    return per_db, unique_dbs
end

local function write_db_file(db_filename, tables, atomic)
    local target = atomic and (db_filename .. ".tmp") or db_filename
    local is_table = {}
    table.insert(is_table, "is_table = {")
    local f = io.open(target, "w")
    if not f then
        vim.notify("Error: Could not write file: " .. db_filename, vim.log.levels.ERROR)
        return false
    end
    f:write("-- Auto-generated. Do not edit.\n")
    f:write("return {\n")
    for _, tname in ipairs(sorted_keys(tables)) do
        table.insert(is_table, string.format('  ["%s"] = true,', escape_lua_string(tname)))
        local cols = vim.deepcopy(tables[tname])
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
    if atomic then
        local ok, err = vim.uv.fs_rename(target, db_filename)
        if not ok then
            vim.fn.delete(target)
            vim.notify("Error: Could not rename file: " .. tostring(err), vim.log.levels.ERROR)
            return false
        end
    end
    _cache[db_filename] = nil
    return true
end

local function write_summary(summary_filename, dbs_set, atomic)
    local target = atomic and (summary_filename .. ".tmp") or summary_filename
    local summary_file = io.open(target, "w")
    if not summary_file then
        return false
    end
    summary_file:write("-- Auto-generated. Do not edit.\n")
    summary_file:write("return {\n")
    for _, db_name in ipairs(sorted_keys(dbs_set)) do
        summary_file:write(string.format('  ["%s"] = true,\n', escape_lua_string(db_name)))
    end
    summary_file:write("}\n")
    summary_file:close()
    if atomic then
        local ok = vim.uv.fs_rename(target, summary_filename)
        if not ok then
            vim.fn.delete(target)
            return false
        end
    end
    _cache[summary_filename] = nil
    return true
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

    -- Accumulators
    local per_db = {}     -- db -> table -> {columns}
    local unique_dbs = {} -- db -> true

    -- Parse lines
    process_in_chunks(lines, 5000, function(raw)
        parse_export_line(raw, per_db, unique_dbs)
    end, function()
        -- Write per-db files
        for db_name, tables in pairs(per_db) do
            local db_filename = data_files_dir .. "/" .. db_name .. ".lua"
            write_db_file(db_filename, tables, false)
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
        if not write_summary(summary_filename, unique_dbs, false) then
            return fail("Error: Could not write summary file: " .. summary_filename)
        end

        -- Write meta file (used by :checkhealth and anything showing "last synced")
        local meta_file = io.open(data_files_dir .. "/meta.lua", "w")
        if meta_file then
            meta_file:write("-- Auto-generated. Do not edit.\n")
            meta_file:write(string.format("return { synced_at = %d, tdpid = %q, user = %q }\n",
                os.time(), user.tdpid or "", user.user or ""))
            meta_file:close()
        end

        -- Swap staging -> final (drops databases that no longer exist on the server)
        local swapped, swap_err = swap_dir(data_files_dir, catalog_dir)
        if not swapped then
            return fail(("Error: Could not move the new catalog into place: %s (%s)")
                :format(catalog_dir, tostring(swap_err)))
        end

        -- Clear _cache for rewritten files in catalog_dir
        _cache = {}

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
        elseif item and not item.db_name and item.tb_name then
            local sess = M.get_session_table(item.tb_name)
            if sess and sess.columns then
                for _, c in ipairs(sess.columns) do
                    local col = type(c) == "table" and c.name or c
                    if col and col ~= "" and not seen[col] then
                        seen[col] = true
                        table.insert(acc, col)
                    end
                end
            end
        end
        ::continue::
    end

    return acc
end

-----------------------------------------------------------------------
-- Session-only volatile/temporary tables registry
-----------------------------------------------------------------------

function M.get_session_table(name)
    local key = M.catalog_key()
    if not key or not name then return nil end
    local t = Schema.session[key]
    return t and t[name:upper()]
end

function M.set_session_table(name, columns, source)
    local key = M.catalog_key()
    if not key or not name then return false end
    Schema.session[key] = Schema.session[key] or {}
    local norm_cols = {}
    for _, c in ipairs(columns or {}) do
        local cname = type(c) == "table" and c.name or c
        if cname and cname ~= "" then
            table.insert(norm_cols, tostring(cname):upper())
        end
    end
    Schema.session[key][name:upper()] = {
        columns = norm_cols,
        source = source or 'buffer',
    }
    local okd, diag = pcall(require, 'vim-teradata.diagnostics')
    if okd and diag.invalidate_all then diag.invalidate_all() end
    return true
end

function M.delete_session_table(name)
    local key = M.catalog_key()
    if not key or not name then return false end
    local t = Schema.session[key]
    local up = name:upper()
    if not (t and t[up]) then return false end
    t[up] = nil
    local okd, diag = pcall(require, 'vim-teradata.diagnostics')
    if okd and diag.invalidate_all then diag.invalidate_all() end
    return true
end

function M.list_session_tables()
    local key = M.catalog_key()
    if not key then return {} end
    local t = Schema.session[key]
    if not t then return {} end
    return sorted_keys(t)
end

local function invalidate_catalog_cache(key, affected_dbs)
    Schema.cache.db[key] = nil
    if affected_dbs then
        for db in pairs(affected_dbs) do
            if Schema.cache.tb[key] then Schema.cache.tb[key][db] = nil end
        end
    else
        Schema.cache.tb[key] = nil
    end
    if M.catalog_key() == key then
        local okd, diag = pcall(require, 'vim-teradata.diagnostics')
        if okd and diag.invalidate_all then
            diag.invalidate_all()
        end
    end
end

local function write_meta_partial(catalog_dir, user)
    local meta_path = catalog_dir .. "/meta.lua"
    local existing = {}
    local ok, loaded = pcall(dofile, meta_path)
    if ok and type(loaded) == "table" then existing = loaded end

    local synced_at_str = existing.synced_at and tostring(existing.synced_at) or "nil"
    local tdpid = user and user.tdpid or existing.tdpid or ""
    local uname = user and user.user or existing.user or ""
    local tmp = meta_path .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write("-- Auto-generated. Do not edit.\n")
        f:write(string.format("return { synced_at = %s, partial_synced_at = %d, tdpid = %q, user = %q }\n",
            synced_at_str, os.time(), tdpid, uname))
        f:close()
        if not vim.uv.fs_rename(tmp, meta_path) then
            vim.fn.delete(tmp)
        end
        _cache[meta_path] = nil
    end
end

--- Merges fetched/deleted objects into an on-disk catalog directory.
--- @param catalog_dir string
--- @param fetched table  per_db from parse_export_lines (may be empty)
--- @param requested table  parsed targets
--- @param mode 'add'|'update'|'delete'
--- @param user table|nil
--- @return { added:string[], updated:string[], removed:string[], missing:string[], affected_dbs:table<string,boolean> }
local function merge_into_catalog(catalog_dir, fetched, requested, mode, user)
    fetched = fetched or {}
    requested = requested or {}
    vim.fn.mkdir(catalog_dir, "p")

    local summary_path = catalog_dir .. "/data.lua"
    local dbs_set = {}
    if vim.fn.filereadable(summary_path) == 1 then
        local ok, loaded = pcall(dofile, summary_path)
        if ok and type(loaded) == "table" then
            for k, v in pairs(loaded) do
                if v == true then dbs_set[k] = true end
            end
        end
    end

    local affected_dbs = {}
    local req_by_db = {}
    for _, t in ipairs(requested) do
        if t.db then
            affected_dbs[t.db] = true
            req_by_db[t.db] = req_by_db[t.db] or { all = false, names = {} }
            if t.all then
                req_by_db[t.db].all = true
            elseif t.name then
                req_by_db[t.db].names[t.name] = true
            end
        end
    end
    for db in pairs(fetched) do
        affected_dbs[db] = true
    end

    local added, updated, removed, missing = {}, {}, {}, {}

    for _, db in ipairs(sorted_keys(affected_dbs)) do
        local db_file = catalog_dir .. "/" .. db .. ".lua"
        local current_tables = {}
        local had_db_file = (vim.fn.filereadable(db_file) == 1)
        if had_db_file then
            local ok, loaded = pcall(dofile, db_file)
            if ok and type(loaded) == "table" then
                for k, v in pairs(loaded) do
                    if k ~= "is_table" and type(v) == "table" then
                        current_tables[k] = v
                    end
                end
            end
        end

        local f_tables = fetched[db] or {}
        local req = req_by_db[db] or { all = false, names = {} }

        if mode == 'add' then
            for _, tname in ipairs(sorted_keys(f_tables)) do
                if current_tables[tname] then
                    table.insert(updated, db .. "." .. tname)
                else
                    table.insert(added, db .. "." .. tname)
                end
                current_tables[tname] = f_tables[tname]
            end
            if req.all then
                if next(f_tables) == nil then
                    table.insert(missing, db .. ".*")
                end
            else
                for _, tname in ipairs(sorted_keys(req.names)) do
                    if not f_tables[tname] then
                        table.insert(missing, db .. "." .. tname)
                    end
                end
            end
        elseif mode == 'update' then
            if req.all then
                for _, tname in ipairs(sorted_keys(current_tables)) do
                    if not f_tables[tname] then
                        table.insert(removed, db .. "." .. tname)
                    end
                end
                for _, tname in ipairs(sorted_keys(f_tables)) do
                    if current_tables[tname] then
                        table.insert(updated, db .. "." .. tname)
                    else
                        table.insert(added, db .. "." .. tname)
                    end
                end
                current_tables = vim.deepcopy(f_tables)
                if next(f_tables) == nil and not had_db_file then
                    table.insert(missing, db .. ".*")
                end
            else
                for _, tname in ipairs(sorted_keys(f_tables)) do
                    if current_tables[tname] then
                        table.insert(updated, db .. "." .. tname)
                    else
                        table.insert(added, db .. "." .. tname)
                    end
                    current_tables[tname] = f_tables[tname]
                end
                for _, tname in ipairs(sorted_keys(req.names)) do
                    if not f_tables[tname] then
                        if current_tables[tname] then
                            current_tables[tname] = nil
                            table.insert(removed, db .. "." .. tname)
                        else
                            table.insert(missing, db .. "." .. tname)
                        end
                    end
                end
            end
        elseif mode == 'delete' then
            if req.all then
                if had_db_file and next(current_tables) ~= nil then
                    for _, tname in ipairs(sorted_keys(current_tables)) do
                        table.insert(removed, db .. "." .. tname)
                    end
                    current_tables = {}
                else
                    table.insert(missing, db .. ".*")
                end
            else
                for _, tname in ipairs(sorted_keys(req.names)) do
                    if current_tables[tname] then
                        current_tables[tname] = nil
                        table.insert(removed, db .. "." .. tname)
                    else
                        table.insert(missing, db .. "." .. tname)
                    end
                end
            end
        end

        if next(current_tables) == nil then
            if vim.fn.filereadable(db_file) == 1 then
                vim.fn.delete(db_file)
            end
            _cache[db_file] = nil
            dbs_set[db] = nil
        else
            write_db_file(db_file, current_tables, true)
            dbs_set[db] = true
        end
    end

    write_summary(summary_path, dbs_set, true)
    write_meta_partial(catalog_dir, user)

    return {
        added = added,
        updated = updated,
        removed = removed,
        missing = missing,
        affected_dbs = affected_dbs,
    }
end

function M.tbuild_bin()
    local bin = 'tbuild'
    if vim.fn.has('win32') == 1 then
        -- On Windows, tbuild.exe relaunches itself from argv[0], so a bare name
        -- ends up as "tbuild.EXEexe". Pass the full path with a lowercase .exe.
        local resolved = vim.fn.exepath('tbuild')
        if resolved ~= '' then
            bin = resolved:gsub('%.EXE$', '.exe')
        end
    end
    return bin
end
local tbuild_bin = M.tbuild_bin

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

    local tbuild_command = {
        tbuild_bin(), '-f', tpt_script, '-u',
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
                vim.notify("TDSync failed: " .. (result.stderr or result.stdout or "unknown error"), vim.log.levels
                    .ERROR)
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

-----------------------------------------------------------------------
-- Incremental TDSync (add / update / delete)
-----------------------------------------------------------------------

--- Resolves an `object_reference` TSNode into (db, name).
--- @param obj_ref TSNode
--- @param source integer|string
--- @return string|nil db, string|nil name
function M.resolve_object_reference(obj_ref, source)
    if not obj_ref then return nil, nil end
    source = source or 0
    local tsu = require('vim-teradata.ts-util')
    local function ntext(n)
        if not n then return nil end
        local ok, txt = pcall(vim.treesitter.get_node_text, n, source)
        return ok and txt or nil
    end

    local db_node     = tsu.child_by_field(obj_ref, 'database')
    local schema_node = tsu.child_by_field(obj_ref, 'schema')
    local name_node   = tsu.child_by_field(obj_ref, 'name')

    local db   = schema_node and ntext(schema_node) or nil
    local name = name_node and ntext(name_node) or nil

    if not db_node and not schema_node and not name_node then
        local ids = {}
        for child in obj_ref:iter_children() do
            if child:type() == 'identifier' then table.insert(ids, child) end
        end
        if #ids == 1 then
            name = ntext(ids[1])
        elseif #ids == 2 then
            db, name = ntext(ids[1]), ntext(ids[2])
        elseif #ids >= 3 then
            db, name = ntext(ids[#ids - 1]), ntext(ids[#ids])
        end
    end
    return db, name
end

--- Extracts object name token(s) from visual range or cursor node.
--- @param args table|nil
--- @return string[]
function M.names_from_context(args)
    if args and args.range and args.range > 0 then
        local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
        if s[2] == args.line1 and e[2] == args.line2 and args.line1 == args.line2 and s[3] > 0 and e[3] > 0 then
            local line = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line1, false)[1] or ""
            return { line:sub(s[3], e[3]) }
        end
        return vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
    if ok and node then
        local tsu = require('vim-teradata.ts-util')
        local obj_ref = tsu.ancestor(node, 'object_reference')
        if obj_ref then
            local db, name = M.resolve_object_reference(obj_ref, bufnr)
            if db and name then
                return { db .. "." .. name }
            elseif name then
                return { name }
            end
        end
    end

    local cword = vim.fn.expand('<cWORD>')
    if cword and cword ~= '' then
        cword = cword:gsub('^[%(,;]+', ''):gsub('[%),;]+$', '')
        if cword ~= '' then return { cword } end
    end
    return {}
end

local function is_valid_td_ident(s)
    return type(s) == 'string' and s:match('^[%w_$#]+$') ~= nil
end

--- Parses a list of raw object name strings into validated target descriptors.
--- @param list string[]
--- @return table[] targets, string[] errs
function M.parse_object_names(list)
    local targets = {}
    local errs = {}
    local seen = {}

    for _, raw_entry in ipairs(list or {}) do
        for token in tostring(raw_entry):gmatch('[^%s,]+') do
            local resolved = M.replace_env_vars(token)
            local raw_parts = vim.split(resolved, '.', { plain = true })
            local parts = {}
            for _, p in ipairs(raw_parts) do
                p = p:gsub('^"(.*)"$', '%1')
                table.insert(parts, p)
            end

            -- 3-part names: keep the last two parts
            if #parts >= 3 then
                parts = { parts[#parts - 1], parts[#parts] }
            end

            if #parts == 1 then
                local name = parts[1]
                if not is_valid_td_ident(name) then
                    table.insert(errs, token)
                else
                    local up = name:upper()
                    local k = "S:" .. up
                    if not seen[k] then
                        seen[k] = true
                        table.insert(targets, { session = true, name = up })
                    end
                end
            elseif #parts == 2 then
                local db, name = parts[1], parts[2]
                if not is_valid_td_ident(db) then
                    table.insert(errs, token)
                elseif name == '*' then
                    local up_db = db:upper()
                    local k = "D:" .. up_db .. ":*"
                    if not seen[k] then
                        seen[k] = true
                        table.insert(targets, { db = up_db, all = true })
                    end
                elseif not is_valid_td_ident(name) then
                    table.insert(errs, token)
                else
                    local up_db, up_name = db:upper(), name:upper()
                    local k = "O:" .. up_db .. "." .. up_name
                    if not seen[k] then
                        seen[k] = true
                        table.insert(targets, { db = up_db, name = up_name })
                    end
                end
            else
                table.insert(errs, token)
            end
        end
    end

    return targets, errs
end

--- Builds the SELECT statement for export_objects.tpt from a list of DB targets.
--- @param db_targets table[]
--- @return string
function M.build_objects_select_stmt(db_targets)
    local by_db = {}
    local db_order = {}
    for _, t in ipairs(db_targets or {}) do
        if t.db then
            if not by_db[t.db] then
                by_db[t.db] = { all = false, names = {} }
                table.insert(db_order, t.db)
            end
            if t.all then
                by_db[t.db].all = true
            elseif t.name then
                add_unique(by_db[t.db].names, t.name)
            end
        end
    end
    table.sort(db_order)

    local clauses = {}
    for _, db in ipairs(db_order) do
        local info = by_db[db]
        if info.all then
            table.insert(clauses, string.format("(t.DatabaseName = '%s')", db))
        elseif #info.names > 0 then
            table.sort(info.names)
            local quoted = {}
            for _, n in ipairs(info.names) do
                table.insert(quoted, string.format("'%s'", n))
            end
            table.insert(clauses, string.format("(t.DatabaseName = '%s' and t.TableName in (%s))",
                db, table.concat(quoted, ",")))
        end
    end

    local pred = #clauses > 0 and table.concat(clauses, "\n     or ") or "1=0"
    return string.format([[lock row for access
select upper(trim(c.DatabaseName) || ',' || trim(c.TableName) || ',' || trim(c.ColumnName))
from DBC.TablesV t
join DBC.ColumnsV c
  on t.DatabaseName = c.DatabaseName and t.TableName = c.TableName
where t.TableKind in ('T','V','M','O','Q')
  and ( %s )
order by c.DatabaseName, c.TableName, c.ColumnId;]], pred)
end

local function format_sync_summary(stats)
    local parts = {}
    local n_add = #(stats.added or {})
    local n_upd = #(stats.updated or {})
    local n_rem = #(stats.removed or {})
    local missing = stats.missing or {}

    if n_add > 0 then table.insert(parts, string.format("+%d added", n_add)) end
    if n_upd > 0 then table.insert(parts, string.format("~%d updated", n_upd)) end
    if n_rem > 0 then table.insert(parts, string.format("-%d removed", n_rem)) end
    if #parts == 0 then table.insert(parts, "0 changed") end

    local msg = "TDSync: " .. table.concat(parts, ", ")
    if #missing > 0 then
        msg = msg .. string.format(" (%s not found)", table.concat(missing, ", "))
    end
    return msg
end

local function find_create_volatile_stmt_text(bufnr, target_name)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "teradata")
    if not ok or not parser then return nil end
    local parse_ok, trees = pcall(function() return parser:parse() end)
    if not parse_ok or not trees or #trees == 0 then return nil end

    local diag = require('vim-teradata.diagnostics')
    local tsu = require('vim-teradata.ts-util')
    if not diag.QUERIES.create_table then return nil end

    for _, tree in ipairs(trees) do
        local root = tree:root()
        for _, ct_node in diag.QUERIES.create_table:iter_captures(root, bufnr, 0, -1) do
            local obj_ref = tsu.child_by_type(ct_node, "object_reference")
            if obj_ref then
                local db, name = M.resolve_object_reference(obj_ref, bufnr)
                if not db and name and name:upper() == target_name:upper() then
                    local stmt_node = tsu.ancestor(ct_node, "statement") or ct_node
                    local txt = diag.get_text(stmt_node, bufnr)
                    if txt then
                        txt = txt:gsub(";%s*$", "")
                        -- Rewrite WITH DATA -> WITH NO DATA if AS SELECT
                        if tsu.child_by_type(ct_node, "create_query") or tsu.child_by_type(ct_node, "keyword_as") then
                            if txt:match("(?i)with%s+data") or txt:lower():match("with%s+data") then
                                txt = txt:gsub("[Ww][Ii][Tt][Hh]%s+[Dd][Aa][Tt][Aa]", "WITH NO DATA")
                            elseif not txt:lower():match("with%s+no%s+data") then
                                txt = txt .. " WITH NO DATA"
                            end
                        end
                        return txt
                    end
                end
            end
        end
    end
    return nil
end

local function handle_session_targets(session_targets, mode, bang, bufnr)
    local added, updated, removed, missing = {}, {}, {}, {}
    if #session_targets == 0 then
        return { added = added, updated = updated, removed = removed, missing = missing }
    end

    local diag = require('vim-teradata.diagnostics')
    local local_tables = diag.collect_buffer_created_tables(bufnr)

    for _, t in ipairs(session_targets) do
        local name = t.name:upper()
        local existed = M.get_session_table(name) ~= nil

        if mode == 'delete' then
            if M.delete_session_table(name) then
                table.insert(removed, name)
            else
                table.insert(missing, name)
            end
        elseif bang then
            -- Fallback via BTEQ (:TDSync add! vt_name)
            local create_sql = find_create_volatile_stmt_text(bufnr, name)
            if not create_sql then
                vim.notify("TDSync: no CREATE VOLATILE TABLE " .. name:lower() .. " in this buffer", vim.log.levels.ERROR)
                table.insert(missing, name)
            else
                local bteq = require('vim-teradata.bteq')
                local sql = create_sql .. ";\nHELP COLUMN " .. name .. ".*;"
                bteq._run_single_query(sql, 'output', function(res, context)
                    local result_path = context and context.result_path
                    if res.rc == 0 and result_path and vim.fn.filereadable(result_path) == 1 then
                        local lines = vim.fn.readfile(result_path)
                        local sep = vim.fn.escape(config.options.sep or '~', "|.*+?^$(){}[]\\`~")
                        local cols = {}
                        for i = 2, #lines do
                            if lines[i] ~= '' then
                                local fields = vim.fn.split(lines[i], sep)
                                local cname = fields[1] and trim(fields[1]) or nil
                                if cname and cname ~= '' then
                                    table.insert(cols, cname:upper())
                                end
                            end
                        end
                        if #cols > 0 then
                            M.set_session_table(name, cols, 'server')
                            vim.notify(string.format("TDSync: %s session table %s (%d columns from server)",
                                existed and "updated" or "added", name, #cols), vim.log.levels.INFO)
                        else
                            vim.notify("TDSync: HELP COLUMN returned no columns for " .. name, vim.log.levels.WARN)
                        end
                    else
                        vim.notify("TDSync: failed to resolve volatile table " .. name .. " on server", vim.log.levels.ERROR)
                    end
                    if result_path then M.remove_files(result_path) end
                end, { session_buf = -1 })
            end
        else
            local entry = local_tables[name]
            if entry and entry.columns and #entry.columns > 0 then
                M.set_session_table(name, entry.columns, 'buffer')
                if existed then
                    table.insert(updated, name)
                else
                    table.insert(added, name)
                end
            else
                if mode == 'update' and existed then
                    M.delete_session_table(name)
                    table.insert(removed, name)
                else
                    table.insert(missing, name)
                end
            end
        end
    end

    return { added = added, updated = updated, removed = removed, missing = missing }
end

function M.sync_complete(arglead, cmdline)
    local subcommands = { 'add', 'update', 'delete' }
    local before = cmdline:sub(1, #cmdline - #arglead)
    -- Strip leading range/marks and command name
    local after_cmd = before:gsub("^%s*:'<,'>%s*", ""):gsub("^%s*:%d*,?%d*%s*", ""):gsub("^%s*[Tt][Dd][Ss][Yy][Nn][Cc]!?%s+", "")

    -- If no subcommand has been completed yet, complete subcommands
    if after_cmd == before or after_cmd:match("^%s*$") then
        local out = {}
        for _, s in ipairs(subcommands) do
            if vim.startswith(s:upper(), arglead:upper()) then
                table.insert(out, s)
            end
        end
        return out
    end

    local candidates = {}
    local dot_pos = arglead:find('.', 1, true)
    if dot_pos then
        local db_prefix = arglead:sub(1, dot_pos - 1):upper()
        table.insert(candidates, db_prefix .. ".*")
        local tbls = M.get_tables(db_prefix) or {}
        table.sort(tbls)
        for _, tb in ipairs(tbls) do
            table.insert(candidates, db_prefix .. "." .. tb)
        end
    else
        local dbs = M.get_databases() or {}
        table.sort(dbs)
        for _, db in ipairs(dbs) do
            table.insert(candidates, db .. ".")
        end
        for _, vt in ipairs(M.list_session_tables()) do
            table.insert(candidates, vt)
        end
    end

    local out = {}
    local lead_up = arglead:upper()
    for _, item in ipairs(candidates) do
        if vim.startswith(item:upper(), lead_up) then
            table.insert(out, item)
        end
    end
    return out
end

function M.sync_command(args)
    args = args or {}
    local fargs = args.fargs or {}
    local sub = fargs[1]
    if not sub then
        return M.export_db_data()
    end
    sub = sub:lower()
    if not vim.tbl_contains({ 'add', 'update', 'delete' }, sub) then
        return vim.notify('TDSync: unknown subcommand ' .. sub, vim.log.levels.ERROR)
    end

    local raw = vim.list_slice(fargs, 2)
    if #raw == 0 then
        raw = M.names_from_context(args)
    end
    if #raw == 0 then
        return vim.notify('TDSync ' .. sub .. ': no object names specified or found at cursor.', vim.log.levels.WARN)
    end

    local targets, errs = M.parse_object_names(raw)
    if #errs > 0 then
        return vim.notify('TDSync: invalid object name(s): ' .. table.concat(errs, ', '), vim.log.levels.ERROR)
    end
    if #targets == 0 then
        return vim.notify('TDSync ' .. sub .. ': no valid targets.', vim.log.levels.WARN)
    end

    local current_user = M.get_current_user()
    if not current_user then
        return vim.notify('No Teradata user selected. Use :TDU.', vim.log.levels.WARN)
    end
    local key = M.catalog_key(current_user)
    if not key then
        return vim.notify('Selected user has no tdpid; cannot determine its metadata catalog.', vim.log.levels.ERROR)
    end

    local session_targets = {}
    local db_targets = {}
    for _, t in ipairs(targets) do
        if t.session then
            table.insert(session_targets, t)
        else
            table.insert(db_targets, t)
        end
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local sess_stats = handle_session_targets(session_targets, sub, args.bang, bufnr)

    if #db_targets == 0 then
        if not args.bang or sub == 'delete' then
            vim.notify(format_sync_summary(sess_stats), vim.log.levels.INFO)
        end
        return
    end

    if syncing[key] then
        return vim.notify('TDSync already running for ' .. current_user.tdpid, vim.log.levels.WARN)
    end

    local catalog_dir = M.catalog_root() .. '/' .. key
    local had_catalog = M.has_catalog(current_user)

    if sub == 'delete' then
        local db_stats = merge_into_catalog(catalog_dir, {}, db_targets, 'delete', current_user)
        invalidate_catalog_cache(key, db_stats.affected_dbs)
        local combined = {
            added = vim.list_extend(vim.deepcopy(sess_stats.added), db_stats.added),
            updated = vim.list_extend(vim.deepcopy(sess_stats.updated), db_stats.updated),
            removed = vim.list_extend(vim.deepcopy(sess_stats.removed), db_stats.removed),
            missing = vim.list_extend(vim.deepcopy(sess_stats.missing), db_stats.missing),
        }
        vim.notify(format_sync_summary(combined), vim.log.levels.INFO)
        return
    end

    -- sub is 'add' or 'update': fetch from server via TPT
    local tpt_script = require('vim-teradata.config').get_tpt_objects_script()
    if not tpt_script then
        return vim.notify('TPT objects export script not found on runtimepath.', vim.log.levels.ERROR)
    end
    local data_tmp = config.options.data_dir
    if data_tmp:find("'", 1, true) then
        return vim.notify("data_dir must not contain a single quote.", vim.log.levels.ERROR)
    end
    local ok, msg = M.check_executables({ 'tbuild' })
    if not ok then return vim.notify(msg, vim.log.levels.ERROR) end

    local tmp_dir = data_tmp .. '/_sync/' .. key
    vim.fn.mkdir(tmp_dir, 'p')

    -- Chunk db_targets into batches of at most 200 items
    local chunks = {}
    local chunk_size = 200
    for i = 1, #db_targets, chunk_size do
        table.insert(chunks, vim.list_slice(db_targets, i, math.min(i + chunk_size - 1, #db_targets)))
    end

    local all_lines = {}
    syncing[key] = true

    local function run_chunk(idx)
        if idx > #chunks then
            local fetched = parse_export_lines(all_lines)
            local db_stats = merge_into_catalog(catalog_dir, fetched, db_targets, sub, current_user)
            syncing[key] = nil
            warned_missing[key] = nil
            invalidate_catalog_cache(key, db_stats.affected_dbs)

            local combined = {
                added = vim.list_extend(vim.deepcopy(sess_stats.added), db_stats.added),
                updated = vim.list_extend(vim.deepcopy(sess_stats.updated), db_stats.updated),
                removed = vim.list_extend(vim.deepcopy(sess_stats.removed), db_stats.removed),
                missing = vim.list_extend(vim.deepcopy(sess_stats.missing), db_stats.missing),
            }
            local summary = format_sync_summary(combined)
            if not had_catalog then
                summary = summary .. " (catalog initialized; run full :TDSync later)"
            end
            vim.notify(summary, vim.log.levels.INFO)
            return
        end

        local select_stmt = M.build_objects_select_stmt(chunks[idx])
        local escaped_stmt = select_stmt:gsub("'", "''")
        local file_name = "objects_tmp.csv"
        local out_csv = tmp_dir .. "/" .. file_name
        local jobvars_path = tmp_dir .. "/jobvars_objects.txt"
        M.remove_files(out_csv, jobvars_path)

        local jobvars_lines = {
            string.format("user        = '%s',", current_user.user),
            string.format("logon_mech  = '%s',", current_user.log_mech),
            string.format("tdpid       = '%s',", current_user.tdpid),
            string.format("data_path   = '%s',", tmp_dir),
            string.format("file_name   = '%s',", file_name),
            string.format("select_stmt = '%s'", escaped_stmt),
        }
        vim.fn.writefile(jobvars_lines, jobvars_path)

        local job_name = string.format("TDSYNC_OBJ_%d_%d", os.time(), idx)
        local cmd = { tbuild_bin(), '-f', tpt_script, '-v', jobvars_path, job_name }

        local spawned, err = pcall(vim.system, cmd, { text = true }, function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    syncing[key] = nil
                    M.remove_files(out_csv, jobvars_path)
                    vim.notify("TDSync failed: " .. (result.stderr or result.stdout or "unknown error"),
                        vim.log.levels.ERROR)
                    return
                end
                if vim.fn.filereadable(out_csv) == 1 then
                    for _, l in ipairs(vim.fn.readfile(out_csv)) do
                        table.insert(all_lines, l)
                    end
                end
                M.remove_files(out_csv, jobvars_path)
                run_chunk(idx + 1)
            end)
        end)

        if not spawned then
            syncing[key] = nil
            M.remove_files(out_csv, jobvars_path)
            vim.notify("TDSync failed to start: " .. tostring(err), vim.log.levels.ERROR)
        end
    end

    run_chunk(1)
end

M._parse_export_lines = parse_export_lines
M._write_db_file = write_db_file
M._write_summary = write_summary
M._merge_into_catalog = merge_into_catalog
M._split_data_db_file_to_lua = split_data_db_file_to_lua
M._is_syncing = function(k) return syncing[k] == true end
M._set_syncing = function(k, v) syncing[k] = v end

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
    local keep = {}
    for _, j in ipairs(M.jobs_all()) do
        if j.status == 'running' then
            if j.query_path then keep[vim.fs.basename(j.query_path)] = true end
            if j.result_path then
                local base = vim.fs.basename(j.result_path)
                keep[base] = true
                keep[base .. '.part'] = true
                keep[base:gsub('%.[^.]*$', '') .. '.jobvars'] = true
            end
        end
    end

    local exports_dir = M.get_history_path('exports_dir_name')
    local now = os.time()
    for _, name in ipairs(vim.fn.isdirectory(exports_dir) == 1 and vim.fn.readdir(exports_dir) or {}) do
        if (name:match('%.jobvars$') or name:match('%.part$')) and not keep[name] then
            local st = vim.uv.fs_stat(exports_dir .. '/' .. name)
            if st and now - st.mtime.sec > 86400 then vim.uv.fs_unlink(exports_dir .. '/' .. name) end
        end
    end

    if not max or max <= 0 then return end
    for _, name in ipairs({ 'queries_dir_name', 'resultsets_dir_name', 'exports_dir_name' }) do
        local dir = M.get_history_path(name)
        if vim.fn.isdirectory(dir) == 1 then
            local files = vim.tbl_filter(function(f)
                return not f:match('%.jobvars$') and not f:match('%.part$')
            end, vim.fn.readdir(dir))
            table.sort(files) -- ids start with a timestamp: lexical == chronological
            for i = 1, #files - max do
                if not keep[files[i]] then vim.uv.fs_unlink(dir .. '/' .. files[i]) end
            end
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
