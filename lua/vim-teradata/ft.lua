local config = require('vim-teradata.config')

local M = {}

-- extensions that already have a filetype callback installed
local registered = {}

--- Extensions currently configured (falls back to the defaults before setup()).
---@return string[]
local function configured_exts()
    return config.options.ft or config.defaults.ft
end

local function sql_mode()
    return config.options.sql_detection or config.defaults.sql_detection
end

--- 'modeline' mode: look for 'teradata' / 'bteq' in the first or last 5 lines.
local function has_teradata_marker(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
    local total = vim.api.nvim_buf_line_count(bufnr)
    if total > 5 then
        vim.list_extend(lines, vim.api.nvim_buf_get_lines(bufnr, math.max(5, total - 5), total, false))
    end
    for _, line in ipairs(lines) do
        local l = line:lower()
        if l:find('teradata', 1, true) or l:find('bteq', 1, true) then
            return true
        end
    end
    return false
end

local function make_detector(ext)
    return function(_, bufnr)
        if not vim.tbl_contains(configured_exts(), ext) then
            return nil
        end
        if ext == 'sql' then
            local mode = sql_mode()
            if mode == 'never' then
                return nil
            end
            if mode == 'modeline' and not has_teradata_marker(bufnr) then
                return 'sql'
            end
        end
        return 'teradata'
    end
end

--- Installs filetype detection for every configured extension. Safe to call
--- several times (plugin load, then again after `setup()`): the detectors read
--- the live config, and only extensions not seen before are added.
function M.register()
    local ext_map = {}
    for _, ext in ipairs(configured_exts()) do
        if not registered[ext] then
            registered[ext] = true
            ext_map[ext] = make_detector(ext)
        end
    end
    if next(ext_map) then
        vim.filetype.add({ extension = ext_map })
    end
end

return M
