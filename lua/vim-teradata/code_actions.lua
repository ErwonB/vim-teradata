local util = require('vim-teradata.util')
local diag = require('vim-teradata.diagnostics')

local M = {}

-- =============================================================================
-- Helpers
-- =============================================================================

---Finds the enclosing statement node from the cursor.
---@param bufnr number
---@return TSNode|nil
local function get_cursor_statement(bufnr)
    local cursor_node = vim.treesitter.get_node({ bufnr = bufnr })
    if not cursor_node then return nil end
    return util.find_node_by_type(cursor_node, "statement")
end

---Finds the alias identifier under cursor (works on definition AND on any usage like `alias.col`).
---@param bufnr number
---@return TSNode|nil the identifier node of the alias
local function find_alias_identifier(bufnr)
    local cursor_node = vim.treesitter.get_node({ bufnr = bufnr })
    if not cursor_node then return nil end

    local node = cursor_node
    while node do
        if node:type() == "identifier" then
            local parent = node:parent()

            -- 1. Table / subquery alias definition
            if parent and parent:type() == "relation" then
                local alias_field = parent:field("alias")[1]
                if alias_field == node then
                    return node
                end
            end

            -- 2. Alias used as prefix (alias.col) in a field/term
            if parent and parent:type() == "object_reference" then
                local grand = parent:parent()
                if grand and (grand:type() == "field" or grand:type() == "term") then
                    return node
                end
            end
        end

        -- If we're on a relation node, grab its alias directly
        if node:type() == "relation" then
            local alias = node:field("alias")[1]
            if alias then return alias end
        end

        if node:type() == "statement" then break end
        node = node:parent()
    end
    return nil
end

-- =============================================================================
-- Action 1: Expand *
-- =============================================================================

---Checks if cursor is on an all_fields (*) node.
---@param bufnr number
---@return TSNode|nil The all_fields node, or nil.
local function find_star_node(bufnr)
    local cursor_node = vim.treesitter.get_node({ bufnr = bufnr })
    if not cursor_node then return nil end
    local node = cursor_node
    while node do
        if node:type() == "all_fields" then
            return node
        end
        if node:type() == "select_expression" or node:type() == "statement" then break end
        node = node:parent()
    end
    return nil
end

---Expands the * into explicit column list.
---@param bufnr number
local function action_expand_star(bufnr)
    local star_node = find_star_node(bufnr)
    if not star_node then
        vim.notify("Could not find * node.", vim.log.levels.WARN)
        return
    end

    local stmt_node = util.find_node_by_type(star_node, "statement")
    if not stmt_node then
        vim.notify("Could not find enclosing statement.", vim.log.levels.WARN)
        return
    end

    local cte_defs = diag.get_cte_definitions(stmt_node, bufnr)
    local scopes = diag.get_query_scopes(stmt_node)

    -- Find the scope that contains our star node
    local target_scope = nil
    local star_sr, _, star_er, _ = star_node:range()
    for _, scope_nodes in ipairs(scopes) do
        for _, node in ipairs(scope_nodes) do
            local s_sr, _, s_er, _ = node:range()
            if star_sr >= s_sr and star_er <= s_er then
                target_scope = scope_nodes
                break
            end
        end
        if target_scope then break end
    end

    if not target_scope then
        vim.notify("Could not determine query scope for *.", vim.log.levels.WARN)
        return
    end

    local relation_map, active_tables = diag.analyze_relations(target_scope, bufnr, {}, cte_defs)

    if #active_tables == 0 then
        vim.notify("No tables found in scope to expand *.", vim.log.levels.WARN)
        return
    end

    local scope_multi_tables = (#active_tables > 1)

    -- Extract qualifier from all_fields node (e.g. `a.*`)
    local qualifier = nil
    for child in star_node:iter_children() do
        if child:type() == "object_reference" then
            local parts = {}
            for part in child:iter_children() do
                if part:type() == "identifier" then
                    table.insert(parts, diag.get_text(part, bufnr))
                end
            end
            if #parts > 0 then
                qualifier = parts[#parts]
            end
            break
        end
    end

    if qualifier then
        local rel = relation_map[qualifier:upper()]
        if not rel then
            vim.notify(string.format("'%s' does not match any table or alias in scope.", qualifier), vim.log.levels.WARN)
            return
        end
        active_tables = { rel }
    end

    -- Build alias map (table_name -> alias) from relations
    local table_to_alias = {}
    for _, scope_node in ipairs(target_scope) do
        for _, rel_node in diag.QUERIES.relation:iter_captures(scope_node, bufnr, 0, -1) do
            if not diag.is_nested_in_subquery(rel_node, scope_node) then
                local alias_node = rel_node:field("alias")[1]
                if alias_node then
                    local alias = diag.get_text(alias_node, bufnr)
                    for child in rel_node:iter_children() do
                        if child:type() == "object_reference" then
                            local parts = {}
                            for part in child:iter_children() do
                                if part:type() == "identifier" then
                                    table.insert(parts, diag.get_text(part, bufnr))
                                end
                            end
                            local tbl_name = parts[#parts]
                            if tbl_name and alias then
                                table_to_alias[tbl_name:upper()] = alias
                            end
                            break
                        elseif child:type() == "subquery" then
                            if alias then
                                table_to_alias[alias:upper()] = alias
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    local all_columns = {}
    for _, rel in ipairs(active_tables) do
        local columns = {}
        local prefix = ""

        local tbl_key = rel.table and rel.table:upper() or nil
        local alias = tbl_key and table_to_alias[tbl_key] or nil

        if qualifier then
            -- explicit qualifier: always use it
            prefix = qualifier .. "."
        elseif alias then
            -- table has an alias: always use it
            prefix = alias .. "."
        elseif scope_multi_tables and rel.table then
            -- multiple unaliased tables: use raw table name
            prefix = rel.table .. "."
        end
        -- single unaliased table: no prefix

        if rel.db and rel.table and not rel.derived then
            columns = util.get_columns({ { db_name = rel.db, tb_name = rel.table } }) or {}
        elseif rel.columns then
            for _, c in ipairs(rel.columns) do
                table.insert(columns, c.name)
            end
        end

        for _, col in ipairs(columns) do
            table.insert(all_columns, prefix .. col)
        end
    end

    if #all_columns == 0 then
        if qualifier then
            vim.notify(string.format("No columns found for %s.*", qualifier), vim.log.levels.WARN)
        else
            vim.notify("No columns found to expand.", vim.log.levels.WARN)
        end
        return
    end

    local replacement = table.concat(all_columns, "\n, ")
    local sr, sc, er, ec = star_node:range()
    vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, vim.split(replacement, "\n"))
end

-- =============================================================================
-- Action 2: Extract Subquery → CTE
-- =============================================================================

---Finds the nearest enclosing subquery node from the cursor.
---@param bufnr number
---@return TSNode|nil subquery_node
---@return TSNode|nil relation_node (parent)
local function find_subquery_node(bufnr)
    local cursor_node = vim.treesitter.get_node({ bufnr = bufnr })
    if not cursor_node then return nil, nil end
    local subquery_node = util.find_node_by_type(cursor_node, "subquery")
    if not subquery_node then return nil, nil end
    local parent = subquery_node:parent()
    if parent and parent:type() == "relation" then
        return subquery_node, parent
    end
    return subquery_node, nil
end

---Extracts a subquery into a CTE.
---@param bufnr number
local function action_extract_cte(bufnr)
    local subquery_node, relation_node = find_subquery_node(bufnr)
    if not subquery_node then
        vim.notify("Cursor is not inside a subquery.", vim.log.levels.WARN)
        return
    end

    local stmt_node = util.find_node_by_type(subquery_node, "statement")
    if not stmt_node then
        vim.notify("Could not find enclosing statement.", vim.log.levels.WARN)
        return
    end

    -- Get the subquery text (without surrounding parentheses)
    local subquery_text = diag.get_text(subquery_node, bufnr)
    if not subquery_text then return end
    -- Strip outer parentheses if present
    subquery_text = subquery_text:gsub("^%s*%(", ""):gsub("%)%s*$", "")

    -- Determine the CTE name from the alias or prompt user
    local alias = nil
    if relation_node then
        local alias_node = relation_node:field("alias")[1]
        if alias_node then
            alias = diag.get_text(alias_node, bufnr)
        end
    end

    local function do_extract(cte_name)
        if not cte_name or cte_name == "" then
            vim.notify("CTE name is required.", vim.log.levels.WARN)
            return
        end

        -- Determine replacement range
        local rep_node = relation_node or subquery_node
        local rep_sr, rep_sc, rep_er, rep_ec = rep_node:range()

        -- Replace the subquery/relation with just the CTE name
        vim.api.nvim_buf_set_text(bufnr, rep_sr, rep_sc, rep_er, rep_ec, { cte_name })

        -- Check if WITH clause already exists
        local stmt_sr, stmt_sc, _, _ = stmt_node:range()
        local has_with = false
        local with_end_row, with_end_col

        for child in stmt_node:iter_children() do
            if child:type() == "keyword_with" then
                has_with = true
            end
            if child:type() == "cte" then
                -- Find the last CTE to append after it
                local last_cte = child
                local sibling = child:next_sibling()
                while sibling do
                    if sibling:type() == "cte" then
                        last_cte = sibling
                    elseif sibling:type() == "," then
                        -- continue
                    else
                        break
                    end
                    sibling = sibling:next_sibling()
                end
                _, _, with_end_row, with_end_col = last_cte:range()
            end
        end

        local cte_block = cte_name .. " as (\n" .. subquery_text .. "\n)"

        if has_with and with_end_row then
            -- Append after the last CTE
            local insert_text = ",\n" .. cte_block
            vim.api.nvim_buf_set_text(bufnr, with_end_row, with_end_col, with_end_row, with_end_col,
                vim.split(insert_text, "\n"))
        else
            -- Prepend WITH clause before the statement
            local insert_text = "with " .. cte_block .. "\n"
            vim.api.nvim_buf_set_text(bufnr, stmt_sr, stmt_sc, stmt_sr, stmt_sc, vim.split(insert_text, "\n"))
        end
    end

    if alias then
        do_extract(alias)
    else
        vim.ui.input({ prompt = "CTE name: " }, function(input)
            if input then
                vim.schedule(function() do_extract(input) end)
            end
        end)
    end
end

-- =============================================================================
-- Action 3: Auto-Alias Tables
-- =============================================================================

---Generates a short alias from a table name.
---E.g. "MY_TABLE" → "mt", "ORDERS" → "o"
---@param table_name string
---@param used_aliases table<string, boolean>
---@return string
local function generate_alias(table_name, used_aliases)
    local name = table_name:lower()

    -- Strategy 1: First letter of each underscore-separated word
    local parts = {}
    for word in name:gmatch("[^_]+") do
        table.insert(parts, word:sub(1, 1))
    end
    local candidate = table.concat(parts, "")

    if candidate == "" then
        candidate = name:sub(1, 1)
    end

    -- Ensure uniqueness
    if not used_aliases[candidate] then
        used_aliases[candidate] = true
        return candidate
    end

    -- Append a number
    local i = 2
    while used_aliases[candidate .. tostring(i)] do
        i = i + 1
    end
    local final = candidate .. tostring(i)
    used_aliases[final] = true
    return final
end

---Auto-aliases all unaliased tables in the statement, and adds prefix to unaliased fields
---(only when the scope has exactly one table)
---@param bufnr number
local function action_auto_alias(bufnr)
    local stmt_node = get_cursor_statement(bufnr)
    if not stmt_node then
        vim.notify("Cursor is not inside a SQL statement.", vim.log.levels.WARN)
        return
    end

    local cte_defs = diag.get_cte_definitions(stmt_node, bufnr)
    local scopes = diag.get_query_scopes(stmt_node)
    if #scopes == 0 then
        vim.notify("No query scopes found.", vim.log.levels.WARN)
        return
    end

    -- Collect existing aliases globally
    local used_aliases = {}
    for _, scope_nodes in ipairs(scopes) do
        for _, node in ipairs(scope_nodes) do
            for _, rel_node in diag.QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
                local alias_node = rel_node:field("alias")[1]
                if alias_node then
                    local alias_text = diag.get_text(alias_node, bufnr)
                    if alias_text then
                        used_aliases[alias_text:lower()] = true
                    end
                end
            end
        end
    end

    local edits = {}

    for _, scope_nodes in ipairs(scopes) do
        -- 1. Identify tables (and derive active_tables)
        local _, active_tables = diag.analyze_relations(scope_nodes, bufnr, {}, cte_defs)

        local scope_table_aliases = {} -- upper(table_name) -> alias

        -- First pass: add missing aliases to tables
        for _, node in ipairs(scope_nodes) do
            for _, rel_node in diag.QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
                if diag.is_nested_in_subquery(rel_node, node) then goto continue end

                local alias_node = rel_node:field("alias")[1]

                -- Skip derived tables / subqueries
                local has_subquery = false
                local obj_ref = nil
                for child in rel_node:iter_children() do
                    if child:type() == "subquery" then
                        has_subquery = true
                        break
                    elseif child:type() == "object_reference" then
                        obj_ref = child
                    end
                end
                if has_subquery or not obj_ref then goto continue end

                local parts = {}
                for part in obj_ref:iter_children() do
                    if part:type() == "identifier" then
                        table.insert(parts, diag.get_text(part, bufnr))
                    end
                end
                local table_name = parts[#parts]
                if not table_name then goto continue end

                local t_upper = table_name:upper()
                local alias

                if alias_node then
                    alias = diag.get_text(alias_node, bufnr)
                    scope_table_aliases[t_upper] = alias
                else
                    alias = generate_alias(table_name, used_aliases)
                    scope_table_aliases[t_upper] = alias
                    local _, _, er, ec = obj_ref:range()
                    table.insert(edits, { row = er, col = ec, text = " " .. alias })
                end

                ::continue::
            end
        end

        -- 2. Prefix fields ONLY for simple single-table scopes
        if #active_tables ~= 1 then goto next_scope end

        local t_name = active_tables[1].table and active_tables[1].table:upper() or nil
        if not t_name then goto next_scope end

        local single_alias = scope_table_aliases[t_name]
        if not single_alias then goto next_scope end

        local function gather_unaliased_fields(container_node)
            if not container_node then return end
            for _, col_node in diag.QUERIES.bare_field:iter_captures(container_node, bufnr, 0, -1) do
                if diag.is_nested_in_subquery(col_node, container_node) then goto skip_field end

                -- bare_field already gives us the unprefixed identifier
                local sr, sc, _, _ = col_node:range()
                table.insert(edits, { row = sr, col = sc, text = single_alias .. "." })

                ::skip_field::
            end
        end

        -- Run on every child of the scope – this covers both SELECT list and WHERE clause
        for _, node in ipairs(scope_nodes) do
            gather_unaliased_fields(node)
        end

        ::next_scope::
    end

    if #edits == 0 then
        vim.notify("All tables already have aliases and fields are prefixed.", vim.log.levels.INFO)
        return
    end

    -- Apply edits bottom-to-top
    table.sort(edits, function(a, b)
        if a.row == b.row then return a.col > b.col end
        return a.row > b.row
    end)

    for _, edit in ipairs(edits) do
        vim.api.nvim_buf_set_text(bufnr, edit.row, edit.col, edit.row, edit.col, { edit.text })
    end

    vim.notify(string.format("Applied %d auto-alias edit(s).", #edits), vim.log.levels.INFO)
end

-- =============================================================================
-- Action 4: Transform SELECT to DELETE
-- =============================================================================

---Transforms a SELECT statement into a DELETE statement (inserts below).
---@param bufnr number
local function action_transform_to_delete(bufnr)
    local stmt_node = get_cursor_statement(bufnr)
    if not stmt_node then
        vim.notify("Cursor is not inside a SQL statement.", vim.log.levels.WARN)
        return
    end

    local select_node = util.find_first_descendant_by_type(stmt_node, "select")
    local from_node = util.find_first_descendant_by_type(stmt_node, "from")

    if not select_node or not from_node then
        vim.notify("Statement does not have a SELECT and FROM clause.", vim.log.levels.WARN)
        return
    end

    local from_sr, from_sc, _, _ = from_node:range()
    local _, _, stmt_er, stmt_ec = stmt_node:range()

    local lines = vim.api.nvim_buf_get_text(bufnr, from_sr, from_sc, stmt_er, stmt_ec, {})
    if not lines or #lines == 0 then return end

    -- Remove trailing semicolon from the extracted text if any, as well as whitespaces
    lines[#lines] = lines[#lines]:gsub("%s*;%s*$", "")

    lines[1] = "delete " .. lines[1]
    lines[#lines] = lines[#lines] .. ";"

    -- Determine indent of the original statement to pad the new statement if desired.
    -- (We will just insert it as is for now)

    -- Insert 2 new lines and the new text below the statement
    local insert_row = stmt_er + 1
    -- ensure we're not inserting out of bounds
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    if insert_row > total_lines then insert_row = total_lines end

    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })
    vim.api.nvim_buf_set_lines(bufnr, insert_row + 1, insert_row + 1, false, lines)

    vim.notify("Transform to DELETE action completed.", vim.log.levels.INFO)
end

-- =============================================================================
-- Action 5: Transform SELECT to INSERT
-- =============================================================================

---Transforms a SELECT statement into an INSERT SELECT statement (inserts below).
---@param bufnr number
local function action_transform_to_insert(bufnr)
    local stmt_node = get_cursor_statement(bufnr)
    if not stmt_node then
        vim.notify("Cursor is not inside a SQL statement.", vim.log.levels.WARN)
        return
    end

    local select_node = util.find_first_descendant_by_type(stmt_node, "select")
    local from_node = util.find_first_descendant_by_type(stmt_node, "from")

    if not select_node or not from_node then
        vim.notify("Statement does not have a SELECT and FROM clause.", vim.log.levels.WARN)
        return
    end

    local cte_defs = diag.get_cte_definitions(stmt_node, bufnr)
    local scopes = diag.get_query_scopes(stmt_node)

    local _, active_tables = {}, {}
    if #scopes > 0 then
        local main_scope_nodes = scopes[1]
        for _, scope in ipairs(scopes) do
            if scope[1] == stmt_node then
                main_scope_nodes = scope
                break
            end
        end
        _, active_tables = diag.analyze_relations(main_scope_nodes, bufnr, {}, cte_defs)
    end

    if #active_tables == 0 then
        vim.notify("No tables found in FROM clause.", vim.log.levels.WARN)
        return
    end

    local target_table = nil
    for _, rel in ipairs(active_tables) do
        if not rel.derived and rel.table then
            target_table = rel.table
            break
        end
    end

    if not target_table then
        vim.notify("Could not find a base table in the SELECT statement.", vim.log.levels.WARN)
        return
    end

    local databases = util.get_databases()
    local filtered_dbs = {}
    for _, db in ipairs(databases or {}) do
        if util.is_a_table(db, target_table) then
            table.insert(filtered_dbs, db)
        end
    end

    if #filtered_dbs == 0 then
        vim.notify("Target table " .. target_table .. " not found in any database.", vim.log.levels.WARN)
        return
    end

    local picker = require('vim-teradata.picker').get()
    picker.pick_completion(
        filtered_dbs,
        {},                   -- context (unused here)
        { fzf_options = "" }, -- single select, no multi
        function(selected, _)
            local selected_db = selected and selected[1] or nil
            if not selected_db then return end

            local target_cols = util.get_columns({ { db_name = selected_db, tb_name = target_table } })
            local all_source_cols = {}
            for _, rel in ipairs(active_tables) do
                local rel_cols = {}
                if rel.db and rel.table and not rel.derived then
                    rel_cols = util.get_columns({ { db_name = rel.db, tb_name = rel.table } })
                elseif rel.columns then
                    for _, c in ipairs(rel.columns) do table.insert(rel_cols, c.name) end
                end
                for _, c in ipairs(rel_cols or {}) do
                    all_source_cols[c:upper()] = true
                end
            end

            local common_cols = {}
            for _, c in ipairs(target_cols or {}) do
                if all_source_cols[c:upper()] then
                    table.insert(common_cols, c)
                end
            end

            if #common_cols == 0 then
                vim.notify("No common columns found between target and source.", vim.log.levels.WARN)
                return
            end

            local from_sr, from_sc, _, _ = from_node:range()
            local _, _, stmt_er, stmt_ec = stmt_node:range()

            local lines = vim.api.nvim_buf_get_text(bufnr, from_sr, from_sc, stmt_er, stmt_ec, {})
            if not lines or #lines == 0 then return end

            lines[#lines] = lines[#lines]:gsub("%s*;%s*$", "")
            lines[#lines] = lines[#lines] .. ";"

            local cols_str = table.concat(common_cols, ",\n    ")
            local insert_clause = string.format("insert into %s.%s (\n    %s\n)", selected_db, target_table, cols_str)
            local select_clause = "select \n    " .. cols_str

            local select_lines = vim.split(select_clause, "\n")
            local insert_lines = vim.split(insert_clause, "\n")

            for i = #select_lines, 1, -1 do
                table.insert(lines, 1, select_lines[i])
            end
            for i = #insert_lines, 1, -1 do
                table.insert(lines, 1, insert_lines[i])
            end

            local insert_row = stmt_er + 1
            local total_lines = vim.api.nvim_buf_line_count(bufnr)
            if insert_row > total_lines then insert_row = total_lines end

            vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })
            vim.api.nvim_buf_set_lines(bufnr, insert_row + 1, insert_row + 1, false, lines)

            vim.notify("Transform to INSERT action completed.", vim.log.levels.INFO)
        end
    )
end

-- =============================================================================
-- Action 6: Autocomplete JOIN Condition
-- =============================================================================

---Autocompletes the JOIN condition matching common fields.
---@param bufnr number
local function action_autocomplete_join(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row_1, col_0 = cursor[1], cursor[2]

    local ts_mod = require('vim-teradata.sql-autocomplete.treesitter')
    local context = ts_mod.analyze_sql_context()

    if not context or not context.tables or #context.tables < 2 then
        vim.notify("Could not find at least 2 tables to join.", vim.log.levels.WARN)
        return
    end

    local tables = context.tables
    local t1 = tables[#tables - 1]
    local t2 = tables[#tables]

    if not t1.tb_name or not t2.tb_name then
        vim.notify("Could not resolve table names for the join.", vim.log.levels.WARN)
        return
    end

    local DatabaseMap = util.get_databases()
    local t1_def = { db_name = t1.db_name, tb_name = t1.tb_name }
    local t2_def = { db_name = t2.db_name, tb_name = t2.tb_name }

    local cols1 = util.get_columns({ t1_def }) or {}
    local cols2 = util.get_columns({ t2_def }) or {}

    if #cols1 == 0 and not t1.db_name then
        for _, db in ipairs(DatabaseMap or {}) do
            if util.is_a_table(db, t1.tb_name) then
                cols1 = util.get_columns({ { db_name = db, tb_name = t1.tb_name } }) or {}
                break
            end
        end
    end
    if #cols2 == 0 and not t2.db_name then
        for _, db in ipairs(DatabaseMap or {}) do
            if util.is_a_table(db, t2.tb_name) then
                cols2 = util.get_columns({ { db_name = db, tb_name = t2.tb_name } }) or {}
                break
            end
        end
    end

    local set1 = {}
    for _, c in ipairs(cols1) do
        set1[c:upper()] = true
    end

    local common = {}
    for _, c in ipairs(cols2) do
        if set1[c:upper()] then
            table.insert(common, c:lower())
        end
    end

    if #common == 0 then
        vim.notify("No common columns found between tables.", vim.log.levels.WARN)
        return
    end

    local alias1 = (t1.alias and t1.alias ~= "") and t1.alias:lower() or t1.tb_name:lower()
    local alias2 = (t2.alias and t2.alias ~= "") and t2.alias:lower() or t2.tb_name:lower()

    local conds = {}
    for _, c in ipairs(common) do
        table.insert(conds, string.format("%s.%s = %s.%s", alias1, c, alias2, c))
    end
    local condition_str = table.concat(conds, " and ")

    vim.api.nvim_buf_set_text(bufnr, row_1 - 1, col_0, row_1 - 1, col_0, { " " .. condition_str })

    vim.notify("Auto-completed JOIN condition.", vim.log.levels.INFO)
end

-- =============================================================================
-- Action 7: Rename Alias
-- =============================================================================

---Renames the alias everywhere in the current statement.
---@param bufnr number
local function action_rename_alias(bufnr)
    local alias_node = find_alias_identifier(bufnr)
    if not alias_node then
        vim.notify("Cursor is not on an alias (definition or usage).", vim.log.levels.WARN)
        return
    end

    local current_name = diag.get_text(alias_node, bufnr)
    if not current_name or current_name == "" then
        vim.notify("Could not read alias name.", vim.log.levels.WARN)
        return
    end

    local stmt_node = util.find_node_by_type(alias_node, "statement")
    if not stmt_node then
        vim.notify("Could not find enclosing statement.", vim.log.levels.WARN)
        return
    end

    vim.ui.input({
        prompt = "New alias name: ",
        default = current_name,
    }, function(new_name)
        if not new_name or new_name == "" or new_name == current_name then
            return
        end

        -- Find every identifier in the statement that matches the alias name
        local edits = {}
        local function collect_matches(n)
            if n:type() == "identifier" then
                if diag.get_text(n, bufnr) == current_name then
                    local sr, sc, er, ec = n:range()
                    table.insert(edits, { sr = sr, sc = sc, er = er, ec = ec, text = new_name })
                end
            end
            for child in n:iter_children() do
                collect_matches(child)
            end
        end

        collect_matches(stmt_node)

        if #edits == 0 then return end

        -- Apply bottom-to-top (safest for ranges)
        table.sort(edits, function(a, b)
            if a.sr == b.sr then return a.sc > b.sc end
            return a.sr > b.sr
        end)

        for _, e in ipairs(edits) do
            vim.api.nvim_buf_set_text(bufnr, e.sr, e.sc, e.er, e.ec, { e.text })
        end

        vim.notify(
            string.format("Renamed alias '%s' → '%s' in %d place(s)", current_name, new_name, #edits),
            vim.log.levels.INFO
        )
    end)
end

-- =============================================================================
-- Public API
-- =============================================================================

---Collects applicable code actions at the cursor and presents them via vim.ui.select.
function M.run()
    local bufnr = vim.api.nvim_get_current_buf()

    local ok, _ = pcall(vim.treesitter.get_parser, bufnr, "sql")
    if not ok then
        vim.notify("Tree-sitter parser for SQL not found.", vim.log.levels.ERROR)
        return
    end

    local actions = {}

    -- Check: Expand *
    if find_star_node(bufnr) then
        table.insert(actions, {
            title = "Expand * with column names",
            fn = function() action_expand_star(bufnr) end,
        })
    end

    -- Check: Extract Subquery → CTE
    local subq = find_subquery_node(bufnr)
    if subq then
        table.insert(actions, {
            title = "Extract subquery into CTE",
            fn = function() action_extract_cte(bufnr) end,
        })
    end

    -- Check: Autocomplete JOIN
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cur_row, cur_col = cursor[1], cursor[2]
    local current_line = vim.api.nvim_buf_get_lines(bufnr, cur_row - 1, cur_row, false)[1] or ""
    local before_cursor = current_line:sub(1, cur_col)
    local last_word = before_cursor:match("%S+$") or ""

    if last_word:upper() == "ON" then
        table.insert(actions, {
            title = "Autocomplete JOIN condition",
            fn = function() action_autocomplete_join(bufnr) end,
        })
    end

    -- Check: Auto-alias tables / Transform to DELETE/INSERT
    local stmt_node = get_cursor_statement(bufnr)
    if stmt_node then
        -- Auto-alias tables logic...
        local scopes = diag.get_query_scopes(stmt_node)
        local has_unaliased = false
        for _, scope_nodes in ipairs(scopes) do
            for _, node in ipairs(scope_nodes) do
                for _, rel_node in diag.QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
                    if diag.is_nested_in_subquery(rel_node, node) then goto continue end
                    local alias_node = rel_node:field("alias")[1]
                    if not alias_node then
                        -- Verify it's a table reference, not a subquery
                        local is_subq = false
                        for child in rel_node:iter_children() do
                            if child:type() == "subquery" then
                                is_subq = true; break
                            end
                        end
                        if not is_subq then
                            has_unaliased = true
                            break
                        end
                    end
                    ::continue::
                end
                if has_unaliased then break end
            end
            if has_unaliased then break end
        end

        if has_unaliased then
            table.insert(actions, {
                title = "Auto-alias tables",
                fn = function() action_auto_alias(bufnr) end,
            })
        end

        local select_node = util.find_first_descendant_by_type(stmt_node, "select")
        local from_node = util.find_first_descendant_by_type(stmt_node, "from")

        if select_node and from_node then
            table.insert(actions, {
                title = "Transform SELECT to DELETE statement",
                fn = function() action_transform_to_delete(bufnr) end,
            })
            table.insert(actions, {
                title = "Transform SELECT to INSERT SELECT statement",
                fn = function() action_transform_to_insert(bufnr) end,
            })
        end
    end

    -- Check: Rename Alias
    if find_alias_identifier(bufnr) then
        table.insert(actions, {
            title = "Rename alias and update all references",
            fn = function() action_rename_alias(bufnr) end,
        })
    end

    if #actions == 0 then
        vim.notify("No code actions available at cursor.", vim.log.levels.INFO)
        return
    end

    vim.ui.select(actions, {
        prompt = "Code Actions:",
        format_item = function(item) return item.title end,
    }, function(choice)
        if choice then
            choice.fn()
        end
    end)
end

return M
