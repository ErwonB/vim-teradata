local utils = require('vim-teradata.util')
local tsu   = require('vim-teradata.ts-util')

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

    local symbols = lang_inspect('teradata')

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
    has_sel_or_dml = vim.treesitter.query.parse("teradata", [[
    [(delete) (keyword_delete)
     (update) (keyword_update)
     (insert) (keyword_insert)
     (select) (keyword_select)
     (keyword_show) (keyword_merge)
     (from) (keyword_from)] @sel
  ]]),
    has_where = vim.treesitter.query.parse("teradata", [[
    [(where) (keyword_where) (order_by)] @where
  ]]),
    has_error = vim.treesitter.query.parse("teradata", [[
    (ERROR) @error
  ]]),
    subq_with_alias = vim.treesitter.query.parse("teradata", [[
    (relation
      (subquery) @subquery
      (keyword_as)?
      alias: (identifier)? @subquery_alias
    )
  ]]),
    select_expression = vim.treesitter.query.parse("teradata", [[
  ((select_expression
     (term
       alias: (identifier) @col) @item))

  ((select_expression
     (term
       value: (field
         name: (identifier) @col)) @item))

]]),
    relation = vim.treesitter.query.parse("teradata", [[ (relation) @rel ]]),
    obj_ref  = vim.treesitter.query.parse("teradata", [[ (object_reference) @obj ]]),
}


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
        if not obj_node or not tsu.is_direct_scope_descendant(obj_node, scope_node) then
            goto continue
        end

        local alias_node = tsu.child_by_field(obj_node, "alias")
        if not alias_node then
            for child in obj_node:iter_children() do
                if child:type() == 'identifier' and child ~= obj_node then
                    alias_node = child
                    break
                end
            end
        end

        local _, schema_name, tbl_name = nil, nil, nil
        local db_node    = tsu.child_by_field(obj_node, "database")
        local schema_node = tsu.child_by_field(obj_node, "schema")
        local tbl_node   = tsu.child_by_field(obj_node, "name")

        if schema_node then schema_name = vim.treesitter.get_node_text(schema_node, source) end
        if tbl_node    then tbl_name    = vim.treesitter.get_node_text(tbl_node,    source) end

        if not db_node and not schema_node and not tbl_node then
            local children = {}
            for child in obj_node:iter_children() do
                if child:type() == 'identifier' then table.insert(children, child) end
            end
            if #children == 1 then
                tbl_name = vim.treesitter.get_node_text(children[1], source)
            elseif #children == 2 then
                schema_name = vim.treesitter.get_node_text(children[1], source)
                tbl_name    = vim.treesitter.get_node_text(children[2], source)
            elseif #children == 3 then
                schema_name = vim.treesitter.get_node_text(children[2], source)
                tbl_name    = vim.treesitter.get_node_text(children[3], source)
            end
        end

        local alias_str = alias_node and vim.treesitter.get_node_text(alias_node, source) or ""

        if schema_name and tbl_name then
            table.insert(tables, {
                db_name = string.upper(schema_name),
                tb_name = string.upper(tbl_name),
                alias   = string.upper(alias_str),
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
            if relation_node and tsu.is_direct_scope_descendant(relation_node, scope_node) then
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
        if not rel_node or not tsu.is_direct_scope_descendant(rel_node, scope_node) then
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

        local alias_node = tsu.child_by_field(rel_node, "alias")
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
            local db_node    = tsu.child_by_field(obj_ref, "database")
            local schema_node = tsu.child_by_field(obj_ref, "schema")
            local tbl_node   = tsu.child_by_field(obj_ref, "name")

            if schema_node then schema_name = vim.treesitter.get_node_text(schema_node, source) end
            if tbl_node    then tbl_name    = vim.treesitter.get_node_text(tbl_node,    source) end

            if not db_node and not schema_node and not tbl_node then
                local children = {}
                for child in obj_ref:iter_children() do
                    if child:type() == 'identifier' then table.insert(children, child) end
                end
                if #children == 1 then
                    tbl_name = vim.treesitter.get_node_text(children[1], source)
                elseif #children == 2 then
                    schema_name = vim.treesitter.get_node_text(children[1], source)
                    tbl_name    = vim.treesitter.get_node_text(children[2], source)
                elseif #children == 3 then
                    schema_name = vim.treesitter.get_node_text(children[2], source)
                    tbl_name    = vim.treesitter.get_node_text(children[3], source)
                end
            end

            local alias_str = alias_node and vim.treesitter.get_node_text(alias_node, source) or ""

            if schema_name and tbl_name then
                table.insert(tables, {
                    db_name = string.upper(schema_name),
                    tb_name = string.upper(tbl_name),
                    alias   = string.upper(alias_str),
                })
            end
        end
        ::continue::
    end
    return tables
end


--- Try to perform error recovery by parsing a query with a dummy character inserted at cursor.
--- @param bufnr integer
--- @param row_1 integer
--- @param col_0 integer
--- @param context table
--- @return boolean True if recovery produced results, false otherwise.
local function try_error_recovery_reparse(bufnr, row_1, col_0, context)
    local modified_buf_text = tsu.build_parsable_query_with_dummy(bufnr, row_1 - 1, col_0)
    local parser = vim.treesitter.get_string_parser(modified_buf_text, "teradata")
    local trees  = parser:parse()
    local cursor_pos_in_modified = row_1 - 1

    if trees and #trees > 0 then
        local root = trees[1]:root()
        local fixed_statement_node = nil

        local stmt_query = vim.treesitter.query.parse("teradata", "(statement) @stmt")
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
            local node_at_cursor = fixed_statement_node:named_descendant_for_range(
                row_1 - 1, col_0, row_1 - 1, col_0)
            local scope_node = tsu.scope_node(node_at_cursor) or fixed_statement_node

            context.tables        = find_all_tables_in_scope(scope_node, modified_buf_text)
            context.buffer_fields = find_all_fields_from_subquery(scope_node, modified_buf_text)

            return (context.tables and #context.tables > 0) or (context.buffer_fields and #context.buffer_fields > 0)
        end
    end
    return false
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
    local line_prefix = tsu.line_prefix(bufnr, row_1, col_0)
    local before_dot_match = line_prefix:match("([%w_]+)%.([%w_]*)$")

    if before_dot_match and utils.is_a_db(before_dot_match) then
        context.type    = 'tables'
        context.db_name = string.upper(before_dot_match)
        return context
    end

    local key_dbs = { from = true, join = true, into = true }
    local before_current    = line_prefix:match("([%w_]+)% ([%w_]*)$")
    local two_before_current = line_prefix:match("([%w_]+)% ([%w_]+)% $")
    if (before_current and key_dbs[before_current:lower()])
        or (two_before_current and two_before_current:lower() == "show")
    then
        return { type = 'databases' }
    end

    local cursor_pos_0 = { row_1 - 1, col_0 }
    local cursor_node  = vim.treesitter.get_node({ bufnr = 0, pos = cursor_pos_0 })

    if not cursor_node then
        context.type       = 'keywords'
        context.candidates = M.get_keywords_for_context(bufnr, row_1, col_0)
        return context
    end

    local statement_node = tsu.enclosing_or_preceding_statement(cursor_node, bufnr, row_1 - 1)
    if not statement_node then
        context.type       = 'keywords'
        context.candidates = M.get_keywords_for_context(bufnr, row_1, col_0)
        return context
    end

    local s_sr, s_er = tsu.node_rows(statement_node)
    local cursor_error_node = nil
    local e_sr, e_er
    for _, node, _ in Q.has_error:iter_captures(cursor_node, bufnr, 0, -1) do
        cursor_error_node = node
        e_sr, e_er = tsu.node_rows(cursor_error_node)
        break
    end

    local has_sel_or_dml = tsu.any_capture(Q.has_sel_or_dml, statement_node, bufnr, s_sr, s_er)
    if (not has_sel_or_dml) and cursor_error_node and cursor_error_node ~= statement_node then
        has_sel_or_dml = tsu.any_capture(Q.has_sel_or_dml, cursor_error_node, bufnr, e_sr, e_er)
    end

    local has_where = false
    local check_nodes = { statement_node }
    if cursor_error_node and cursor_error_node ~= statement_node then
        table.insert(check_nodes, cursor_error_node)
    end

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
            scope_node            = tsu.scope_node(cursor_node) or statement_node
            context.tables        = find_all_tables_in_scope(scope_node, bufnr)
            context.buffer_fields = find_all_fields_from_subquery(scope_node, bufnr)
            -- Fallback: If standard path found no useful results and there's an adjacent ERROR,
            -- attempt error-recovery reparse
            if tsu.has_adjacent_error(statement_node) then
                try_error_recovery_reparse(bufnr, row_1, col_0, context)
            end
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
                try_error_recovery_reparse(bufnr, row_1, col_0, context)
            end
        end

        -- Fallback if no tables found (e.g. invalid query structure or DML like insert/update without FROM)
        if (not context.tables or #context.tables == 0) and (not context.buffer_fields or #context.buffer_fields == 0) then
            scope_node            = scope_node or statement_node
            context.tables        = find_all_object_reference(scope_node, bufnr)
            context.buffer_fields = find_all_fields_from_subquery(scope_node, bufnr)
        end

        if (context.tables and #context.tables > 0) or (context.buffer_fields and #context.buffer_fields > 0) then
            context.type     = 'columns'
            context.is_where = has_where
            if before_dot_match then
                context.alias_prefix = string.upper(before_dot_match)
            end
            return context
        end
    end

    -- 3. Grammar-aware keyword context
    context.type       = 'keywords'
    context.candidates = M.get_keywords_for_context(bufnr, row_1, col_0)
    return context
end

---
--- Core keyword resolution.
---
--- Returns (candidates, is_filtered) where:
---   candidates   — the list of keyword strings to offer
---   is_filtered  — true when the list was narrowed by the grammar follow set
---
--- This is the single place that owns the follow-set lookup logic.
--- Both public helpers below delegate here.
---
--- @param bufnr  integer
--- @param row_1  integer  1-indexed row
--- @param col_0  integer  0-indexed column
--- @return string[], boolean
local function resolve_keywords(bufnr, row_1, col_0)

    local prev_kw = tsu.previous_keyword_at_cursor(bufnr, row_1, col_0)
    if prev_kw then
        local ok, follow_sets = pcall(require, 'vim-teradata.sql-autocomplete.follow_sets')
        if ok and follow_sets then
            local allowed = follow_sets['keyword_' .. prev_kw]
            if allowed and #allowed > 0 then
                return allowed, true
            end
        end
    end

    return M.get_sql_keywords(), false
end


---
--- Returns the keyword candidate list for the current cursor position.
---
--- Used by analyze_sql_context() when context.type ends up as 'keywords'.
--- Returns only the list; the filtered/unfiltered distinction is encoded in
--- which list is returned.
---
--- @param bufnr  integer
--- @param row_1  integer  1-indexed row
--- @param col_0  integer  0-indexed column
--- @return string[]
function M.get_keywords_for_context(bufnr, row_1, col_0)
    local candidates, _ = resolve_keywords(bufnr, row_1, col_0)
    return candidates
end


---
--- Returns the keyword candidate list AND a boolean flag indicating whether
--- the list was narrowed by the grammar follow set.
---
--- Used by completion.lua when injecting keywords alongside non-keyword
--- context results (columns / tables / databases), so it can promote filtered
--- keywords to the same priority tier as the primary results.
---
--- @param bufnr  integer
--- @param row_1  integer  1-indexed row
--- @param col_0  integer  0-indexed column
--- @return string[], boolean is_filtered
function M.get_keywords_for_context_with_flag(bufnr, row_1, col_0)
    return resolve_keywords(bufnr, row_1, col_0)
end

return M
