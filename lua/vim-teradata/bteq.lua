local config = require('vim-teradata.config')
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
function M.build_script(sql, user_obj, options, output_path)
    local body = build_header(user_obj.user, user_obj.tdpid, user_obj.log_mech)
    vim.list_extend(body, {
        '.set titledashes off',
        '.set separator \'' .. config.options.sep .. '\'',
        '.EXPORT FILE = ' .. output_path .. ';',
        '.set WIDTH 1048575',
    })
    if options.operation == 'output' then
        vim.list_extend(body, {
            '.set retlimit ' .. config.options.retlimit,
        })
    end
    vim.list_extend(body, vim.fn.split(sql, '\n'))
    vim.list_extend(body, { ';', '.LOGOFF', '.EXIT' })
    return { script = body }
end

--- Starts an asynchronous BTEQ job.
--- @param script_lines table The script lines to send to BTEQ.
--- @param on_done function The callback function(res).
function M.start_job(script_lines, on_done)
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

return M
