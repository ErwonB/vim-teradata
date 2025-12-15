local M = {}

function M.new()
    return setmetatable({}, { __index = M })
end

function M:get_completions(_, callback)
    local raw_items = require('vim-teradata.sql-autocomplete.completion').complete_blink()

    local items = raw_items or {}

    callback({ items = items })
end

return M
