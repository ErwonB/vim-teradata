-- lua/teradata/fzf.lua
local ui = require('vim-teradata.ui')
local util = require('vim-teradata.util')

local M = {}

function M.find_query_by_content()
    if vim.fn.exists('*fzf#run') == 0 then
        return vim.notify('Error: fzf.vim plugin not found.', vim.log.levels.ERROR)
    end
    local ok, msg = util.check_executables({ 'rg', 'bat', 'fzf' })
    if not ok then
        return vim.notify(msg, vim.log.levels.ERROR)
    end

    local queries_dir = util.get_history_path('queries_dir_name')
    if vim.fn.isdirectory(queries_dir) == 0 then
        return vim.notify('Error: Query history directory not found.', vim.log.levels.ERROR)
    end

    local rg_command = 'rg --column --line-number --no-heading --smart-case "" .'
    local fzf_options = {
        '--ansi',
        '--prompt="Grep Queries> "',
        '--delimiter=:',
        '--preview="bat --style=numbers --color=always --highlight-line {2} -- {1}"',
        '--preview-window=right:60%:wrap',
    }

    vim.fn['fzf#run']({
        source = rg_command,
        sink = function(selected_line)
            local parts = vim.fn.split(selected_line, ':', true)
            local filename = vim.fn.fnamemodify(parts[1], ':t')
            ui.open_query_result_pair(filename)
        end,
        options = table.concat(fzf_options, ' '),
        dir = queries_dir,
    })
end

return M
