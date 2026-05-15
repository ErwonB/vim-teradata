local M = {}

-- Checks if a parser is available for `lang` in `bufnr`.
---@param bufnr integer
---@param lang? string  defaults to "teradata"
---@return vim.treesitter.LanguageTree|nil
function M.ensure_parser(bufnr, lang)
    lang = lang or "teradata"
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok or not parser then
        vim.notify("Tree-sitter parser for " .. lang .. " not found.", vim.log.levels.ERROR)
        return nil
    end
    return parser
end

-- Walks from `node` upward through ancestors (including itself).
-- Returns the first node whose type matches `types`.
-- `types` may be a single string or a set-table { type_name = true, ... }.
---@param node TSNode?
---@param types string|table
---@return TSNode|nil
function M.ancestor(node, types)
    if not node then return nil end
    local match = type(types) == "string"
        and function(t) return t == types end
        or function(t) return types[t] end
    local current = node
    while current do
        if match(current:type()) then return current end
        current = current:parent()
    end
    return nil
end

-- Returns the first descendant of `node` (DFS over all children) whose type matches `types`.
-- `types` may be a single string or a set-table { type_name = true, ... }.
---@param node TSNode?
---@param types string|table
---@return TSNode|nil
function M.descendant(node, types)
    if not node then return nil end
    local match = type(types) == "string"
        and function(t) return t == types end
        or function(t) return types[t] end
    for child in node:iter_children() do
        if match(child:type()) then return child end
        local found = M.descendant(child, types)
        if found then return found end
    end
    return nil
end

-- Returns the first direct child of `node` whose type matches `type_name`.
---@param node TSNode?
---@param type_name string
---@return TSNode|nil
function M.child_by_type(node, type_name)
    if not node then return nil end
    for child in node:iter_children() do
        if child:type() == type_name then return child end
    end
    return nil
end

-- Returns the first child of `node` for a named grammar field.
-- Wraps TSNode:field() (Neovim 0.9+).
---@param node TSNode?
---@param field_name string
---@return TSNode|nil
function M.child_by_field(node, field_name)
    if not node then return nil end
    return node:field(field_name)[1]
end

-- Returns the nearest enclosing scope node (subquery or statement) for `node`.
---@param node TSNode?
---@return TSNode|nil
function M.scope_node(node)
    return M.ancestor(node, { subquery = true, statement = true })
end

-- Returns true when `node` is a descendant of `scope_node` without any
-- intermediate `subquery` node in the path.
---@param node TSNode
---@param scope_node TSNode
---@return boolean
function M.is_direct_scope_descendant(node, scope_node)
    local current = node:parent()
    while current do
        if current == scope_node then return true end
        if current:type() == 'subquery' then return false end
        current = current:parent()
    end
    return false
end

-- Finds the enclosing `statement` ancestor, or—at the program level—the closest
-- preceding `statement` sibling. Returns an ERROR node as a last resort.
---@param node TSNode?
---@param bufnr integer
---@param cursor_row integer  0-indexed cursor row
---@return TSNode|nil
function M.enclosing_or_preceding_statement(node, bufnr, cursor_row)
    bufnr = bufnr or 0
    if not node then return nil end

    local original_node_start_row = math.max(select(1, node:start()), cursor_row)

    -- 1. Walk ancestors looking for an enclosing statement
    local current = node
    local root_node = nil
    while current do
        local ntype = current:type()
        if ntype == 'statement' then return current end
        if ntype == 'program' then
            root_node = current
            break
        end
        local parent = current:parent()
        if not parent then
            if ntype == 'program' then root_node = current end
            break
        end
        current = parent
    end

    -- 2. Scan program children backwards for the nearest preceding statement
    if root_node then
        local prev_type = nil
        for i = 0, root_node:child_count() - 1 do
            local child = root_node:child(root_node:child_count() - 1 - i)
            if not child then goto continue end
            local _, _, child_end_row, _ = child:range()
            if child_end_row <= original_node_start_row then
                if child:type() == 'statement' and prev_type ~= ';' then
                    return child
                end
                prev_type = child:type()
            end
            ::continue::
        end
    end

    -- 3. Fallback for top-level ERROR nodes
    if current and current:type() == 'ERROR' then
        return current
    end

    return nil
end

-- Returns the 0-indexed start/end row pair for `node` as a half-open range.
---@param node TSNode
---@return integer, integer
function M.node_rows(node)
    local sr, _, er, _ = node:range()
    return sr, er + 1
end

-- Returns true if `query` has at least one capture in `node`.
---@param query vim.treesitter.Query
---@param node TSNode
---@param bufnr integer
---@param start_row? integer
---@param end_row? integer
---@return boolean
function M.any_capture(query, node, bufnr, start_row, end_row)
    for _ in query:iter_captures(node, bufnr, start_row, end_row) do
        return true
    end
    return false
end

-- Returns the content of `bufnr` line `row` (1-indexed) up to `col` (0-indexed byte column).
---@param bufnr? integer  defaults to current buffer (0)
---@param row integer  1-indexed row
---@param col integer  0-indexed byte column
---@return string
function M.line_prefix(bufnr, row, col)
    bufnr = bufnr or 0
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    return line:sub(1, col)
end

-- Returns true when `statement_node` is immediately followed (skipping `;` siblings)
-- by an ERROR node within one row.
---@param statement_node TSNode
---@return boolean
function M.has_adjacent_error(statement_node)
    local next_sib = statement_node:next_sibling()
    while next_sib and next_sib:type() == ';' do
        next_sib = next_sib:next_sibling()
    end
    if next_sib and next_sib:type() == 'ERROR' then
        local stmt_end_row = select(3, statement_node:range())
        local err_start_row = select(1, next_sib:range())
        if err_start_row <= stmt_end_row + 1 then
            return true
        end
    end
    return false
end

-- Returns a list of up to `count` consecutive `statement` nodes starting at `stmt_node`,
-- following next named siblings.
---@param stmt_node TSNode
---@param count integer
---@return TSNode[]
function M.collect_next_sibling_statement_nodes(stmt_node, count)
    local nodes = { stmt_node }
    local node = stmt_node
    while #nodes < count do
        node = node:next_named_sibling()
        if not node then break end
        if node:type() == 'statement' then
            table.insert(nodes, node)
        end
    end
    return nodes
end

-- Returns true if `node` (a `statement`) has a `keyword_merge` direct child.
---@param node TSNode
---@return boolean
function M.is_merge_statement(node)
    if not node or node:type() ~= 'statement' then return false end
    for child in node:iter_children() do
        if child:type() == 'keyword_merge' then return true end
    end
    return false
end

-- Builds a copy of the buffer text with a single dummy identifier ('a') inserted at
-- the cursor position, making an incomplete query parsable by tree-sitter.
---@param bufnr integer
---@param row_0 integer  0-indexed row
---@param col_0 integer  0-indexed byte column
---@return string
function M.build_parsable_query_with_dummy(bufnr, row_0, col_0)
    local line    = vim.api.nvim_buf_get_lines(bufnr, row_0, row_0 + 1, false)[1] or ""
    local before  = vim.api.nvim_buf_get_lines(bufnr, 0, row_0, false)
    local prefix  = vim.api.nvim_buf_get_text(bufnr, row_0, 0, row_0, col_0, {})[1] or ""
    local suffix  = vim.api.nvim_buf_get_text(bufnr, row_0, col_0, row_0, #line, {})[1] or ""
    local after   = vim.api.nvim_buf_get_lines(bufnr, row_0 + 1, -1, false)
    local parts   = {}
    vim.list_extend(parts, before)
    table.insert(parts, prefix .. "a" .. suffix)
    vim.list_extend(parts, after)
    return table.concat(parts, "\n")
end

-- Finds the next node of `target_type` after the cursor, walking forward through
-- siblings and then up to ancestor siblings.
-- `opts` may include { bufnr, pos } (defaults to current buffer / cursor position).
---@param target_type string
---@param opts? { bufnr?: integer, pos?: integer[] }
---@return TSNode|nil
function M.next_node_by_type(target_type, opts)
    opts = opts or {}
    local buf = opts.bufnr or vim.api.nvim_get_current_buf()
    local cursor_node = vim.treesitter.get_node({ bufnr = buf, pos = opts.pos })
    if not cursor_node then return nil end

    if cursor_node:type() == "program" or not cursor_node:parent() then
        local cursor = opts.pos or vim.api.nvim_win_get_cursor(0)
        local row = cursor[1] - 1  -- 0-indexed
        local col = cursor[2]
        for child in cursor_node:iter_children() do
            local start_row, start_col = child:range()
            if (start_row > row or (start_row == row and start_col > col))
                and child:type() == target_type then
                return child
            end
        end
        return nil
    end

    local node = cursor_node
    while node do
        local sibling = node:next_sibling()
        while sibling do
            if sibling:type() == target_type then return sibling end
            local found = M.descendant(sibling, target_type)
            if found then return found end
            sibling = sibling:next_sibling()
        end
        node = node:parent()
    end
    return nil
end

-- Finds the previous node of `target_type` before the cursor, walking backward through
-- siblings and then up to ancestor siblings.
-- `opts` may include { bufnr, pos } (defaults to current buffer / cursor position).
---@param target_type string
---@param opts? { bufnr?: integer, pos?: integer[] }
---@return TSNode|nil
function M.prev_node_by_type(target_type, opts)
    opts = opts or {}
    local buf = opts.bufnr or vim.api.nvim_get_current_buf()
    local cursor_node = vim.treesitter.get_node({ bufnr = buf, pos = opts.pos })
    if not cursor_node then return nil end

    if cursor_node:type() == "program" or not cursor_node:parent() then
        local cursor = opts.pos or vim.api.nvim_win_get_cursor(0)
        local row = cursor[1] - 1  -- 0-indexed
        local col = cursor[2]
        local last_found = nil
        for child in cursor_node:iter_children() do
            local start_row, start_col = child:range()
            if start_row > row or (start_row == row and start_col >= col) then break end
            if child:type() == target_type then last_found = child end
        end
        return last_found
    end

    local node = cursor_node
    while node do
        local sibling = node:prev_sibling()
        while sibling do
            if sibling:type() == target_type then return sibling end
            local found = M.descendant(sibling, target_type)
            if found then return found end
            sibling = sibling:prev_sibling()
        end
        node = node:parent()
    end
    return nil
end

-- Finds the range of the nearest ancestor node matching `target_type`, extended
-- to include adjacent delimiters (commas, semicolons, AND/OR keywords).
-- Returns s_row, s_col, e_row, e_col, or nil values if the node is not found.
---@param target_type string
---@param bufnr integer
---@return integer?, integer?, integer?, integer?
function M.node_range_with_delimiters(target_type, bufnr)
    local current_node = vim.treesitter.get_node({ bufnr = bufnr })
    if not current_node then return end

    local node = M.ancestor(current_node, target_type)
    if not node then
        vim.notify("Node '" .. target_type .. "' not found.", vim.log.levels.WARN)
        return
    end

    local s_row, s_col, e_row, e_col = node:range()

    if target_type == "term" then
        local prev = node:prev_sibling()
        local next = node:next_sibling()
        if prev and prev:type() == "," then
            s_row, s_col = prev:range()
        elseif next and next:type() == "," then
            local _, _, ne_row, ne_col = next:range()
            e_row, e_col = ne_row, ne_col
        end

    elseif target_type == "binary_expression" then
        local prev = node:prev_sibling()
        local next = node:next_sibling()
        if prev and (prev:type() == "keyword_and" or prev:type() == "keyword_or") then
            s_row, s_col = prev:range()
        elseif next and (next:type() == "keyword_and" or next:type() == "keyword_or") then
            local _, _, ne_row, ne_col = next:range()
            e_row, e_col = ne_row, ne_col
        end

        local parent = node:parent()
        if parent and parent:type() == "where" then
            local binary_count = 0
            for child in parent:iter_children() do
                if child:type() == "binary_expression" then
                    binary_count = binary_count + 1
                end
            end
            if binary_count == 1 then
                s_row, s_col, e_row, e_col = parent:range()
            end
        end

    elseif target_type == "statement" then
        local next = node:next_sibling()
        if next and next:type() == ";" then
            local _, _, ne_row, ne_col = next:range()
            e_row, e_col = ne_row, ne_col
        end
    end

    return s_row, s_col, e_row, e_col
end

-- ---------------------------------------------------------------------------
-- Grammar-aware keyword context
-- ---------------------------------------------------------------------------

-- Returns the keyword name (without "keyword_" prefix, lowercase) that
-- immediately precedes the word currently being typed, or nil if none found.
--
-- Strategy: tokenise the line prefix up to the cursor.
--   • If the prefix ends in a non-space character, the last token is the
--     partial word being typed — skip it and examine the one before it.
--   • If the prefix ends in a space, all tokens are complete — examine the
--     last one.
-- The candidate is then verified against the loaded teradata grammar's symbol
-- table to guard against false positives from identifiers or literals.
--
-- This lexical fallback is intentionally simple and handles the primary
-- real-world case: the user typed a keyword, pressed space, and is about to
-- type (or trigger completion for) the next token.  The tree-sitter parse
-- is usually an ERROR node at this point, so a node-walk would be unreliable.
--
---@param bufnr integer
---@param row_1 integer  1-indexed row
---@param col_0 integer  0-indexed byte column
---@return string|nil  e.g. "inner", "nonsequenced", "left"
function M.previous_keyword_at_cursor(bufnr, row_1, col_0)
    local prefix = M.line_prefix(bufnr, row_1, col_0)

    -- Split on whitespace
    local tokens = {}
    for tok in prefix:gmatch('%S+') do
        table.insert(tokens, tok)
    end

    if #tokens == 0 then return nil end

    -- Determine which token to examine:
    --   Prefix ends with non-space → last token is the partial word being
    --   typed; the previous keyword is the one before it.
    --   Prefix ends with space     → cursor is right after a completed token.
    local target_idx
    if prefix:sub(-1):match('%S') then
        target_idx = #tokens - 1
    else
        target_idx = #tokens
    end

    if target_idx < 1 then return nil end

    local candidate = tokens[target_idx]:lower()

    -- Verify it is a keyword_<candidate> symbol in the loaded teradata grammar.
    local ok, symbols = pcall(function()
        return vim.treesitter.language.inspect('teradata').symbols
    end)
    if not ok or not symbols then return nil end

    if symbols['keyword_' .. candidate] ~= nil then
        return candidate
    end

    return nil
end

return M
