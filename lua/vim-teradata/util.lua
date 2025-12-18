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

--- Splits a temporary CSV file into per-database files and generates a summary file.
--- @return nil
local function split_data_db_file_to_lua()
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
        return vim.notify("Error: Could not open the input file: " .. input_filename, vim.log.levels.ERROR)
    end

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
    for raw in input_file:lines() do
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
    end
    input_file:close()

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
end

local function load_databases(summary_file)
    if not Schema.cache.db then
        Schema.cache.db = assert(dofile(summary_file))
    end
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
    if not Schema.cache.tb[db] then
        Schema.cache.tb[db] = assert(dofile(db_file))
    end
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
    return Schema.cache.tb[db].is_table[tb]
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
    for tb, _ in pairs(Schema.cache.tb[db].is_table or {}) do
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
    for _, c in ipairs(Schema.cache.tb[db][tb] or {}) do
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

            for _, col in ipairs(Schema.cache.tb[item.db_name][item.tb_name] or {}) do
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
    local current_user = config.options.users[config.options.current_user_index]
    local user = current_user.user
    local tdpid = current_user.tdpid
    local logon_mech = current_user.log_mech
    local tpt_script = config.options.tpt_script

    local data_tmp = config.options.data_dir

    local ok, msg = M.check_executables({ 'tbuild' })
    if not ok then
        return vim.notify(msg, vim.log.levels.ERROR)
    end

    if not user or not tdpid or not tpt_script or not logon_mech then
        return vim.notify("Missing TD env variables", vim.log.levels.ERROR)
    end

    local tbuild_command = "tbuild -f " ..
        tpt_script ..
        " -u \"user='" ..
        user .. "', logon_mech='" .. logon_mech .. "', tdpid='" .. tdpid .. "', data_path='" .. data_tmp .. "'\""

    local data_tmp_file = data_tmp .. "/data_tmp.csv"
    M.remove_files(data_tmp_file)
    local tpt_result = vim.fn.system(tbuild_command)
    local exit_code = vim.v.shell_error
    if exit_code ~= 0 then
        return vim.notify("tbuild command failed : " .. tpt_result, vim.log.levels.ERROR)
    end

    split_data_db_file_to_lua()
    M.remove_files(data_tmp_file)
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

function M.load_config()
    local file = config.options.history_dir .. '/users.json'
    if vim.fn.filereadable(file) == 1 then
        local content = vim.fn.readfile(file)
        local data = vim.fn.json_decode(table.concat(content, '\n'))
        config.options.users = data.users or {}
        config.options.current_user_index = data.current_user_index
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

function M.formatString(s, width)
    local len = #s
    if len >= width then
        return s
    end
    local padding = string.rep(' ', width - len)
    return padding .. s
end

--- Generates a unique query ID based on timestamp and random number.
--- @return string The unique ID.
function M.get_unique_query_id()
    return os.date('%Y%m%d%H%M%S_') .. math.random(1000, 9999)
end

---------------
---tree-sitter helper
---------------

-- Helper: Recursively find the first descendant of a specific type
-- @param node TSNode The node to start searching from
-- @param target_type string The node type to look for
-- @return TSNode|nil The first matching descendant, or nil
local function find_first_descendant_by_type(node, target_type)
    if not node then return nil end

    -- Check children
    for child in node:iter_children() do
        if child:type() == target_type then
            return child
        end
        -- Recurse into the child
        local found = find_first_descendant_by_type(child, target_type)
        if found then
            return found
        end
    end
    return nil
end

---Finds a direct child of a specific type.
---@param node TSNode|nil
---@param type_name string
---@return TSNode|nil
function M.get_child_by_type(node, type_name)
    if not node then return nil end
    for child in node:iter_children() do
        if child:type() == type_name then return child end
    end
    return nil
end

-- Helper: Find ancestor or self by type
function M.find_node_by_type(start_node, target_type)
    local node = start_node
    while node do
        if node:type() == target_type then
            return node
        end
        node = node:parent()
    end
    return nil
end

--- Find the next node of a specific type (searching up, forward, and down)
-- @param target_type string The node type to look for
-- @return TSNode|nil
function M.find_next_node_by_type(target_type)
    local buf = vim.api.nvim_get_current_buf()
    local cursor_node = vim.treesitter.get_node({ bufnr = buf })
    if not cursor_node then return nil end

    if cursor_node:type() == "program" or not cursor_node:parent() then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, col = cursor[1] - 1, cursor[2]
        row = row - 1

        for child in cursor_node:iter_children() do
            local start_row, start_col, _, _ = child:range()
            if (start_row > row or (start_row == row and start_col > col))
                and child:type() == target_type then
                return child
            end
        end
        return nil
    end

    -- Walk up the tree, checking next siblings and their descendants
    ---@type TSNode|nil
    local node = cursor_node

    while node do
        local sibling = node:next_sibling()
        while sibling do
            -- 1. Check if the sibling ITSELF matches
            if sibling:type() == target_type then
                return sibling
            end

            -- 2. Check the sibling's DESCENDANTS
            local descendant = find_first_descendant_by_type(sibling, target_type)
            if descendant then
                return descendant
            end

            sibling = sibling:next_sibling()
        end

        -- Climb up
        node = node:parent()
    end

    return nil
end

--- Find the previous node of a specific type (searching up, backward, and down)
-- @param target_type string The node type to look for
-- @return TSNode|nil
function M.find_prev_node_by_type(target_type)
    local buf = vim.api.nvim_get_current_buf()
    local cursor_node = vim.treesitter.get_node({ bufnr = buf })
    if not cursor_node then return nil end

    if cursor_node:type() == "program" or not cursor_node:parent() then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, col = cursor[1] - 1, cursor[2]
        row = row - 1

        local last_found = nil
        for child in cursor_node:iter_children() do
            local start_row, start_col, _, _ = child:range()
            if start_row > row or (start_row == row and start_col >= col) then
                break
            end
            if child:type() == target_type then
                last_found = child
            end
        end
        return last_found
    end

    -- Walk up the tree, checking previous siblings and their descendants
    ---@type TSNode|nil
    local node = cursor_node

    while node do
        local sibling = node:prev_sibling()
        while sibling do
            -- 1. Check if the sibling ITSELF matches
            if sibling:type() == target_type then
                return sibling
            end

            -- 2. Check the sibling's DESCENDANTS
            -- For simplicity and performance, we use the 'find_first_descendant_by_type'
            -- or the more common 'query-based search' for finding the nearest ancestor/descendant.
            -- Since a query is overkill, we use the simple recursive check.
            local descendant = find_first_descendant_by_type(sibling, target_type)
            if descendant then
                return descendant
            end

            sibling = sibling:prev_sibling()
        end
        node = node:parent()
    end

    return nil
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
    local ok = pcall(function() j.handle:kill(15) end) -- SIGTERM
    j.status = 'canceled'
    j.finished_at = os.time()
    j.message = 'Canceled'
    return ok
end

return M
