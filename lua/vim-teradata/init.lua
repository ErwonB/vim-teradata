local config = require('vim-teradata.config')
local ft = require('vim-teradata.ft')
local compat = require('vim-teradata.compat')

local M = {}

function M.setup(user_config)
    compat.check()
    config.setup(user_config)
    ft.register()
end

return M
