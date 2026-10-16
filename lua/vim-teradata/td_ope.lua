local tsu = require('vim-teradata.ts-util')
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
    DELETE = "delete",
    FROM = "from",
    WHERE = "where",
    WHEN = "when_clause",
    GROUP_BY = "group_by",
    ORDER_BY = "order_by",
    HAVING = "having",
    QUALIFY = "qualify",
    SAMPLE = "sample_clause",
    EXPAND_ON = "expand_on_clause",
    WINDOW = "window_clause",
    PIVOT = "pivot",
    JOIN = "join",
    CROSS_JOIN = "cross_join",
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
    SET_OPERATION = "set_operation",
    CTE = "cte",
    CREATE_MACRO = "create_macro",
    CREATE_VIEW = "create_view",
    CREATE_QUERY = "create_query",
    USING_MODIFIER = "using_request_modifier",
    LOGGING_ERRORS = "logging_errors_clause",
    ISOLATED_LOADING = "isolated_loading_clause",
    CREATE_PROCEDURE = "create_procedure",
    COMPOUND_STMT = "compound_statement",
    PROC_IF = "procedure_if_statement",
    PROC_ELSEIF = "procedure_elseif_statement",
    PROC_ELSE = "procedure_else_statement",
    PROC_FOR = "procedure_for_statement",
    DECLARE_STMT = "declare_statement",
    CREATE_FUNCTION = "create_function",
    FUNCTION_BODY = "function_body",
    CREATE_JOIN_INDEX = "create_join_index",
    CREATE_HASH_INDEX = "create_hash_index",
    CREATE_DATABASE = "create_database",
    MODIFY_DATABASE = "modify_database",
    ALTER_TABLE = "alter_table",
    INSERT_EXPLAIN = "insert_explain",
}

local MAJOR_CLAUSES = {
    [NODE.FROM] = true,
    [NODE.WHERE] = true,
    [NODE.GROUP_BY] = true,
    [NODE.ORDER_BY] = true,
    [NODE.HAVING] = true,
    [NODE.SELECT] = true,
    [NODE.UPDATE] = true,
    [NODE.INSERT] = true,
    [NODE.DELETE] = true,
    [NODE.SET_OPERATION] = true,
    [NODE.QUALIFY] = true,
    [NODE.SAMPLE] = true,
    [NODE.EXPAND_ON] = true,
    [NODE.WINDOW] = true,
    [NODE.PIVOT] = true,
    [NODE.CROSS_JOIN] = true,
    [NODE.TEMP_MODIFIER] = true,
    [NODE.LOCK] = true,
    [NODE.USING_MODIFIER] = true,
    [NODE.LOGGING_ERRORS] = true,
    [NODE.ISOLATED_LOADING] = true,
}

local CREATE_TABLE_SECTIONS = {
    [NODE.COLUMN_DEFS] = true,
    [NODE.CREATE_QUERY] = true,
    ["primary_index_clause"] = true,
    ["index_clause"] = true,
    ["index_definition"] = true,
    ["partition_by"] = true,
    ["partition_by_clause"] = true,
    ["with_data_clause"] = true,
    ["storage_location"] = true,
    ["row_format"] = true,
    ["table_sort"] = true,
    ["table_partition"] = true,
    ["storage_parameters"] = true,
}

-- Forward declaration
local format_node





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

        if c_type == NODE.TERM or c_type == NODE.FIELD or c_type == "all_fields" or c_type == NODE.IDENTIFIER then
            if is_first_field then
                table.insert(parts, current_indent .. txt)
                is_first_field = false
            else
                table.insert(parts, "\n" .. current_indent .. ", " .. txt)
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

        if c_type == "keyword_update" or c_type == "keyword_upd" then
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
        elseif c_type == NODE.JOIN or c_type == NODE.CROSS_JOIN then
            table.insert(parts, "\n" .. current_indent .. txt)
        elseif c_type == "keyword_else" then
            table.insert(parts, "\n" .. current_indent .. txt)
        elseif c_type == NODE.INSERT then
            table.insert(parts, "\n" .. current_indent .. INDENT_STR .. txt)
        elseif c_type == NODE.ISOLATED_LOADING then
            table.insert(parts, "\n" .. current_indent .. txt)
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
            -- After THEN: handle UPDATE/INSERT/DELETE blocks
            if c_type == "keyword_update" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_set" then
                inside_set = true
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_delete" or c_type == "keyword_del" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
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
                    if col_child:named() then
                        local item_txt
                        if col_child:type() == NODE.COLUMN then
                            local id_node = col_child:named_child(0)
                            item_txt = id_node and format_node(id_node, buf, indent_lvl) or format_node(col_child, buf, indent_lvl)
                        else
                            item_txt = format_node(col_child, buf, indent_lvl)
                        end
                        if is_first_col then
                            table.insert(col_parts, indent_deeper .. item_txt)
                            is_first_col = false
                        else
                            table.insert(col_parts, "\n" .. indent_deeper .. ", " .. item_txt)
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
        elseif c_type == NODE.PAR_EXPR or c_type == NODE.BINARY_EXPR or c_type == NODE.RELATION or c_type == NODE.TERM then
            -- predicate appended after ON with a space
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
                local prev_er, prev_ec
                do
                    local sr, sc, _, _ = child:range(); prev_er, prev_ec = sr, sc
                end

                for grandchild in child:iter_children() do
                    local gc_type = grandchild:type()
                    local gc_sr, gc_sc, gc_er, gc_ec = grandchild:range()

                    -- Capture gap before this grandchild (e.g. 'YYYY-MM-DD' after keyword_format)
                    if gc_sr > prev_er or (gc_sr == prev_er and gc_sc > prev_ec) then
                        local gap = api.nvim_buf_get_text(buf, prev_er, prev_ec, gc_sr, gc_sc, {})
                        local joined = table.concat(gap, " "):match("^%s*(.-)%s*$")
                        if joined ~= "" then
                            table.insert(col_parts, joined)
                        end
                    end

                    local gc_txt = format_node(grandchild, buf, indent_lvl)
                    if (gc_type == NODE.IDENTIFIER or gc_type == NODE.LITERAL) and name_txt == "" then
                        name_txt = gc_txt
                    else
                        table.insert(col_parts, gc_txt)
                    end

                    prev_er, prev_ec = gc_er, gc_ec
                end

                -- Capture any trailing gap after the last node (e.g. 'YYYYMMDD' with no NOT NULL)
                local _, _, parent_er, parent_ec = child:range()
                if prev_er ~= nil and (parent_er > prev_er or (parent_er == prev_er and parent_ec > prev_ec)) then
                    local gap = api.nvim_buf_get_text(buf, prev_er, prev_ec, parent_er, parent_ec, {})
                    local joined = table.concat(gap, " "):match("^%s*(.-)%s*$")
                    if joined ~= "" then
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
        elseif c_type:match("comment") or c_type == NODE.MARGINALIA then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        end
    end
    return table.concat(parts, "")
end

local function format_insert(node, buf, indent_lvl, current_indent)
    local parts = {}
    local column_list_text = ""
    local is_first_header = true

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_insert" or c_type == "keyword_ins" or c_type == "keyword_into"
            or c_type == "keyword_replace" or c_type == "keyword_overwrite" or c_type == "keyword_ignore" then
            local txt = format_node(child, buf, indent_lvl)
            if is_first_header then
                table.insert(parts, txt)
                is_first_header = false
            else
                table.insert(parts, " " .. txt)
            end
        elseif c_type == NODE.OBJECT_REF or c_type == NODE.RELATION then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.LIST then
            local col_parts = {}
            local col_indent = string.rep(INDENT_STR, indent_lvl + 1)
            local is_first_item = true

            for col_child in child:iter_children() do
                if col_child:named() then
                    local item_txt
                    if col_child:type() == NODE.COLUMN then
                        local identifier_node = col_child:named_child(0)
                        item_txt = identifier_node and format_node(identifier_node, buf, indent_lvl) or format_node(col_child, buf, indent_lvl)
                    else
                        item_txt = format_node(col_child, buf, indent_lvl)
                    end
                    if is_first_item then
                        table.insert(col_parts, col_indent .. item_txt)
                        is_first_item = false
                    else
                        table.insert(col_parts, "\n" .. col_indent .. ", " .. item_txt)
                    end
                end
            end
            column_list_text = "\n" .. current_indent .. "(\n" .. table.concat(col_parts, "") .. "\n" .. current_indent .. ")"
            table.insert(parts, column_list_text)
        elseif c_type == "keyword_values" then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == "," then
            table.insert(parts, ",")
        elseif MAJOR_CLAUSES[c_type] or c_type == NODE.SELECT or c_type == NODE.SET_OPERATION or c_type == NODE.CTE or c_type == "keyword_with" then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        else
            if child:named() then
                local rest_txt = format_node(child, buf, indent_lvl)
                if rest_txt ~= "" then
                    table.insert(parts, "\n" .. current_indent .. rest_txt)
                end
            end
        end
    end

    return table.concat(parts, "")
end

--- Formats a set operation: UNION [ALL], INTERSECT [ALL], EXCEPT [ALL], MINUS [ALL]
local function format_set_operation(node, buf, indent_lvl, current_indent)
    local parts       = {}
    local pending_ops = {}
    local in_operator = false

    local function flush_ops()
        if #pending_ops > 0 then
            table.insert(parts, "\n" .. current_indent .. table.concat(pending_ops, " "))
            pending_ops = {}
        end
        in_operator = false
    end

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_union"
            or c_type == "keyword_intersect"
            or c_type == "keyword_except"
            or c_type == "keyword_minus" then
            in_operator = true
            table.insert(pending_ops, get_formatted_text(child, buf))
        elseif (c_type == "keyword_all" or c_type == "keyword_distinct") and in_operator then
            table.insert(pending_ops, get_formatted_text(child, buf))
        elseif MAJOR_CLAUSES[c_type] or c_type == NODE.SELECT then
            if c_type == NODE.SELECT then
                flush_ops()
                local txt = format_node(child, buf, indent_lvl)
                if #parts == 0 then
                    table.insert(parts, txt)
                else
                    table.insert(parts, "\n" .. current_indent .. txt)
                end
            else
                local txt = format_node(child, buf, indent_lvl)
                table.insert(parts, "\n" .. current_indent .. txt)
            end
        else
            flush_ops()
            local txt = format_node(child, buf, indent_lvl)
            if #parts > 0 then
                table.insert(parts, "\n" .. current_indent .. txt)
            else
                table.insert(parts, txt)
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats a WITH … AS (cte) … [SELECT/INSERT/UPDATE] statement
local function format_cte(node, buf, indent_lvl, current_indent)
    local parts = {}
    local is_first_cte = true

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_with" then
            table.insert(parts, get_formatted_text(child, buf))
        elseif c_type == NODE.CTE then
            local inner_indent = string.rep(INDENT_STR, indent_lvl + 1)

            -- 1. CTE name (first named child typed identifier, not an argument field)
            local name_node    = child:named_child(0)
            local cte_name     = name_node and get_formatted_text(name_node, buf) or ""

            -- 2. Argument list via the "argument" field
            local arg_nodes    = child:field("argument")
            local arg_str      = ""
            if #arg_nodes > 0 then
                local arg_names = {}
                for _, an in ipairs(arg_nodes) do
                    table.insert(arg_names, get_formatted_text(an, buf))
                end
                arg_str = "(" .. table.concat(arg_names, ", ") .. ")"
            end

            -- 3. Body: the inner statement (last named child of type statement)
            local body_node = nil
            for cte_child in child:iter_children() do
                if cte_child:type() == NODE.STATEMENT then
                    body_node = cte_child
                end
            end

            local body_str = ""
            if body_node then
                local body = format_node(body_node, buf, indent_lvl + 1)
                body_str = " (\n" .. inner_indent .. body .. "\n" .. current_indent .. ")"
            end

            local cte_text = cte_name .. arg_str .. " as" .. body_str

            if is_first_cte then
                table.insert(parts, " " .. cte_text)
                is_first_cte = false
            else
                table.insert(parts, "\n" .. current_indent .. ", " .. cte_text)
            end
        elseif c_type == "," then
            -- top-level comma between CTEs: already handled by is_first_cte logic, skip
        elseif MAJOR_CLAUSES[c_type] or c_type == NODE.SELECT then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.SELECT_EXPR then
            table.insert(parts, "\n" .. format_node(child, buf, indent_lvl))
        else
            if child:named() then
                local txt = format_node(child, buf, indent_lvl)
                if txt ~= "" then
                    table.insert(parts, " " .. txt)
                end
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats a CREATE MACRO statement
local function format_create_macro(node, buf, indent_lvl, current_indent)
    local parts        = {}
    local param_parts  = {}
    local body_stmts   = {}
    local seen_as      = false
    local param_indent = string.rep(INDENT_STR, indent_lvl + 1)
    local body_indent  = string.rep(INDENT_STR, indent_lvl + 1)

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_create" or c_type == "keyword_replace" then
            table.insert(parts, get_formatted_text(child, buf))
        elseif c_type == "keyword_macro" then
            table.insert(parts, " " .. get_formatted_text(child, buf))
        elseif c_type == NODE.OBJECT_REF then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.COL_DEF then
            table.insert(param_parts, format_node(child, buf, indent_lvl))
        elseif c_type == "keyword_as" then
            if #param_parts > 0 then
                table.insert(parts, " (\n")
                for i, p in ipairs(param_parts) do
                    if i == 1 then
                        table.insert(parts, param_indent .. " " .. p)
                    else
                        table.insert(parts, "\n" .. param_indent .. ", " .. p)
                    end
                end
                table.insert(parts, "\n" .. current_indent .. ")")
            end
            seen_as = true
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type == NODE.STATEMENT and seen_as then
            local body = format_node(child, buf, indent_lvl + 1)
            body = body:gsub("%s*;%s*$", "")
            table.insert(body_stmts, body)
        elseif c_type == "(" or c_type == ")" or c_type == "," or c_type == ";" then
            -- Skip punctuation reproduced manually
        else
            if child:named() then
                local txt = format_node(child, buf, indent_lvl)
                if txt ~= "" then
                    table.insert(parts, " " .. txt)
                end
            end
        end
    end

    if #body_stmts > 0 then
        local joined = table.concat(body_stmts, "\n" .. body_indent .. ";\n" .. body_indent)
        table.insert(parts, " (\n" .. body_indent .. joined .. "\n" .. current_indent .. ")")
    end

    return table.concat(parts, "")
end


--- Formats a CREATE [REPLACE] VIEW statement
local function format_create_view(node, buf, indent_lvl, current_indent)
    local parts   = {}
    local seen_as = false

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_create" or c_type == "keyword_replace"
            or c_type == "keyword_recursive" or c_type == "keyword_temp"
            or c_type == "keyword_temporary" or c_type == "keyword_view" then
            if #parts == 0 then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, " " .. get_formatted_text(child, buf))
            end
        elseif c_type == NODE.OBJECT_REF then
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        elseif c_type == "(" then
            table.insert(parts, " (")
        elseif c_type == "," then
            table.insert(parts, ", ")
        elseif c_type == ")" then
            table.insert(parts, ")")
        elseif c_type == NODE.IDENTIFIER then
            table.insert(parts, get_formatted_text(child, buf))
        elseif c_type == "keyword_as" then
            seen_as = true
            table.insert(parts, " " .. get_formatted_text(child, buf))
        elseif c_type == NODE.CREATE_QUERY and seen_as then
            local is_first = true
            for qchild in child:iter_children() do
                local qc_type = qchild:type()
                local txt     = format_node(qchild, buf, indent_lvl)

                if MAJOR_CLAUSES[qc_type] or qc_type == NODE.SELECT then
                    table.insert(parts, "\n" .. current_indent .. txt)
                elseif qc_type == NODE.SELECT_EXPR then
                    table.insert(parts, "\n" .. txt)
                else
                    if not is_first and parts[#parts] and not parts[#parts]:match("\n%s*$") then
                        table.insert(parts, " ")
                    end
                    table.insert(parts, txt)
                end
                is_first = false
            end
        elseif c_type == "keyword_with" or c_type == "keyword_check" or c_type == "keyword_option" or c_type == "keyword_local" then
            if c_type == "keyword_with" then
                table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
            else
                table.insert(parts, " " .. get_formatted_text(child, buf))
            end
        elseif not child:named() then
            -- do nothing
        else
            local txt = format_node(child, buf, indent_lvl)
            if txt ~= "" then
                table.insert(parts, " " .. txt)
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats a SAMPLE clause (simple or WHEN ... THEN ... ELSE ... END)
local function format_sample(node, buf, indent_lvl, current_indent)
    local parts = {}
    local kw_indent = "\n" .. current_indent .. INDENT_STR
    local has_when = false
    for child in node:iter_children() do
        if child:type() == "keyword_when" then
            has_when = true
            break
        end
    end

    if not has_when then
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)
            if c_type == "," then
                table.insert(parts, ", ")
            elseif #parts > 0 and parts[#parts]:sub(-1) ~= " " then
                table.insert(parts, " " .. txt)
            else
                table.insert(parts, txt)
            end
        end
        return table.concat(parts, "")
    end

    for child in node:iter_children() do
        local c_type = child:type()
        local txt = format_node(child, buf, indent_lvl + 1)
        if c_type == "keyword_sample" then
            table.insert(parts, txt)
        elseif c_type == "keyword_when" or c_type == "keyword_else" or c_type == "keyword_end" then
            table.insert(parts, kw_indent .. txt)
        else
            if #parts > 0 and parts[#parts]:sub(-1) ~= "\n" and parts[#parts]:sub(-1) ~= " " and c_type ~= "," then
                table.insert(parts, " ")
            end
            table.insert(parts, txt)
        end
    end
    return table.concat(parts, "")
end


--- Formats a compound statement (BEGIN ... END)
local function format_compound_statement(node, buf, indent_lvl, current_indent)
    local parts = {}
    local inner_indent = current_indent .. INDENT_STR

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_begin" then
            if #parts == 0 then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
            end
        elseif c_type == "keyword_end" then
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type == ";" then
            table.insert(parts, ";")
        elseif c_type == ":" then
            table.insert(parts, ":")
        elseif child:named() then
            local txt = format_node(child, buf, indent_lvl + 1)
            table.insert(parts, "\n" .. inner_indent .. txt)
        else
            table.insert(parts, " " .. format_node(child, buf, indent_lvl))
        end
    end

    return table.concat(parts, "")
end


--- Formats a procedural IF statement
local function format_proc_if(node, buf, indent_lvl, current_indent)
    local parts = {}
    local inner_indent = current_indent .. INDENT_STR
    local seen_then = false

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_if" and not seen_then then
            table.insert(parts, get_formatted_text(child, buf))
        elseif c_type == "keyword_then" then
            seen_then = true
            table.insert(parts, " " .. get_formatted_text(child, buf))
        elseif c_type == NODE.PROC_ELSEIF then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.PROC_ELSE then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == "keyword_end" then
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type == "keyword_if" and seen_then then
            table.insert(parts, " " .. get_formatted_text(child, buf))
        elseif c_type == ";" then
            table.insert(parts, ";")
        elseif child:named() then
            if not seen_then then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            else
                table.insert(parts, "\n" .. inner_indent .. format_node(child, buf, indent_lvl + 1))
            end
        end
    end
    return table.concat(parts, "")
end


--- Formats a procedural FOR loop
local function format_proc_for(node, buf, indent_lvl, current_indent)
    local parts = {}
    local inner_indent = current_indent .. INDENT_STR
    local seen_do = false

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_for" and not seen_do then
            if #parts == 0 then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, " " .. get_formatted_text(child, buf))
            end
        elseif c_type == "keyword_do" then
            seen_do = true
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type == "keyword_end" then
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type == "keyword_for" and seen_do then
            table.insert(parts, " " .. get_formatted_text(child, buf))
        elseif c_type == ";" then
            table.insert(parts, ";")
        elseif child:named() then
            if not seen_do then
                if c_type == NODE.SELECT or MAJOR_CLAUSES[c_type] then
                    table.insert(parts, "\n" .. inner_indent .. format_node(child, buf, indent_lvl + 1))
                else
                    table.insert(parts, " " .. format_node(child, buf, indent_lvl))
                end
            else
                table.insert(parts, "\n" .. inner_indent .. format_node(child, buf, indent_lvl + 1))
            end
        end
    end
    return table.concat(parts, "")
end


--- Formats CREATE [REPLACE] PROCEDURE
local function format_create_procedure(node, buf, indent_lvl, current_indent)
    local parts = {}
    local header_parts = {}
    local body_node = nil

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_create" or c_type == "keyword_replace" or c_type == "keyword_procedure" then
            table.insert(header_parts, get_formatted_text(child, buf))
        elseif c_type == NODE.OBJECT_REF then
            table.insert(header_parts, format_node(child, buf, indent_lvl))
        elseif c_type == "procedure_arguments" then
            table.insert(parts, table.concat(header_parts, " "))
            header_parts = {}

            local arg_parts = {}
            local arg_indent = current_indent .. INDENT_STR
            local is_first_arg = true
            for achild in child:iter_children() do
                if achild:named() then
                    local atxt = format_node(achild, buf, indent_lvl + 1)
                    if is_first_arg then
                        table.insert(arg_parts, arg_indent .. atxt)
                        is_first_arg = false
                    else
                        table.insert(arg_parts, "\n" .. arg_indent .. ", " .. atxt)
                    end
                end
            end
            if #arg_parts > 0 then
                table.insert(parts, " (\n" .. table.concat(arg_parts, "") .. "\n" .. current_indent .. ")")
            else
                table.insert(parts, " ()")
            end
        elseif c_type == "procedure_body" or c_type == NODE.COMPOUND_STMT then
            body_node = child
        elseif c_type:match("^procedure_") then
            if #header_parts > 0 then
                table.insert(parts, table.concat(header_parts, " "))
                header_parts = {}
            end
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == NODE.COMMENT or c_type == NODE.MARGINALIA then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        end
    end

    if #header_parts > 0 then
        table.insert(parts, table.concat(header_parts, " "))
    end

    if body_node then
        table.insert(parts, "\n" .. current_indent .. format_node(body_node, buf, indent_lvl))
    end

    return table.concat(parts, "")
end


--- Formats CREATE [REPLACE] FUNCTION
local function format_create_function(node, buf, indent_lvl, current_indent)
    local parts = {}
    local header_parts = {}
    local seen_header = false

    for child in node:iter_children() do
        local c_type = child:type()

        if c_type == "keyword_create" or c_type == "keyword_replace" or c_type == "keyword_function" then
            table.insert(header_parts, get_formatted_text(child, buf))
        elseif c_type == NODE.OBJECT_REF and not seen_header then
            table.insert(header_parts, format_node(child, buf, indent_lvl))
        elseif c_type == "function_arguments" then
            table.insert(header_parts, format_node(child, buf, indent_lvl))
            table.insert(parts, table.concat(header_parts, " "))
            seen_header = true
        elseif c_type == "keyword_returns" then
            if not seen_header and #header_parts > 0 then
                table.insert(parts, table.concat(header_parts, " "))
                seen_header = true
            end
            table.insert(parts, "\n" .. current_indent .. get_formatted_text(child, buf))
        elseif c_type:match("^function_") and c_type ~= "function_body" then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        elseif c_type == "function_body" or c_type == NODE.FUNCTION_BODY then
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        else
            if child:named() then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            else
                table.insert(parts, format_node(child, buf, indent_lvl))
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats CREATE DATABASE and MODIFY DATABASE
local function format_database_ddl(node, buf, indent_lvl, current_indent)
    local parts = {}
    local header_parts = {}
    local seen_as = false
    local attr_indent = current_indent .. INDENT_STR
    local current_attr = {}
    local is_first_attr = true

    local function flush_attr()
        if #current_attr > 0 then
            local attr_txt = table.concat(current_attr, " ")
            if is_first_attr then
                table.insert(parts, "\n" .. attr_indent .. "  " .. attr_txt)
                is_first_attr = false
            else
                table.insert(parts, "\n" .. attr_indent .. ", " .. attr_txt)
            end
            current_attr = {}
        end
    end

    for child in node:iter_children() do
        local c_type = child:type()

        if not seen_as then
            if c_type == "keyword_as" then
                seen_as = true
                table.insert(header_parts, get_formatted_text(child, buf))
                table.insert(parts, table.concat(header_parts, " "))
            else
                table.insert(header_parts, format_node(child, buf, indent_lvl))
            end
        else
            if c_type == "," then
                flush_attr()
            elseif c_type == "=" then
                table.insert(current_attr, "=")
            elseif child:named() then
                table.insert(current_attr, format_node(child, buf, indent_lvl))
            end
        end
    end
    flush_attr()

    return table.concat(parts, "")
end


--- Formats ALTER TABLE
local function format_alter_table(node, buf, indent_lvl, current_indent)
    local parts = {}
    local header_parts = {}
    local seen_name = false
    local spec_indent = current_indent .. INDENT_STR
    local is_first_spec = true

    for child in node:iter_children() do
        local c_type = child:type()

        if not seen_name then
            table.insert(header_parts, format_node(child, buf, indent_lvl))
            if c_type == NODE.OBJECT_REF then
                seen_name = true
                table.insert(parts, table.concat(header_parts, " "))
            end
        else
            if c_type == NODE.COMMENT or c_type == NODE.MARGINALIA then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type == "," then
                -- Comma handled below
            elseif child:named() then
                local txt = format_node(child, buf, indent_lvl + 1)
                if is_first_spec then
                    table.insert(parts, "\n" .. spec_indent .. "  " .. txt)
                    is_first_spec = false
                else
                    table.insert(parts, "\n" .. spec_indent .. ", " .. txt)
                end
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats CREATE JOIN INDEX
local function format_create_join_index(node, buf, indent_lvl, current_indent)
    local parts = {}
    local seen_as = false

    for child in node:iter_children() do
        local c_type = child:type()
        local txt = format_node(child, buf, indent_lvl)

        if not seen_as then
            if c_type == "keyword_as" then
                seen_as = true
                table.insert(parts, " " .. txt)
            elseif #parts == 0 then
                table.insert(parts, txt)
            else
                table.insert(parts, " " .. txt)
            end
        else
            if CREATE_TABLE_SECTIONS[c_type] or c_type == NODE.SELECT or MAJOR_CLAUSES[c_type] then
                table.insert(parts, "\n" .. current_indent .. txt)
            elseif c_type == NODE.SELECT_EXPR then
                table.insert(parts, "\n" .. txt)
            else
                if parts[#parts] and not parts[#parts]:match("\n%s*$") then
                    table.insert(parts, " ")
                end
                table.insert(parts, txt)
            end
        end
    end

    return table.concat(parts, "")
end


--- Formats CREATE HASH INDEX
local function format_create_hash_index(node, buf, indent_lvl, current_indent)
    local parts = {}

    for child in node:iter_children() do
        local c_type = child:type()
        local txt = format_node(child, buf, indent_lvl)

        if c_type == "keyword_on" or c_type == "keyword_by" or c_type == "hash_index_order_by_clause" then
            table.insert(parts, "\n" .. current_indent .. txt)
        elseif c_type == "hash_index_option" then
            table.insert(parts, "\n" .. current_indent .. txt)
        elseif #parts == 0 then
            table.insert(parts, txt)
        else
            if parts[#parts] and not parts[#parts]:match("\n%s*$") and c_type ~= "," and c_type ~= "(" and c_type ~= ")" then
                table.insert(parts, " ")
            end
            table.insert(parts, txt)
        end
    end

    return table.concat(parts, "")
end


--- Formats INSERT EXPLAIN
local function format_insert_explain(node, buf, indent_lvl, current_indent)
    local parts = {}
    local header_done = false

    for child in node:iter_children() do
        local c_type = child:type()

        if not header_done then
            if c_type == NODE.SELECT or c_type == NODE.INSERT or c_type == NODE.UPDATE or c_type == NODE.DELETE or c_type == NODE.STATEMENT then
                header_done = true
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            else
                local txt = format_node(child, buf, indent_lvl)
                if #parts == 0 then
                    table.insert(parts, txt)
                else
                    table.insert(parts, " " .. txt)
                end
            end
        else
            table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
        end
    end

    return table.concat(parts, "")
end


--- Main Recursive Formatter
format_node = function(node, buf, indent_lvl, context)
    local type = node:type()
    local current_indent = string.rep(INDENT_STR, indent_lvl)

    -- Base case: Leaf nodes or tokens without separate AST children
    if node:child_count() == 0 or type == NODE.LITERAL or type == NODE.IDENTIFIER then
        return get_formatted_text(node, buf)
    end

    -- Handlers for specific node types

    -- set_operation: UNION [ALL] / INTERSECT [ALL] / EXCEPT [ALL] / MINUS [ALL]
    if type == NODE.SET_OPERATION then
        return format_set_operation(node, buf, indent_lvl, current_indent)
    end

    -- create_macro
    if type == NODE.CREATE_MACRO then
        return format_create_macro(node, buf, indent_lvl, current_indent)
    end

    -- create_procedure
    if type == NODE.CREATE_PROCEDURE then
        return format_create_procedure(node, buf, indent_lvl, current_indent)
    end

    -- compound_statement
    if type == NODE.COMPOUND_STMT then
        return format_compound_statement(node, buf, indent_lvl, current_indent)
    end

    -- procedure_if_statement
    if type == NODE.PROC_IF then
        return format_proc_if(node, buf, indent_lvl, current_indent)
    end

    -- procedure_for_statement
    if type == NODE.PROC_FOR then
        return format_proc_for(node, buf, indent_lvl, current_indent)
    end

    -- create_function
    if type == NODE.CREATE_FUNCTION then
        return format_create_function(node, buf, indent_lvl, current_indent)
    end

    -- create_database / modify_database
    if type == NODE.CREATE_DATABASE or type == NODE.MODIFY_DATABASE then
        return format_database_ddl(node, buf, indent_lvl, current_indent)
    end

    -- alter_table
    if type == NODE.ALTER_TABLE then
        return format_alter_table(node, buf, indent_lvl, current_indent)
    end

    -- create_join_index
    if type == NODE.CREATE_JOIN_INDEX then
        return format_create_join_index(node, buf, indent_lvl, current_indent)
    end

    -- create_hash_index
    if type == NODE.CREATE_HASH_INDEX then
        return format_create_hash_index(node, buf, indent_lvl, current_indent)
    end

    -- insert_explain
    if type == NODE.INSERT_EXPLAIN then
        return format_insert_explain(node, buf, indent_lvl, current_indent)
    end

    -- sample_clause
    if type == NODE.SAMPLE then
        return format_sample(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.QUALIFY then
        local parts = {}
        for child in node:iter_children() do
            if child:type() == "keyword_qualify" then
                table.insert(parts, get_formatted_text(child, buf))
            else
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            end
        end
        return table.concat(parts, "")
    end

    if type == NODE.EXPAND_ON then
        local parts = {}
        for child in node:iter_children() do
            local txt = format_node(child, buf, indent_lvl)
            if #parts > 0 and parts[#parts]:sub(-1) ~= " " and child:type() ~= "," then
                table.insert(parts, " ")
            end
            table.insert(parts, txt)
        end
        return table.concat(parts, "")
    end

    if type == NODE.STATEMENT or type == NODE.SELECT then
        if type == NODE.STATEMENT and is_merge_statement(node) then
            return format_merge(node, buf, indent_lvl, current_indent)
        end

        -- CTE: statement with keyword_with before main query
        if type == NODE.STATEMENT then
            local has_with = false
            for child in node:iter_children() do
                if child:type() == "keyword_with" then
                    has_with = true
                    break
                elseif child:type() == NODE.SELECT or child:type() == NODE.INSERT or child:type() == NODE.UPDATE or child:type() == NODE.DELETE then
                    break
                end
            end
            if has_with then
                return format_cte(node, buf, indent_lvl, current_indent)
            end
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
        -- Non-AND/OR expressions fall through to Generic Fallback to preserve gaps (e.g. ESCAPE '\')
    end

    if type == NODE.JOIN or type == NODE.CROSS_JOIN then
        local parts = {}
        for child in node:iter_children() do
            local c_type = child:type()
            if c_type == NODE.RELATION or c_type == NODE.SUBQUERY or c_type == NODE.OBJECT_REF then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_on" then
                table.insert(parts, "\n" .. current_indent .. format_node(child, buf, indent_lvl))
            elseif c_type == NODE.BINARY_EXPR and c_type ~= "keyword_full" and c_type ~= "keyword_join" and c_type ~= "keyword_cross" then
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
            local inner_indent = string.rep(INDENT_STR, indent_lvl + 1)
            local is_first_inner = true

            for child in node:iter_children() do
                local c_type = child:type()
                if c_type == "(" then
                    table.insert(parts, "(\n" .. inner_indent)
                elseif c_type == ")" then
                    table.insert(parts, "\n" .. current_indent .. ")")
                else
                    local txt = format_node(child, buf, indent_lvl + 1)
                    if MAJOR_CLAUSES[c_type] or c_type == NODE.SELECT then
                        if not is_first_inner then
                            table.insert(parts, "\n" .. inner_indent .. txt)
                        else
                            table.insert(parts, txt)
                        end
                    elseif c_type == NODE.SELECT_EXPR then
                        table.insert(parts, (is_first_inner and "" or "\n") .. txt)
                    else
                        if not is_first_inner then
                            if parts[#parts] and not parts[#parts]:match("\n%s*$") then
                                table.insert(parts, " ")
                            end
                        end
                        table.insert(parts, txt)
                    end
                    is_first_inner = false
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

    if type == NODE.CREATE_VIEW then
        return format_create_view(node, buf, indent_lvl, current_indent)
    end

    if type == NODE.CREATE_TABLE then
        local parts = {}
        local is_first = true
        for child in node:iter_children() do
            local c_type = child:type()
            local txt = format_node(child, buf, indent_lvl)
            if CREATE_TABLE_SECTIONS[c_type] then
                table.insert(parts, "\n" .. current_indent .. txt)
            elseif c_type == "keyword_no" or c_type == "keyword_on" then
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

            if c_type == "keyword_partition" then
                table.insert(parts, format_node(child, buf, indent_lvl))
            elseif c_type == "keyword_by" then
                table.insert(parts, " " .. format_node(child, buf, indent_lvl))
            elseif c_type == NODE.PAR_EXPR then
                local p_indent = current_indent .. INDENT_STR
                for pchild in child:iter_children() do
                    local pt = pchild:type()
                    if pt == "(" then
                        table.insert(parts, "\n" .. p_indent .. "(")
                    elseif pt == ")" then
                        table.insert(parts, "\n" .. p_indent .. ")")
                    else
                        table.insert(parts, "\n" .. p_indent .. format_node(pchild, buf, indent_lvl + 1))
                    end
                end
            else
                table.insert(parts, "\n" .. current_indent .. INDENT_STR .. format_node(child, buf, indent_lvl + 1))
            end
        end
        return table.concat(parts, "")
    end

    -- Generic Fallback
    local parts = {}
    local prev_er, prev_ec
    local prev_was_comment = false
    do
        local sr, sc, _, _ = node:range(); prev_er, prev_ec = sr, sc
    end

    for child in node:iter_children() do
        local c_type = child:type()
        local c_sr, c_sc, c_er, c_ec = child:range()

        -- Capture gap before this child (e.g. '1' between keyword_interval and keyword_month)
        if c_sr > prev_er or (c_sr == prev_er and c_sc > prev_ec) then
            local gap = api.nvim_buf_get_text(buf, prev_er, prev_ec, c_sr, c_sc, {})
            local joined = table.concat(gap, " "):match("^%s*(.-)%s*$")
            if joined ~= "" then
                local prev = parts[#parts]
                if prev_was_comment then
                    table.insert(parts, "\n" .. current_indent)
                    prev_was_comment = false
                elseif #parts > 0 and prev ~= "(" and prev:sub(-1) ~= "\n" then
                    table.insert(parts, " ")
                end
                table.insert(parts, joined)
            end
        end

        local txt = format_node(child, buf, indent_lvl, context)
        local prev = parts[#parts]

        if prev_was_comment then
            table.insert(parts, "\n" .. current_indent .. txt)
            prev_was_comment = false
        elseif c_type == "." or (prev and prev:sub(-1) == ".") then
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

        if c_type == NODE.COMMENT then
            prev_was_comment = true
        end

        prev_er, prev_ec = c_er, c_ec
    end

    -- Capture any trailing gap after the last child (e.g. trailing numbers, format strings, literals)
    local _, _, parent_er, parent_ec = node:range()
    if prev_er ~= nil and (parent_er > prev_er or (parent_er == prev_er and parent_ec > prev_ec)) then
        local gap = api.nvim_buf_get_text(buf, prev_er, prev_ec, parent_er, parent_ec, {})
        local joined = table.concat(gap, " "):match("^%s*(.-)%s*$")
        if joined ~= "" then
            local prev = parts[#parts]
            if prev_was_comment then
                table.insert(parts, "\n" .. current_indent)
            elseif #parts > 0 and prev ~= "(" and prev:sub(-1) ~= "\n" then
                table.insert(parts, " ")
            end
            table.insert(parts, joined)
        end
    end

    return table.concat(parts, "")
end

--- Replace '...' / "..." literals and -- / /* */ comments with opaque placeholders so that
--- whitespace normalisation cannot alter them. Returns protected text and a restore function.
local function protect_literals(text)
    local saved = {}
    local function stash(s)
        saved[#saved + 1] = s
        return '\1' .. #saved .. '\2'
    end
    local out, i, n = {}, 1, #text
    while i <= n do
        local c, two = text:sub(i, i), text:sub(i, i + 1)
        if c == "'" or c == '"' then
            local j = i + 1
            while j <= n do
                if text:sub(j, j) == c then
                    if text:sub(j + 1, j + 1) == c then j = j + 2 else break end
                else
                    j = j + 1
                end
            end
            local stop = math.min(j, n)
            out[#out + 1] = stash(text:sub(i, stop))
            i = stop + 1
        elseif two == '--' then
            local j = text:find('\n', i, true) or (n + 1)
            out[#out + 1] = stash(text:sub(i, j - 1))
            i = j
        elseif two == '/*' then
            local _, e = text:find('*/', i + 2, true)
            local stop = e or n
            out[#out + 1] = stash(text:sub(i, stop))
            i = stop + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out), function(s)
        return (s:gsub('\1(%d+)\2', function(k) return saved[tonumber(k)] end))
    end
end

--- Formats a list of statement nodes in-place (bottom-up to preserve ranges).
local function format_statement_nodes(nodes, buf)
    -- Sort descending by start_row so replacements don't shift earlier nodes
    table.sort(nodes, function(a, b)
        local r1 = a:range()
        local r2 = b:range()
        return r1 > r2
    end)

    for _, node in ipairs(nodes) do
        local formatted = format_node(node, buf, 0)

        local protected, restore = protect_literals(formatted)
        protected = protected:gsub(" %.", ".")
            :gsub("%. ", ".")
            :gsub("%( %)", "()")
            :gsub(" %( ", "(")
            :gsub(" ,", ",")
            :gsub("\n ", "\n" .. INDENT_STR)
        formatted = restore(protected)

        local s_row, s_col, e_row, e_col = node:range()
        local lines = vim.split(formatted, "\n")

        local ok, err = pcall(api.nvim_buf_set_text, buf, s_row, s_col, e_row, e_col, lines)
        if not ok then
            vim.notify("Failed to apply formatting: " .. tostring(err), LOG_LEVELS.ERROR)
        end
    end
end

--- Formats the SQL statement(s) under the cursor.
--- When called as :nTDF, formats n consecutive statements.
function M.format_current_statement(args)
    local buf = api.nvim_get_current_buf()

    if not tsu.ensure_parser(buf) then return end

    local node = ts.get_node({ bufnr = buf, ignore_injections = false })

    -- Traverse up to find the statement
    node = tsu.ancestor(node, NODE.STATEMENT)

    if not node then
        vim.notify("Cursor is not inside a valid SQL statement.", LOG_LEVELS.WARN)
        return
    end

    local count = (args and args.count and args.count > 0) and args.count or 1
    local nodes = tsu.collect_next_sibling_statement_nodes(node, count)
    format_statement_nodes(nodes, buf)
end

--- Formats all SQL statements in the current buffer.
function M.format_all_statements()
    local buf = api.nvim_get_current_buf()
    local parser = tsu.ensure_parser(buf)
    if not parser then return end

    local tree = parser:parse()[1]
    local root = tree:root()

    local nodes = {}
    for child in root:iter_children() do
        if child:type() == 'statement' then
            table.insert(nodes, child)
        end
    end

    if #nodes == 0 then
        vim.notify("No statements found in buffer.", LOG_LEVELS.WARN)
        return
    end

    format_statement_nodes(nodes, buf)
end

--- copy the nearest ancestor node matching the given type
-- @param target_node_type string
function M.copy_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local s_row, s_col, e_row, e_col = tsu.node_range_with_delimiters(target_node_type, buf)
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
    local s_row, s_col, e_row, e_col = tsu.node_range_with_delimiters(target_node_type, buf)

    if s_row and s_col and e_row and e_col then
        api.nvim_buf_set_text(buf, s_row, s_col, e_row, e_col, {})
    end
end

--- Comments the nearest ancestor node matching the given type
-- @param target_node_type string
function M.comment_node(target_node_type)
    local buf = api.nvim_get_current_buf()
    local left, right = "/*", "*/"

    local s_row, s_col, e_row, e_col = tsu.node_range_with_delimiters(target_node_type, buf)

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
    local node = tsu.next_node_by_type(target_node_type)
    if node then
        local r, c, _, _ = node:range()
        vim.cmd("normal! m'")
        api.nvim_win_set_cursor(0, { r + 1, c })
    else
        vim.notify("No next " .. target_node_type .. " found.", LOG_LEVELS.INFO)
    end
end

--- Moves cursor to the previous node of the given type
-- @param target_node_type string (e.g. "statement")
function M.jump_to_prev(target_node_type)
    local node = tsu.prev_node_by_type(target_node_type)
    if node then
        local r, c, _, _ = node:range()
        vim.cmd("normal! m'")
        api.nvim_win_set_cursor(0, { r + 1, c })
    else
        vim.notify("No previous " .. target_node_type .. " found.", LOG_LEVELS.INFO)
    end
end

M._protect_literals = protect_literals

return M
