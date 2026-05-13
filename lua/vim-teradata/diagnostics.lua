local util = require('vim-teradata.util')
local tsu  = require('vim-teradata.ts-util')
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

local NODE = {
    EXISTS = "exists",
    SELECT = "select",
    SELECT_EXPR = "select_expression",
    SUBQUERY = "subquery",
    OBJ_REF = "object_reference",
    IDENTIFIER = "identifier",
    SET_OPE = "set_operation",
    TERM = "term",
    FIELD = "field",
    GROUP_BY = "group_by",
    INVOCATION = "invocation",
    LITERAL = "literal",
    JOIN = "join",
}

local AGGREGATE_FNS = {
    COUNT = true, SUM = true, AVG = true, MIN = true, MAX = true,
    STDDEV = true, STDDEV_POP = true, STDDEV_SAMP = true,
    VAR_POP = true, VAR_SAMP = true, VARIANCE = true,
    KURTOSIS = true, SKEW = true, CORR = true,
    COVAR_POP = true, COVAR_SAMP = true,
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
    subquery_select = parse_query("sql", [[ (subquery (select (select_expression) @sub_select_expr)) ]]),
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

    syntax_error = parse_query("sql", [[ (ERROR) @error ]]),

    join_nodes     = parse_query("sql", [[ (join) @join ]]),
    select_exprs   = parse_query("sql", [[ (select (select_expression) @sel_expr) ]]),
    group_by_nodes = parse_query("sql", [[ (group_by) @gb ]]),
    cte_select_exp = parse_query("sql", [[ (cte (statement (select (select_expression) @cte_sel_expr))) ]]),
    invocation_nod = parse_query("sql", [[ (invocation) @inv ]]),
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

---Returns a flat list of AND-conjuncts from a binary_expression tree.
---@param node TSNode
---@return TSNode[]
local function flatten_and_conjuncts(node)
    if node:type() ~= "binary_expression" then return { node } end
    local has_and = false
    for c in node:iter_children() do
        if c:type() == "keyword_and" then has_and = true; break end
    end
    if not has_and then return { node } end
    local out = {}
    for c in node:iter_children() do
        if c:type() ~= "keyword_and" then
            vim.list_extend(out, flatten_and_conjuncts(c))
        end
    end
    return #out > 0 and out or { node }
end

---Returns true if inv_node is a call to a known aggregate function.
---@param inv_node TSNode
---@param bufnr number
---@return boolean
local function is_aggregate_invocation(inv_node, bufnr)
    for c in inv_node:iter_children() do
        if c:type() == NODE.OBJ_REF then
            local name_id = nil
            for part in c:iter_children() do
                if part:type() == NODE.IDENTIFIER then name_id = part end
            end
            if name_id then
                return AGGREGATE_FNS[normalize(get_text(name_id, bufnr) or "")] == true
            end
        end
    end
    return false
end

---Returns true if node is a descendant of an aggregate invocation, stopping at select_expression.
---@param node TSNode
---@param bufnr number
---@return boolean
local function is_under_aggregate(node, bufnr)
    local p = node:parent()
    while p do
        local t = p:type()
        if t == NODE.SELECT_EXPR then return false end
        if t == NODE.INVOCATION and is_aggregate_invocation(p, bufnr) then return true end
        p = p:parent()
    end
    return false
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

-- forward declaration
local get_query_scopes
local analyze_relations

-- =============================================================================
-- Logic: Union & Subquery Compatibility
-- =============================================================================

local function get_columns_from_select_expr(expr_node, bufnr)
    local cols = {}
    local number_fields = 0
    for term_node in expr_node:iter_children() do
        if term_node:type() == NODE.TERM then
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
                    if field_node:type() == NODE.FIELD then
                        local child = field_node:child(0)
                        if child and child:type() == NODE.OBJ_REF then
                            local name_nodes = field_node:field("name")
                            if #name_nodes > 0 then
                                final_name = get_text(name_nodes[1], bufnr)
                            end
                        else
                            local name_node = field_node:field("name")[1]
                            if name_node and name_node:type() == NODE.IDENTIFIER then
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
            local parent = node:parent()
            if parent then parent = parent:parent() end
            if parent == union_node then
                table.insert(select_exprs, node)
            end

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

local function check_subquery_unnamed_fields(stmt_node, bufnr, diagnostics)
    for _, select_expr_node in QUERIES.subquery_select:iter_captures(stmt_node, bufnr, 0, -1) do
        local seen_cols = {}
        local exists_node = tsu.ancestor(select_expr_node, NODE.EXISTS)
        local sel_expr_txt = get_text(select_expr_node, bufnr)
        if not exists_node and sel_expr_txt ~= "*" then
            local _, cols = get_columns_from_select_expr(select_expr_node, bufnr)
            for _, col in ipairs(cols) do
                if col.name == "" then
                    add_diagnostic(
                        diagnostics,
                        col.node,
                        bufnr,
                        SEVERITY.ERROR,
                        "Subquery field must have a name or an alias."
                    )
                else
                    local col_norm = normalize(col.name)
                    if seen_cols[col_norm] then
                        add_diagnostic(
                            diagnostics,
                            col.node,
                            bufnr,
                            SEVERITY.ERROR,
                            "Duplication of column " .. col_norm .. " in a derived table"
                        )
                    end
                    seen_cols[col_norm] = true
                end
            end
        end
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
                if child:type() == NODE.SELECT then
                    select_node = child
                    break
                end
            end

            if not select_node then return cte_defs end
            local select_expr = nil
            for child in select_node:iter_children() do
                if child:type() == NODE.SELECT_EXPR then
                    select_expr = child
                    break
                end
            end

            local cols = {}
            if select_expr then
                if get_text(select_expr, bufnr) == "*" then
                    -- Expansion logic for CTEs
                    local inner_scopes = get_query_scopes(cte_body_node)
                    if #inner_scopes > 0 then
                        local _, inner_active = analyze_relations(inner_scopes[1], bufnr, {}, cte_defs)
                        for _, rel in ipairs(inner_active) do
                            if rel.db and rel.table then
                                local schema_cols = util.get_columns({ { db_name = rel.db, tb_name = rel.table } }) or {}
                                for _, c in ipairs(schema_cols) do table.insert(cols, { name = c }) end
                            elseif rel.columns then
                                for _, c in ipairs(rel.columns) do table.insert(cols, { name = c.name }) end
                            end
                        end
                    end
                else
                    _, cols = get_columns_from_select_expr(select_expr, bufnr)
                end
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

function analyze_relations(scope_nodes, bufnr, diagnostics, cte_defs)
    local relation_map = {}
    local active_tables_list = {}
    local temp_rels = {}
    local has_unqualified = false

    for _, node in ipairs(scope_nodes) do
        for _, rel_node in QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(rel_node, node) then goto continue end

            local is_derived = false
            for child in rel_node:iter_children() do
                if child:type() == NODE.SUBQUERY then
                    is_derived = true
                    break
                end
            end

            local obj_ref = nil
            if not is_derived then
                for child in rel_node:iter_children() do
                    if child:type() == NODE.OBJ_REF then
                        obj_ref = child
                        break
                    end
                end
            end

            if obj_ref then
                local parts = {}
                for part in obj_ref:iter_children() do
                    if part:type() == NODE.IDENTIFIER then table.insert(parts, get_text(part, bufnr)) end
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
                    local cols = {}

                    local subquery_node = nil
                    for child in rel_node:iter_children() do
                        if child:type() == NODE.SUBQUERY then
                            subquery_node = child
                            break
                        end
                    end

                    if subquery_node then
                        local select_node = tsu.descendant(subquery_node, NODE.SELECT)
                        local select_expr = select_node and
                            tsu.descendant(select_node, NODE.SELECT_EXPR)

                        if select_expr then
                            local expr_text = get_text(select_expr, bufnr)
                            -- CASE: SELECT *
                            if expr_text == "*" then
                                -- We look at the relations inside the subquery to expand the *
                                local inner_scopes = get_query_scopes(subquery_node)
                                if #inner_scopes > 0 then
                                    -- Run a "silent" analysis on the inner scope to find its source tables
                                    -- We pass an empty table for diagnostics to avoid duplicate reporting
                                    local _, inner_active = analyze_relations(inner_scopes[1], bufnr, {}, cte_defs)
                                    for _, rel in ipairs(inner_active) do
                                        if rel.db and rel.table then
                                            -- Base Table: fetch real columns from schema
                                            local schema_cols = util.get_columns({ { db_name = rel.db, tb_name = rel.table } }) or
                                                {}
                                            for _, cname in ipairs(schema_cols) do
                                                table.insert(cols, { name = cname })
                                            end
                                        elseif rel.columns then
                                            -- Nested derived table or CTE: use its already resolved columns
                                            for _, c in ipairs(rel.columns) do
                                                table.insert(cols, { name = c.name })
                                            end
                                        end
                                    end
                                end
                            else
                                -- CASE: Explicit column list
                                _, cols = get_columns_from_select_expr(select_expr, bufnr)
                            end
                        end
                    end

                    local def = {
                        derived = true,
                        columns = cols,
                        table = normalize(alias),
                        is_cte = false
                    }
                    relation_map[normalize(alias)] = def
                    table.insert(active_tables_list, def)
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

local function check_ambiguous_columns(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified)
    if has_unqualified then return end

    if #active_tables < 2 then return end

    for _, node in ipairs(scope_nodes) do
        for _, col_node in QUERIES.bare_field:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(col_node, node) then goto continue end

            local field_node = col_node:parent()
            if not field_node then goto continue end

            local parent = field_node:parent()
            if parent and parent:type() == "assignment" then
                local left = parent:field("left")[1]
                -- Check if this node is the LHS of the assignment
                if left and left:id() == field_node:id() then
                    local update_node = parent:parent()
                    -- Ensure we are in an UPDATE statement context
                    if update_node and update_node:type() == "update" then
                        -- 1. Extract the Update Target Name
                        local target_parts = {}
                        for child in update_node:iter_children() do
                            if child:type() == NODE.OBJ_REF then
                                for part in child:iter_children() do
                                    if part:type() == NODE.IDENTIFIER then
                                        table.insert(target_parts, get_text(part, bufnr))
                                    end
                                end
                                break
                            end
                        end

                        -- 2. Normalize Target (DB.TABLE or TABLE/ALIAS)
                        local t_db, t_name
                        if #target_parts == 2 then
                            t_db = util.replace_env_vars(target_parts[1]):upper()
                            t_name = target_parts[2]:upper()
                        elseif #target_parts == 1 then
                            t_name = target_parts[1]:upper()
                        end

                        if t_name then
                            -- 3. Find the matching relation in active_tables
                            local target_rel = relation_map[t_name]

                            if not target_rel then
                                for _, rel in ipairs(active_tables) do
                                    local r_alias = rel.alias and normalize(rel.alias)
                                    local r_table = normalize(rel.table)
                                    local r_db    = rel.db and normalize(rel.db)

                                    local match   = false
                                    if t_db then
                                        -- Match Qualified (DB.TABLE)
                                        if r_db == t_db and r_table == t_name then match = true end
                                    else
                                        -- Match Unqualified (Alias or Table Name)
                                        if (r_alias == t_name) or (not r_alias and r_table == t_name) then match = true end
                                    end

                                    if match then
                                        target_rel = rel
                                        break
                                    end
                                end
                            end

                            -- 4. Validate existence in Target Table ONLY
                            if target_rel then
                                local col_name = get_text(col_node, bufnr)
                                local has_col = false

                                if target_rel.is_cte then
                                    for _, c in ipairs(target_rel.columns) do
                                        if normalize_col(c.name) == normalize_col(col_name) then
                                            has_col = true
                                            break
                                        end
                                    end
                                elseif target_rel.db then
                                    has_col = has_column(target_rel.db, target_rel.table, col_name)
                                end

                                if not has_col then
                                    add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR,
                                        string.format('Column "%s" not found in update target "%s"', col_name, t_name))
                                end

                                goto continue
                            end
                        end
                    end
                end
            end

            local is_qualified = false
            for child in field_node:iter_children() do
                if child:type() == NODE.IDENTIFIER then
                    is_qualified = true; break
                end
            end

            if not is_qualified then
                local col_name = get_text(col_node, bufnr)
                local found_in = {}

                for _, rel in ipairs(active_tables) do
                    local has_col = false
                    if rel.is_cte or (rel.derived and rel.columns) then
                        for _, col in ipairs(rel.columns) do
                            if normalize_col(col.name) == normalize_col(col_name) then
                                has_col = true
                                break
                            end
                        end
                    elseif rel.db then
                        has_col = has_column(rel.db, rel.table, col_name)
                    end

                    if has_col then table.insert(found_in, rel.table or "subquery") end
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
                if child:type() == NODE.OBJ_REF then
                    qualifier_node = child:named_child(child:named_child_count() - 1)
                elseif child:type() == NODE.IDENTIFIER and child:parent():field("name")[1] == child then
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
                    -- Check against columns if it's a CTE OR a derived table with columns
                    if rel_def.is_cte or (rel_def.derived and rel_def.columns) then
                        for _, col in ipairs(rel_def.columns) do
                            if normalize_col(col.name) == col_norm then
                                found = true
                                break
                            end
                        end
                    elseif rel_def.db then
                        found = has_column(rel_def.db, rel_def.table, col_name)
                    end

                    if not found then
                        add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR,
                            string.format('Column "%s" not found in %s "%s"',
                                col_name,
                                rel_def.derived and "derived table" or "table",
                                rel_def.table or rel_def.name))
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
                if child:type() == NODE.OBJ_REF then
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
                    local has_col = false

                    if rel.is_cte or (rel.derived and rel.columns) then
                        for _, col in ipairs(rel.columns) do
                            if normalize_col(col.name) == col_norm then
                                has_col = true
                                break
                            end
                        end
                        local label = rel.is_cte and "CTE" or "derived"
                        table.insert(searched_in, string.format("%s (%s)", rel.table, label))
                    elseif not rel.derived and rel.db then
                        local t_name = rel.table
                        local d_name = rel.db
                        table.insert(searched_in, d_name .. "." .. t_name)
                        has_col = has_column(d_name, t_name, col_name)
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
-- Logic: New Statement-level Checks
-- =============================================================================

local function check_select_star_in_subquery(stmt_node, bufnr, diagnostics)
    for _, expr in QUERIES.subquery_select:iter_captures(stmt_node, bufnr, 0, -1) do
        if tsu.ancestor(expr, NODE.EXISTS) then goto continue end
        if get_text(expr, bufnr) == "*" then
            add_diagnostic(diagnostics, expr, bufnr, SEVERITY.INFO,
                "SELECT * inside subquery — list columns explicitly to guard against schema drift.")
        end
        ::continue::
    end
    for _, expr in QUERIES.cte_select_exp:iter_captures(stmt_node, bufnr, 0, -1) do
        if get_text(expr, bufnr) == "*" then
            add_diagnostic(diagnostics, expr, bufnr, SEVERITY.INFO,
                "SELECT * inside CTE — list columns explicitly to guard against schema drift.")
        end
    end
end

local function check_group_by_ordinal(stmt_node, bufnr, diagnostics)
    for _, gb in QUERIES.group_by_nodes:iter_captures(stmt_node, bufnr, 0, -1) do
        for child in gb:iter_children() do
            if child:type() == NODE.LITERAL then
                local txt = get_text(child, bufnr) or ""
                if txt:match("^%d+$") then
                    add_diagnostic(diagnostics, child, bufnr, SEVERITY.INFO,
                        string.format('GROUP BY uses ordinal %s — prefer an explicit column name.', txt))
                end
            end
        end
    end
end

local function check_duplicate_columns_in_select(stmt_node, bufnr, diagnostics)
    for _, sel_expr in QUERIES.select_exprs:iter_captures(stmt_node, bufnr, 0, -1) do
        local seen_alias = {}
        local seen_expr  = {}
        for term in sel_expr:iter_children() do
            if term:type() ~= NODE.TERM then goto next_term end
            local alias_node = term:field("alias")[1]
            local value_node = term:named_child(0)
            local alias_key  = alias_node and normalize(get_text(alias_node, bufnr) or "")
            local val_text   = value_node and get_text(value_node, bufnr)
            local expr_key   = val_text and val_text:gsub("%s+", " "):upper()

            if alias_key then
                if seen_alias[alias_key] then
                    add_diagnostic(diagnostics, term, bufnr, SEVERITY.WARN,
                        string.format('Duplicate output alias "%s" in SELECT list.', alias_key))
                else
                    seen_alias[alias_key] = true
                end
            elseif expr_key then
                if seen_expr[expr_key] then
                    add_diagnostic(diagnostics, term, bufnr, SEVERITY.WARN,
                        string.format('Duplicate expression in SELECT list: %s', val_text))
                else
                    seen_expr[expr_key] = true
                end
            end
            ::next_term::
        end
    end
end

local function check_unused_cte(stmt_node, bufnr, diagnostics, cte_defs)
    if next(cte_defs) == nil then return end
    local referenced = {}
    for _, rel in QUERIES.relation:iter_captures(stmt_node, bufnr, 0, -1) do
        local obj_ref
        for c in rel:iter_children() do
            if c:type() == NODE.OBJ_REF then obj_ref = c; break end
        end
        if not obj_ref then goto continue end
        local parts = {}
        for p in obj_ref:iter_children() do
            if p:type() == NODE.IDENTIFIER then table.insert(parts, get_text(p, bufnr)) end
        end
        if #parts == 1 then
            referenced[normalize(parts[1])] = true
        end
        ::continue::
    end
    for name_norm, def in pairs(cte_defs) do
        if not referenced[name_norm] then
            add_diagnostic(diagnostics, def.node, bufnr, SEVERITY.WARN,
                string.format('CTE "%s" is defined but never referenced.', def.name))
        end
    end
end

-- =============================================================================
-- Logic: New Per-scope Checks
-- =============================================================================

local function check_duplicate_join_conditions(scope_nodes, bufnr, diagnostics)
    for _, node in ipairs(scope_nodes) do
        for _, join in QUERIES.join_nodes:iter_captures(node, bufnr, 0, -1) do
            if is_nested_in_subquery(join, node) then goto continue end
            local pred = join:field("predicate")[1]
            if not pred then goto continue end
            local seen = {}
            for _, conj in ipairs(flatten_and_conjuncts(pred)) do
                local raw = get_text(conj, bufnr) or ""
                local key = raw:gsub("%s+", " "):upper()
                local lhs, rhs = key:match("^(.+)%s*=%s*(.+)$")
                if lhs and rhs then
                    lhs = lhs:gsub("^%s+", ""):gsub("%s+$", "")
                    rhs = rhs:gsub("^%s+", ""):gsub("%s+$", "")
                    if lhs > rhs then key = rhs .. " = " .. lhs end
                end
                if seen[key] then
                    add_diagnostic(diagnostics, conj, bufnr, SEVERITY.WARN,
                        "Duplicate join condition in ON clause.")
                else
                    seen[key] = true
                end
            end
            ::continue::
        end
    end
end

local function check_non_aggregated_columns(scope_nodes, bufnr, diagnostics)
    local sel_expr, gb_node
    for _, n in ipairs(scope_nodes) do
        -- select is a direct child of statement
        if not sel_expr and n:type() == NODE.SELECT then
            sel_expr = tsu.descendant(n, NODE.SELECT_EXPR)
        end
        -- group_by lives inside `from`, so search recursively with scope guard
        if not gb_node then
            for _, gb in QUERIES.group_by_nodes:iter_captures(n, bufnr, 0, -1) do
                if not is_nested_in_subquery(gb, n) then
                    gb_node = gb; break
                end
            end
        end
    end
    if not sel_expr then return end

    -- Detect aggregation: GROUP BY present, or aggregate invocation in SELECT list
    local has_aggregate = false
    for _, inv in QUERIES.invocation_nod:iter_captures(sel_expr, bufnr, 0, -1) do
        if is_aggregate_invocation(inv, bufnr) then has_aggregate = true; break end
    end
    if not gb_node and not has_aggregate then return end

    -- Collect GROUP BY expressions, resolving ordinals against SELECT terms
    local select_terms = {}
    for t in sel_expr:iter_children() do
        if t:type() == NODE.TERM then table.insert(select_terms, t) end
    end

    local gb_field_names = {}
    local gb_expr_texts  = {}

    local function index_gb_expression(expr_node)
        local txt = (get_text(expr_node, bufnr) or ""):gsub("%s+", " "):upper()
        gb_expr_texts[txt] = true
        for _, f in QUERIES.bare_field:iter_captures(expr_node, bufnr, 0, -1) do
            gb_field_names[normalize_col(get_text(f, bufnr) or "")] = true
        end
    end

    if gb_node then
        for child in gb_node:iter_children() do
            local t = child:type()
            if t == "keyword_group" or t == "keyword_by" or t == "," then goto skip_gb end
            local raw = (get_text(child, bufnr) or ""):gsub("%s+", "")
            local ordinal = tonumber(raw:match("^(%d+)$"))
            if ordinal then
                local resolved = select_terms[ordinal]
                if resolved then
                    local alias = resolved:field("alias")[1]
                    local value = resolved:named_child(0)
                    if alias then
                        gb_field_names[normalize_col(get_text(alias, bufnr) or "")] = true
                    elseif value then
                        index_gb_expression(value)
                    end
                end
            else
                index_gb_expression(child)
            end
            ::skip_gb::
        end
    end

    -- Flag bare columns in SELECT not covered by GROUP BY and not under an aggregate
    for _, term in ipairs(select_terms) do
        local value = term:named_child(0)
        if not value then goto next_term end
        local val_text = (get_text(value, bufnr) or ""):gsub("%s+", " "):upper()
        if gb_expr_texts[val_text] then goto next_term end

        local term_alias = term:field("alias")[1]
        if term_alias then
            local alias_name = normalize_col(get_text(term_alias, bufnr) or "")
            if gb_field_names[alias_name] then goto next_term end
        end

        for _, col in QUERIES.bare_field:iter_captures(term, bufnr, 0, -1) do
            if is_under_aggregate(col, bufnr) then goto next_col end
            local name = normalize_col(get_text(col, bufnr) or "")
            if not gb_field_names[name] then
                add_diagnostic(diagnostics, col, bufnr, SEVERITY.ERROR,
                    string.format('"%s" must appear in GROUP BY or be wrapped in an aggregate.', name))
            end
            ::next_col::
        end
        ::next_term::
    end
end

-- =============================================================================
-- Main Processing Logic (Scope Builder)
-- =============================================================================

function get_query_scopes(root_node)
    local scopes = {}

    local function traverse(node)
        local type = node:type()
        local is_container = (type == 'statement' or type == 'subquery')

        if is_container then
            local has_set_op = false
            for child in node:iter_children() do
                if child:type() == NODE.SET_OPE then
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
                        if n:type() == NODE.SELECT then
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
    check_subquery_unnamed_fields(stmt_node, bufnr, diagnostics)
    check_select_star_in_subquery(stmt_node, bufnr, diagnostics)
    check_group_by_ordinal(stmt_node, bufnr, diagnostics)
    check_duplicate_columns_in_select(stmt_node, bufnr, diagnostics)
    check_unused_cte(stmt_node, bufnr, diagnostics, cte_defs)

    local scopes = get_query_scopes(stmt_node)

    for _, scope_nodes in ipairs(scopes) do
        local relation_map, active_tables, has_unqualified = analyze_relations(scope_nodes, bufnr, diagnostics, cte_defs)
        local output_aliases = get_output_aliases(scope_nodes, bufnr)
        check_field_validity(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified,
            output_aliases)
        check_ambiguous_columns(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified)
        check_undefined_alias(scope_nodes, bufnr, diagnostics)
        check_duplicate_join_conditions(scope_nodes, bufnr, diagnostics)
        check_non_aggregated_columns(scope_nodes, bufnr, diagnostics)
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

-- =============================================================================
-- Shared helpers (used by code_actions.lua)
-- =============================================================================

M.QUERIES = QUERIES
M.get_query_scopes = get_query_scopes
M.analyze_relations = analyze_relations
M.get_cte_definitions = get_cte_definitions
M.get_columns_from_select_expr = get_columns_from_select_expr
M.is_nested_in_subquery = is_nested_in_subquery
M.get_text = get_text

return M
