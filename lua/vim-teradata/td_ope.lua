local util = require('vim-teradata.util')
local M = {}
local api = vim.api
local ts = vim.treesitter

-- Configuration & Constants
local INDENT_STR = "  "
local LOG_LEVELS = vim.log.levels

-- Node Types and Keywords (Avoid Magic Strings)
local NODE = {
    TERM = "term",
    STATEMENT = "statement",
    IDENTIFIER = "identifier",
    SELECT = "select",
    UPDATE = "update",
    INSERT = "insert",
    FROM = "from",
    WHERE = "where",
    WHEN = "when_clause",
    GROUP_BY = "group_by",
    ORDER_BY = "order_by",
    HAVING = "having",
    JOIN = "join",
    CASE = "case",
    COLUMN_DEFS = "column_definitions",
    COL_DEF = "column_definition",
    COLUMN = "column",
    CONSTRAINTS = "constraints",
    CONSTRAINT = "constraint",
    CREATE_TABLE = "create_table",
    LIST = "list",
    LOCK = "lock_clause",
    SUBQUERY = "subquery",
    BINARY_EXPR = "binary_expression",
    SELECT_EXPR = "select_expression",
    TEMP_MODIFIER = "temporal_modifier",
    ASSIGNMENT = "assignment",
    RELATION = "relation",
    OBJECT_REF = "object_reference",
    FIELD = "field",
    INVOCATION = "invocation",
    PAR_EXPR = "parenthesized_expression",
    LITERAL = "literal",
    COMMENT = "comment",
    MARGINALIA = "marginalia",
}

local MAJOR_CLAUSES = {
    [NODE.FROM] = true,
    [NODE.WHERE] = true,
    [NODE.GROUP_BY] = true,
    [NODE.ORDER_BY] = true,
    [NODE.HAVING] = true,
    [NODE.SELECT] = true,
    [NODE.UPDATE] = true,
    [NODE.TEMP_MODIFIER] = true,
    [NODE.LOCK] = true,
}

local CREATE_TABLE_SECTIONS = {
    [NODE.COLUMN_DEFS] = true,
    ["primary_index_clause"] = true,
    ["index_definition"] = true,
    ["partition_by"] = true,
    ["partition_by_clause"] = true,
}

-- Forward declaration
local format_node

-- Helper: Check if parser is available
local function ensure_parser(buf)
    local ok, parser = pcall(ts.get_parser, buf, "sql")
    if not ok or not parser then
        vim.notify("Tree-sitter parser for SQL not found.", LOG_LEVELS.ERROR)
        return nil
    end
    return parser
end




-- Detects whether a statement is a MERGE statement
local function is_merge_statement(node)
    if not node or node:type() ~= NODE.STATEMENT then return false end
    for child in node:iter_children() do
        if child:type() == "keyword_merge" then
            return true
        end
    end
    return false
end

--- Selects a node and adjusts range to include delimiters (commas/semicolons)
local function get_node_range_with_delimiters(target_node_type, buf)
    local current_node = ts.get_node({ bufnr = buf })
    if not current_node then return end

    local node = util.find_node_by_type(current_node, target_node_type)
    if not node then
        vim.notify("Node '" .. target_node_type .. "' not found.", LOG_LEVELS.WARN)
        return
    end

    local s_row, s_col, e_row, e_col = node:range()

    if target_node_type == NODE.TERM then
        local prev = node:prev_sibling()
        local next = node:next_sibling()

        -- Check previous sibling for comma
        if prev and prev:type() == "," then
            local cs_row, cs_col, _, _ = prev:range()
            s_row = cs_row
            s_col = cs_col
            -- Check next sibling for comma if previous didn't match
        elseif next and next:type() == "," then
            local _, _, ce_row, ce_col = next:range()
            e_row = ce_row
            e_col = ce_col
        end
    elseif target_node_type == NODE.BINARY_EXPR then
        local prev = node:prev_sibling()
        local next = node:next_sibling()

        -- Check previous sibling for and/or
        if prev and (prev:type() == "keyword_and" or prev:type() == "keyword_or") then
            local cs_row, cs_col, _, _ = prev:range()
            s_row = cs_row
            s_col = cs_col
            -- Check next sibling for and/or if previous didn't match
        elseif next and (next:type() == "keyword_and" or next:type() == "keyword_or") then
            local _, _, ce_row, ce_col = next:range()
            e_row = ce_row
            e_col = ce_col
        end


        -- Edge case: only one binary_expression in WHERE
        local parent = node:parent()
        if parent and parent:type() == "where" then
            local binary_count = 0
            for child in parent:iter_children() do
                if child:type() == "binary_expression" then
                    binary_count = binary_count + 1
                end
            end

            if binary_count == 1 then
                local ws_row, ws_col, we_row, we_col = parent:range()
                s_row = ws_row
                s_col = ws_col
                e_row = we_row
                e_col = we_col
            end
        end
    elseif target_node_type == NODE.STATEMENT then
        local next = node:next_sibling()
        if next and next:type() == ";" then
            local _, _, se_row, se_col = next:range()
            e_row = se_row
            e_col = se_col
        end
    end

    return s_row, s_col, e_row, e_col
end


--- Extract text and apply casing rules
local function get_formatted_text(node, buf)
    local text = ts.get_node_text(node, buf)
    local type = node:type()
    local parent = node:parent()

    -- Rule 1: Keywords -> Lowercase
    if type:match("^keyword_") then
        return string.lower(text)
    end

    -- Rule 2: Identifiers -> Uppercase (with exceptions)
    if type == NODE.IDENTIFIER and parent then
        local ptype = parent:type()

        -- Exception A: Aliases (e.g., "AS z")
        local alias_nodes = parent:field("alias")
        if #alias_nodes > 0 then
            -- If parent is NOT a term, it's a regular alias -> lowercase
            if ptype ~= NODE.TERM then
                return string.lower(text)
            end
            return string.upper(text)
        end

        -- Exception B: Function Names (trim, cast, etc.)
        if ptype == NODE.OBJECT_REF then
            local grandparent = parent:parent()
            if grandparent then
                local gtype = grandparent:type()
                if gtype == NODE.FIELD then
                    return string.lower(text)
                end
                if gtype == NODE.INVOCATION then
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


-- Specialized Formatters
local function format_select_expression(node, buf, indent_lvl, current_indent)
    local parts = {}
    local is_first_field = true
    local children = {}

    for child in node:iter_children() do
        table.insert(children, child)
    end

    for i, child in ipairs(children) do
        local txt = format_node(child, buf, indent_lvl)
        local c_type = child:type()
        local trailing_newline = (i == #children) and "\n" or ""

        if c_type == NODE.TERM or c_type == NODE.FIELD or c_type == "all_fields" or c_type == NODE.IDENTIFIER then
            if is_first_field then
                table.insert(parts, current_indent .. txt)
                is_first_field = false
            else
                table.insert(parts, "\n" .. current_indent .. ", " .. txt .. trailing_newline)
            end
        elseif c_type == "," then
            -- Handled manually above
        else
            table.insert(parts, txt)
        end
    end
    return table.concat(parts, "")
end

local function format_update(node, buf, indent_lvl, current_indent)
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
        elseif c_type == NODE.WHERE then
            inside_set = false
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl, NODE.WHERE))
        elseif c_type == NODE.ASSIGNMENT then
            table.insert(parts, " " .. txt)
        elseif c_type == "," then
            if inside_set then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. ",")
            else
                table.insert(parts, ",")
            end
        elseif c_type == NODE.RELATION then
            local prev = child:prev_sibling()
            if prev and prev:type() == "keyword_from" then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
            elseif prev and prev:type() == "," then
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
            else
                table.insert(parts, " " .. txt)
            end
        else
            -- Check previous part for spacing
            local prev_part = parts[#parts]
            if prev_part and not prev_part:match("%s$") and not prev_part:match("\n$") and c_type ~= "," then
                table.insert(parts, " ")
            end
            table.insert(parts, txt)
        end
    end
    return table.concat(parts, "")
end


-- Formats a single WHEN clause (WHEN MATCHED / WHEN NOT MATCHED ...)
local function format_merge_when(node, buf, indent_lvl, current_indent)
    local parts = {}
    local indent_then = current_indent .. INDENT_STR
    local indent_deeper = indent_then .. INDENT_STR
    local column_list_text = ""

    -- Accumulate "WHEN ..." header until keyword_then
    local seen_then = false
    local inside_set = false

    for child in node:iter_children() do
        local c_type = child:type()

        if not seen_then then
            if c_type == "keyword_then" then
                seen_then = true
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type:match("^keyword_") then
                -- WHEN / NOT / MATCHED: append with spaces
                local txt = format_node(child, buf, indent_lvl)
                if #parts == 0 then
                    -- start on the same line as base_indent already emitted by caller
                    table.insert(parts, txt)
                else
                    table.insert(parts, " " .. txt)
                end
            else
                -- Any predicate after WHEN (rare), append with space
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            end
        else
            -- After THEN: handle UPDATE/INSERT blocks
            if c_type == "keyword_update" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_set" then
                inside_set = true
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type == "," then
                if inside_set then
                    table.insert(parts, "\n" .. indent_then .. ",")
                else
                    table.insert(parts, ",")
                end
            elseif c_type == NODE.ASSIGNMENT then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_insert" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == NODE.LIST then
                -- Decide whether this LIST is a column list (after INSERT) or a VALUES list
                local col_parts = {}
                local is_first_col = true
                for col_child in child:iter_children() do
                    if col_child:type() == NODE.COLUMN then
                        local identifier_node = col_child:named_child(0)
                        if identifier_node then
                            local identifier_txt = format_node(identifier_node, buf, indent_lvl)
                            if is_first_col then
                                table.insert(col_parts, indent_deeper .. identifier_txt)
                                is_first_col = false
                            else
                                table.insert(col_parts, "\n" .. indent_deeper .. ", " .. identifier_txt)
                            end
                        end
                    elseif col_child:type() == NODE.FIELD then
                        local identifier_txt = format_node(col_child, buf, indent_lvl)
                        if is_first_col then
                            table.insert(col_parts, indent_deeper .. identifier_txt)
                            is_first_col = false
                        else
                            table.insert(col_parts, "\n" .. indent_deeper .. ", " .. identifier_txt)
                        end
                    end
                end
                column_list_text = "\n" ..
                    current_indent .. "(\n" .. table.concat(col_parts, "") .. "\n" .. current_indent .. ")"
                table.insert(parts, column_list_text)
            elseif c_type == "keyword_values" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            else
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            end
        end
    end

    return table.concat(parts, "")
end

-- Formats the whole MERGE statement (detected inside a 'statement' node)
local function format_merge(node, buf, indent_lvl, current_indent)
    local parts = {}
    local kw_indent = current_indent
    local indent_1 = kw_indent .. INDENT_STR

    for child in node:iter_children() do
        local c_type = child:type()
        local txt = format_node(child, buf, indent_lvl)

        if c_type == "keyword_merge" or c_type == "keyword_into" then
            -- MERGE INTO ...
            table.insert(parts, txt)
            table.insert(parts, " ")
        elseif c_type == NODE.OBJECT_REF or c_type == NODE.IDENTIFIER then
            -- target table & alias
            table.insert(parts, txt)
            table.insert(parts, " ")
        elseif c_type == "keyword_using" then
            -- USING ... (start on new line)
            table.insert(parts, "\n" .. kw_indent .. txt .. " ")
        elseif c_type == NODE.RELATION or c_type == NODE.OBJECT_REF or c_type == NODE.SUBQUERY then
            -- relation after USING
            table.insert(parts, txt)
            table.insert(parts, " ")
        elseif c_type == "keyword_on" then
            -- ON clause header on new line
            table.insert(parts, "\n" .. indent_1 .. txt)
        elseif c_type == NODE.PAR_EXPR then
            -- predicate in parentheses appended after ON with a space
            table.insert(parts, " " .. txt)
        elseif c_type == NODE.WHEN then
            -- Each WHEN clause starts on a new line at indent_1
            table.insert(parts, "\n" .. indent_1 .. format_merge_when(child, buf, indent_lvl, indent_1))
        else
            -- Pass-through (punctuation like ';', comments, or other nodes)
            table.insert(parts, txt)
        end
    end

    return table.concat(parts, "")
end


local function format_column_definitions(node, buf, indent_lvl, current_indent)
    local parts = {}
    local is_first_col = true
    local col_indent = string.rep(INDENT_STR, indent_lvl + 1)
    local max_name_len = 0

    -- Helper to detect if a definition is actually a PERIOD FOR clause
    local function is_period_clause(n)
        for child in n:iter_children() do
            if child:type() == "keyword_period" then return true end
        end
        return false
    end

    -- Pass 1: Calculate max length (Skip PERIOD FOR clauses)
    for child in node:iter_children() do
        if child:type() == NODE.COL_DEF and not is_period_clause(child) then
            local name_node = child:field("name")
            if #name_node == 0 then
                local first_child = child:child(0)
                if first_child then
                    for grandchild in first_child:iter_children() do
                        if grandchild:type() == NODE.IDENTIFIER then
                            name_node = { grandchild }
                            break
                        end
                    end
                end
            end

            if #name_node > 0 then
                local name_txt = get_formatted_text(name_node[1], buf)
                if #name_txt > max_name_len then
                    max_name_len = #name_txt
                end
            end
        end
    end

    -- Pass 2: Formatting
    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "(" then
            table.insert(parts, "(\n")
        elseif c_type == ")" then
            table.insert(parts, "\n" .. current_indent .. ")")
        elseif c_type == NODE.COL_DEF then
            if is_period_clause(child) then
                local period_parts = {}
                for grandchild in child:iter_children() do
                    table.insert(period_parts, format_node(grandchild, buf, indent_lvl + 1))
                end
                local line = table.concat(period_parts, " ")

                if is_first_col then
                    table.insert(parts, col_indent .. " " .. line)
                    is_first_col = false
                else
                    table.insert(parts, "\n" .. col_indent .. ", " .. line)
                end
            else
                -- STANDARD COLUMN ALIGNMENT LOGIC
                local col_parts = {}
                local name_txt = ""
                local last_r, last_c = -1, -1

                for grandchild in child:iter_children() do
                    local gc_txt = format_node(grandchild, buf, indent_lvl)
                    local gc_type = grandchild:type()
                    local _, _, er, ec = grandchild:range()
                    last_r, last_c = er, ec

                    if gc_type == NODE.IDENTIFIER and name_txt == "" then
                        name_txt = gc_txt
                    else
                        table.insert(col_parts, gc_txt)
                    end
                end

                -- Capture missing text
                local _, _, parent_er, parent_ec = child:range()
                if last_r ~= -1 and (parent_ec > last_c or parent_er > last_r) then
                    local missing_text = api.nvim_buf_get_text(buf, last_r, last_c, parent_er, parent_ec, {})
                    local joined = table.concat(missing_text, " ")
                    if joined:match("%S") then
                        table.insert(col_parts, joined)
                    end
                end

                local padding = ""
                if max_name_len > 0 then
                    padding = string.rep(" ", max_name_len - #name_txt)
                end

                local final_line = name_txt .. padding .. " " .. table.concat(col_parts, " ")

                if is_first_col then
                    table.insert(parts, col_indent .. " " .. final_line)
                    is_first_col = false
                else
                    table.insert(parts, "\n" .. col_indent .. ", " .. final_line)
                end
            end
        elseif c_type == NODE.CONSTRAINTS then
            for constraint_node in child:iter_children() do
                if constraint_node:type() == NODE.CONSTRAINT then
                    local constraint_text = format_node(constraint_node, buf, indent_lvl + 1)
                    constraint_text = constraint_text:gsub("^%s*", col_indent .. ", ")
                    constraint_text = constraint_text:gsub("\n%s*", "\n" .. col_indent .. "  ")
                    table.insert(parts, "\n" .. constraint_text)
                end
            end
        elseif c_type:match("comment") then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        end
    end
    return table.concat(parts, "")
end

local function format_insert(node, buf, indent_lvl, current_indent)
    local parts = {}
    local column_list_text = ""

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_insert" or c_type == "keyword_into" or c_type == NODE.OBJECT_REF then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.LIST then
            local col_parts = {}
            local col_indent = string.rep(INDENT_STR, indent_lvl + 1)
            local is_first_col = true
            local is_first_value = true

            for col_child in child:iter_children() do
                if col_child:type() == NODE.COLUMN then
                    local identifier_node = col_child:named_child(0)
                    if identifier_node then
                        local identifier_txt = format_node(identifier_node, buf, indent_lvl)
                        if is_first_col then
                            table.insert(col_parts, col_indent .. identifier_txt)
                            is_first_col = false
                        else
                            table.insert(col_parts, "\n" .. col_indent .. ", " .. identifier_txt)
                        end
                    end
                elseif col_child:type() == NODE.LITERAL then
                    local literal_txt = ts.get_node_text(col_child, buf)
                    if is_first_value then
                        table.insert(col_parts, col_indent .. literal_txt)
                        is_first_value = false
                    else
                        table.insert(col_parts, "\n" .. col_indent .. ", " .. literal_txt)
                    end
                end
            end
            column_list_text = "\n(\n" .. table.concat(col_parts, "") .. "\n" .. current_indent .. ")"
            table.insert(parts, column_list_text)
        else
            local rest_txt = format_node(child, buf, indent_lvl)
            if rest_txt ~= "" and rest_txt ~= "," then
                table.insert(parts, "\n" .. current_indent .. rest_txt)
            end
        end
    end

    return table.concat(parts, "")
end

--- Main Recursive Formatter
format_node = function(node, buf, indent_lvl, context)
    local type = node:type()
    local current_indent = string.rep(INDENT_STR, indent_lvl)

    -- Base case: Leaf nodes
    if node:child_count() == 0 or type == NODE.LITERAL then
        return get_formatted_text(node, buf)
    end

    -- Handlers for specific node types
    if type == NODE.STATEMENT or type == NODE.SELECT then
        if type == NODE.STATEMENT and is_merge_statement(node) then
            return format_merge(node, buf, indent_lvl, current_indent)
        end

        local parts = {}
        local is_first = true

        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)

            if MAJOR_CLAUSES[c_type] or c_type == NODE.SELECT then
                if not is_first then
                    table.insert(parts, "\n" .. current_indent .. txt)
                else
                    table.insert(parts, txt)
                end
            elseif c_type == NODE.SELECT_EXPR then
                -- Add newline unless it's the very first element
                table.insert(parts, (is_first and "" or "\n") .. txt)
            else
                -- Small keywords or punctuation
                if not is_first then
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

    if type == NODE.SELECT_EXPR then
        return format_select_expression(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.UPDATE then
        return format_update(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.FROM then
        local parts = {}
        for child in node:iter_children() do
            if child:type() == "keyword_from" then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    if type == NODE.WHERE then
        local parts = {}
        for child in node:iter_children() do
            if child:type() == "keyword_where" then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, " " .. format_node(child, buf, indent_lvl, NODE.WHERE))
            end
        end
        return table.concat(parts, "")
    end

    if type == NODE.BINARY_EXPR then
        local left = node:field("left")
        local right = node:field("right")
        local op = node:field("operator")

        if #op > 0 and (op[1]:type() == "keyword_and" or op[1]:type() == "keyword_or") then
            local l_txt = format_node(left[1], buf, indent_lvl, context)
            local op_txt = get_formatted_text(op[1], buf)
            local r_txt = format_node(right[1], buf, indent_lvl, context)
            return l_txt .. "\n" .. current_indent .. op_txt .. " " .. r_txt
        end

        local parts = {}
        for child in node:iter_children() do
            table.insert(parts, format_node(child, buf, indent_lvl, context))
        end
        return table.concat(parts, " ")
    end

    if type == NODE.JOIN then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()
            if c_type == NODE.RELATION then
                table.insert(parts, "\n" .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_on" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == NODE.BINARY_EXPR and c_type ~= "keyword_full" and c_type ~= "keyword_join" then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            else
                if #parts > 0 then table.insert(parts, " ") end
                table.insert(parts, format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    if type == NODE.SUBQUERY or type == NODE.RELATION then
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
                    table.insert(parts, format_node(child, buf, indent_lvl + 1))
                end
            end
            return table.concat(parts, "")
        end
    end

    if type == NODE.CASE then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl + 1)
            local kw_indent = "\n" .. current_indent .. INDENT_STR

            if c_type == "keyword_case" then
                table.insert(parts, get_formatted_text(child, buf))
            elseif c_type == "keyword_when" or c_type == "keyword_end" or c_type == "keyword_else" then
                table.insert(parts, kw_indent .. txt)
            else
                table.insert(parts, " " .. txt)
            end
        end
        return table.concat(parts, "")
    end

    if type == NODE.COLUMN_DEFS then
        return format_column_definitions(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.CREATE_TABLE then
        local parts = {}
        local is_first = true
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)
            if CREATE_TABLE_SECTIONS[c_type] then
                table.insert(parts, "\n" .. current_indent .. txt)
            else
                if not is_first and parts[#parts] and not parts[#parts]:match("\n%s*$") then
                    table.insert(parts, " ")
                end
                table.insert(parts, txt)
            end
            is_first = false
        end
        return table.concat(parts, "")
    end

    if type == NODE.INSERT then
        return format_insert(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.TEMP_MODIFIER then
        local parts = {}
        for child in node:iter_children() do
            table.insert(parts, get_formatted_text(child, buf))
        end
        return table.concat(parts, " ") .. "\n" .. string.rep(INDENT_STR, indent_lvl)
    end

    if type == NODE.LOCK then
        local parts = {}
        local is_first_lock_keyword = true

        for child in node:iter_children() do
            local c_type = child:type()
            local txt = get_formatted_text(child, buf)

            if c_type == "keyword_lock" or c_type == "keyword_locking" then
                if is_first_lock_keyword then
                    table.insert(parts, txt)
                    is_first_lock_keyword = false
                else
                    table.insert(parts, "\n" .. current_indent .. txt)
                end
            else
                table.insert(parts, " " .. txt)
            end
        end

        return table.concat(parts, "")
    end

    if type == NODE.CONSTRAINT then
        local parts = {}
        local indent = string.rep(INDENT_STR, indent_lvl + 1)

        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl + 1)

            if c_type == NODE.BINARY_EXPR then
                local expr = format_node(child, buf, indent_lvl + 2)
                expr = expr:gsub("\n", "\n" .. indent .. "   ")
                table.insert(parts, expr)
            else
                table.insert(parts, " " .. txt)
            end
        end

        local result = table.concat(parts, "")
        return result
    end

    if type == "partition_by_clause" then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)

            if c_type == "keyword_partition" then
                table.insert(parts, txt)
            elseif c_type == "keyword_by" then
                table.insert(parts, " " .. txt)
            else
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. format_node(child, buf, indent_lvl + 1))
            end
        end
        return table.concat(parts, "")
    end

    -- Generic Fallback
    local parts = {}
    for child in node:iter_children() do
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
            if #parts > 0 and prev ~= "(" and prev:sub(-1) ~= "\n" then
                table.insert(parts, " ")
            end
            table.insert(parts, txt)
        end
    end
    return table.concat(parts, "")
end

--- Formats the SQL statement under the cursor
function M.format_current_statement()
    local buf = api.nvim_get_current_buf()
    local cursor = api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]

    if not ensure_parser(buf) then return end

    local root = ts.get_parser(buf, "sql"):parse()[1]:root()
    local node = root:named_descendant_for_range(row, col, row, col)

    -- Traverse up to find the statement
    node = util.find_node_by_type(node, NODE.STATEMENT)

    if not node then
        vim.notify("Cursor is not inside a valid SQL statement.", LOG_LEVELS.WARN)
        return
    end

    local formatted = format_node(node, buf, 0)

    -- Post-processing sanitization (cleaning up artifact spaces from recursion)
    -- Optimized replacements using patterns
    formatted = formatted:gsub(" %.", ".")
        :gsub("%. ", ".")
        :gsub("%( %)", "()")
        :gsub(" %( ", "(")
        :gsub(" ,", ",")
        :gsub("\n ", "\n" .. INDENT_STR)

    local s_row, s_col, e_row, e_col = node:range()
    local lines = vim.split(formatted, "\n")

    -- Use pcall for API safety
    local ok, err = pcall(api.nvim_buf_set_text, buf, s_row, s_col, e_row, e_col, lines)
    if not ok then
        vim.notify("Failed to apply formatting: " .. tostring(err), LOG_LEVELS.ERROR)
    end
end

--- copy the nearest ancestor node matching the given type
-- @param target_node_type string
function M.copy_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local s_row, s_col, e_row, e_col = get_node_range_with_delimiters(target_node_type, buf)
    if s_row and s_col and e_row and e_col then
        local lines = vim.api.nvim_buf_get_text(buf, s_row, s_col, e_row, e_col, {})
        local text = table.concat(lines, '\n')
        vim.fn.setreg('"', text)
    end
end

--- Deletes the nearest ancestor node matching the given type
-- @param target_node_type string
function M.delete_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local s_row, s_col, e_row, e_col = get_node_range_with_delimiters(target_node_type, buf)

    if s_row and s_col and e_row and e_col then
        api.nvim_buf_set_text(buf, s_row, s_col, e_row, e_col, {})
    end
end

--- Comments the nearest ancestor node matching the given type
-- @param target_node_type string
function M.comment_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local left, right = "/*", "*/"

    local s_row, s_col, e_row, e_col = get_node_range_with_delimiters(target_node_type, buf)

    if s_row and s_col and e_row and e_col then
        -- Apply right side first to avoid index shifting if on same line (though ranges handles this)
        api.nvim_buf_set_text(buf, e_row, e_col, e_row, e_col, { right })
        api.nvim_buf_set_text(buf, s_row, s_col, s_row, s_col, { left })
    end
end

--- Uncomments the current node (handles block and line comments)
function M.uncomment_node()
    local buf = api.nvim_get_current_buf()
    local node = ts.get_node({ bufnr = buf })
    if not node then
        vim.notify("No node found under cursor.", LOG_LEVELS.WARN)
        return
    end

    local type = node:type()

    -- 1. Handle Block Comments (marginalia)
    if type == NODE.MARGINALIA then
        local text = ts.get_node_text(node, buf)
        -- Sanitize regex to prevent malformed pattern errors
        local content_text = text:gsub("^/%*%s?", ""):gsub("%s?%*/$", "")
        local content = vim.split(content_text, "\n")

        local sr, sc, er, ec = node:range()
        api.nvim_buf_set_text(buf, sr, sc, er, ec, content)
        return
    end

    -- 2. Handle Line Comments (comment)
    if type == NODE.COMMENT then
        local start_node = node
        local end_node = node

        -- Expand selection to contiguous comment block
        local prev = start_node:prev_sibling()
        while prev and prev:type() == NODE.COMMENT do
            start_node = prev
            prev = start_node:prev_sibling()
        end

        local next_node = end_node:next_sibling()
        while next_node and next_node:type() == NODE.COMMENT do
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

--- Moves cursor to the next node of the given type
-- @param target_node_type string (e.g. "statement")
function M.jump_to_next(target_node_type)
    local node = util.find_next_node_by_type(target_node_type)
    if node then
        local r, c, _, _ = node:range()
        api.nvim_win_set_cursor(0, { r + 1, c })
    else
        vim.notify("No next " .. target_node_type .. " found.", LOG_LEVELS.INFO)
    end
end

--- Moves cursor to the previous node of the given type
-- @param target_node_type string (e.g. "statement")
function M.jump_to_prev(target_node_type)
    local node = util.find_prev_node_by_type(target_node_type)
    if node then
        local r, c, _, _ = node:range()
        api.nvim_win_set_cursor(0, { r + 1, c })
    else
        vim.notify("No previous " .. target_node_type .. " found.", LOG_LEVELS.INFO)
    end
end

return M
