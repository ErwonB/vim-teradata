local M = {}

function M.get()
    local name = require('vim-teradata.config').options.picker or 'auto'
    if name == 'auto' then
        name = M.detect()
    end
    local ok, adapter = pcall(require, 'vim-teradata.picker.' .. name)
    if not ok then
        vim.notify('[vim-teradata] Unknown picker: ' .. name .. '. Falling back to fzf_vim.', vim.log.levels.WARN)
        return require('vim-teradata.picker.fzf_vim')
    end
    return adapter
end

function M.detect()
    if pcall(require, 'fzf-lua') then return 'fzf_lua' end
    if pcall(require, 'snacks') then return 'snacks' end
    if pcall(require, 'telescope') then return 'telescope' end
    return 'fzf_vim'
end

return M
