local M = {}
local api = vim.api
local ts = vim.treesitter

local INDENT_STR = "  "

local function select_node(target_node_type, buf)
    local node = ts.get_node({ bufnr = buf })

    while node do
        if node:type() == target_node_type then
            break
        end
        node = node:parent()
    end

    if not node then
        vim.notify("Node '" .. target_node_type .. "' not found.", vim.log.levels.WARN)
        return
    end

    local s_row, s_col, e_row, e_col = node:range()
    if target_node_type == "term" then
        local prev = node:prev_sibling()

        -- Check if previous node exists and is exactly a comma
        if prev and prev:type() == "," then
            -- Expand the start coordinates to include the comma
            local comma_s_row, comma_s_col, _, _ = prev:range()
            s_row = comma_s_row
            s_col = comma_s_col
        else -- first field
            local next = node:next_sibling()
            if next and next:type() == "," then
                local _, _, comma_e_row, comma_e_col = next:range()
                e_row = comma_e_row
                e_col = comma_e_col
            end
        end
    else
        if target_node_type == "statement" then
            local next = node:next_sibling()
            if next and next:type() == ";" then
                local _, _, semicolon_e_row, semicolon_e_col = next:range()
                e_row = semicolon_e_row
                e_col = semicolon_e_col
            end
        end
    end
    return s_row, s_col, e_row, e_col
end

local function get_node_text(node, buf)
    local text = ts.get_node_text(node, buf)
    local type = node:type()
    local parent = node:parent()

    -- Keywords -> LOWERCASE
    if type:match("^keyword_") then
        return string.lower(text)
    end

    -- Identifiers -> UPPERCASE (with exceptions)
    if type == "identifier" then
        if parent then
            local ptype = parent:type()

            -- Exception A: Aliases (e.g., ") as z") -> lowercase
            -- We check if the current node is the one referenced by the 'alias' field of the parent
            local alias_node = parent:field("alias")
            if #alias_node > 0 and alias_node[1]:id() == node:id() then
                if ptype ~= "term" then
                    return string.lower(text)
                end

                return string.upper(text)
            end

            -- Exception B: Function Names (trim, cast) -> lowercase
            if ptype == "object_reference" then
                local grandparent = parent:parent()

                if grandparent and grandparent:type() == "field" then
                    return string.lower(text)
                end

                if grandparent and grandparent:type() == "invocation" then
                    local func_name_node = grandparent:named_child(0)
                    if func_name_node and func_name_node:id() == parent:id() then
                        return string.lower(text)
                    end
                end
            end
        end
        return string.upper(text)
    end

    return text
end

-- HELPER: Identify Major Clauses that need newlines
local function is_major_clause(type)
    return type == "from" or
        type == "where" or
        type == "group_by" or
        type == "order_by" or
        type == "having" or
        type == "select" or
        type == "update" or
        type == "temporal_modifier"
end

local function is_create_table_section(type)
    return type == "column_definitions" or
        type == "primary_index_clause" or
        type == "index_definition" or
        type == "partition_by"
end

local format_node

-- CORE LOGIC
format_node = function(node, buf, indent_lvl, context)
    local type = node:type()
    local current_indent = string.rep(INDENT_STR, indent_lvl)

    -- LEAF NODES
    if node:child_count() == 0 then
        return get_node_text(node, buf)
    end

    -- STATEMENT & SELECT NODES (The Structural Skeleton)
    -- We handle 'select' here too so subqueries align their FROM/WHERE clauses correctly
    if type == "statement" or type == "select" then
        local parts = {}
        local is_first = true

        for child in node:iter_children() do
            local c_type = child:type()
            -- Recurse
            local txt = format_node(child, buf, indent_lvl)

            -- CHECK: Does this child start a new section?
            if is_major_clause(c_type) or c_type == "select" then
                if not is_first then
                    -- Force Newline + Indent before FROM, WHERE, etc.
                    table.insert(parts, "\n" .. current_indent .. txt)
                else
                    table.insert(parts, txt)
                end
            elseif c_type == "select_expression" then
                -- Select expression handles its own internal newlines,
                -- but we ensure a newline exists before it if it's not the very first thing
                if not is_first then
                    table.insert(parts, "\n" .. txt) -- select_expression adds its own indent
                else
                    table.insert(parts, txt)
                end
            else
                -- Tiny keywords like 'distinct' or 'lock' or ';'
                if not is_first then
                    -- Heuristic: Don't add space if previous char was newline
                    if parts[#parts] and not parts[#parts]:match("\n%s*$") then
                        table.insert(parts, " ")
                    end
                end
                table.insert(parts, txt)
            end
            is_first = false
        end
        return table.concat(parts, "")
    end

    -- SELECT LIST (Fields)
    if type == "select_expression" then
        local parts = {}
        local is_first_field = true

        local children = {}
        for child in node:iter_children() do
            table.insert(children, child)
        end

        for i, child in ipairs(children) do
            local txt = format_node(child, buf, indent_lvl)
            local c_type = child:type()
            local newline = ""
            if i == #children then
                newline = "\n"
            end

            if c_type == "term" or c_type == "field" or c_type == "all_fields" or c_type == "identifier" then
                if is_first_field then
                    table.insert(parts, current_indent .. txt)
                    is_first_field = false
                else
                    table.insert(parts, "\n" .. current_indent .. ", " .. txt .. newline)
                end
            elseif c_type == "," then
                -- Ignore, we inject manually
            else
                -- Comments or modifiers
                table.insert(parts, txt)
            end
        end
        return table.concat(parts, "")
    end

    -- UPDATE STATEMENT
    if type == "update" then
        local parts = {}
        local inside_set = false

        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)

            if c_type == "keyword_update" then
                table.insert(parts, txt)
            elseif c_type == "keyword_set" then
                inside_set = true
                table.insert(parts, "\n" .. current_indent .. txt)
            elseif c_type == "keyword_from" then
                inside_set = false
                table.insert(parts, "\n" .. current_indent .. txt)
            elseif c_type == "where" then
                inside_set = false
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl, "where"))
            elseif c_type == "assignment" then
                -- Handle Assignments (field = value)
                -- If previous sibling was SET, we space it out.
                -- If previous was a comma (which we handled by inserting a newline), we append.
                local prev = child:prev_sibling()
                if prev and prev:type() == "," then
                    table.insert(parts, " " .. txt)
                else
                    table.insert(parts, " " .. txt)
                end
            elseif c_type == "," then
                if inside_set then
                    -- Leading comma style for SET clause
                    table.insert(parts, "\n" .. current_indent .. INDENT_STR .. ",")
                else
                    -- Normal comma (likely inside table list in FROM)
                    table.insert(parts, ",")
                end
            elseif c_type == "relation" then
                -- Check if this relation is part of the FROM clause
                local prev = child:prev_sibling()
                if prev and prev:type() == "keyword_from" then
                    -- First table in FROM -> Indent
                    table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
                elseif prev and prev:type() == "," then
                    -- Subsequent tables in FROM (e.g., Implicit Joins) -> Indent + Newline
                    -- Note: The comma logic above appends ",". We might need a newline here.
                    -- If we aren't inside SET, the comma just printed ",".
                    -- Let's force a newline for clarity in table lists.
                    table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
                else
                    -- Target table (after UPDATE)
                    table.insert(parts, " " .. txt)
                end
            else
                -- Fallback for other nodes
                local prev_part = parts[#parts]
                if prev_part and not prev_part:match("%s$") and not prev_part:match("\n$") and c_type ~= "," then
                    table.insert(parts, " ")
                end
                table.insert(parts, txt)
            end
        end
        return table.concat(parts, "")
    end

    -- FROM CLAUSE (Wrapper)
    if type == "from" then
        local parts = {}
        for child in node:iter_children() do
            if child:type() == "keyword_from" then
                table.insert(parts, get_node_text(child, buf))
            else
                -- The table(s)
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    -- WHERE CLAUSE (Wrapper)
    if type == "where" then
        local parts = {}
        for child in node:iter_children() do
            if child:type() == "keyword_where" then
                table.insert(parts, get_node_text(child, buf))
            else
                table.insert(parts, " " .. format_node(child, buf, indent_lvl, "where"))
            end
        end
        return table.concat(parts, "")
    end

    -- BINARY EXPRESSIONS (AND/OR Splitting)
    if type == "binary_expression" then
        local left = node:field("left")
        local right = node:field("right")
        local op = node:field("operator")

        if #op > 0 and (op[1]:type() == "keyword_and" or op[1]:type() == "keyword_or") then
            -- RECURSE with context!
            local l_txt = format_node(left[1], buf, indent_lvl, context)
            local op_txt = get_node_text(op[1], buf)
            local r_txt = format_node(right[1], buf, indent_lvl, context)

            return l_txt .. "\n" .. current_indent .. op_txt .. " " .. r_txt
        end

        -- Fallback for math/other binaries: Ensure context is passed down!
        local parts = {}
        for child in node:iter_children() do
            table.insert(parts, format_node(child, buf, indent_lvl, context))
        end
        return table.concat(parts, " ")
    end

    -- JOIN (Full Join structure)
    if type == "join" then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()

            if c_type == "relation" then
                -- The table being joined
                table.insert(parts, "\n" .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_on" then
                -- The ON keyword
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == "binary_expression" and child:type() ~= "keyword_full" and child:type() ~= "keyword_join" then
                -- The predicate (z.id = m.id)
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            else
                -- Keywords (FULL JOIN)
                if #parts > 0 then table.insert(parts, " ") end
                table.insert(parts, format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    -- PARENTHESES / SUBQUERIES
    if type == "subquery" or type == "relation" then
        local has_paren = false
        for child in node:iter_children() do
            if child:type() == "(" then
                has_paren = true
                break
            end
        end

        if has_paren then
            local parts = {}
            for child in node:iter_children() do
                local c_type = child:type()
                if c_type == "(" then
                    table.insert(parts, "(\n" .. string.rep(INDENT_STR, indent_lvl + 1))
                elseif c_type == ")" then
                    table.insert(parts, "\n" .. current_indent .. ")")
                else
                    -- Indent content deeper
                    table.insert(parts, format_node(child, buf, indent_lvl + 1))
                end
            end
            return table.concat(parts, "")
        end
    end

    -- CASE STATEMENT
    if type == "case" then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl + 1)

            if c_type == "keyword_case" then
                table.insert(parts, get_node_text(child, buf))
            elseif c_type == "keyword_when" then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
            elseif c_type == "keyword_end" then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
            elseif c_type == "keyword_else" then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
            else
                table.insert(parts, " " .. txt)
            end
        end
        return table.concat(parts, "")
    end

    if type == "column_definitions" then
        local parts = {}
        local is_first_col = true
        local col_indent = string.rep(INDENT_STR, indent_lvl + 1)

        -- PASS 1: Calculate Max Length of Column Names for Alignment
        local max_name_len = 0

        for child in node:iter_children() do
            if child:type() == "column_definition" then
                -- Find the name node (identifier)
                local name_node = child:field("name")
                if #name_node == 0 then
                    -- Fallback: loop children if field name not available in grammar version
                    for grandchild in child[1]:iter_children() do
                        if grandchild:type() == "identifier" then
                            name_node = grandchild
                            break
                        end
                    end
                end

                if #name_node > 0 then
                    local name_txt = get_node_text(name_node[1], buf) -- Should be UPPERCASE based on your rules
                    if #name_txt > max_name_len then
                        max_name_len = #name_txt
                    end
                end
            end
        end

        -- PASS 2: Formatting
        for child in node:iter_children() do
            local c_type = child:type()

            if c_type == "(" then
                table.insert(parts, "(\n")
            elseif c_type == ")" then
                table.insert(parts, "\n" .. current_indent .. ")")
            elseif c_type == "column_definition" then
                -- [CUSTOM LOGIC FOR ALIGNMENT]
                -- Instead of calling format_node(child), we process it manually here

                local col_parts = {}
                local name_txt = ""
                local last_r, last_c = -1, -1

                -- Iterate children of the column_definition (Name, Type, Not Null, Format...)
                for grandchild in child:iter_children() do
                    local gc_txt = format_node(grandchild, buf, indent_lvl)
                    local gc_type = grandchild:type()

                    local _, _, er, ec = grandchild:range()
                    last_r, last_c = er, ec

                    -- Capture the name, buffer the rest
                    if gc_type == "identifier" and name_txt == "" then
                        name_txt = gc_txt
                    else
                        table.insert(col_parts, gc_txt)
                    end
                end

                local _, _, parent_er, parent_ec = child:range()
                if last_r ~= -1 and (parent_ec > last_c or parent_er > last_r) then
                    -- Retrieve the raw missing text from the buffer
                    local missing_text = api.nvim_buf_get_text(buf, last_r, last_c, parent_er, parent_ec, {})
                    local joined = table.concat(missing_text, " ")
                    -- If it's not just whitespace, append it
                    if joined:match("%S") then
                        table.insert(col_parts, joined)
                    end
                end

                -- Calculate Padding
                local padding = ""
                if max_name_len > 0 then
                    local spaces_needed = max_name_len - #name_txt
                    padding = string.rep(" ", spaces_needed)
                end

                -- Assemble: NAME + Padding + Rest (Type, Constraints, Format)
                local rest_of_line = table.concat(col_parts, " ")
                local final_line = name_txt .. padding .. " " .. rest_of_line

                if is_first_col then
                    table.insert(parts, col_indent .. " " .. final_line)
                    is_first_col = false
                else
                    table.insert(parts, "\n" .. col_indent .. ", " .. final_line)
                end
            elseif c_type == "," then
                -- Skip existing commas
            elseif c_type:match("comment") then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    if type == "create_table" then
        local parts = {}
        local is_first = true

        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)

            if is_create_table_section(c_type) then
                table.insert(parts, "\n" .. current_indent .. txt)
            else
                if not is_first then
                    -- Don't add space if previous was newline
                    if parts[#parts] and not parts[#parts]:match("\n%s*$") then
                        table.insert(parts, " ")
                    end
                end
                table.insert(parts, txt)
            end
            is_first = false
        end
        return table.concat(parts, "")
    end

    if type == "insert" then
        local parts = {}
        local header_parts = {}
        local column_list_text = ""

        for child in node:iter_children() do
            local c_type = child:type()

            if c_type == "keyword_insert" or c_type == "keyword_into" or c_type == "object_reference" then
                -- Collect header (INSERT INTO table_name)
                table.insert(header_parts, format_node(child, buf, indent_lvl))
            elseif c_type == "list" then
                local col_parts = {}
                local col_indent = string.rep(INDENT_STR, indent_lvl + 1)
                local is_first_col = true

                for col_child in child:iter_children() do
                    if col_child:type() == "column" then
                        local identifier_node = col_child:named_child(0)
                        local identifier_txt = format_node(identifier_node, buf, indent_lvl)

                        if is_first_col then
                            table.insert(col_parts, col_indent .. identifier_txt)
                            is_first_col = false
                        else
                            table.insert(col_parts, "\n" .. col_indent .. ", " .. identifier_txt)
                        end
                    end
                end

                column_list_text = "\n(\n" .. table.concat(col_parts, "") .. "\n" .. current_indent .. ")"
            else
                local rest_txt = format_node(child, buf, indent_lvl)
                if rest_txt ~= "" and rest_txt ~= "," then
                    table.insert(parts, "\n" .. current_indent .. rest_txt)
                end
            end
        end

        table.insert(parts, 1, table.concat(header_parts, " "))
        table.insert(parts, 2, column_list_text)

        return table.concat(parts, "")
    end

    if type == "temporal_modifier" then
        local parts = {}
        for child in node:iter_children() do
            local txt = get_node_text(child, buf) -- Use get_node_text to preserve case
            table.insert(parts, txt)
        end
        local modifier_text = table.concat(parts, " ")
        return modifier_text .. "\n" .. string.rep(INDENT_STR, indent_lvl)
    end

    -- GENERIC FALLBACK
    local parts = {}
    for child in node:iter_children() do
        -- CRITICAL: Pass 'context' down here so nested binary_expressions know they are in WHERE
        local txt = format_node(child, buf, indent_lvl, context)
        local c_type = child:type()
        local prev = parts[#parts]

        if c_type == "." or (prev and prev:sub(-1) == ".") then
            table.insert(parts, txt)
        elseif c_type == "(" then
            table.insert(parts, " " .. txt)
        elseif c_type == ")" then
            table.insert(parts, txt)
        else
            if #parts > 0 and prev ~= "(" and prev:sub(-1) ~= "\n" then table.insert(parts, " ") end
            table.insert(parts, txt)
        end
    end
    return table.concat(parts, "")
end

function M.format_current_statement()
    local buf = api.nvim_get_current_buf()
    local cursor = api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]

    local parser = ts.get_parser(buf, "sql")
    local tree = parser:parse()[1]
    local root = tree:root()

    local node = root:named_descendant_for_range(row, col, row, col)
    while node and node:type() ~= "statement" do
        node = node:parent()
        if not node then break end
    end

    if not node then
        vim.notify("No Tree-sitter parser found.", vim.log.levels.ERROR)
        return
    end

    local formatted = format_node(node, buf, 0)

    -- Final Cleanup
    formatted = formatted:gsub(" %.", ".")
    formatted = formatted:gsub("%. ", ".")
    formatted = formatted:gsub("%( %)", "()")
    formatted = formatted:gsub(" %( ", "(")
    formatted = formatted:gsub(" ,", ",")
    -- Restore indentation broken by double space fix
    formatted = formatted:gsub("\n ", "\n" .. INDENT_STR)

    local s_row, s_col, e_row, e_col = node:range()
    local lines = vim.split(formatted, "\n")
    api.nvim_buf_set_text(buf, s_row, s_col, e_row, e_col, lines)
end

--- Deletes the first ancestor node matching the given type
-- @param target_node_type string: The type of node to search for (e.g., "where", "join")
function M.delete_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local s_row, s_col, e_row, e_col = select_node(target_node_type, buf)

    if s_row and s_col and e_row and e_col then
        api.nvim_buf_set_text(buf, s_row, s_col, e_row, e_col, {})
    end
end

--- Comments the first ancestor node matching the given type
-- @param target_node_type string: The type of node to search for (e.g. "select", "where_clause")
function M.comment_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local left, right = "/*", "*/"

    local s_row, s_col, e_row, e_col = select_node(target_node_type, buf)

    if s_row and s_col and e_row and e_col then
        api.nvim_buf_set_text(buf, e_row, e_col, e_row, e_col, { right })
        api.nvim_buf_set_text(buf, s_row, s_col, s_row, s_col, { left })
    end
end

function M.uncomment_node()
    local buf = api.nvim_get_current_buf()
    local node = ts.get_node({ bufnr = buf })
    if not node then
        vim.notify("No Tree-sitter parser found.", vim.log.levels.ERROR)
        return
    end

    local curr = node
    local type = curr:type()

    -- 1. Handle Block Comments (marginalia) -> Remove /* */
    if type == "marginalia" then
        local text = ts.get_node_text(curr, buf)
        local content = vim.split(text:gsub("^/%*%s?", ""):gsub("%s?%*/$", ""), "\n")

        local sr, sc, er, ec = curr:range()
        api.nvim_buf_set_text(buf, sr, sc, er, ec, content)
        return
    end

    -- 2. Handle Line Comments (comment) -> Remove --
    if type == "comment" then
        local start_node = curr

        local prev = start_node:prev_sibling()
        while prev and prev:type() == "comment" do
            start_node = prev
            prev = start_node:prev_sibling()
        end

        local end_node = curr
        local next_node = end_node:next_sibling()
        while next_node and next_node:type() == "comment" do
            end_node = next_node
            next_node = end_node:next_sibling()
        end

        local sr, sc, _, _ = start_node:range()
        local _, _, er, ec = end_node:range()

        local lines = api.nvim_buf_get_text(buf, sr, sc, er, ec, {})

        for i, line in ipairs(lines) do
            lines[i] = line:gsub("^(%s*)%-%-%s?", "%1")
        end

        api.nvim_buf_set_text(buf, sr, sc, er, ec, lines)
    end
end

return M
