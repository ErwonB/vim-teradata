local M = {}

function M.new()
    return setmetatable({}, { __index = M })
end

--- blink calls this to decide whether the source participates for the current buffer.
function M:enabled()
    return vim.bo.filetype == 'teradata'
end

function M:get_trigger_characters()
    return { '.' }
end

function M:get_completions(_, callback)
    local ok, items = pcall(function()
        return require('vim-teradata.sql-autocomplete.completion').complete_items()
    end)
    callback({
        items = ok and items or {},
        is_incomplete_backward = false,
        is_incomplete_forward = false,
    })
    return function() end -- cancel handle
end

return M
