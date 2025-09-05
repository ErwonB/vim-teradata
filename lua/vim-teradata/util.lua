local config = require('vim-teradata.config')
local M = {}
--- Safely removes one or more files.
--- @param ... string One or more file paths to delete.
function M.remove_files(...)
    for _, file in ipairs({ ... }) do
        if vim.fn.filereadable(file) == 1 then
            vim.fn.delete(file)
        end
    end
end

--- Gets the full path for a temporary file.
--- @param name string The name of the temp file (e.g., 'bteq_script_name').
--- @return string The full, absolute path.
function M.get_temp_path(name)
    return config.options.temp_dir .. '/' .. config.options[name]
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
            return false, string.format('Error: %s is not installed or not in your PATH.', cmd) --
        end
    end
    return true, ""
end

--- Loads the saved users configuration.
function M.load_config()
    local file = config.options.history_dir .. '/users.json'
    if vim.fn.filereadable(file) == 1 then
        local content = vim.fn.readfile(file)
        local data = vim.fn.json_decode(table.concat(content, '\n'))
        config.options.users = data.users or {}
        config.options.current_user_index = data.current_user_index
    end
end

--- Saves the current users configuration.
function M.save_config()
    local file = config.options.history_dir .. '/users.json'
    local data = {
        users = config.options.users,
        current_user_index = config.options.current_user_index,
    }
    vim.fn.writefile({ vim.fn.json_encode(data) }, file)
end

--- Format string if more than 100s of characters
function M.formatString(s, width)
    local len = #s
    if len >= width then
        return s
    end

    local padding = string.rep(' ', width - len)
    return padding .. s
end

return M
