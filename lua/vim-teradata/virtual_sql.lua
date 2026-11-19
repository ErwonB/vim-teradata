-- vim-teradata: SQL query wrapping, expression reference rewriting, and
-- volatile-table DDL generation for virtual answerset pushdown (Patch 3).

local util = require('vim-teradata.util')

local M = {}

local NESTED_TYPES = {
    subquery                    = true,
    cte                         = true,
    common_table_expression     = true,
    window_specification        = true,
    ordered_analytical_function = true,
}

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Quotes a SQL identifier in double quotes, doubling internal double quotes.
--- @param name string
--- @return string
function M.quote_ident(name)
    return '"' .. tostring(name):gsub('"', '""') .. '"'
end

local function lock_clause_is_access(node)
    for child in node:iter_children() do
        if child:type() == 'keyword_access' then
            return true
        end
    end
    return false
end

local function find_top_level_order_by(node)
    for child in node:iter_children() do
        local t = child:type()
        if t == 'order_by' then
            return child
        end
        if child:named() and not NESTED_TYPES[t] then
            local found = find_top_level_order_by(child)
            if found then return found end
        end
    end
    return nil
end

--- Analyzes a single SELECT statement so it can be wrapped as a derived table.
--- Hoists any leading LOCKING ... FOR ACCESS and top-level WITH clause into
--- `prefix`, and strips any top-level ORDER BY into `order_by`.
--- @param sql string original query text
--- @param header string[] result column names
--- @return table|nil wrapped { prefix = string, base = string, order_by = string|nil }, string|nil err
function M.analyze(sql, header)
    if type(header) ~= 'table' or #header == 0 then
        return nil, 'Result header is empty.'
    end
    for _, h in ipairs(header) do
        if type(h) ~= 'string' or trim(h) == '' then
            return nil, 'Result header contains an empty column name.'
        end
    end

    local replaced = util.replace_env_vars(sql or '')
    local stmts = {}
    for _, s in ipairs(util.split_statements(replaced)) do
        local stripped = util.strip_leading_noise(s)
        if stripped ~= '' then
            stmts[#stmts + 1] = stripped
        end
    end
    if #stmts == 0 then
        return nil, 'The query is empty.'
    end
    if #stmts > 1 then
        return nil, 'Only a single SELECT statement can be wrapped.'
    end

    local stmt = stmts[1]:gsub('[%s;]+$', '')
    local head = stmt:lower()
    if head:match('^explain%f[%W]') or head:match('^show%f[%W]') or head:match('^help%f[%W]') then
        return nil, 'EXPLAIN, SHOW and HELP queries cannot be wrapped.'
    end
    local starts_ok = head:match('^select%f[%W]')
        or head:match('^sel%f[%W]')
        or head:match('^with%f[%W]')
        or head:match('^lock%f[%W]')
        or head:match('^locking%f[%W]')
    if not starts_ok then
        return nil, 'Only SELECT statements can be wrapped.'
    end

    local parse_src = stmt .. ';'
    local ok_p, parser = pcall(vim.treesitter.get_string_parser, parse_src, 'teradata')
    if not ok_p or not parser then
        return nil, 'Teradata tree-sitter parser is not available.'
    end
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if not root or root:has_error() then
        return nil, 'Query has syntax errors and cannot be wrapped.'
    end
    if root:named_child_count() ~= 1 or root:named_child(0):type() ~= 'statement' then
        return nil, 'Only a single SELECT statement can be wrapped.'
    end

    local stmt_node = root:named_child(0)
    local main_node = nil
    for child in stmt_node:iter_children() do
        if child:named() then
            local ct = child:type()
            if ct == 'lock_clause' then
                if not lock_clause_is_access(child) then
                    return nil, 'Only LOCKING ... FOR ACCESS modifiers are supported.'
                end
            elseif ct == 'select' or ct == 'set_operation' then
                if not main_node then main_node = child end
            elseif ct ~= 'keyword_with' and ct ~= 'keyword_recursive' and ct ~= 'cte' and ct ~= 'from' then
                return nil, 'Only SELECT statements can be wrapped.'
            end
        end
    end
    if not main_node then
        return nil, 'Only SELECT statements can be wrapped.'
    end

    local _, _, main_start = main_node:start()
    local prefix = trim(stmt:sub(1, main_start))

    local ob_node = find_top_level_order_by(stmt_node)
    local base, order_by
    if ob_node then
        local _, _, ob_start = ob_node:start()
        local _, _, ob_end   = ob_node:end_()
        order_by = trim(stmt:sub(ob_start + 1, ob_end))
        base = trim(stmt:sub(main_start + 1, ob_start) .. stmt:sub(ob_end + 1))
    else
        base = trim(stmt:sub(main_start + 1))
        order_by = nil
    end

    return {
        prefix   = prefix,
        base     = base,
        order_by = order_by,
    }, nil
end

--- Builds `"( <base> ) AS vt ("C1", "C2", ...)"` for a wrapped query.
--- @param wrapped { base: string }
--- @param header string[]
--- @return string
function M.derived(wrapped, header)
    local cols = {}
    for i, h in ipairs(header) do
        cols[i] = M.quote_ident(h)
    end
    return string.format('( %s ) AS vt (%s)', wrapped.base, table.concat(cols, ', '))
end

--- Rewrites column references inside `expr` using tree-sitter node byte ranges
--- (right-to-left, never regex). Real columns become `<alias>."<HEADER>"` (or
--- `"<HEADER>"` when `alias == ''`); references to earlier virtual columns in
--- `vcol_sql_map` are substituted as `( <other sql expr> )`.
--- @param expr string
--- @param header string[]
--- @param vcol_sql_map table<string, string>|nil upper-cased vcol name -> already rewritten SQL expr
--- @param alias string|nil defaults to 'vt'
--- @return string|nil rewritten, string|nil err
function M.rewrite_expr(expr, header, vcol_sql_map, alias)
    if type(expr) ~= 'string' or trim(expr) == '' then
        return nil, 'empty expression'
    end
    vcol_sql_map = vcol_sql_map or {}
    local qual = (alias == nil) and 'vt.' or (alias ~= '' and (alias .. '.') or '')

    local hdr_exact, hdr_upper = {}, {}
    for _, h in ipairs(header or {}) do
        hdr_exact[h] = h
        if not hdr_upper[h:upper()] then
            hdr_upper[h:upper()] = h
        end
    end

    local prefix = 'SELECT ' .. expr
    local src = prefix .. ' FROM __vt__;'
    local ok_p, parser = pcall(vim.treesitter.get_string_parser, src, 'teradata')
    if not ok_p or not parser then
        return nil, 'teradata tree-sitter parser is not available'
    end
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if not root or root:has_error() then
        return nil, 'syntax error in expression'
    end

    local stmt = root:named_child(0)
    local sel = stmt and stmt:named_child(0)
    local sel_expr = nil
    if sel then
        for child in sel:iter_children() do
            if child:type() == 'select_expression' then sel_expr = child break end
        end
    end
    local term = sel_expr and sel_expr:named_child(0)
    if not term then return nil, 'invalid expression' end

    local offset = #'SELECT '
    local edits = {}

    local function resolve_col(raw_name, quoted)
        if not quoted then
            local up = raw_name:upper()
            if vcol_sql_map[up] then
                return '( ' .. vcol_sql_map[up] .. ' )'
            end
            local h = hdr_upper[up]
            if h then
                return qual .. M.quote_ident(h)
            end
        else
            if vcol_sql_map[raw_name] or vcol_sql_map[raw_name:upper()] then
                return '( ' .. (vcol_sql_map[raw_name] or vcol_sql_map[raw_name:upper()]) .. ' )'
            end
            local h = hdr_exact[raw_name] or hdr_upper[raw_name:upper()]
            if h then
                return qual .. M.quote_ident(h)
            end
        end
        return nil
    end

    local function collect_refs(node)
        local t = node:type()
        if t == 'field' then
            local name_node = node:field('name')[1]
            if not name_node and node:named_child_count() > 0 then
                name_node = node:named_child(node:named_child_count() - 1)
            end
            if name_node then
                local raw = trim(vim.treesitter.get_node_text(name_node, src))
                local quoted = false
                if raw:match('^".*"$') then
                    raw = raw:sub(2, -2):gsub('""', '"')
                    quoted = true
                end
                local _, _, s_byte = node:start()
                local _, _, e_byte = node:end_()
                edits[#edits + 1] = {
                    s      = s_byte - offset,
                    e      = e_byte - offset,
                    name   = raw,
                    quoted = quoted,
                }
            end
            return
        elseif t == 'literal' then
            local raw = trim(vim.treesitter.get_node_text(node, src))
            if raw:match('^".*"$') then
                local unq = raw:sub(2, -2):gsub('""', '"')
                local _, _, s_byte = node:start()
                local _, _, e_byte = node:end_()
                edits[#edits + 1] = {
                    s      = s_byte - offset,
                    e      = e_byte - offset,
                    name   = unq,
                    quoted = true,
                }
            end
            return
        elseif t == 'invocation' then
            -- Handle SUBSTRING(x FROM 2) where `x` is parsed as `unit: (object_reference)`
            local fn_node = nil
            for child in node:iter_children() do
                if child:type() == 'object_reference' then fn_node = child break end
            end
            local fn_name = fn_node and trim(vim.treesitter.get_node_text(fn_node, src)):upper() or ''
            local unit_node = node:field('unit')[1]
            if (fn_name == 'SUBSTRING' or fn_name == 'SUBSTR') and unit_node then
                local raw = trim(vim.treesitter.get_node_text(unit_node, src))
                local quoted = false
                if raw:match('^".*"$') then
                    raw = raw:sub(2, -2):gsub('""', '"')
                    quoted = true
                end
                local _, _, s_byte = unit_node:start()
                local _, _, e_byte = unit_node:end_()
                edits[#edits + 1] = {
                    s      = s_byte - offset,
                    e      = e_byte - offset,
                    name   = raw,
                    quoted = quoted,
                }
                for child in node:iter_children() do
                    if child:named() and child ~= fn_node and child ~= unit_node then
                        collect_refs(child)
                    end
                end
                return
            end
        end

        for child in node:iter_children() do
            if child:named() then
                collect_refs(child)
            end
        end
    end

    collect_refs(term)
    table.sort(edits, function(a, b) return a.s > b.s end)

    local out = expr
    for _, ed in ipairs(edits) do
        local repl = resolve_col(ed.name, ed.quoted)
        if not repl then
            return nil, string.format("unknown column '%s'", ed.name)
        end
        out = out:sub(1, ed.s) .. repl .. out:sub(ed.e + 1)
    end
    return out, nil
end

--- Builds the SQL select-list term for a single column in footer mode `mode`.
--- @param mode string
--- @param col_expr string SQL expression or quoted column identifier
--- @param is_numeric boolean
--- @return string
function M.footer_term(mode, col_expr, is_numeric)
    if mode == 'sum' then
        return is_numeric and string.format('SUM(%s)', col_expr) or 'CAST(NULL AS INTEGER)'
    elseif mode == 'avg' then
        return is_numeric and string.format('AVG(CAST(%s AS FLOAT))', col_expr) or 'CAST(NULL AS INTEGER)'
    elseif mode == 'min' then
        return string.format('MIN(%s)', col_expr)
    elseif mode == 'max' then
        return string.format('MAX(%s)', col_expr)
    elseif mode == 'count' then
        return string.format('COUNT(%s)', col_expr)
    elseif mode == 'nulls' then
        return string.format('COUNT(*) - COUNT(%s)', col_expr)
    elseif mode == 'distinct' then
        return string.format('COUNT(DISTINCT %s)', col_expr)
    end
    return 'CAST(NULL AS INTEGER)'
end

--- Builds the aggregate pushdown SELECT statement for the summary footer.
--- @param opts { sql: string|nil, header: string[], columns: { name: string, is_numeric: boolean, expr: string|nil }[], vcols: table[]|nil, mode: string, vt_name: string|nil }
--- @return string|nil sql, string|nil err
function M.build_footer_sql(opts)
    local header  = opts.header or {}
    local columns = opts.columns or {}
    local mode    = opts.mode
    if #columns == 0 then return nil, 'No displayed columns.' end

    local vcol_sql_map = {}
    for _, vc in ipairs(opts.vcols or {}) do
        local rw, rerr = M.rewrite_expr(vc.expr, header, vcol_sql_map, 'vt')
        if not rw then return nil, rerr end
        vcol_sql_map[vc.name:upper()] = rw
        vcol_sql_map[vc.name] = rw
    end

    local terms = {}
    for i, col in ipairs(columns) do
        local col_expr
        if col.expr then
            local rw = vcol_sql_map[col.name:upper()] or vcol_sql_map[col.name]
            if not rw then
                local rerr
                rw, rerr = M.rewrite_expr(col.expr, header, vcol_sql_map, 'vt')
                if not rw then return nil, rerr end
            end
            col_expr = rw
        else
            col_expr = M.quote_ident(col.name)
        end
        terms[i] = M.footer_term(mode, col_expr, col.is_numeric == true)
    end

    if opts.vt_name and opts.vt_name ~= '' then
        return string.format('SELECT %s FROM %s AS vt;', table.concat(terms, ', '), opts.vt_name), nil
    end

    local wrapped, werr = M.analyze(opts.sql or '', header)
    if not wrapped then return nil, werr end
    local pre = (wrapped.prefix ~= '') and (wrapped.prefix .. '\n') or ''
    return string.format('%sSELECT %s\nFROM %s;',
        pre, table.concat(terms, ', '), M.derived(wrapped, header)), nil
end

--- Checks if an outer `ORDER BY ...` clause only references columns present in `header`
--- (or 1..#header positional numbers) and rewrites column references to `"<HEADER>"`.
local function rewrite_outer_order_by(order_by, header)
    if not order_by or order_by == '' then return nil, false end
    local src = 'SELECT 1 FROM __vt__ ' .. order_by .. ';'
    local ok_p, parser = pcall(vim.treesitter.get_string_parser, src, 'teradata')
    if not ok_p or not parser then return nil, true end
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if not root or root:has_error() then return nil, true end

    local ob_node = find_top_level_order_by(root)
    if not ob_node then return nil, true end

    local hdr_exact, hdr_upper = {}, {}
    for _, h in ipairs(header) do
        hdr_exact[h] = h
        if not hdr_upper[h:upper()] then hdr_upper[h:upper()] = h end
    end

    local offset = #'SELECT 1 FROM __vt__ '
    local edits = {}
    local valid = true

    local function walk(node)
        if not valid then return end
        local t = node:type()
        if t == 'field' then
            local name_node = node:field('name')[1]
            if not name_node and node:named_child_count() > 0 then
                name_node = node:named_child(node:named_child_count() - 1)
            end
            local raw = name_node and trim(vim.treesitter.get_node_text(name_node, src)) or ''
            if raw:match('^".*"$') then raw = raw:sub(2, -2):gsub('""', '"') end
            local matched = hdr_exact[raw] or hdr_upper[raw:upper()]
            if not matched then
                valid = false
                return
            end
            local _, _, sb = node:start()
            local _, _, eb = node:end_()
            edits[#edits + 1] = { s = sb - offset, e = eb - offset, repl = M.quote_ident(matched) }
            return
        elseif t == 'literal' then
            local raw = trim(vim.treesitter.get_node_text(node, src))
            if raw:match('^".*"$') then
                local unq = raw:sub(2, -2):gsub('""', '"')
                local matched = hdr_exact[unq] or hdr_upper[unq:upper()]
                if not matched then
                    valid = false
                    return
                end
                local _, _, sb = node:start()
                local _, _, eb = node:end_()
                edits[#edits + 1] = { s = sb - offset, e = eb - offset, repl = M.quote_ident(matched) }
            elseif raw:match('^%d+$') then
                local pos = tonumber(raw)
                if not pos or pos < 1 or pos > #header then
                    valid = false
                    return
                end
            end
            return
        end
        for child in node:iter_children() do
            if child:named() then walk(child) end
        end
    end

    walk(ob_node)
    if not valid then return nil, true end

    table.sort(edits, function(a, b) return a.s > b.s end)
    local out = order_by
    for _, ed in ipairs(edits) do
        out = out:sub(1, ed.s) .. ed.repl .. out:sub(ed.e + 1)
    end
    return out, false
end

--- Builds the pushdown SELECT statement for `:TDColPush`.
--- @param opts { sql: string|nil, header: string[], vcols: { name: string, expr: string }[], vt_name: string|nil }
--- @return string|nil sql, string|nil err, boolean|nil dropped_order_by
function M.build_col_push_sql(opts)
    local header = opts.header or {}
    local vcols  = opts.vcols or {}
    if #vcols == 0 then
        return nil, 'No virtual columns defined to push.'
    end

    local vcol_sql_map = {}
    local select_items = { 'vt.*' }
    for _, vc in ipairs(vcols) do
        local rw, rerr = M.rewrite_expr(vc.expr, header, vcol_sql_map, 'vt')
        if not rw then return nil, rerr end
        vcol_sql_map[vc.name:upper()] = rw
        vcol_sql_map[vc.name] = rw
        select_items[#select_items + 1] = string.format('%s AS %s', rw, M.quote_ident(vc.name))
    end

    if opts.vt_name and opts.vt_name ~= '' then
        return string.format('SELECT %s\nFROM %s AS vt;',
            table.concat(select_items, ', '), opts.vt_name), nil, false
    end

    local wrapped, werr = M.analyze(opts.sql or '', header)
    if not wrapped then return nil, werr end

    local outer_ob, dropped = nil, false
    if wrapped.order_by then
        outer_ob, dropped = rewrite_outer_order_by(wrapped.order_by, header)
    end

    local pre = (wrapped.prefix ~= '') and (wrapped.prefix .. '\n') or ''
    local ob_line = outer_ob and ('\n' .. outer_ob) or ''
    return string.format('%sSELECT %s\nFROM %s%s;',
        pre, table.concat(select_items, ', '), M.derived(wrapped, header), ob_line), nil, dropped
end

--- Default volatile table name `VAS_<sanitized query_id>` (max 128 chars, starts with a letter).
--- @param query_id string|nil
--- @return string
function M.default_vt_name(query_id)
    local s = 'VAS_' .. tostring(query_id or 'RESULT'):gsub('[^%w_]', '_')
    if not s:match('^[%a]') then
        s = 'VAS_' .. s
    end
    return s:sub(1, 128)
end

--- Validates a volatile table identifier.
--- @param name string
--- @return boolean ok, string|nil err
function M.validate_vt_name(name)
    if type(name) ~= 'string' or name == '' then
        return false, 'Volatile table name cannot be empty.'
    end
    if #name > 128 or not name:match('^[%a][%w_]*$') then
        return false, 'Invalid volatile table name (must start with a letter and contain only letters, digits, or _).'
    end
    return true, nil
end

--- Builds the `CREATE VOLATILE TABLE <name> AS (...) WITH DATA NO PRIMARY INDEX ON COMMIT PRESERVE ROWS;` DDL.
--- @param sql string
--- @param header string[]
--- @param vt_name string|nil
--- @return string|nil ddl, string|nil err, string|nil resolved_name
function M.build_materialize_sql(sql, header, vt_name)
    vt_name = (vt_name and trim(vt_name) ~= '') and trim(vt_name) or M.default_vt_name(nil)
    local ok_n, nerr = M.validate_vt_name(vt_name)
    if not ok_n then return nil, nerr end

    local wrapped, werr = M.analyze(sql, header)
    if not wrapped then return nil, werr end

    -- In Teradata, LOCKING modifiers must precede CREATE VOLATILE TABLE rather
    -- than sitting inside AS (...), whereas WITH clauses sit inside AS (...).
    local lock_part, with_part = '', wrapped.prefix
    if with_part:lower():match('^lock') then
        local s_with = with_part:lower():find('%f[%w]with%f[%W]')
        if s_with then
            lock_part = trim(with_part:sub(1, s_with - 1)) .. '\n'
            with_part = trim(with_part:sub(s_with))
        else
            lock_part = with_part .. '\n'
            with_part = ''
        end
    end
    local inner_prefix = (with_part ~= '') and (with_part .. ' ') or ''

    local ddl = string.format(
        '%sCREATE VOLATILE TABLE %s AS (\n  %sSELECT * FROM %s\n) WITH DATA\nNO PRIMARY INDEX\nON COMMIT PRESERVE ROWS;',
        lock_part, vt_name, inner_prefix, M.derived(wrapped, header)
    )
    return ddl, nil, vt_name
end

return M
