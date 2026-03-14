local util = require('vim-teradata.util')
local diag = require('vim-teradata.diagnostics')
local ts = require('vim-teradata.sql-autocomplete.treesitter')

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

---Auto-aliases all unaliased tables in the statement.
---@param bufnr number
local function action_auto_alias(bufnr)
    local stmt_node = get_cursor_statement(bufnr)
    if not stmt_node then
        vim.notify("Cursor is not inside a SQL statement.", vim.log.levels.WARN)
        return
    end

    local scopes = diag.get_query_scopes(stmt_node)
    if #scopes == 0 then
        vim.notify("No query scopes found.", vim.log.levels.WARN)
        return
    end

    -- Collect existing aliases
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

    -- Collect relations that need aliases (in reverse line order to avoid index shifts)
    local edits = {}
    for _, scope_nodes in ipairs(scopes) do
        for _, node in ipairs(scope_nodes) do
            for _, rel_node in diag.QUERIES.relation:iter_captures(node, bufnr, 0, -1) do
                if diag.is_nested_in_subquery(rel_node, node) then goto continue end

                local alias_node = rel_node:field("alias")[1]
                if alias_node then goto continue end -- already has alias

                -- Check it's not a subquery (we only auto-alias direct table references)
                local has_subquery = false
                for child in rel_node:iter_children() do
                    if child:type() == "subquery" then
                        has_subquery = true
                        break
                    end
                end
                if has_subquery then goto continue end

                -- Find the object_reference to get the table name
                local obj_ref = nil
                for child in rel_node:iter_children() do
                    if child:type() == "object_reference" then
                        obj_ref = child
                        break
                    end
                end

                if obj_ref then
                    local parts = {}
                    for part in obj_ref:iter_children() do
                        if part:type() == "identifier" then
                            table.insert(parts, diag.get_text(part, bufnr))
                        end
                    end
                    local table_name = parts[#parts]
                    if table_name then
                        local alias = generate_alias(table_name, used_aliases)
                        local _, _, er, ec = obj_ref:range()
                        table.insert(edits, { row = er, col = ec, alias = alias })
                    end
                end

                ::continue::
            end
        end
    end

    if #edits == 0 then
        vim.notify("All tables already have aliases.", vim.log.levels.INFO)
        return
    end

    -- Sort edits in reverse order (bottom-to-top, right-to-left)
    table.sort(edits, function(a, b)
        if a.row == b.row then return a.col > b.col end
        return a.row > b.row
    end)

    for _, edit in ipairs(edits) do
        vim.api.nvim_buf_set_text(bufnr, edit.row, edit.col, edit.row, edit.col, { " " .. edit.alias })
    end

    vim.notify(string.format("Added %d alias(es).", #edits), vim.log.levels.INFO)
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

    -- Check: Auto-alias tables
    local stmt_node = get_cursor_statement(bufnr)
    if stmt_node then
        -- Check if there are unaliased relations
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
