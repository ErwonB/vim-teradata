local util = require('vim-teradata.util')
local M = {}

-- =============================================================================
-- Configuration & Constants
-- =============================================================================

local NAMESPACE = vim.api.nvim_create_namespace("vim-teradata")
local DIAGNOSTIC_SOURCE = "vim-teradata"
local MAX_ERROR_CONTEXT_LEN = 40

local SEVERITY = {
    ERROR = vim.diagnostic.severity.ERROR,
    WARN = vim.diagnostic.severity.WARN,
    INFO = vim.diagnostic.severity.INFO,
}

-- =============================================================================
-- Schema Loading & Caching
-- =============================================================================

local function normalize(str)
    return str:upper()
end

local function normalize_col(str)
    return str:gsub("%s+$", ""):upper()
end

local function has_db(db_name)
    return util.is_a_db(db_name)
end

local function has_table(db, tb)
    local db_norm = normalize(db)
    local tb_norm = normalize(tb)
    return util.is_a_table(db_norm, tb_norm)
end


local function has_column(db, tb, col)
    local db_norm = normalize(db)
    local tb_norm = normalize(tb)
    local col_norm = normalize_col(col)
    return util.is_a_column(db_norm, tb_norm, col_norm)
end

-- =============================================================================
-- Treesitter Queries
-- =============================================================================

local ts_query = vim.treesitter.query
local parse_query = ts_query.parse or ts_query.parse_query

local QUERIES = {
    alias_def = parse_query("sql", [[ (relation alias: (identifier) @alias_definition) ]]),
    alias_use = parse_query("sql",
        [[ (select_expression (term value: (field (object_reference name: (identifier) @alias_usage)))) ]]),
    union_select = parse_query("sql", [[ (set_operation (select (select_expression) @select_expr)) ]]),
    union_block = parse_query("sql", [[ (set_operation) @union_block ]]),
    relation = parse_query("sql", [[ (relation) @relation ]]),
    statement = parse_query("sql", [[ (statement) @stmt ]]),
    cte_def = parse_query("sql", [[
        (cte
            (identifier) @cte_name
            (statement) @cte_body
        ) @cte
    ]]),

    select_output_alias = parse_query("sql", [[
    (select_expression
      (term
        alias: (identifier) @output_alias
      )
    )
  ]]),

    qualified_field = parse_query("sql", [[
    (field
      (object_reference name: (identifier) @qualifier)
      name: (identifier) @col_name
    ) @field
  ]]),

    bare_field = parse_query("sql", [[
    (field name: (identifier) @col)
  ]]),

    syntax_error = parse_query("sql", [[ (ERROR) @error ]])
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
    local near = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if near ~= "" and #near < MAX_ERROR_CONTEXT_LEN then
        return string.format('Unexpected token near "%s" (in %s).', near, ctx)
    end
    return "Syntax error."
end

--- Checks if a captured node is actually inside a nested subquery or set operation
--- This prevents the outer scope (e.g. INSERT statement) from seeing tables inside the UNION parts
local function is_nested_in_subquery(node, root_container)
    local parent = node:parent()
    while parent do
        if parent == root_container then return false end
        local type = parent:type()
        -- Treat set_operation as a boundary just like subquery
        if type == "subquery" or type == "set_operation" then return true end
        parent = parent:parent()
    end
    return false
end

-- =============================================================================
-- Logic: Union Compatibility
-- =============================================================================

local function get_columns_from_select_expr(expr_node, bufnr)
    local cols = {}
    local number_fields = 0
    for term_node in expr_node:iter_children() do
        if term_node:type() == "term" then
            local final_name = nil
            local start_row, start_col
            number_fields = number_fields + 1
            local field_node = term_node:named_child(0)
            if field_node then
                start_row, start_col = term_node:range()

                local alias_node = term_node:field("alias")[1]
                if alias_node then
                    final_name = get_text(alias_node, bufnr)
                else
                    if field_node:type() == "field" then
                        local child = field_node:child(0)
                        if child and child:type() == "object_reference" then
                            local name_nodes = field_node:field("name")
                            if #name_nodes > 0 then
                                final_name = get_text(name_nodes[1], bufnr)
                            end
                        else
                            local name_node = field_node:field("name")[1]
                            if name_node and name_node:type() == "identifier" then
                                final_name = get_text(name_node, bufnr)
                            end
                        end
                    end
                end
            end
            table.insert(cols, {
                name = final_name or "",
                node = term_node,
                lnum = start_row or 0,
                col = start_col or 0
            })
        end
    end
    return number_fields, cols
end

local function check_union_column_compatibility(stmt_node, bufnr, diagnostics)
    for _, union_node in QUERIES.union_block:iter_captures(stmt_node, bufnr, 0, -1) do
        local select_exprs = {}
        for _, node in QUERIES.union_select:iter_captures(union_node, bufnr, 0, -1) do
            table.insert(select_exprs, node)
        end

        if #select_exprs < 2 then goto continue end

        local first_number_fields, first_cols = get_columns_from_select_expr(select_exprs[1], bufnr)
        if first_number_fields == 0 then goto continue end

        for i = 2, #select_exprs do
            local current_number_fields, current_cols = get_columns_from_select_expr(select_exprs[i], bufnr)

            if first_number_fields ~= current_number_fields then
                local msg = string.format(
                    "UNION: expected %d columns but got %d in SELECT #%d",
                    #first_cols, #current_cols, i
                )
                for _, col_info in ipairs(current_cols) do
                    add_diagnostic(diagnostics, col_info.node, bufnr, SEVERITY.ERROR, msg)
                end
            else
                for j, col_info in ipairs(current_cols) do
                    local expected = first_cols[j].name
                    if normalize(expected) ~= normalize(col_info.name) then
                        local msg = string.format(
                            'UNION column %d: "%s" does not match first SELECT\'s "%s"',
                            j, col_info.name, expected
                        )
                        add_diagnostic(diagnostics, col_info.node, bufnr, SEVERITY.WARN, msg)
                    end
                end
            end
        end

        ::continue::
    end
end

-- =============================================================================
-- Logic: CTE Analysis
-- =============================================================================

--- Extracts CTE definitions (name and output columns) from a statement node.
--- @param stmt_node TSNode The root statement node (which may contain a WITH clause).
--- @param bufnr number The buffer number.
--- @return table A map of normalized CTE name to its definition.
local function get_cte_definitions(stmt_node, bufnr)
    local cte_defs = {}

    for _, cte_def_match, _ in QUERIES.cte_def:iter_matches(stmt_node, bufnr, 0, -1) do
        local cte_name_node
        local cte_body_node
        for capid, n in pairs(cte_def_match) do
            if QUERIES.cte_def.captures[capid] == "cte_name" then cte_name_node = n[1] end
            if QUERIES.cte_def.captures[capid] == "cte_body" then cte_body_node = n[1] end
        end

        local cte_name = get_text(cte_name_node, bufnr)

        if cte_name and cte_body_node then
            local select_node = nil
            for child in cte_body_node:iter_children() do
                if child:type() == "select" then
                    select_node = child
                    break
                end
            end

            if not select_node then return cte_defs end
            local select_expr = nil
            for child in select_node:iter_children() do
                if child:type() == "select_expression" then
                    select_expr = child
                    break
                end
            end

            local cols = {}
            if select_expr then
                _, cols = get_columns_from_select_expr(select_expr, bufnr)
            end

            cte_defs[normalize(cte_name)] = {
                name = cte_name,
                columns = cols,
                node = cte_name_node,
            }
        end
    end
    return cte_defs
end

-- =============================================================================
-- Logic: Schema Analysis (Scoped with boundary check)
-- =============================================================================

local function analyze_relations(scope_nodes, bufnr, diagnostics, cte_defs)
    local relation_map = {}
    local active_tables_list = {}
    local temp_rels = {}
    local has_unqualified = false

    for _, node in ipairs(scope_nodes) do
        for _, rel_node in QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(rel_node, node) then goto continue end

            local is_derived = false
            for child in rel_node:iter_children() do
                if child:type() == "subquery" then
                    is_derived = true
                    break
                end
            end

            local obj_ref = nil
            if not is_derived then
                for child in rel_node:iter_children() do
                    if child:type() == "object_reference" then
                        obj_ref = child
                        break
                    end
                end
            end

            if obj_ref then
                local parts = {}
                for part in obj_ref:iter_children() do
                    if part:type() == "identifier" then table.insert(parts, get_text(part, bufnr)) end
                end

                local db_name, table_name
                if #parts == 2 then
                    db_name = util.replace_env_vars(parts[1]):upper()
                    table_name = parts[2]
                elseif #parts == 1 then
                    table_name = parts[1]
                end

                local alias_node = rel_node:field("alias")[1]
                local alias = alias_node and get_text(alias_node, bufnr)

                local def = { db = db_name, table = table_name, derived = false }

                table.insert(temp_rels, { def = def, node = obj_ref, alias = alias })
            elseif is_derived then
                local alias_node = rel_node:field("alias")[1]
                if alias_node then
                    local alias = get_text(alias_node, bufnr)
                    relation_map[normalize(alias)] = { derived = true }
                end
            end

            ::continue::
        end
    end

    local used_dbs = {}
    for _, item in ipairs(temp_rels) do
        if item.def.db then
            used_dbs[item.def.db] = true
        end
    end

    for _, item in ipairs(temp_rels) do
        local def = item.def
        local node = item.node
        local alias = item.alias
        local is_valid = true

        if def.db then
            if not has_db(def.db) then
                add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR, 'Unknown database: "' .. def.db .. '"')
                is_valid = false
            else
                if not has_table(def.db, def.table) then
                    add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR,
                        'Table "' .. def.table .. '" not found in ' .. def.db)
                    is_valid = false
                end
            end
        else -- Unqualified table/alias
            local cte_def = cte_defs[normalize(def.table)]

            if cte_def then
                -- It's a CTE. Mark as derived/CTE and add columns.
                def.derived = true
                def.is_cte = true -- Custom flag to distinguish CTE from generic derived
                def.columns = cte_def.columns
                is_valid = true   -- It's a valid reference.
            else
                -- Not a CTE, so it must be an unqualified base table.
                has_unqualified = true
                local found = false
                for db in pairs(used_dbs) do
                    if has_table(db, def.table) then
                        found = true
                        break
                    end
                end
                if next(used_dbs) ~= nil and not found then
                    add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR,
                        'Unknown table: "' .. def.table .. '" (not found in used databases)')
                    is_valid = false
                end
            end
        end

        if is_valid then
            -- Note: 'def' is now either a valid base table OR a valid CTE definition.
            relation_map[normalize(def.table)] = def
            if alias then relation_map[normalize(alias)] = def end
            table.insert(active_tables_list, def)
        end
    end

    return relation_map, active_tables_list, has_unqualified
end

-- Capture output aliases (AS xxx) from the SELECT list to treat them as valid columns
local function get_output_aliases(scope_nodes, bufnr)
    local output_aliases = {}
    for _, node in ipairs(scope_nodes) do
        for _, alias_node in QUERIES.select_output_alias:iter_captures(node, bufnr, 0, -1) do
            if not is_nested_in_subquery(alias_node, node) then
                local text = get_text(alias_node, bufnr)
                if text then
                    output_aliases[normalize(text)] = true
                end
            end
        end
    end
    return output_aliases
end

local function check_ambiguous_columns(scope_nodes, bufnr, active_tables, diagnostics, has_unqualified)
    if has_unqualified then return end

    if #active_tables < 2 then return end

    for _, node in ipairs(scope_nodes) do
        for _, col_node in QUERIES.bare_field:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(col_node, node) then goto continue end

            local field_node = col_node:parent()
            local is_qualified = false
            for child in field_node:iter_children() do
                if child:type() == "object_reference" then
                    is_qualified = true; break
                end
            end

            if not is_qualified then
                local col_name = get_text(col_node, bufnr)
                local found_in = {}

                for _, rel in ipairs(active_tables) do
                    if rel.derived and not rel.is_cte then goto next_rel end

                    local t_name = rel.table
                    local d_name = rel.db
                    local has_col = false

                    if rel.is_cte then
                        -- Check column in CTE
                        for _, cte_col in ipairs(rel.columns) do
                            if normalize_col(cte_col.name) == normalize_col(col_name) then
                                has_col = true
                                break
                            end
                        end
                    elseif d_name then
                        -- Check column in base table
                        has_col = has_column(d_name, t_name, col_name)
                    end

                    if has_col then table.insert(found_in, t_name) end
                    ::next_rel::
                end

                if #found_in > 1 then
                    local list = table.concat(found_in, ", ")
                    local msg = string.format('Ambiguous column "%s" — exists in: %s', col_name, list)
                    add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR, msg)
                end
            end
            ::continue::
        end
    end
end

local function check_field_validity(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified,
                                    output_aliases)
    for _, node in ipairs(scope_nodes) do
        for _, field_node in QUERIES.qualified_field:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(field_node, node) then goto continue end

            local qualifier_node = nil
            local col_node = nil

            for child in field_node:iter_children() do
                if child:type() == "object_reference" then
                    qualifier_node = child:named_child(child:named_child_count() - 1)
                elseif child:type() == "identifier" and child:parent():field("name")[1] == child then
                    col_node = child
                end
            end

            if qualifier_node and col_node then
                local qualifier = get_text(qualifier_node, bufnr)
                local col_name = get_text(col_node, bufnr)
                local col_norm = normalize_col(col_name)
                local rel_def = relation_map[normalize(qualifier)]

                if rel_def then
                    local found = false
                    if rel_def.is_cte then
                        -- Check against CTE columns
                        for _, cte_col in ipairs(rel_def.columns) do
                            if normalize_col(cte_col.name) == col_norm then
                                found = true
                                break
                            end
                        end
                    elseif rel_def.derived then
                        goto continue -- Derived tables (not CTEs) are not checked for columns.
                    elseif rel_def.db then
                        found = has_column(rel_def.db, rel_def.table, col_name)
                    end

                    if not found then
                        add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR,
                            string.format('Column "%s" not found in table "%s"', col_name, rel_def.table or rel_def.name))
                    end
                end
            end
            ::continue::
        end

        for _, col_node in QUERIES.bare_field:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(col_node, node) then goto continue end

            local field_node = col_node:parent()
            local is_qualified = false
            for child in field_node:iter_children() do
                if child:type() == "object_reference" then
                    is_qualified = true; break
                end
            end

            local has_derived = false
            for _, t in pairs(relation_map) do
                if t.derived and not t.is_cte then
                    has_derived = true
                    break
                end
            end

            if not is_qualified and #active_tables > 0 and not has_derived then
                local col_name = get_text(col_node, bufnr)
                local col_norm = normalize_col(col_name)

                if output_aliases[col_norm] then goto continue end

                local found_anywhere = false
                local searched_in = {}

                for _, rel in ipairs(active_tables) do
                    local is_base_table = not rel.derived
                    local has_col = false

                    if rel.is_cte then
                        for _, cte_col in ipairs(rel.columns) do
                            if normalize_col(cte_col.name) == col_norm then
                                has_col = true
                                break
                            end
                        end
                        table.insert(searched_in, rel.table .. " (CTE)")
                    elseif is_base_table then
                        local t_name = rel.table
                        local d_name = rel.db
                        table.insert(searched_in, d_name and (d_name .. "." .. t_name) or ("unqualified." .. t_name))
                        if d_name then
                            has_col = has_column(d_name, t_name, col_name)
                        end
                    end

                    if has_col then found_anywhere = true end
                end

                if not found_anywhere and #searched_in > 0 then
                    if not has_unqualified then
                        local tables_str = table.concat(searched_in, ", ")
                        add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR,
                            string.format('Column "%s" not found in any active table (%s)', col_name, tables_str))
                    end
                end
            end
            ::continue::
        end
    end
end

local function check_undefined_alias(scope_nodes, bufnr, diagnostics)
    local defined_aliases = {}
    for _, node in ipairs(scope_nodes) do
        for _, cap in QUERIES.alias_def:iter_captures(node, bufnr, 0, -1) do
            if not is_nested_in_subquery(cap, node) then
                local text = get_text(cap, bufnr)
                if text then defined_aliases[normalize(text)] = true end
            end
        end
    end

    for _, node in ipairs(scope_nodes) do
        for _, cap in QUERIES.alias_use:iter_captures(node, bufnr, 0, -1) do
            if not is_nested_in_subquery(cap, node) then
                local text = get_text(cap, bufnr)
                if text and not defined_aliases[normalize(text)] then
                    add_diagnostic(diagnostics, cap, bufnr, SEVERITY.ERROR,
                        'Alias "' .. text .. '" does not exist in query')
                end
            end
        end
    end
end

-- =============================================================================
-- Main Processing Logic (Scope Builder)
-- =============================================================================

local function get_query_scopes(root_node)
    local scopes = {}

    local function traverse(node)
        local type = node:type()
        local is_container = (type == 'statement' or type == 'subquery')

        if is_container then
            local has_set_op = false
            for child in node:iter_children() do
                if child:type() == 'set_operation' then
                    has_set_op = true
                    break
                end
            end

            if has_set_op then
                for child in node:iter_children() do traverse(child) end
            else
                local scope = {}
                for child in node:iter_children() do
                    table.insert(scope, child)
                end
                if #scope > 0 then table.insert(scopes, scope) end
                for child in node:iter_children() do traverse(child) end
            end
        elseif type == 'set_operation' then
            local current_scope = {}
            for child in node:iter_children() do
                local c_type = child:type()
                if c_type == 'select' then
                    local has_select = false
                    for _, n in ipairs(current_scope) do
                        if n:type() == 'select' then
                            has_select = true
                            break
                        end
                    end
                    if has_select then
                        table.insert(scopes, current_scope)
                        current_scope = {}
                    end
                end
                if c_type ~= 'keyword_union' and c_type ~= 'union' then
                    table.insert(current_scope, child)
                end
                traverse(child)
            end
            if #current_scope > 0 then table.insert(scopes, current_scope) end
        else
            for child in node:iter_children() do traverse(child) end
        end
    end

    traverse(root_node)
    return scopes
end

local function process_statement(stmt_node, bufnr, diagnostics)
    local cte_defs = get_cte_definitions(stmt_node, bufnr)

    check_union_column_compatibility(stmt_node, bufnr, diagnostics)

    local scopes = get_query_scopes(stmt_node)

    for _, scope_nodes in ipairs(scopes) do
        -- Pass CTE definitions to analyze_relations
        local relation_map, active_tables, has_unqualified = analyze_relations(scope_nodes, bufnr, diagnostics, cte_defs)
        local output_aliases = get_output_aliases(scope_nodes, bufnr)
        check_field_validity(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified,
            output_aliases)
        check_ambiguous_columns(scope_nodes, bufnr, active_tables, diagnostics, has_unqualified)
        check_undefined_alias(scope_nodes, bufnr, diagnostics)
    end
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.update_diagnostics(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "sql")
    if not ok or not parser then return end

    local trees = parser:parse()
    if not trees then return end

    local diagnostics = {}
    for _, tree in ipairs(trees) do
        local root = tree:root()

        for _, node in QUERIES.syntax_error:iter_captures(root, bufnr, 0, -1) do
            add_diagnostic(diagnostics, node, bufnr, SEVERITY.ERROR, get_syntax_error_message(node, bufnr))
        end

        for _, stmt_node in QUERIES.statement:iter_captures(root, bufnr, 0, -1) do
            process_statement(stmt_node, bufnr, diagnostics)
        end
    end
    vim.diagnostic.reset(NAMESPACE, bufnr)
    vim.diagnostic.set(NAMESPACE, bufnr, diagnostics)
end

return M
