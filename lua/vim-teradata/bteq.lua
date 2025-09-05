local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
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
--- Gets the next available query history number.
--- @return number The next integer for naming query/result files.
local function get_next_query_number()
    local queries_dir = util.get_history_path('queries_dir_name')
    local files = vim.fn.glob(queries_dir .. '/*', false, true)
    ---@type number?
    local max_num = 0
    for _, file in ipairs(files) do
        local filename = vim.fn.fnamemodify(file, ':t')
        if filename:match('^%d+$') then
            local num = tonumber(filename)
            if num > max_num then
                max_num = num
            end
        end
    end
    return max_num + 1
end
--- Builds a BTEQ script for a given operation.
--- @param sql string The SQL query.
--- @param user_obj table The user object containing user, tdpid, log_mech.
--- @param options table Additional options like operation type, pattern, etc.
--- @return table A table containing the BTEQ script (as a list of strings) and context.
function M.build_script(sql, user_obj, options)
    local body = build_header(user_obj.user, user_obj.tdpid, user_obj.log_mech)
    local context = {}
    if options.operation == 'output' then
        context.query_num = get_next_query_number()
        local result_path = util.get_history_path('resultsets_dir_name') .. '/' .. context.query_num
        local query_path = util.get_history_path('queries_dir_name') .. '/' .. context.query_num
        vim.fn.writefile(vim.fn.split(sql, '\n'), query_path)
        vim.list_extend(body, {
            '.set titledashes off',
            '.set WIDTH 30000',
            '.set retlimit ' .. config.options.retlimit,
            '.set separator \'' .. config.options.sep .. '\'',
            '.EXPORT FILE = ' .. result_path .. ';',
        })
        vim.list_extend(body, vim.fn.split(sql, '\n'))
    else -- syntax, explain
        vim.list_extend(body, {
            '.set titledashes off',
            '.set WIDTH 30000',
            '.set separator \'' .. config.options.sep .. '\'',
            '.EXPORT FILE = ' .. util.get_temp_path('bteq_output_name') .. ';',
        })
        vim.list_extend(body, vim.fn.split(sql, '\n'))
    end
    vim.list_extend(body, { ';', '.LOGOFF', '.EXIT' })
    return { script = body, context = context }
end

--- Executes the BTEQ script.
--- @return table A table with {rc, stdout, stderr, log_path}.
function M.execute()
    local script_path = util.get_temp_path('bteq_script_name')
    local log_path = util.get_temp_path('bteq_log_name')
    local redirect_error = config.options.bteq_open_log_when_error and " 2>&1" or ""
    local command = string.format('bteq < %s > %s %s', vim.fn.fnameescape(script_path), vim.fn.fnameescape(log_path),
        redirect_error)
    local result = vim.fn.system(command)
    return {
        rc = vim.v.shell_error,
        msg = result,
        log_path = log_path,
    }
end

return M
