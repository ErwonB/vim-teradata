local M = {}

-- =============================================================================
-- Constants & Configuration
-- =============================================================================

local NAMESPACE = vim.api.nvim_create_namespace("vim-teradata")
local DIAGNOSTIC_SOURCE = "vim-teradata"
local MAX_ERROR_CONTEXT_LEN = 40

-- Severity Mapping
local SEVERITY = {
    ERROR = vim.diagnostic.severity.ERROR,
    WARN = vim.diagnostic.severity.WARN,
    INFO = vim.diagnostic.severity.INFO,
    HINT = vim.diagnostic.severity.HINT,
}

-- =============================================================================
-- Treesitter Queries
-- =============================================================================
-- Queries are compiled once at module load time for performance.

local ts_query = vim.treesitter.query
local parse_query = ts_query.parse or ts_query.parse_query

local QUERIES = {
    alias_def = parse_query("sql", [[
    (relation alias: (identifier) @alias_definition)
  ]]),

    alias_use = parse_query("sql", [[
    (select_expression
      (term
        value: (field
          (object_reference
            name: (identifier) @alias_usage))))
  ]]),

    union_select = parse_query("sql", [[
    (set_operation
      (select
        (select_expression) @select_expr
      )
    )
  ]]),

    relation = parse_query("sql", [[
    (relation) @relation
  ]]),

    statement = parse_query("sql", [[
    (statement) @stmt
  ]]),

    qualified_field = parse_query("sql", [[
    (field
      (object_reference
        name: (identifier) @qualifier)
      name: (identifier) @col_name
    ) @field
  ]]),

    bare_field = parse_query("sql", [[
    (field name: (identifier) @col)
  ]]),

    syntax_error = parse_query("sql", [[
    (ERROR) @error
  ]])
}

-- =============================================================================
-- Helper Functions
-- =============================================================================

---Safely retrieves node text.
---@param node TSNode|nil
---@param bufnr number
---@return string|nil
local function get_text(node, bufnr)
    if not node then return nil end
    local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
    return ok and text or nil
end

---Adds a diagnostic to the table.
---@param diagnostics table
---@param node TSNode
---@param bufnr number
---@param severity number
---@param message string
local function add_diagnostic(diagnostics, node, bufnr, severity, message)
    local sr, sc, er, ec = node:range()
    table.insert(diagnostics, {
        bufnr = bufnr,
        lnum = sr,
        col = sc,
        end_lnum = er,
        end_col = ec,
        severity = severity,
        message = message,
        source = DIAGNOSTIC_SOURCE,
    })
end

---Recursively finds missing symbols in error nodes.
---@param node TSNode
---@return string|nil
local function find_missing_symbol(node)
    if node:missing() then return node:type() end
    for i = 0, node:child_count() - 1 do
        local child = node:child(i)
        if child then
            local sym = find_missing_symbol(child)
            if sym then return sym end
        end
    end
    return nil
end

---Generates a human-readable error message from a syntax error node.
---@param err_node TSNode
---@param bufnr number
---@return string
local function get_syntax_error_message(err_node, bufnr)
    local parent = err_node:parent()
    local ctx = parent and parent:type() or "file"

    local missing = find_missing_symbol(err_node)
    if missing then
        return string.format("Expected %s here (while parsing %s).", missing, ctx)
    end

    local text = get_text(err_node, bufnr) or ""
    -- Clean whitespace
    local near = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    if near ~= "" and #near < MAX_ERROR_CONTEXT_LEN then
        return string.format('Unexpected token near "%s" (in %s).', near, ctx)
    end

    return "Syntax error."
end

-- =============================================================================
-- Logic: Check Union Compatibility
-- =============================================================================

local function get_columns_from_select_expr(expr_node, bufnr)
    local cols = {}

    for term_node in expr_node:iter_children() do
        if term_node:type() == "term" then
            local field_node = term_node:named_child(0)
            if field_node then
                local col_name = nil
                local start_row, start_col = term_node:range()

                -- Priority 1: Explicit Alias (AS xyz)
                local alias_node = term_node:field("alias")[1]
                if alias_node then
                    col_name = get_text(alias_node, bufnr)
                else
                    -- Priority 2: Qualified/Unqualified Name
                    if field_node:type() == "field" then
                        local child = field_node:child(0)
                        if child and child:type() == "object_reference" then
                            -- table.col or alias.col
                            local name_node = child:named_child(1)
                            if name_node then
                                col_name = get_text(name_node, bufnr)
                            end
                        else
                            -- plain col
                            local name_node = field_node:field("name")[1]
                            if name_node and name_node:type() == "identifier" then
                                col_name = get_text(name_node, bufnr)
                            end
                        end
                    end
                end

                if col_name then
                    table.insert(cols, {
                        name = col_name,
                        node = term_node,
                        lnum = start_row,
                        col = start_col,
                    })
                end
            end
        end
    end
    return cols
end

local function check_union_column_compatibility(stmt_node, bufnr, diagnostics)
    local select_exprs = {}

    -- Capture select expressions specifically within this statement
    for _, node in QUERIES.union_select:iter_captures(stmt_node, bufnr, 0, -1) do
        table.insert(select_exprs, node)
    end

    if #select_exprs < 2 then return end

    local first_cols = get_columns_from_select_expr(select_exprs[1], bufnr)
    if #first_cols == 0 then return end

    for i = 2, #select_exprs do
        local current_cols = get_columns_from_select_expr(select_exprs[i], bufnr)

        -- Check 1: Column Count Mismatch
        if #current_cols ~= #first_cols then
            local msg = string.format(
                "UNION: expected %d columns but got %d in SELECT #%d",
                #first_cols, #current_cols, i
            )
            for _, col_info in ipairs(current_cols) do
                add_diagnostic(diagnostics, col_info.node, bufnr, SEVERITY.ERROR, msg)
            end
        else
            -- Check 2: Name Mismatch (Warning)
            for j, col_info in ipairs(current_cols) do
                local expected = first_cols[j].name
                if col_info.name:lower() ~= expected:lower() then
                    local msg = string.format(
                        'UNION column %d: "%s" does not match first SELECT\'s "%s"',
                        j, col_info.name, expected
                    )
                    add_diagnostic(diagnostics, col_info.node, bufnr, SEVERITY.WARN, msg)
                end
            end
        end
    end
end

-- =============================================================================
-- Logic: Ambiguous Columns & Relations
-- =============================================================================

local function get_all_relations(stmt_node, bufnr)
    local relations = {} -- Key: lower(alias_or_table) => true

    for _, rel_node in QUERIES.relation:iter_captures(stmt_node, bufnr, 0, -1) do
        local obj_ref = nil
        for child in rel_node:iter_children() do
            if child:type() == "object_reference" then
                obj_ref = child
                break
            end
        end

        if obj_ref then
            -- Table name is the last identifier in object_reference
            local table_name_node = obj_ref:named_child(obj_ref:named_child_count() - 1)
            if table_name_node then
                local table_name = get_text(table_name_node, bufnr)
                if table_name then
                    -- Check for alias
                    local alias_node = rel_node:field("alias")[1]
                    local alias = alias_node and get_text(alias_node, bufnr)

                    -- The key used in SQL to refer to this is the alias if present, else the table name
                    local key = (alias or table_name):lower()
                    relations[key] = {
                        alias = alias and alias:lower() or nil,
                        table = table_name:lower(),
                        node = rel_node
                    }
                end
            end
        end
    end
    return relations
end

local function build_column_map(stmt_node, bufnr, relations)
    local col_to_tables = {}

    for _, field_node in QUERIES.qualified_field:iter_captures(stmt_node, bufnr, 0, -1) do
        local qualifier_node = nil
        local col_node = nil

        for child in field_node:iter_children() do
            if child:type() == "object_reference" then
                -- The qualifier is the last part of the object reference
                qualifier_node = child:named_child(child:named_child_count() - 1)
            elseif child:type() == "identifier" and child:parent():field("name")[1] == child then
                col_node = child
            end
        end

        if qualifier_node and col_node then
            local qualifier = get_text(qualifier_node, bufnr)
            local col_name = get_text(col_node, bufnr)

            if qualifier and col_name then
                qualifier = qualifier:lower()
                col_name = col_name:lower()

                if relations[qualifier] then
                    col_to_tables[col_name] = col_to_tables[col_name] or {}
                    if not vim.tbl_contains(col_to_tables[col_name], qualifier) then
                        table.insert(col_to_tables[col_name], qualifier)
                    end
                end
            end
        end
    end
    return col_to_tables
end

local function check_ambiguous_columns(stmt_node, bufnr, diagnostics)
    local relations = get_all_relations(stmt_node, bufnr)
    if vim.tbl_count(relations) < 2 then return end

    local col_to_tables = build_column_map(stmt_node, bufnr, relations)

    for _, col_node in QUERIES.bare_field:iter_captures(stmt_node, bufnr, 0, -1) do
        -- Ensure this is truly a bare field (no object_reference sibling)
        local field_node = col_node:parent()
        local has_qualifier = false
        for child in field_node:iter_children() do
            if child:type() == "object_reference" then
                has_qualifier = true
                break
            end
        end

        if not has_qualifier then
            local col_name = get_text(col_node, bufnr)
            if col_name then
                local tables_with_col = col_to_tables[col_name:lower()] or {}

                if #tables_with_col >= 2 then
                    local list = table.concat(tables_with_col, ", ")
                    local msg = string.format('Ambiguous column "%s" — exists in: %s', col_name, list)
                    add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR, msg)
                end
            end
        end
    end
end

-- =============================================================================
-- Logic: Undefined Aliases
-- =============================================================================

local function check_undefined_alias(stmt_node, bufnr, diagnostics)
    local defined_aliases = {}

    -- Pass 1: Collect Definitions
    for _, node in QUERIES.alias_def:iter_captures(stmt_node, bufnr, 0, -1) do
        local text = get_text(node, bufnr)
        if text then defined_aliases[text:lower()] = true end
    end

    -- Pass 2: Check Usages
    for _, node in QUERIES.alias_use:iter_captures(stmt_node, bufnr, 0, -1) do
        local text = get_text(node, bufnr)
        if text and not defined_aliases[text:lower()] then
            local msg = string.format('Alias "%s" does not exist in query', text)
            add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR, msg)
        end
    end
end

function M.update_diagnostics(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- Safety check: parser availability
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "sql")
    if not ok or not parser then return end

    local tree = parser:parse()[1]
    if not tree then return end

    local root = tree:root()
    local diagnostics = {}

    -- 1. Global Syntax Check
    for _, node in QUERIES.syntax_error:iter_captures(root, bufnr, 0, -1) do
        local msg = get_syntax_error_message(node, bufnr)
        add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR, msg)
    end

    -- 2. Per-Statement Checks
    -- Processing per statement ensures aliases don't leak between queries in the same file
    for _, stmt_node in QUERIES.statement:iter_captures(root, bufnr, 0, -1) do
        check_ambiguous_columns(stmt_node, bufnr, diagnostics)
        check_union_column_compatibility(stmt_node, bufnr, diagnostics)
        check_undefined_alias(stmt_node, bufnr, diagnostics)
    end

    vim.diagnostic.reset(NAMESPACE, bufnr)
    vim.diagnostic.set(NAMESPACE, bufnr, diagnostics)
end

return M
