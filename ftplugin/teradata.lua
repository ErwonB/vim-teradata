if vim.b.did_ftplugin then return end
vim.b.did_ftplugin = 1

require('vim-teradata.ftplugin').attach(vim.api.nvim_get_current_buf())

local undo = "lua require('vim-teradata.ftplugin').detach()"
local cfg = require('vim-teradata.config').options
if cfg and cfg.treesitter_folds then
    vim.opt_local.foldmethod = 'expr'
    vim.opt_local.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
    undo = undo .. '|setlocal foldmethod< foldexpr<'
end
vim.b.undo_ftplugin = vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. '|' .. undo) or undo
