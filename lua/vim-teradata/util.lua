local config = require('vim-teradata.config')
local M = {}

--- Safely removes one or more files.
--- @param ... string One or more file paths to delete.
function M.remove_files(...)
    for _, file in ipairs({ ... }) do
        if file and file ~= '' and vim.fn.filereadable(file) == 1 then
            vim.fn.delete(file)
        end
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
