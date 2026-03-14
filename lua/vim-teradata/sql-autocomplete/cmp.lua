local source = {}

function source.new()
    return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
    return { '.' }
end

function source:complete(_, callback)
    local items = require('vim-teradata.sql-autocomplete.completion').complete_items()
    callback({ items = items or {} })
end

return source
