local utils = require('vim-teradata.util')

local M = {}

---
--- Dynamic Keyword Extraction
---
local _cached_keywords = nil

function M.get_sql_keywords()
    if _cached_keywords then return _cached_keywords end

    local keywords = {}
    local unique_map = {}

    local lang_inspect = vim.treesitter.language.inspect
    if not lang_inspect then
        return {}
    end

    local symbols = lang_inspect('sql')

    for name, is_named in pairs(symbols.symbols) do
        local word = nil

        if is_named and name:match("^keyword_") then
            word = name:gsub("^keyword_", "")
        end

        if word then
            local lower = word:lower()
            if not unique_map[lower] then
                unique_map[lower] = true
                table.insert(keywords, lower)
            end
        end
    end

    -- Adding specific `lock row for access`
    local word = "lock row for access"
    if not unique_map[word] then
        unique_map[word] = true
        table.insert(keywords, word)
    end

    _cached_keywords = keywords
    return keywords
end

local Q = {
    has_sel_or_dml = vim.treesitter.query.parse("sql", [[
    [(delete) (keyword_delete)
     (update) (keyword_update)
     (insert) (keyword_insert)
     (select) (keyword_select)
     (keyword_show) (keyword_merge)
     (from) (keyword_from)] @sel
  ]]),
    has_where = vim.treesitter.query.parse("sql", [[
    [(where) (keyword_where) (order_by)] @where
  ]]),
    has_error = vim.treesitter.query.parse("sql", [[
    (ERROR) @error
  ]]),
    subq_with_alias = vim.treesitter.query.parse("sql", [[
    (relation
      (subquery) @subquery
      (keyword_as)?
      alias: (identifier)? @subquery_alias
    )
  ]]),
    select_expression = vim.treesitter.query.parse("sql", [[
  ((select_expression
     (term
       alias: (identifier) @col) @item))

  ((select_expression
     (term
       value: (field
         name: (identifier) @col)) @item))

]]),
    relation = vim.treesitter.query.parse("sql", [[ (relation) @rel ]]),
    obj_ref = vim.treesitter.query.parse("sql", [[ (object_reference) @obj ]]),
}

local function node_rows(n)
    local sr, _, er, _ = n:range()
    return sr, er + 1
end

local function any_capture(query, node, bufnr, start_row, end_row)
    for _ in query:iter_captures(node, bufnr, start_row, end_row) do
        return true
    end
    return false
end

local function get_line_prefix(row, col)
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    return line:sub(1, col)
end

---
--- Finds the closest ancestor node that acts as a scope boundary (subquery or statement).
--- @param node TSNode? The starting node.
--- @return table|nil The scope node.
---
local function get_scope_node(node)
    local current = node
    while current do
        local type = current:type()
        -- TODO create a list of those types of node
        if type == 'subquery' or type == 'statement' then
            return current
        end
        current = current:parent()
    end
    return nil
end

---
--- Checks if a node is a direct descendant of the scope node
--- meaning it is not nested inside another intermediate subquery.
--- @param node table The node to check (e.g., a relation).
--- @param scope_node table The defining scope (subquery or statement).
--- @return boolean
---
local function is_direct_scope_descendant(node, scope_node)
    local current = node:parent()
    while current do
        if current == scope_node then return true end
        -- If we hit an intermediate subquery before the scope node, it's nested too deep.
        if current:type() == 'subquery' then return false end
        current = current:parent()
    end
    return false
end

---
--- Finds the enclosing statement node for a given node.
--- @param node table The starting Tree-sitter node.
--- @param bufnr number The buffer number.
--- @param cursor_row number The row number of the cursor (0-indexed).
--- @return table|nil The enclosing or relevant preceding statement node.
---
local function get_enclosing_or_relevant_preceding_statement(node, bufnr, cursor_row)
    bufnr = bufnr or 0
    if not node then return nil end

    local current = node
    local root_node = nil
    local original_node_start_row, _, _, _ = node:start()
    original_node_start_row = math.max(original_node_start_row, cursor_row)

    -- 1. Try to find the enclosing statement by going up the tree
    while current do
        local ntype = current:type()
        if ntype == 'statement' then
            return current
        end
        if ntype == 'program' then
            root_node = current
            break
        end
        local parent = current:parent()
        if not parent then
            -- If we reached the top without finding 'program', treat this as root
            if ntype == 'program' then root_node = current end
            break
        end
        current = parent
    end

    -- 2. If no enclosing statement found, but we identified the program root
    if root_node then
        local prev_type = nil
        -- Iterate backwards to find the closest preceding statement
        for i = 0, root_node:child_count() - 1 do
            local child = root_node:child(root_node:child_count() - 1 - i)
            if not child then goto continue end

            local _, _, child_end_row, _ = child:range()

            -- Check if this child ends at or before the cursor area
            if child_end_row <= original_node_start_row then
                if child:type() == 'statement' and prev_type ~= ';' then
                    return child
                end
                prev_type = child:type()
            end
            ::continue::
        end
    end

    -- 3. If we are at the top level (e.g. single line query parsed as ERROR or program -> ERROR)
    -- 'current' holds the last node visited (likely 'program' or 'ERROR' root)
    if current and current:type() == 'ERROR' then
        return current
    end

    return nil
end


---
--- Manual implementation of the missing 'child_by_field_name' helper.
--- @param node table The Tree-sitter node to search.
--- @param field_name string The name of the field to find.
--- @return table|nil The child node, or nil if not found.
---
local function get_child_by_field_name(node, field_name)
    if not node then
        return nil
    end
    for i = 0, node:named_child_count() - 1 do
        if node.field_name_for_child and node:field_name_for_child(i) == field_name then
            return node:named_child(i)
        end
    end
    return nil
end

---
--- Try to build parsable query with dummy field
--- @param bufnr integer buffer number
--- @param row_0 integer row position
--- @param col_0 integer col position
--- @return string modified buffer string
local function try_build_parsable_query(bufnr, row_0, col_0)
    local dummy = "a"
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, row_0, false)
    local line = vim.api.nvim_buf_get_lines(bufnr, row_0, row_0 + 1, false)[1] or ""
    local line_byte_len = #line

    local prefix = vim.api.nvim_buf_get_text(bufnr, row_0, 0, row_0, col_0, {})[1] or ""
    local suffix = vim.api.nvim_buf_get_text(bufnr, row_0, col_0, row_0, line_byte_len, {})[1] or ""
    local after = vim.api.nvim_buf_get_lines(bufnr, row_0 + 1, -1, false)

    local parts = {}
    vim.list_extend(parts, before)
    table.insert(parts, prefix .. dummy .. suffix)
    vim.list_extend(parts, after)
    return table.concat(parts, "\n")
end

---
--- Finds all object_reference in a scope
--- @param scope_node table The enclosing statement node.
--- @param source integer|string The buffer number or source string for get_node_text and iter_captures. Defaults to 0.
--- @return table A list of { db_name, tb_name, alias } tables.
---
local function find_all_object_reference(scope_node, source)
    source = source or 0
    local tables = {}

    for _, obj_node, _ in Q.obj_ref:iter_captures(scope_node, source, 0, -1) do
        -- Ensure object is part of the current scope
        if not obj_node or not is_direct_scope_descendant(obj_node, scope_node) then
            goto continue
        end

        local alias_node = get_child_by_field_name(obj_node, "alias")
        if not alias_node then
            for child in obj_node:iter_children() do
                if child:type() == 'identifier' and child ~= obj_node then
                    alias_node = child
                    break
                end
            end
        end

        local _, schema_name, tbl_name = nil, nil, nil
        local db_node = get_child_by_field_name(obj_node, "database")
        local schema_node = get_child_by_field_name(obj_node, "schema")
        local tbl_node = get_child_by_field_name(obj_node, "name")

        if schema_node then schema_name = vim.treesitter.get_node_text(schema_node, source) end
        if tbl_node then tbl_name = vim.treesitter.get_node_text(tbl_node, source) end

        if not db_node and not schema_node and not tbl_node then
            local children = {}
            for child in obj_node:iter_children() do
                if child:type() == 'identifier' then table.insert(children, child) end
            end
            if #children == 1 then
                tbl_name = vim.treesitter.get_node_text(children[1], source)
            elseif #children == 2 then
                schema_name = vim.treesitter.get_node_text(children[1], source)
                tbl_name = vim.treesitter.get_node_text(children[2], source)
            elseif #children == 3 then
                schema_name = vim.treesitter.get_node_text(children[2], source)
                tbl_name = vim.treesitter.get_node_text(children[3], source)
            end
        end

        local alias_str = alias_node and vim.treesitter.get_node_text(alias_node, source) or ""

        if schema_name and tbl_name then
            table.insert(tables, {
                db_name = string.upper(schema_name),
                tb_name = string.upper(tbl_name),
                alias = string.upper(alias_str),
            })
        end
        ::continue::
    end
    return tables
end

---
--- Finds fields from subqueries defined strictly within the current scope.
---
--- @param scope_node TSNode The enclosing statement node.
--- @param source integer|string Buffer number or source string for get_node_text/iter_* (defaults to 0).
--- @return table
local function find_all_fields_from_subquery(scope_node, source)
    source = source or 0
    local results = {}

    for _, match, _ in Q.subq_with_alias:iter_matches(scope_node, source, 0, -1) do
        local subquery_node, alias_node
        for capid, n in pairs(match) do
            local capname = Q.subq_with_alias.captures[capid]
            if capname == "subquery" then
                subquery_node = n[1]
            elseif capname == "subquery_alias" then
                alias_node = n[1]
            end
        end

        if subquery_node then
            -- Verify scoping: The subquery must be a direct child relation of the scope
            local relation_node = subquery_node:parent()
            if relation_node and is_direct_scope_descendant(relation_node, scope_node) then
                local subquery_alias = ""
                if alias_node then
                    subquery_alias = vim.treesitter.get_node_text(alias_node, source)
                end
                local fields = {}

                for _, sel_expr_match, _ in Q.select_expression:iter_matches(subquery_node, source, 0, -1) do
                    local col_node
                    for capid, n in pairs(sel_expr_match) do
                        if Q.select_expression.captures[capid] == "col" then col_node = n[1] end
                    end
                    if col_node then
                        local col_name = vim.treesitter.get_node_text(col_node, source)
                        if col_name and col_name ~= "" then table.insert(fields, col_name) end
                    end
                end

                if #fields > 0 then
                    table.insert(results, { field_list = fields, alias = subquery_alias })
                end
            end
        end
    end
    return results
end

---
--- Finds all tables and aliases strictly within a given scope.
--- @param scope_node table The enclosing statement node.
--- @param source integer|string The buffer number or source string for get_node_text and iter_captures. Defaults to 0.
--- @return table A list of { db_name, tb_name, alias } tables.
---
local function find_all_tables_in_scope(scope_node, source)
    source = source or 0
    local tables = {}

    for _, rel_node, _ in Q.relation:iter_captures(scope_node, source, 0, -1) do
        if not rel_node or not is_direct_scope_descendant(rel_node, scope_node) then
            goto continue
        end

        local obj_ref = nil
        for child in rel_node:iter_children() do
            if child:type() == "subquery" then goto continue end
            if child:type() == "object_reference" then
                obj_ref = child
                break
            end
        end

        local alias_node = get_child_by_field_name(rel_node, "alias")
        if not alias_node then
            for child in rel_node:iter_children() do
                if child:type() == 'identifier' and child ~= obj_ref then
                    alias_node = child
                    break
                end
            end
        end

        if obj_ref then
            local _, schema_name, tbl_name = nil, nil, nil
            local db_node = get_child_by_field_name(obj_ref, "database")
            local schema_node = get_child_by_field_name(obj_ref, "schema")
            local tbl_node = get_child_by_field_name(obj_ref, "name")

            if schema_node then schema_name = vim.treesitter.get_node_text(schema_node, source) end
            if tbl_node then tbl_name = vim.treesitter.get_node_text(tbl_node, source) end

            if not db_node and not schema_node and not tbl_node then
                local children = {}
                for child in obj_ref:iter_children() do
                    if child:type() == 'identifier' then table.insert(children, child) end
                end
                if #children == 1 then
                    tbl_name = vim.treesitter.get_node_text(children[1], source)
                elseif #children == 2 then
                    schema_name = vim.treesitter.get_node_text(children[1], source)
                    tbl_name = vim.treesitter.get_node_text(children[2], source)
                elseif #children == 3 then
                    schema_name = vim.treesitter.get_node_text(children[2], source)
                    tbl_name = vim.treesitter.get_node_text(children[3], source)
                end
            end

            local alias_str = alias_node and vim.treesitter.get_node_text(alias_node, source) or ""

            if schema_name and tbl_name then
                table.insert(tables, {
                    db_name = string.upper(schema_name),
                    tb_name = string.upper(tbl_name),
                    alias = string.upper(alias_str),
                })
            end
        end
        ::continue::
    end
    return tables
end

---
--- Analyzes the SQL context at the cursor using Tree-sitter.
--- @return table The context { type, db_name, tables, alias_prefix, ... }
---
function M.analyze_sql_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row_1, col_0 = cursor[1], cursor[2]
    local context = {}

    -- 1. Immediate Check for Table Context (DB.)
    local line_prefix = get_line_prefix(row_1, col_0)
    local before_dot_match = line_prefix:match("([%w_]+)%.([%w_]*)$")

    if before_dot_match and utils.is_a_db(before_dot_match) then
        context.type = 'tables'
        context.db_name = string.upper(before_dot_match)
        return context
    end

    local key_dbs = { from = true, join = true, into = true }
    local before_current = line_prefix:match("([%w_]+)% ([%w_]*)$")
    local two_before_current = line_prefix:match("([%w_]+)% ([%w_]+)% $")
    if (before_current and key_dbs[before_current:lower()])
        or (two_before_current and two_before_current:lower() == "show")
    then
        return { type = 'databases' }
    end

    local cursor_pos_0 = { row_1 - 1, col_0 }
    local cursor_node = vim.treesitter.get_node({ bufnr = 0, pos = cursor_pos_0 })

    if not cursor_node then
        context.type = 'keywords'
        context.candidates = M.get_sql_keywords()
        return context
    end

    local statement_node = get_enclosing_or_relevant_preceding_statement(cursor_node, bufnr, row_1 - 1)
    if not statement_node then
        context.type = 'keywords'
        context.candidates = M.get_sql_keywords()
        return context
    end

    local s_sr, s_er = node_rows(statement_node)
    local cursor_error_node = nil
    local e_sr, e_er
    for _, node, _ in Q.has_error:iter_captures(cursor_node, bufnr, 0, -1) do
        cursor_error_node = node
        e_sr, e_er = node_rows(cursor_error_node)
        break
    end

    local has_sel_or_dml = any_capture(Q.has_sel_or_dml, statement_node, bufnr, s_sr, s_er)
    if (not has_sel_or_dml) and cursor_error_node and cursor_error_node ~= statement_node then
        has_sel_or_dml = any_capture(Q.has_sel_or_dml, cursor_error_node, bufnr, e_sr, e_er)
    end

    local has_where = false
    local check_nodes = { statement_node }
    if cursor_error_node and cursor_error_node ~= statement_node then table.insert(check_nodes, cursor_error_node) end

    for _, n in ipairs(check_nodes) do
        for _, node, _ in Q.has_where:iter_captures(n, bufnr, 0, -1) do
            local s_row, s_col = node:start()
            if s_row < row_1 - 1 or (s_row == row_1 - 1 and s_col < col_0) then
                has_where = true
                break
            end
        end
        if has_where then break end
    end

    if has_sel_or_dml or has_where then
        local scope_node = nil

        local has_error = false
        for _, _, _ in Q.has_error:iter_captures(statement_node, bufnr, 0, -1) do
            has_error = true
            break
        end

        if not has_error then
            -- Standard path: use scope relative to cursor
            scope_node = get_scope_node(cursor_node) or statement_node
            context.tables = find_all_tables_in_scope(scope_node, bufnr)
            context.buffer_fields = find_all_fields_from_subquery(scope_node, bufnr)
        elseif has_sel_or_dml and statement_node then
            -- Error path: try to rebuild and parse
            local kw_node = nil
            for child in statement_node:iter_children() do
                if child:type() == 'keyword_select' or child:type() == 'select' then
                    kw_node = child
                    break
                end
            end

            if kw_node then
                local modified_buf_text = try_build_parsable_query(bufnr, row_1 - 1, col_0)
                local lang = "sql"
                local parser = vim.treesitter.get_string_parser(modified_buf_text, lang)
                local trees = parser:parse()

                if trees and #trees > 0 then
                    local root = trees[1]:root()
                    local fixed_statement_node = nil
                    local cursor_pos_in_modified = cursor_pos_0[1]

                    local stmt_query = vim.treesitter.query.parse("sql", "(statement) @stmt")
                    for _, stmt_node, _ in stmt_query:iter_captures(root, modified_buf_text, 0, -1) do
                        local s_start_row, _, s_end_row, s_end_col = stmt_node:range()
                        if cursor_pos_in_modified >= s_start_row and
                            (cursor_pos_in_modified < s_end_row or
                                (cursor_pos_in_modified == s_end_row and col_0 <= s_end_col)) then
                            fixed_statement_node = stmt_node
                            break
                        end
                    end
                    if not fixed_statement_node and root:named_child_count() > 0 then
                        fixed_statement_node = root:named_child(0)
                    end

                    if fixed_statement_node and fixed_statement_node:type() == 'statement' then
                        -- Identify scope in the modified tree
                        local node_at_cursor = fixed_statement_node:named_descendant_for_range(row_1 - 1, col_0,
                            row_1 - 1, col_0)
                        scope_node = get_scope_node(node_at_cursor) or fixed_statement_node

                        context.tables = find_all_tables_in_scope(scope_node, modified_buf_text)
                        context.buffer_fields = find_all_fields_from_subquery(scope_node, modified_buf_text)
                    end
                end
            end
        end

        -- Fallback if no tables found (e.g. invalid query structure or DML like insert/update without FROM)
        if (not context.tables or #context.tables == 0) and (not context.buffer_fields or #context.buffer_fields == 0) then
            scope_node = scope_node or statement_node
            context.tables = find_all_object_reference(scope_node, bufnr)
            context.buffer_fields = find_all_fields_from_subquery(scope_node, bufnr)
        end

        if (context.tables and #context.tables > 0) or (context.buffer_fields and #context.buffer_fields > 0) then
            context.type = 'columns'
            context.is_where = has_where
            if before_dot_match then
                context.alias_prefix = string.upper(before_dot_match)
            end
            return context
        end
    end

    -- 3. Default to Dynamic Keyword Context
    context.type = 'keywords'
    context.candidates = M.get_sql_keywords()
    return context
end

return M
