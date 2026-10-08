local M = {}
local ID = 'td_sql_completion'

--- Best-effort auto-registration with blink.cmp. Relies on blink internals and may
--- break on blink refactors; the documented way is the user-side config (see docs).
---@return boolean registered
function M.register_blink()
    local has_blink, blink = pcall(require, 'blink.cmp')
    if not has_blink then return false end
    return (pcall(function()
        local blink_config = require('blink.cmp.config')
        local provider_lib = require('blink.cmp.sources.lib.provider')
        local sources_lib = require('blink.cmp.sources.lib')

        local cfg = {
            name = 'TD SQL Completion',
            module = 'vim-teradata.sql-autocomplete.blink',
            score_offset = 0,
        }
        blink_config.sources.providers[ID] = cfg

        local default = blink_config.sources.default or {}
        if not vim.tbl_contains(default, ID) then table.insert(default, ID) end
        blink_config.sources.default = default

        sources_lib.providers[ID] = provider_lib.new(ID, cfg)
        if blink.reload then blink.reload(ID) end
    end))
end

---@return boolean registered
function M.register_cmp()
    local ok, cmp = pcall(require, 'cmp')
    if not ok then return false end
    return (pcall(function()
        cmp.register_source(ID, require('vim-teradata.sql-autocomplete.cmp').new())
    end))
end

return M
