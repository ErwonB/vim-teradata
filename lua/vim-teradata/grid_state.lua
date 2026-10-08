local M = {}
local S = {} -- bufnr -> { key = value }

function M.get(bufnr, key)
    local s = S[bufnr]
    return s and s[key]
end

function M.set(bufnr, key, value)
    local s = S[bufnr]
    if not s then
        s = {}
        S[bufnr] = s
        vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
            group = vim.api.nvim_create_augroup('VimTeradata', { clear = false }),
            buffer = bufnr, once = true,
            callback = function() S[bufnr] = nil end,
        })
    end
    s[key] = value
end

function M.clear(bufnr) S[bufnr] = nil end

return M
