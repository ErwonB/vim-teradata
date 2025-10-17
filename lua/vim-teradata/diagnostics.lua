local M = {}

-- Create a single namespace for all our diagnostics
local namespace = vim.api.nvim_create_namespace("vim-teradata")
local query = vim.treesitter.query
local parse_query = query.parse or query.parse_query

local queries = {
    -- Query for ERROR nodes
    syntax_error = {
        query_string = "((ERROR) @error)",
        message = "Syntax error",
        severity = vim.diagnostic.severity.ERROR,
    },

    -- EXAMPLE: Add another query here for deprecated keywords
    -- deprecated_keyword = {
    --   query_string = "((keyword_deprecated) @deprecated)",
    --   message = "This keyword is deprecated.",
    --   severity = vim.diagnostic.severity.WARN,
    -- }
}

-- Find the first missing node under `node` and return its type (symbol name).
local function find_missing_symbol(node)
    if node:missing() then
        return node:type()
    end
    for i = 0, node:child_count() - 1 do
        local child = node:child(i)
        local sym = find_missing_symbol(child)
        if sym then return sym end
    end
end

-- Get a short, one-line snippet of a node's source text.
local function snippet_of(node, bufnr, maxlen)
    maxlen = maxlen or 40
    local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
    if not ok or not text or text == "" then return "" end
    text = text:gsub("%s+", " ")
    if #text > maxlen then
        text = text:sub(1, maxlen - 1) .. "…"
    end
    return text
end

local function message_from_error_node(err_node, bufnr)
    local ctx = err_node:parent() and err_node:parent():type() or "file"

    -- If a missing symbol exists anywhere below the error, prefer that wording.
    local missing = find_missing_symbol(err_node)
    if missing then
        return string.format("Expected %s here (while parsing %s).", missing, ctx)
    end

    -- Otherwise, craft an "unexpected token" message, with local context if possible.
    local near = snippet_of(err_node, bufnr)
    if near ~= "" then
        return string.format('Unexpected token near "%s" (in %s).', near, ctx)
    end

    -- Fallback if the error node has no extractable text.
    return string.format("Syntax error in %s.", ctx)
end


function M.update_diagnostics(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    vim.diagnostic.reset(namespace, bufnr)

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'sql')
    if not ok or not parser then return end

    local tree = parser:parse()[1]
    if not tree then return end
    local root = tree:root()

    local diagnostics = {}

    for _, def in pairs(queries) do
        local q = parse_query('sql', def.query_string)

        for cap_id, node, _ in q:iter_captures(root, bufnr, 0, -1) do
            local cap = q.captures[cap_id]
            if cap == "error" then
                local sr, sc, er, ec = node:range()
                local msg = message_from_error_node(node, bufnr)
                diagnostics[#diagnostics + 1] = {
                    bufnr = bufnr,
                    lnum = sr,
                    col = sc,
                    end_lnum = er,
                    end_col = ec,
                    severity = def.severity,
                    message = msg,
                    source = "vim-teradata",
                }
            end
        end
    end

    vim.diagnostic.set(namespace, bufnr, diagnostics)
end

return M
