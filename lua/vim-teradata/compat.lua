local M = {}
M.MIN = '0.12'
local warned = false

function M.ok()
    return vim.fn.has('nvim-0.12') == 1
end

--- Returns false (and warns once) when Neovim is too old.
function M.check()
    if M.ok() then return true end
    if not warned then
        warned = true
        vim.notify(('[vim-teradata] requires Neovim >= %s (running %s)'):format(M.MIN, tostring(vim.version())),
            vim.log.levels.ERROR)
    end
    return false
end

return M
