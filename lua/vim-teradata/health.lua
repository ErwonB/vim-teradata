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
    if tpt_bin ~= "" then
        vim.health.ok("tbuild (TPT) found at " .. tpt_bin)
    else
        vim.health.info("tbuild not found in PATH (optional; needed only for TPT exports)")
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
end

return M
