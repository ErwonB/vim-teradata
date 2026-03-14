-- lua/teradata/fzf.lua
local ui = require('vim-teradata.ui')
local util = require('vim-teradata.util')

local M = {}

function M.find_query_by_content()
    local queries_dir = util.get_history_path('queries_dir_name')
    if vim.fn.isdirectory(queries_dir) == 0 then
        return vim.notify('Error: Query history directory not found.', vim.log.levels.ERROR)
    end

    local picker = require('vim-teradata.picker').get()
    picker.grep_queries(queries_dir, function(filename)
        ui.open_query_result_pair(filename)
    end)
end

return M
