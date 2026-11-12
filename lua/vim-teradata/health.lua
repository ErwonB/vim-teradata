local M = {}

function M.check()
    vim.health.start("vim-teradata")

    local config = require("vim-teradata.config").ensure()
    local compat = require("vim-teradata.compat")

    -- 1. Neovim version
    local v = vim.version()
    local vstr = v.major .. "." .. v.minor .. "." .. v.patch
    if compat.ok() then
        vim.health.ok("Neovim version >= " .. compat.MIN .. " (" .. vstr .. ")")
    else
        vim.health.error("Neovim version >= " .. compat.MIN .. " required (detected " .. vstr .. ")")
    end

    -- 2. External binaries
    local bteq_bin = vim.fn.exepath("bteq")
    if bteq_bin ~= "" then
        vim.health.ok("bteq found at " .. bteq_bin)
    else
        vim.health.warn("bteq not found in PATH; query execution requires bteq")
    end

    local tpt_bin = vim.fn.exepath("tbuild")
    local export_cfg = config.export or {}
    if tpt_bin ~= "" then
        vim.health.ok("tbuild (TPT) found at " .. tpt_bin)
    elseif export_cfg.enabled then
        vim.health.warn("tbuild not found in PATH; full exports (:TDExport) need it (or set export.enabled = false)")
    else
        vim.health.info("tbuild not found in PATH (optional; needed only for TPT exports)")
    end

    for _, route in ipairs({ "W", "R" }) do
        local ok_script, export_script = pcall(require("vim-teradata.config").get_tpt_export_script, route)
        if ok_script and export_script and vim.fn.filereadable(export_script) == 1 then
            vim.health.ok(("TPT export script (route %s): %s"):format(route, export_script))
        else
            vim.health.warn(("TPT export script for route %s not found (export.tpt_script or the bundled lua/vim-teradata/tpt/*.tpt)"):format(route))
        end
    end
    for _, tool in ipairs({ "twbkill", "twbrmcp", "tlogview" }) do
        if vim.fn.exepath(tool) ~= "" then
            vim.health.ok(tool .. " found")
        else
            vim.health.info(tool .. " not found in PATH (cancel cleanup / log hints unavailable)")
        end
    end

    -- 3. Tree-sitter parser
    local ok_lang, loaded = pcall(vim.treesitter.language.add, "teradata")
    local has_parser = ok_lang and loaded
    if has_parser then
        vim.health.ok("Tree-sitter parser for 'teradata' is available")
    else
        vim.health.warn("Tree-sitter parser for 'teradata' not found; install via tree-sitter or nvim-treesitter")
    end

    -- 4. Completion plugins
    local has_blink = pcall(require, "blink.cmp")
    local has_cmp = pcall(require, "cmp")
    if has_blink then
        vim.health.ok("blink.cmp is installed and supported")
    elseif has_cmp then
        vim.health.ok("nvim-cmp is installed and supported")
    else
        vim.health.info("Neither blink.cmp nor nvim-cmp found; omnifunc (<C-x><C-o>) and the picker (<C-x><C-u>) are available")
    end

    -- 5. Picker
    local picker_module = require("vim-teradata.picker")
    local configured = config.picker or "auto"
    local active = configured == "auto" and picker_module.detect() or configured
    if configured == "auto" then
        vim.health.ok("Active picker: " .. active .. " (auto-detected)")
    elseif pcall(require, "vim-teradata.picker." .. configured) then
        vim.health.ok("Active picker: " .. active .. " (configured)")
    else
        vim.health.warn("Configured picker '" .. configured .. "' is unknown; falling back to native")
    end

    -- 6. Users / connection profiles
    local users = config.users or {}
    if #users > 0 then
        vim.health.ok(string.format("Configured users: %d profile(s)", #users))
    else
        vim.health.warn("No users configured; use setup({ users = ... }) or :TDU to add a profile")
    end

    -- 7. Diagnostics configuration
    local diag = config.diagnostics or {}
    if diag.enabled == false then
        vim.health.info("Diagnostics are disabled in config (diagnostics.enabled = false)")
    else
        vim.health.ok("Diagnostics enabled")
    end

    -- 8. Metadata catalog of the active user
    local util = require("vim-teradata.util")
    local cur = util.get_current_user()
    if not cur then
        vim.health.info("No active user; no metadata catalog selected (use :TDU)")
    else
        local key = util.catalog_key(cur)
        local meta = util.catalog_meta(cur)
        if not key then
            vim.health.warn("Active user has no tdpid; cannot locate its metadata catalog")
        elseif meta then
            vim.health.ok(string.format("Metadata catalog '%s' synced %s", key, os.date("%Y-%m-%d %H:%M", meta.synced_at)))
        else
            vim.health.warn(string.format("No metadata catalog for '%s'; run :TDSync", key))
        end
    end

    -- 9. Persistent BTEQ sessions
    local sessions = package.loaded["vim-teradata.session"]
    if sessions and sessions.count() > 0 then
        vim.health.ok(string.format("%d persistent BTEQ session(s) open (:TDSessions)", sessions.count()))
    else
        vim.health.info("No persistent BTEQ session open (see :TDSession)")
    end
end

return M
