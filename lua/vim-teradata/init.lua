local config = require('vim-teradata.config')

local M = {}

function M.setup(user_config)
    config.setup(user_config)

    local extension_map = {}
    for _, ext in ipairs(config.options.ft) do
        extension_map[ext] = "teradata"
    end

    vim.filetype.add({
        extension = extension_map,
    })
end

return M
