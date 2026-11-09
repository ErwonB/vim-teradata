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
    HINT = vim.diagnostic.severity.HINT,
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
    CURSOR_PARAMETER = "cursor_parameter",
    WINDOW_FUNCTION = "window_function",
}

local AGGREGATE_FNS = {
    COUNT = true, SUM = true, AVG = true, MIN = true, MAX = true,
    STDDEV = true, STDDEV_POP = true, STDDEV_SAMP = true,
    VAR_POP = true, VAR_SAMP = true, VARIANCE = true,
    KURTOSIS = true, SKEW = true, CORR = true,
    COVAR_POP = true, COVAR_SAMP = true,
    MEDIAN = true, PERCENTILE_DISC = true, PERCENTILE_CONT = true,
    PERCENT_RANK = true, RANK = true, CUME_DIST = true,
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
    if not util.has_catalog() then return true end
    return util.is_a_db(db_name)
end

local function has_table(db, tb)
    if not util.has_catalog() then return true end
    local db_norm = normalize(db)
    local tb_norm = normalize(tb)
    return util.is_a_table(db_norm, tb_norm)
end


local function has_column(db, tb, col)
    if not util.has_catalog() then return true end
    local db_norm = normalize(db)
    local tb_norm = normalize(tb)
    local col_norm = normalize_col(col)
    return util.is_a_column(db_norm, tb_norm, col_norm)
end

-- =============================================================================
-- Treesitter Queries
-- =============================================================================

local QUERY_SRC = {
    alias_def = [[ (relation alias: (identifier) @alias_definition) ]],
    alias_use = [[ (select_expression (term value: (field (object_reference name: (identifier) @alias_usage)))) ]],
    union_select = [[ (set_operation (select (select_expression) @select_expr)) ]],
    union_block = [[ (set_operation) @union_block ]],
    subquery_select = [[ (subquery (select (select_expression) @sub_select_expr)) ]],
    relation = [[ (relation) @relation ]],
    statement = [[ (statement) @stmt ]],
    create_table = [[ (create_table) @ct ]],
    cte_def = [[
        (cte
            . (identifier) @cte_name
            (statement) @cte_body
        ) @cte
    ]],
    cte_column_list = [[
        (cte
            . (identifier)
            (identifier) @cte_col
            (keyword_as))
    ]],

    select_output_alias = [[
    (select_expression
      (term
        alias: (identifier) @output_alias
      )
    )
  ]],

    qualified_field = [[
    (field
      (object_reference name: (identifier) @qualifier)
      name: (identifier) @col_name
    ) @field
  ]],

    bare_field = [[
    (field name: (identifier) @col)
  ]],

    syntax_error = [[ (ERROR) @error ]],

    join_nodes     = [[ (join) @join ]],
    select_exprs   = [[ (select (select_expression) @sel_expr) ]],
    group_by_nodes = [[ (group_by) @gb ]],
    cte_select_exp = [[ (cte (statement (select (select_expression) @cte_sel_expr))) ]],
    invocation_nod = [[ (invocation) @inv ]],
}

local QUERIES = setmetatable({}, {
    __index = function(tbl, key)
        local src = QUERY_SRC[key]
        if not src then return nil end
        local parse_fn = vim.treesitter.query.parse
        local ok, q = pcall(parse_fn, "teradata", src)
        if not ok then
            return nil
        end
        rawset(tbl, key, q)
        return q
    end,
})

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

---Returns true if node is inside a window_function (OVER ...) before hitting select_expression.
---@param node TSNode
---@return boolean
local function is_under_window(node)
    local p = node:parent()
    while p do
        local t = p:type()
        if t == NODE.SELECT_EXPR then return false end
        if t == NODE.WINDOW_FUNCTION then return true end
        p = p:parent()
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
-- Logic: CTE & Local Table Analysis
-- =============================================================================

local buffer_local_tables = {}

local function cte_explicit_columns(cte_node, bufnr)
    local cols, first_seen = {}, false
    for child in cte_node:iter_children() do
        local t = child:type()
        if t == 'keyword_as' then break end
        if t == NODE.IDENTIFIER then
            if first_seen then
                table.insert(cols, { name = get_text(child, bufnr), node = child })
            else
                first_seen = true
            end
        end
    end
    return cols
end

local function find_first_select(node)
    if not node then return nil end
    for child in node:iter_children() do
        local t = child:type()
        if t == NODE.SELECT then
            return child
        elseif t ~= NODE.SUBQUERY then
            local found = find_first_select(child)
            if found then return found end
        end
    end
    return nil
end

--- Resolves output columns of a statement, subquery, or create_query node.
--- @param statement_or_query_node TSNode
--- @param bufnr number
--- @param cte_defs table|nil
--- @param local_tables table|nil
--- @return table|nil cols (nil when columns could not be resolved)
local function resolve_select_columns(statement_or_query_node, bufnr, cte_defs, local_tables)
    local select_node = find_first_select(statement_or_query_node)
    if not select_node then return nil end

    local select_expr = nil
    for child in select_node:iter_children() do
        if child:type() == NODE.SELECT_EXPR then
            select_expr = child
            break
        end
    end
    if not select_expr then return nil end

    local cols = {}
    if get_text(select_expr, bufnr) == "*" then
        local inner_scopes = get_query_scopes(statement_or_query_node)
        if #inner_scopes > 0 then
            local _, inner_active = analyze_relations(inner_scopes[1], bufnr, {}, cte_defs or {}, local_tables)
            for _, rel in ipairs(inner_active) do
                if rel.columns_unknown then
                    return nil
                elseif rel.db and rel.table then
                    local schema_cols = util.get_columns({ { db_name = rel.db, tb_name = rel.table } }) or {}
                    if #schema_cols == 0 and util.has_catalog() then
                        return nil
                    end
                    for _, c in ipairs(schema_cols) do table.insert(cols, { name = c }) end
                elseif rel.columns and #rel.columns > 0 then
                    for _, c in ipairs(rel.columns) do table.insert(cols, { name = c.name }) end
                else
                    return nil
                end
            end
        end
        if #cols == 0 then return nil end
    else
        _, cols = get_columns_from_select_expr(select_expr, bufnr)
        if #cols == 0 then return nil end
    end

    return cols
end

--- Collects single-part CREATE TABLE definitions from a root node (or buffer).
--- @param root_or_bufnr TSNode|number
--- @param bufnr number|nil
--- @return table<string, {name:string, columns:table|nil, volatile:boolean}>
local function collect_buffer_created_tables(root_or_bufnr, bufnr)
    local root = root_or_bufnr
    if type(root_or_bufnr) == "number" then
        bufnr = root_or_bufnr
        local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "teradata")
        if not ok or not parser then return {} end
        local parse_ok, trees = pcall(function() return parser:parse() end)
        if not parse_ok or not trees or #trees == 0 then return {} end
        root = trees[1]:root()
    end
    if not root or not bufnr then return {} end

    local out = {}
    if not QUERIES.create_table then return out end

    for _, ct_node in QUERIES.create_table:iter_captures(root, bufnr, 0, -1) do
        local obj_ref = nil
        local volatile = false
        local has_global, has_temp = false, false
        local col_defs_node = nil
        local query_node = nil

        for child in ct_node:iter_children() do
            local t = child:type()
            if t == NODE.OBJ_REF and not obj_ref then
                obj_ref = child
            elseif t == "keyword_volatile" then
                volatile = true
            elseif t == "keyword_global" then
                has_global = true
            elseif t == "keyword_temporary" then
                has_temp = true
            elseif t == "column_definitions" then
                col_defs_node = child
            elseif t == "create_query" or t == "statement" or t == "subquery" then
                query_node = child
            end
        end

        if has_global and has_temp then volatile = true end

        if obj_ref then
            local parts = {}
            for part in obj_ref:iter_children() do
                if part:type() == NODE.IDENTIFIER then
                    table.insert(parts, get_text(part, bufnr))
                end
            end

            if #parts == 1 and parts[1] then
                local tbl_name = parts[1]
                local cols = nil

                if col_defs_node then
                    local explicit_cols = {}
                    for child in col_defs_node:iter_children() do
                        if child:type() == "column_definition" then
                            local name_node = child:field("name")[1]
                            if not name_node then
                                for sub in child:iter_children() do
                                    if sub:type() == NODE.IDENTIFIER then
                                        name_node = sub
                                        break
                                    end
                                end
                            end
                            local cname = name_node and get_text(name_node, bufnr)
                            if cname then
                                table.insert(explicit_cols, { name = cname, node = name_node })
                            end
                        end
                    end
                    if #explicit_cols > 0 then
                        cols = explicit_cols
                    end
                end

                if not cols and query_node then
                    cols = resolve_select_columns(query_node, bufnr, {}, out)
                elseif not cols then
                    -- Handle case where SELECT is direct child of create_table
                    cols = resolve_select_columns(ct_node, bufnr, {}, out)
                end

                out[normalize(tbl_name)] = {
                    name = tbl_name,
                    columns = cols,
                    volatile = volatile,
                }
            end
        end
    end

    return out
end

--- Extracts CTE definitions (name and output columns) from a statement node.
--- @param stmt_node TSNode The root statement node (which may contain a WITH clause).
--- @param bufnr number The buffer number.
--- @param local_tables table|nil Optional buffer-created tables map.
--- @return table A map of normalized CTE name to its definition.
local function get_cte_definitions(stmt_node, bufnr, local_tables)
    local cte_defs = {}

    -- Pre-pass: register every CTE name so recursive self-references resolve.
    for _, m, _ in QUERIES.cte_def:iter_matches(stmt_node, bufnr, 0, -1) do
        for capid, n in pairs(m) do
            if QUERIES.cte_def.captures[capid] == "cte_name" then
                local nm = get_text(n[1], bufnr)
                if nm then
                    -- Seed with node/name so check_unused_cte never sees nil.
                    cte_defs[normalize(nm)] = { name = nm, columns = {}, node = n[1] }
                end
            end
        end
    end

    -- Main pass: fill in columns, overwriting the seed entries.
    for _, cte_def_match, _ in QUERIES.cte_def:iter_matches(stmt_node, bufnr, 0, -1) do
        local cte_node
        local cte_name_node
        local cte_body_node
        for capid, n in pairs(cte_def_match) do
            local cap = QUERIES.cte_def.captures[capid]
            if cap == "cte" then cte_node = n[1] end
            if cap == "cte_name" then cte_name_node = n[1] end
            if cap == "cte_body" then cte_body_node = n[1] end
        end

        local cte_name = get_text(cte_name_node, bufnr)
        if not (cte_name and cte_body_node) then goto next_cte end

        local cols = cte_node and cte_explicit_columns(cte_node, bufnr) or {}
        local columns_unknown = false

        if #cols == 0 then
            local resolved = resolve_select_columns(cte_body_node, bufnr, cte_defs, local_tables)
            if resolved and #resolved > 0 then
                cols = resolved
            else
                cols = {}
                columns_unknown = true
            end
        end

        cte_defs[normalize(cte_name)] = {
            name            = cte_name,
            columns         = cols,
            columns_unknown = columns_unknown,
            node            = cte_name_node,
        }

        ::next_cte::
    end

    return cte_defs
end

-- =============================================================================
-- Logic: Schema Analysis (Scoped with boundary check)
-- =============================================================================

--- @return boolean|nil  true = column exists, false = definitely missing,
---                      nil = cannot tell (unknown relation) -> NO diagnostic
local function relation_has_column(rel, col_name)
    if rel.columns_unknown then return nil end
    if rel.columns then
        local want = normalize_col(col_name)
        for _, c in ipairs(rel.columns) do
            if normalize_col(c.name) == want then return true end
        end
        return false
    end
    if rel.db and rel.table then
        return has_column(rel.db, rel.table, col_name)
    end
    return nil
end

analyze_relations = function(scope_nodes, bufnr, diagnostics, cte_defs, local_tables)
    cte_defs = cte_defs or {}
    local_tables = local_tables or buffer_local_tables[bufnr] or {}
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
                    local columns_unknown = false

                    local subquery_node = nil
                    for child in rel_node:iter_children() do
                        if child:type() == NODE.SUBQUERY then
                            subquery_node = child
                            break
                        end
                    end

                    if subquery_node then
                        local resolved = resolve_select_columns(subquery_node, bufnr, cte_defs, local_tables)
                        if resolved and #resolved > 0 then
                            cols = resolved
                        else
                            cols = {}
                            columns_unknown = true
                        end
                    end

                    local def = {
                        derived = true,
                        columns = cols,
                        columns_unknown = columns_unknown,
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
        elseif def.table then -- Unqualified table/alias
            local tbl_norm = normalize(def.table)
            local cte_def = cte_defs[tbl_norm]
            local local_entry = local_tables[tbl_norm]
            local sess_entry = util.get_session_table and util.get_session_table(tbl_norm) or nil

            if cte_def then
                -- 1. CTE
                def.derived = true
                def.is_cte = true
                def.columns = cte_def.columns
                def.columns_unknown = cte_def.columns_unknown
                if def.columns_unknown then has_unqualified = true end
                is_valid = true
            elseif local_entry or sess_entry then
                -- 2. local_tables[NAME] or 3. util.get_session_table(NAME)
                local entry = local_entry or sess_entry
                def.local_table = true
                if entry.columns then
                    local norm_cols = {}
                    for _, c in ipairs(entry.columns) do
                        table.insert(norm_cols, type(c) == "table" and c or { name = c })
                    end
                    def.columns = norm_cols
                    def.columns_unknown = false
                else
                    def.columns = nil
                    def.columns_unknown = true
                    has_unqualified = true
                end
                is_valid = true
            else
                -- 4. Found in one of used_dbs
                local matching_dbs = {}
                for db in pairs(used_dbs) do
                    if has_table(db, def.table) then
                        table.insert(matching_dbs, db)
                    end
                end
                if #matching_dbs > 0 then
                    has_unqualified = true
                    if #matching_dbs == 1 then
                        def.db = matching_dbs[1]
                    else
                        def.columns_unknown = true
                    end
                    is_valid = true
                else
                    -- 5. Otherwise: unknown unqualified relation
                    def.columns_unknown = true
                    has_unqualified = true
                    add_diagnostic(diagnostics, node, bufnr, SEVERITY.HINT,
                        string.format('Table "%s" is not in the metadata catalog (volatile table or default database?)', def.table))
                    is_valid = true
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
                                local res = relation_has_column(target_rel, col_name)

                                if res == false then
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
                    local res = relation_has_column(rel, col_name)
                    if res == true then
                        table.insert(found_in, rel.table or "subquery")
                    end
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
                local rel_def = relation_map[normalize(qualifier)]

                if rel_def then
                    local res = relation_has_column(rel_def, col_name)
                    if res == false then
                        local label = rel_def.is_cte and "CTE"
                            or rel_def.derived and "derived table"
                            or rel_def.local_table and "volatile table"
                            or "table"
                        add_diagnostic(diagnostics, col_node, bufnr, SEVERITY.ERROR,
                            string.format('Column "%s" not found in %s "%s"',
                                col_name,
                                label,
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
                local inconclusive = false
                local searched_in = {}

                for _, rel in ipairs(active_tables) do
                    local res = relation_has_column(rel, col_name)
                    if res == nil then
                        inconclusive = true
                    else
                        if rel.is_cte or rel.derived then
                            local label = rel.is_cte and "CTE" or "derived"
                            table.insert(searched_in, string.format("%s (%s)", rel.table, label))
                        elseif rel.local_table then
                            table.insert(searched_in, string.format("%s (volatile)", rel.table))
                        elseif rel.db and rel.table then
                            table.insert(searched_in, rel.db .. "." .. rel.table)
                        else
                            table.insert(searched_in, rel.table or "table")
                        end
                        if res == true then found_anywhere = true end
                    end
                end

                if not found_anywhere and not inconclusive and #searched_in > 0 then
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

local function check_undefined_alias(scope_nodes, bufnr, diagnostics, relation_map)
    local defined_aliases = {}
    if relation_map then
        for k in pairs(relation_map) do
            defined_aliases[k] = true
        end
    end
    for _, node in ipairs(scope_nodes) do
        for _, cap in QUERIES.alias_def:iter_captures(node, bufnr, 0, -1) do
            if not is_nested_in_subquery(cap, node) then
                local text = get_text(cap, bufnr)
                if text then defined_aliases[normalize(text)] = true end
            end
        end
        for _, rel_node in QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
            if not is_nested_in_subquery(rel_node, node) then
                for child in rel_node:iter_children() do
                    if child:type() == NODE.OBJ_REF then
                        local parts = {}
                        for p in child:iter_children() do
                            if p:type() == NODE.IDENTIFIER then
                                table.insert(parts, get_text(p, bufnr))
                            end
                        end
                        if #parts > 0 and parts[#parts] then
                            defined_aliases[normalize(parts[#parts])] = true
                        end
                        break
                    end
                end
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
        if is_aggregate_invocation(inv, bufnr) and not is_under_window(inv, bufnr) then has_aggregate = true; break end
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
            if is_under_window(col, bufnr) then goto next_col end
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

get_query_scopes = function(root_node)
    local scopes = {}

    local function traverse(node)
        local type = node:type()
        local is_container = (type == 'statement' or type == 'subquery' or type == 'create_query')

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

local function process_statement(stmt_node, bufnr, diagnostics, local_tables)
    local parent = stmt_node:parent()
    if parent and parent:type() == "cte" then return end

    local_tables = local_tables or buffer_local_tables[bufnr] or {}
    local cte_defs = get_cte_definitions(stmt_node, bufnr, local_tables)

    check_union_column_compatibility(stmt_node, bufnr, diagnostics)
    check_subquery_unnamed_fields(stmt_node, bufnr, diagnostics)
    check_select_star_in_subquery(stmt_node, bufnr, diagnostics)
    check_group_by_ordinal(stmt_node, bufnr, diagnostics)
    check_duplicate_columns_in_select(stmt_node, bufnr, diagnostics)
    check_unused_cte(stmt_node, bufnr, diagnostics, cte_defs)

    local scopes = get_query_scopes(stmt_node)

    for _, scope_nodes in ipairs(scopes) do
        local relation_map, active_tables, has_unqualified = analyze_relations(scope_nodes, bufnr, diagnostics, cte_defs, local_tables)
        local output_aliases = get_output_aliases(scope_nodes, bufnr)
        check_field_validity(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified,
            output_aliases)
        check_ambiguous_columns(scope_nodes, bufnr, relation_map, active_tables, diagnostics, has_unqualified)
        check_undefined_alias(scope_nodes, bufnr, diagnostics, relation_map)
        check_duplicate_join_conditions(scope_nodes, bufnr, diagnostics)
        check_non_aggregated_columns(scope_nodes, bufnr, diagnostics)
    end
end

-- =============================================================================
-- Public API
-- =============================================================================

local last_tick = {}
local warned_parser = false

function M.invalidate(bufnr)
    if bufnr then
        last_tick[bufnr] = nil
    end
end

function M.invalidate_all()
    last_tick = {}
end

function M.forget(bufnr)
    if bufnr then
        last_tick[bufnr] = nil
        buffer_local_tables[bufnr] = nil
    end
end

function M.update_diagnostics(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    if last_tick[bufnr] == tick then
        return
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "teradata")
    if not ok or not parser then
        if not warned_parser then
            warned_parser = true
            vim.notify("Teradata tree-sitter parser not available; diagnostics disabled", vim.log.levels.WARN)
        end
        return
    end

    local parse_ok, trees = pcall(function() return parser:parse() end)
    if not parse_ok or not trees or #trees == 0 then return end

    local result = {}
    local run_ok, err = pcall(function()
        local local_tables = {}
        for _, tree in ipairs(trees) do
            local root = tree:root()
            local collected = collect_buffer_created_tables(root, bufnr)
            for k, v in pairs(collected) do
                local_tables[k] = v
            end
        end
        buffer_local_tables[bufnr] = local_tables

        for _, tree in ipairs(trees) do
            local root = tree:root()
            if QUERIES.syntax_error then
                for _, node in QUERIES.syntax_error:iter_captures(root, bufnr, 0, -1) do
                    add_diagnostic(result, node, bufnr, SEVERITY.ERROR, get_syntax_error_message(node, bufnr))
                end
            end

            if QUERIES.statement then
                for _, stmt_node in QUERIES.statement:iter_captures(root, bufnr, 0, -1) do
                    process_statement(stmt_node, bufnr, result, local_tables)
                end
            end
        end
    end)

    if not run_ok then
        return
    end

    last_tick[bufnr] = tick
    vim.diagnostic.set(NAMESPACE, bufnr, result)
end

-- =============================================================================
-- Shared helpers (used by code_actions.lua)
-- =============================================================================

M.NAMESPACE = NAMESPACE
M.QUERIES = QUERIES
M.get_query_scopes = get_query_scopes
M.analyze_relations = analyze_relations
M.get_cte_definitions = get_cte_definitions
M.get_columns_from_select_expr = get_columns_from_select_expr
M.collect_buffer_created_tables = collect_buffer_created_tables
M.resolve_select_columns = resolve_select_columns
M.is_nested_in_subquery = is_nested_in_subquery
M.get_text = get_text

return M
