-- vim-teradata: Teradata SQL scalar expression parser and evaluator for
-- virtual computed columns (Patch 2).
--
-- Expressions are parsed with the tree-sitter `teradata` grammar by wrapping
-- them in `SELECT <expr> FROM __vt__;`, then converted into a small pure-Lua
-- AST so evaluation does not require keeping tree-sitter nodes alive.

local config  = require('vim-teradata.config')
local virtual = require('vim-teradata.virtual')

local M = {}

local function null_token()
    return (config.options and config.options.null_token)
        or (config.defaults and config.defaults.null_token)
        or 'NULL'
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- =============================================================================
-- Civil calendar date helper (YYYY-MM-DD and YY/MM/DD)
-- =============================================================================

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_leap_year(y)
    return (y % 4 == 0) and (y % 100 ~= 0 or y % 400 == 0)
end

local function days_in_month(y, m)
    if m == 2 and is_leap_year(y) then return 29 end
    return DAYS_IN_MONTH[m] or 0
end

local function ymd_to_days(y, m, d)
    local yr = m <= 2 and (y - 1) or y
    local era = math.floor((yr >= 0 and yr or (yr - 399)) / 400)
    local yoe = yr - era * 400
    local mp = m > 2 and (m - 3) or (m + 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function days_to_ymd(z)
    z = z + 719468
    local era = math.floor((z >= 0 and z or (z - 146096)) / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and (mp + 3) or (mp - 9)
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function parse_date(s)
    if type(s) ~= 'string' then return nil end
    s = trim(s)
    local y, m, d, fmt
    local y4, m2, d2 = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if y4 then
        y, m, d = tonumber(y4), tonumber(m2), tonumber(d2)
        fmt = 'YYYY-MM-DD'
    else
        local yy, mm, dd = s:match('^(%d%d)/(%d%d)/(%d%d)$')
        if yy then
            local yn = tonumber(yy)
            y = yn < 70 and (2000 + yn) or (1900 + yn)
            m, d = tonumber(mm), tonumber(dd)
            fmt = 'YY/MM/DD'
        end
    end
    if not y or m < 1 or m > 12 or d < 1 or d > days_in_month(y, m) then
        return nil
    end
    return { y = y, m = m, d = d, days = ymd_to_days(y, m, d), fmt = fmt }
end

local function format_date(days, fmt)
    local y, m, d = days_to_ymd(days)
    if fmt == 'YY/MM/DD' then
        return string.format('%02d/%02d/%02d', y % 100, m, d)
    end
    return string.format('%04d-%02d-%02d', y, m, d)
end

-- =============================================================================
-- Supported SQL functions
-- =============================================================================

M.FUNCTIONS = {
    'COALESCE', 'NULLIF', 'ZEROIFNULL', 'NULLIFZERO',
    'ABS', 'ROUND', 'TRUNC', 'CEILING', 'CEIL', 'FLOOR',
    'SQRT', 'LN', 'EXP', 'POWER', 'POW', 'LEAST', 'GREATEST',
    'UPPER', 'LOWER', 'TRIM', 'LENGTH', 'CHARACTER_LENGTH', 'CHAR_LENGTH', 'CHARS',
    'SUBSTR', 'SUBSTRING', 'INDEX', 'POSITION', 'OREPLACE', 'EXTRACT',
}

local SUPPORTED_FN = {}
for _, name in ipairs(M.FUNCTIONS) do
    SUPPORTED_FN[name] = true
end

-- =============================================================================
-- Tree-sitter -> AST conversion
-- =============================================================================

local function node_text(node, src)
    if not node then return '' end
    return vim.treesitter.get_node_text(node, src) or ''
end

local function has_subquery(node)
    if node:type() == 'subquery' then return true end
    for child in node:iter_children() do
        if child:named() and has_subquery(child) then return true end
    end
    return false
end

local function decimal_places_of_literal(txt)
    local frac = txt:match('%.(%d+)$')
    return frac and #frac or 0
end

local function apply_unary_neg(ast)
    -- In tree-sitter-teradata, unary_expression has lower precedence than
    -- binary_expression, so `-a + b` parses as `-(a + b)`. Push unary `-`
    -- down into the leftmost operand of unparenthesized binary expressions.
    if ast.k == 'bin' and not ast.paren then
        ast.l = apply_unary_neg(ast.l)
        return ast
    end
    return { k = 'neg', e = ast }
end

local build_ast

local function unwrap_term(node, src)
    if node:type() == 'term' then
        local v = node:field('value')[1] or node:named_child(0)
        if not v then return nil, 'empty term' end
        return build_ast(v, src)
    end
    return build_ast(node, src)
end

local function convert_literal(node, src)
    for child in node:iter_children() do
        local ct = child:type()
        if ct == 'keyword_null' then
            return { k = 'null' }
        elseif ct == 'keyword_true' then
            return { k = 'bool', v = true }
        elseif ct == 'keyword_false' then
            return { k = 'bool', v = false }
        end
    end

    local txt = trim(node_text(node, src))
    local d_lit = txt:match('^[dD][aA][tT][eE]%s+\'([^\']*)\'$')
    if d_lit then
        return { k = 'str', v = d_lit:gsub("''", "'") }
    end
    if txt:match('^".*"$') then
        local name = txt:sub(2, -2):gsub('""', '"')
        return { k = 'col', name = name, quoted = true }
    end
    if txt:match("^'.*'$") then
        local s = txt:sub(2, -2):gsub("''", "'")
        return { k = 'str', v = s }
    end
    local n = tonumber(txt)
    if n ~= nil then
        return { k = 'num', v = n, dec = decimal_places_of_literal(txt) }
    end
    return nil, 'invalid literal: ' .. txt
end

local function convert_field(node, src)
    local name_node = node:field('name')[1]
    if not name_node then
        local count = node:named_child_count()
        if count > 0 then name_node = node:named_child(count - 1) end
    end
    if not name_node then return nil, 'invalid column reference' end
    local raw = trim(node_text(name_node, src))
    if raw:match('^".*"$') then
        return { k = 'col', name = raw:sub(2, -2):gsub('""', '"'), quoted = true }
    end
    return { k = 'col', name = raw:upper(), quoted = false }
end

local function convert_binary(node, src)
    local left_node  = node:field('left')[1]
    local right_node = node:field('right')[1]
    local op_node    = node:field('operator')[1]

    if not left_node or not right_node then
        return nil, 'malformed binary expression'
    end

    local l_ast, l_err = build_ast(left_node, src)
    if not l_ast then return nil, l_err end

    local op
    if op_node then
        local ot = op_node:type()
        if ot == 'keyword_and' then op = 'AND'
        elseif ot == 'keyword_or' then op = 'OR'
        elseif ot == 'keyword_mod' then op = 'MOD'
        elseif ot == 'keyword_is' then op = 'IS'
        elseif ot == 'is_not' then op = 'IS NOT'
        elseif ot == 'keyword_in' then op = 'IN'
        elseif ot == 'not_in' then op = 'NOT IN'
        elseif ot == 'keyword_like' then op = 'LIKE'
        elseif ot == 'not_like' then op = 'NOT LIKE'
        else
            op = trim(node_text(op_node, src)):upper()
        end
    else
        for child in node:iter_children() do
            if not child:named() then
                local t = trim(node_text(child, src))
                if t ~= '' then
                    op = t:upper()
                    break
                end
            end
        end
    end

    if not op then
        return nil, 'unknown binary operator'
    end

    if op == 'IN' or op == 'NOT IN' then
        if right_node:type() ~= 'list' then
            return nil, 'expected value list after ' .. op
        end
        local items = {}
        for child in right_node:iter_children() do
            if child:named() then
                local item_ast, err = unwrap_term(child, src)
                if not item_ast then return nil, err end
                items[#items + 1] = item_ast
            end
        end
        return { k = 'in', e = l_ast, list = items, negated = (op == 'NOT IN') }
    end

    local r_ast, r_err = build_ast(right_node, src)
    if not r_ast then return nil, r_err end

    if op == 'IS' or op == 'IS NOT' then
        if r_ast.k == 'null' then
            return { k = 'isnull', e = l_ast, negated = (op == 'IS NOT') }
        end
        return nil, 'unsupported IS predicate'
    end

    if op == '==' then op = '=' end
    return { k = 'bin', op = op, l = l_ast, r = r_ast }
end

local function convert_between(node, src)
    local left_node = node:field('left')[1]
    local low_node  = node:field('low')[1]
    local high_node = node:field('high')[1]
    if not (left_node and low_node and high_node) then
        return nil, 'malformed BETWEEN expression'
    end
    local e_ast, err1 = build_ast(left_node, src)
    if not e_ast then return nil, err1 end
    local low_ast, err2 = build_ast(low_node, src)
    if not low_ast then return nil, err2 end
    local high_ast, err3 = build_ast(high_node, src)
    if not high_ast then return nil, err3 end

    local negated = false
    for child in node:iter_children() do
        if child:type() == 'keyword_not' then
            negated = true
            break
        end
    end
    return { k = 'between', e = e_ast, low = low_ast, high = high_ast, negated = negated }
end

local function convert_case(node, src)
    local children = {}
    for child in node:iter_children() do
        if child:named() then children[#children + 1] = child end
    end

    local idx = 1
    if children[idx] and children[idx]:type() == 'keyword_case' then
        idx = idx + 1
    end

    local subject_ast = nil
    if children[idx] and children[idx]:type() ~= 'keyword_when' then
        local s_err
        subject_ast, s_err = unwrap_term(children[idx], src)
        if not subject_ast then return nil, s_err end
        idx = idx + 1
    end

    local whens = {}
    local else_ast = nil

    while idx <= #children do
        local ct = children[idx]:type()
        if ct == 'keyword_when' then
            local cond_node = children[idx + 1]
            local then_kw   = children[idx + 2]
            local val_node  = children[idx + 3]
            if not (cond_node and then_kw and then_kw:type() == 'keyword_then' and val_node) then
                return nil, 'malformed CASE WHEN clause'
            end
            local cond_ast, cerr = unwrap_term(cond_node, src)
            if not cond_ast then return nil, cerr end
            if subject_ast then
                cond_ast = { k = 'bin', op = '=', l = subject_ast, r = cond_ast }
            end
            local val_ast, verr = unwrap_term(val_node, src)
            if not val_ast then return nil, verr end
            whens[#whens + 1] = { cond = cond_ast, val = val_ast }
            idx = idx + 4
        elseif ct == 'keyword_else' then
            local else_node = children[idx + 1]
            if not else_node then return nil, 'malformed CASE ELSE clause' end
            local eerr
            else_ast, eerr = unwrap_term(else_node, src)
            if not else_ast then return nil, eerr end
            idx = idx + 2
        elseif ct == 'keyword_end' then
            break
        else
            return nil, 'unexpected node in CASE: ' .. ct
        end
    end

    if #whens == 0 then
        return nil, 'CASE expression requires at least one WHEN branch'
    end
    return { k = 'case', whens = whens, else_ = else_ast }
end

local function convert_cast(node, src)
    local param = node:field('parameter')[1]
    if not param then return nil, 'malformed CAST expression' end
    local e_ast, err = unwrap_term(param, src)
    if not e_ast then return nil, err end

    local type_node = nil
    local seen_as = false
    for child in node:iter_children() do
        if child:type() == 'keyword_as' then
            seen_as = true
        elseif seen_as and child:named() then
            type_node = child
            break
        end
    end
    if not type_node then return nil, 'missing target type in CAST' end

    local tt = type_node:type()
    local type_spec
    if tt == 'int' or tt == 'bigint' or tt == 'smallint' or tt == 'byteint'
        or tt == 'keyword_int' or tt == 'keyword_integer'
        or tt == 'keyword_bigint' or tt == 'keyword_smallint' or tt == 'keyword_byteint' then
        type_spec = { kind = 'INTEGER' }
    elseif tt == 'decimal' then
        local p_node = type_node:field('precision')[1]
        local s_node = type_node:field('scale')[1]
        local p = p_node and tonumber(node_text(p_node, src)) or 18
        local s = s_node and tonumber(node_text(s_node, src)) or 0
        type_spec = { kind = 'DECIMAL', p = p, s = s }
    elseif tt == 'varchar' or tt == 'char' then
        local sz_node = type_node:field('size')[1]
        local n = sz_node and tonumber(node_text(sz_node, src)) or nil
        type_spec = { kind = 'VARCHAR', n = n }
    elseif tt == 'keyword_date' then
        type_spec = { kind = 'DATE' }
    elseif tt == 'float' or tt == 'double' or tt == 'real'
        or tt == 'keyword_float' or tt == 'keyword_real' or tt == 'keyword_double' then
        type_spec = { kind = 'FLOAT' }
    else
        return nil, 'unsupported CAST type: ' .. node_text(type_node, src)
    end

    return { k = 'cast', e = e_ast, type = type_spec }
end

local function convert_invocation(node, src)
    local fn_node = nil
    for child in node:iter_children() do
        if child:type() == 'object_reference' then
            fn_node = child
            break
        end
    end
    if not fn_node then return nil, 'malformed function call' end
    local fn_name = trim(node_text(fn_node, src)):upper()
    if not SUPPORTED_FN[fn_name] then
        return nil, 'unsupported function: ' .. fn_name
    end

    -- Special syntactic forms: EXTRACT, SUBSTRING(... FROM ...), POSITION(... IN ...), TRIM(... FROM ...)
    if fn_name == 'EXTRACT' then
        local unit_node = node:field('unit')[1]
        if not unit_node then return nil, 'EXTRACT requires YEAR, MONTH or DAY' end
        local unit = trim(node_text(unit_node, src)):upper()
        if unit ~= 'YEAR' and unit ~= 'MONTH' and unit ~= 'DAY' then
            return nil, 'unsupported EXTRACT unit: ' .. unit
        end
        local target_node = nil
        local seen_from = false
        for child in node:iter_children() do
            if child:type() == 'keyword_from' then
                seen_from = true
            elseif seen_from and child:named() then
                target_node = child
                break
            end
        end
        if not target_node then return nil, 'malformed EXTRACT expression' end
        local d_ast, err = unwrap_term(target_node, src)
        if not d_ast then return nil, err end
        return { k = 'call', fn = 'EXTRACT', args = { { k = 'str', v = unit }, d_ast } }
    end

    if fn_name == 'SUBSTRING' or fn_name == 'SUBSTR' then
        local expr_field = node:field('expression')[1]
        local from_field = node:field('from')[1]
        local for_field  = node:field('for')[1]
        if expr_field and from_field then
            local e_ast, err1 = unwrap_term(expr_field, src)
            if not e_ast then return nil, err1 end
            local f_ast, err2 = unwrap_term(from_field, src)
            if not f_ast then return nil, err2 end
            local args = { e_ast, f_ast }
            if for_field then
                local l_ast, err3 = unwrap_term(for_field, src)
                if not l_ast then return nil, err3 end
                args[3] = l_ast
            end
            return { k = 'call', fn = 'SUBSTR', args = args }
        end
        -- `SUBSTRING(x FROM 2)` without FOR parses via the `unit` + `keyword_from` + `term` branch
        local unit_node = node:field('unit')[1]
        if unit_node then
            local raw_u = trim(node_text(unit_node, src))
            local x_ast
            if raw_u:match('^".*"$') then
                x_ast = { k = 'col', name = raw_u:sub(2, -2):gsub('""', '"'), quoted = true }
            else
                x_ast = { k = 'col', name = raw_u:upper(), quoted = false }
            end
            local from_term = nil
            local seen_from = false
            for child in node:iter_children() do
                if child:type() == 'keyword_from' then
                    seen_from = true
                elseif seen_from and child:named() then
                    from_term = child
                    break
                end
            end
            if not from_term then return nil, 'malformed SUBSTRING expression' end
            local f_ast, ferr = unwrap_term(from_term, src)
            if not f_ast then return nil, ferr end
            return { k = 'call', fn = 'SUBSTR', args = { x_ast, f_ast } }
        end
    end

    if fn_name == 'POSITION' then
        local exprs = node:field('expression')
        if exprs and #exprs == 2 then
            local needle, err1 = unwrap_term(exprs[1], src)
            if not needle then return nil, err1 end
            local hay, err2 = unwrap_term(exprs[2], src)
            if not hay then return nil, err2 end
            return { k = 'call', fn = 'POSITION', args = { needle, hay } }
        end
    end

    if fn_name == 'TRIM' then
        local has_from = false
        local mode = 'BOTH'
        local before_from = {}
        local after_from = nil
        for child in node:iter_children() do
            if child:named() and child ~= fn_node then
                local ct = child:type()
                if ct == 'keyword_both' then
                    mode = 'BOTH'
                elseif ct == 'keyword_leading' then
                    mode = 'LEADING'
                elseif ct == 'keyword_trailing' then
                    mode = 'TRAILING'
                elseif ct == 'keyword_from' then
                    has_from = true
                elseif not has_from then
                    before_from[#before_from + 1] = child
                else
                    after_from = child
                end
            end
        end
        if has_from and after_from then
            local target_ast, err1 = unwrap_term(after_from, src)
            if not target_ast then return nil, err1 end
            local char_ast = { k = 'str', v = ' ' }
            if #before_from > 0 then
                local cerr
                char_ast, cerr = unwrap_term(before_from[1], src)
                if not char_ast then return nil, cerr end
            end
            return { k = 'call', fn = 'TRIM', args = { target_ast, char_ast, { k = 'str', v = mode } } }
        end
    end

    -- Standard comma-separated parameter list
    local params = node:field('parameter')
    local args = {}
    for _, p in ipairs(params or {}) do
        local a_ast, err = unwrap_term(p, src)
        if not a_ast then return nil, err end
        args[#args + 1] = a_ast
    end
    return { k = 'call', fn = fn_name, args = args }
end

build_ast = function(node, src)
    if not node then return nil, 'empty expression node' end
    local t = node:type()

    if t == 'parenthesized_expression' then
        for child in node:iter_children() do
            if child:named() then
                local inner, err = unwrap_term(child, src)
                if not inner then return nil, err end
                inner.paren = true
                return inner
            end
        end
        return nil, 'empty parenthesized expression'
    elseif t == 'literal' then
        return convert_literal(node, src)
    elseif t == 'keyword_null' then
        return { k = 'null' }
    elseif t == 'keyword_true' then
        return { k = 'bool', v = true }
    elseif t == 'keyword_false' then
        return { k = 'bool', v = false }
    elseif t == 'field' then
        return convert_field(node, src)
    elseif t == 'unary_expression' then
        local operand = node:field('operand')[1]
        if not operand then return nil, 'malformed unary expression' end
        local inner, err = build_ast(operand, src)
        if not inner then return nil, err end
        local op_node = node:field('operator')[1]
        if op_node and op_node:type() == 'keyword_not' then
            return { k = 'not', e = inner }
        end
        local sign = '+'
        for child in node:iter_children() do
            if not child:named() then
                local s = trim(node_text(child, src))
                if s == '-' or s == '+' then sign = s break end
            end
        end
        if sign == '-' then
            return apply_unary_neg(inner)
        end
        return inner
    elseif t == 'binary_expression' then
        return convert_binary(node, src)
    elseif t == 'between_expression' then
        return convert_between(node, src)
    elseif t == 'case' then
        return convert_case(node, src)
    elseif t == 'cast' then
        return convert_cast(node, src)
    elseif t == 'invocation' then
        return convert_invocation(node, src)
    end

    return nil, 'unsupported construct: ' .. t
end

--- Parses `expr` (Teradata SQL scalar expression) into an AST.
--- @param expr string
--- @return table|nil ast, string|nil err
function M.parse(expr)
    if type(expr) ~= 'string' or not expr:match('%S') then
        return nil, 'empty expression'
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

    if root:named_child_count() ~= 1 or root:named_child(0):type() ~= 'statement' then
        return nil, 'expected a single scalar expression'
    end

    local stmt = root:named_child(0)
    if stmt:named_child_count() ~= 2 then
        return nil, 'expected a single scalar expression'
    end

    local sel_node  = stmt:named_child(0)
    local from_node = stmt:named_child(1)
    if sel_node:type() ~= 'select' or from_node:type() ~= 'from' then
        return nil, 'expected a single scalar expression'
    end
    if trim(node_text(from_node, src)) ~= 'FROM __vt__' then
        return nil, 'syntax error in expression'
    end

    local sel_expr = nil
    for child in sel_node:iter_children() do
        if child:named() then
            if child:type() == 'select_expression' then
                sel_expr = child
            elseif child:type() ~= 'keyword_select' then
                return nil, 'unsupported select modifier in expression'
            end
        end
    end
    if not sel_expr or sel_expr:named_child_count() ~= 1 then
        return nil, 'expected a single scalar expression (multiple terms found)'
    end

    local term = sel_expr:named_child(0)
    if term:type() ~= 'term' or #term:field('alias') > 0 then
        return nil, 'syntax error in expression'
    end

    local _, _, term_end = term:end_()
    if term_end > #prefix then
        return nil, 'incomplete expression'
    end

    if has_subquery(term) then
        return nil, 'subqueries are not supported in virtual columns'
    end

    local val_node = term:field('value')[1] or term:named_child(0)
    local ast, err = build_ast(val_node, src)
    if not ast then return nil, err end
    ast.src = expr
    return ast, nil
end

--- Column names referenced by the AST (upper-cased when unquoted, exact when quoted).
--- Also accepts a raw expression string for convenience.
--- @param ast table|string
--- @return string[]
function M.references(ast)
    if type(ast) == 'string' then
        local parsed = M.parse(ast)
        if not parsed then return {} end
        ast = parsed
    end
    if type(ast) ~= 'table' then return {} end

    local refs, seen = {}, {}
    local function walk(n)
        if type(n) ~= 'table' then return end
        if n.k == 'col' then
            local key = n.quoted and n.name or n.name:upper()
            if not seen[key] then
                seen[key] = true
                refs[#refs + 1] = key
            end
        elseif n.k == 'bin' then
            walk(n.l)
            walk(n.r)
        elseif n.k == 'neg' or n.k == 'not' or n.k == 'isnull' or n.k == 'cast' then
            walk(n.e)
        elseif n.k == 'between' then
            walk(n.e)
            walk(n.low)
            walk(n.high)
        elseif n.k == 'in' then
            walk(n.e)
            for _, item in ipairs(n.list or {}) do walk(item) end
        elseif n.k == 'call' then
            for _, a in ipairs(n.args or {}) do walk(a) end
        elseif n.k == 'case' then
            for _, w in ipairs(n.whens or {}) do
                walk(w.cond)
                walk(w.val)
            end
            if n.else_ then walk(n.else_) end
        end
    end
    walk(ast)
    return refs
end

-- =============================================================================
-- Evaluator
-- =============================================================================

local function to_num(v)
    if type(v) == 'number' then return v end
    if type(v) == 'string' then return virtual.to_number(v) end
    return nil
end

local function val_to_string(v, dec)
    if v == nil then return nil end
    if type(v) == 'number' then
        return virtual.format_number(v, dec)
    end
    if type(v) == 'boolean' then
        return v and '1' or '0'
    end
    return tostring(v)
end

local function round_to(n, s)
    s = s or 0
    local factor = 10 ^ s
    if n >= 0 then
        return math.floor(n * factor + 0.5) / factor
    else
        return -math.floor(-n * factor + 0.5) / factor
    end
end

local function trunc_to(n, s)
    s = s or 0
    local factor = 10 ^ s
    if n >= 0 then
        return math.floor(n * factor) / factor
    else
        return math.ceil(n * factor) / factor
    end
end

local function sql_like_to_pattern(pat)
    local out = { '^' }
    for i = 1, #pat do
        local c = pat:sub(i, i)
        if c == '%' then
            out[#out + 1] = '.*'
        elseif c == '_' then
            out[#out + 1] = '.'
        elseif c:find('[%^%$%(%)%%%.%[%]%*%+%-%?]') then
            out[#out + 1] = '%' .. c
        else
            out[#out + 1] = c
        end
    end
    out[#out + 1] = '$'
    return table.concat(out)
end

local function compare_values(a, b)
    local na, nb = to_num(a), to_num(b)
    if na ~= nil and nb ~= nil then
        if na == nb then return 0 end
        return na < nb and -1 or 1
    end
    local sa, sb = tostring(a), tostring(b)
    if sa == sb then return 0 end
    return sa < sb and -1 or 1
end

local eval_node

local FN_DISPATCH = {
    COALESCE = function(args, lookup)
        for _, a in ipairs(args) do
            local v, dec, err = eval_node(a, lookup)
            if err then return nil, nil, err end
            if v ~= nil then return v, dec, nil end
        end
        return nil, nil, nil
    end,

    NULLIF = function(args, lookup)
        if #args ~= 2 then return nil, nil, 'NULLIF requires 2 arguments' end
        local a, dec_a, err1 = eval_node(args[1], lookup)
        if err1 then return nil, nil, err1 end
        local b, _, err2 = eval_node(args[2], lookup)
        if err2 then return nil, nil, err2 end
        if a == nil then return nil, nil, nil end
        if b ~= nil and compare_values(a, b) == 0 then
            return nil, nil, nil
        end
        return a, dec_a, nil
    end,

    ZEROIFNULL = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'ZEROIFNULL requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err then return nil, nil, err end
        if v == nil then return 0, 0, nil end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for ZEROIFNULL' end
        return n, dec or 0, nil
    end,

    NULLIFZERO = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'NULLIFZERO requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err then return nil, nil, err end
        if v == nil then return nil, nil, nil end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for NULLIFZERO' end
        if n == 0 then return nil, nil, nil end
        return n, dec or 0, nil
    end,

    ABS = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'ABS requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for ABS' end
        return math.abs(n), dec or 0, nil
    end,

    ROUND = function(args, lookup)
        if #args < 1 or #args > 2 then return nil, nil, 'ROUND requires 1 or 2 arguments' end
        local v, _, err1 = eval_node(args[1], lookup)
        if err1 or v == nil then return nil, nil, err1 end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for ROUND' end
        local s = 0
        if args[2] then
            local sv, _, err2 = eval_node(args[2], lookup)
            if err2 or sv == nil then return nil, nil, err2 end
            s = math.floor(to_num(sv) or 0)
        end
        local r = round_to(n, s)
        if s > 0 then
            return { fixed_dec = s, num = r }, s, nil
        end
        return r, 0, nil
    end,

    TRUNC = function(args, lookup)
        if #args < 1 or #args > 2 then return nil, nil, 'TRUNC requires 1 or 2 arguments' end
        local v, _, err1 = eval_node(args[1], lookup)
        if err1 or v == nil then return nil, nil, err1 end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for TRUNC' end
        local s = 0
        if args[2] then
            local sv, _, err2 = eval_node(args[2], lookup)
            if err2 or sv == nil then return nil, nil, err2 end
            s = math.floor(to_num(sv) or 0)
        end
        return trunc_to(n, s), math.max(0, s), nil
    end,

    CEILING = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'CEILING requires 1 argument' end
        local v, _, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for CEILING' end
        return math.ceil(n), 0, nil
    end,

    FLOOR = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'FLOOR requires 1 argument' end
        local v, _, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for FLOOR' end
        return math.floor(n), 0, nil
    end,

    SQRT = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'SQRT requires 1 argument' end
        local v, _, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil or n < 0 then return nil, nil, 'invalid argument for SQRT' end
        return math.sqrt(n), 4, nil
    end,

    LN = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'LN requires 1 argument' end
        local v, _, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil or n <= 0 then return nil, nil, 'invalid argument for LN' end
        return math.log(n), 4, nil
    end,

    EXP = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'EXP requires 1 argument' end
        local v, _, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric argument required for EXP' end
        return math.exp(n), 4, nil
    end,

    POWER = function(args, lookup)
        if #args ~= 2 then return nil, nil, 'POWER requires 2 arguments' end
        local b, dec_b, err1 = eval_node(args[1], lookup)
        if err1 or b == nil then return nil, nil, err1 end
        local e, _, err2 = eval_node(args[2], lookup)
        if err2 or e == nil then return nil, nil, err2 end
        local nb, ne = to_num(b), to_num(e)
        if nb == nil or ne == nil then return nil, nil, 'numeric arguments required for POWER' end
        return nb ^ ne, math.max(dec_b or 0, 4), nil
    end,

    LEAST = function(args, lookup)
        if #args == 0 then return nil, nil, 'LEAST requires arguments' end
        local best, best_dec = nil, 0
        for _, a in ipairs(args) do
            local v, dec, err = eval_node(a, lookup)
            if err or v == nil then return nil, nil, err end
            if best == nil or compare_values(v, best) < 0 then
                best, best_dec = v, dec or 0
            end
        end
        return best, best_dec, nil
    end,

    GREATEST = function(args, lookup)
        if #args == 0 then return nil, nil, 'GREATEST requires arguments' end
        local best, best_dec = nil, 0
        for _, a in ipairs(args) do
            local v, dec, err = eval_node(a, lookup)
            if err or v == nil then return nil, nil, err end
            if best == nil or compare_values(v, best) > 0 then
                best, best_dec = v, dec or 0
            end
        end
        return best, best_dec, nil
    end,

    UPPER = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'UPPER requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        return val_to_string(v, dec):upper(), 0, nil
    end,

    LOWER = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'LOWER requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        return val_to_string(v, dec):lower(), 0, nil
    end,

    TRIM = function(args, lookup)
        if #args < 1 then return nil, nil, 'TRIM requires at least 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        local s = val_to_string(v, dec)
        local ch = ' '
        if args[2] then
            local cv, cdec, cerr = eval_node(args[2], lookup)
            if cerr or cv == nil then return nil, nil, cerr end
            ch = val_to_string(cv, cdec)
        end
        local mode = 'BOTH'
        if args[3] then
            local mv, mdec, merr = eval_node(args[3], lookup)
            if merr or mv == nil then return nil, nil, merr end
            mode = val_to_string(mv, mdec):upper()
        end
        if ch == '' then return s, 0, nil end
        local esc = ch:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%1')
        if mode == 'BOTH' or mode == 'LEADING' then
            s = s:gsub('^(' .. esc .. ')+', '')
        end
        if mode == 'BOTH' or mode == 'TRAILING' then
            s = s:gsub('(' .. esc .. ')+$', '')
        end
        return s, 0, nil
    end,

    LENGTH = function(args, lookup)
        if #args ~= 1 then return nil, nil, 'LENGTH requires 1 argument' end
        local v, dec, err = eval_node(args[1], lookup)
        if err or v == nil then return nil, nil, err end
        return vim.fn.strchars(val_to_string(v, dec)), 0, nil
    end,

    SUBSTR = function(args, lookup)
        if #args < 2 or #args > 3 then return nil, nil, 'SUBSTR requires 2 or 3 arguments' end
        local sv, sdec, err1 = eval_node(args[1], lookup)
        if err1 or sv == nil then return nil, nil, err1 end
        local start_v, _, err2 = eval_node(args[2], lookup)
        if err2 or start_v == nil then return nil, nil, err2 end
        local start_idx = math.floor(to_num(start_v) or 1)
        local s = val_to_string(sv, sdec)
        local total = vim.fn.strchars(s)
        local len = total
        if args[3] then
            local len_v, _, err3 = eval_node(args[3], lookup)
            if err3 or len_v == nil then return nil, nil, err3 end
            len = math.floor(to_num(len_v) or 0)
        end
        if start_idx < 1 then
            len = len + start_idx - 1
            start_idx = 1
        end
        if len <= 0 or start_idx > total then return '', 0, nil end
        return vim.fn.strcharpart(s, start_idx - 1, len), 0, nil
    end,

    INDEX = function(args, lookup)
        if #args ~= 2 then return nil, nil, 'INDEX requires 2 arguments' end
        local hay, hdec, err1 = eval_node(args[1], lookup)
        if err1 or hay == nil then return nil, nil, err1 end
        local needle, ndec, err2 = eval_node(args[2], lookup)
        if err2 or needle == nil then return nil, nil, err2 end
        local hs, ns = val_to_string(hay, hdec), val_to_string(needle, ndec)
        if ns == '' then return 1, 0, nil end
        local pos = hs:find(ns, 1, true)
        return pos or 0, 0, nil
    end,

    POSITION = function(args, lookup)
        if #args ~= 2 then return nil, nil, 'POSITION requires 2 arguments' end
        local needle, ndec, err1 = eval_node(args[1], lookup)
        if err1 or needle == nil then return nil, nil, err1 end
        local hay, hdec, err2 = eval_node(args[2], lookup)
        if err2 or hay == nil then return nil, nil, err2 end
        local hs, ns = val_to_string(hay, hdec), val_to_string(needle, ndec)
        if ns == '' then return 1, 0, nil end
        local pos = hs:find(ns, 1, true)
        return pos or 0, 0, nil
    end,

    OREPLACE = function(args, lookup)
        if #args < 2 or #args > 3 then return nil, nil, 'OREPLACE requires 2 or 3 arguments' end
        local sv, sdec, err1 = eval_node(args[1], lookup)
        if err1 or sv == nil then return nil, nil, err1 end
        local search_v, fdec, err2 = eval_node(args[2], lookup)
        if err2 or search_v == nil then return nil, nil, err2 end
        local repl = ''
        if args[3] then
            local rv, rdec, err3 = eval_node(args[3], lookup)
            if err3 or rv == nil then return nil, nil, err3 end
            repl = val_to_string(rv, rdec)
        end
        local s = val_to_string(sv, sdec)
        local pat = val_to_string(search_v, fdec)
        if pat == '' then return s, 0, nil end
        local esc_pat = pat:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%1')
        local esc_rep = repl:gsub('%%', '%%%%')
        return (s:gsub(esc_pat, esc_rep)), 0, nil
    end,

    EXTRACT = function(args, lookup)
        if #args ~= 2 then return nil, nil, 'EXTRACT requires unit and date' end
        local unit_v, _, err1 = eval_node(args[1], lookup)
        if err1 or unit_v == nil then return nil, nil, err1 end
        local dv, ddec, err2 = eval_node(args[2], lookup)
        if err2 or dv == nil then return nil, nil, err2 end
        local dt = parse_date(val_to_string(dv, ddec))
        if not dt then return nil, nil, 'invalid date for EXTRACT' end
        local u = tostring(unit_v):upper()
        if u == 'YEAR' then return dt.y, 0, nil end
        if u == 'MONTH' then return dt.m, 0, nil end
        if u == 'DAY' then return dt.d, 0, nil end
        return nil, nil, 'unsupported EXTRACT unit: ' .. u
    end,
}

FN_DISPATCH.CEIL             = FN_DISPATCH.CEILING
FN_DISPATCH.POW              = FN_DISPATCH.POWER
FN_DISPATCH.CHARACTER_LENGTH = FN_DISPATCH.LENGTH
FN_DISPATCH.CHAR_LENGTH      = FN_DISPATCH.LENGTH
FN_DISPATCH.CHARS            = FN_DISPATCH.LENGTH
FN_DISPATCH.SUBSTRING        = FN_DISPATCH.SUBSTR

local function unwrap_fixed(v)
    if type(v) == 'table' and v.fixed_dec ~= nil then
        return v.num, v.fixed_dec
    end
    return v, nil
end

eval_node = function(node, lookup)
    local k = node.k
    if k == 'null' then
        return nil, 0, nil
    elseif k == 'num' then
        return node.v, node.dec or 0, nil
    elseif k == 'str' then
        return node.v, 0, nil
    elseif k == 'bool' then
        return node.v, 0, nil
    elseif k == 'col' then
        local raw = lookup(node.name, node.quoted)
        if raw == nil then return nil, 0, nil end
        local trimmed = type(raw) == 'string' and trim(raw) or tostring(raw)
        if trimmed == '' or trimmed == null_token() then
            return nil, 0, nil
        end
        local n = virtual.to_number(trimmed)
        if n ~= nil then
            return n, decimal_places_of_literal(trimmed), nil
        end
        return trimmed, 0, nil
    elseif k == 'neg' then
        local v, dec, err = eval_node(node.e, lookup)
        v = unwrap_fixed(v)
        if err or v == nil then return nil, nil, err end
        local n = to_num(v)
        if n == nil then return nil, nil, 'numeric operand required for unary -' end
        return -n, dec or 0, nil
    elseif k == 'not' then
        local v, _, err = eval_node(node.e, lookup)
        if err or v == nil then return nil, nil, err end
        return not v, 0, nil
    elseif k == 'isnull' then
        local v, _, err = eval_node(node.e, lookup)
        if err then return nil, nil, err end
        local is_null = (v == nil)
        return node.negated and (not is_null) or is_null, 0, nil
    elseif k == 'between' then
        local v, _, err1 = eval_node(node.e, lookup)
        if err1 then return nil, nil, err1 end
        local low, _, err2 = eval_node(node.low, lookup)
        if err2 then return nil, nil, err2 end
        local high, _, err3 = eval_node(node.high, lookup)
        if err3 then return nil, nil, err3 end
        v, low, high = unwrap_fixed(v), unwrap_fixed(low), unwrap_fixed(high)
        if v == nil or low == nil or high == nil then return nil, 0, nil end
        local inside = compare_values(v, low) >= 0 and compare_values(v, high) <= 0
        return node.negated and (not inside) or inside, 0, nil
    elseif k == 'in' then
        local v, _, err = eval_node(node.e, lookup)
        if err then return nil, nil, err end
        v = unwrap_fixed(v)
        if v == nil then return nil, 0, nil end
        local has_null = false
        for _, item in ipairs(node.list or {}) do
            local iv, _, ierr = eval_node(item, lookup)
            if ierr then return nil, nil, ierr end
            iv = unwrap_fixed(iv)
            if iv == nil then
                has_null = true
            elseif compare_values(v, iv) == 0 then
                return not node.negated, 0, nil
            end
        end
        if has_null then return nil, 0, nil end
        return node.negated and true or false, 0, nil
    elseif k == 'case' then
        for _, w in ipairs(node.whens or {}) do
            local cond, _, cerr = eval_node(w.cond, lookup)
            if cerr then return nil, nil, cerr end
            if cond == true then
                return eval_node(w.val, lookup)
            end
        end
        if node.else_ then
            return eval_node(node.else_, lookup)
        end
        return nil, 0, nil
    elseif k == 'cast' then
        local v, dec, err = eval_node(node.e, lookup)
        if err or v == nil then return nil, nil, err end
        v = unwrap_fixed(v)
        local t = node.type
        if t.kind == 'INTEGER' then
            local n = to_num(v)
            if n == nil then return nil, nil, 'cannot CAST non-numeric value to INTEGER' end
            return trunc_to(n, 0), 0, nil
        elseif t.kind == 'DECIMAL' then
            local n = to_num(v)
            if n == nil then return nil, nil, 'cannot CAST non-numeric value to DECIMAL' end
            local r = round_to(n, t.s)
            return { fixed_dec = t.s, num = r }, t.s, nil
        elseif t.kind == 'FLOAT' then
            local n = to_num(v)
            if n == nil then return nil, nil, 'cannot CAST non-numeric value to FLOAT' end
            return n, math.max(dec or 0, 4), nil
        elseif t.kind == 'VARCHAR' then
            local s = val_to_string(v, dec)
            if t.n and vim.fn.strchars(s) > t.n then
                s = vim.fn.strcharpart(s, 0, t.n)
            end
            return s, 0, nil
        elseif t.kind == 'DATE' then
            local dt = parse_date(val_to_string(v, dec))
            if not dt then return nil, nil, 'cannot CAST value to DATE' end
            return format_date(dt.days, dt.fmt), 0, nil
        end
        return nil, nil, 'unsupported CAST target'
    elseif k == 'call' then
        local fn = FN_DISPATCH[node.fn]
        if not fn then return nil, nil, 'unsupported function: ' .. tostring(node.fn) end
        return fn(node.args or {}, lookup)
    elseif k == 'bin' then
        local op = node.op
        if op == 'AND' then
            local l, _, err1 = eval_node(node.l, lookup)
            if err1 then return nil, nil, err1 end
            if l == false then return false, 0, nil end
            local r, _, err2 = eval_node(node.r, lookup)
            if err2 then return nil, nil, err2 end
            if r == false then return false, 0, nil end
            if l == true and r == true then return true, 0, nil end
            return nil, 0, nil
        elseif op == 'OR' then
            local l, _, err1 = eval_node(node.l, lookup)
            if err1 then return nil, nil, err1 end
            if l == true then return true, 0, nil end
            local r, _, err2 = eval_node(node.r, lookup)
            if err2 then return nil, nil, err2 end
            if r == true then return true, 0, nil end
            if l == false and r == false then return false, 0, nil end
            return nil, 0, nil
        end

        local l, dec_l, err1 = eval_node(node.l, lookup)
        if err1 then return nil, nil, err1 end
        local r, dec_r, err2 = eval_node(node.r, lookup)
        if err2 then return nil, nil, err2 end

        local fl, fdec_l = unwrap_fixed(l)
        local fr, fdec_r = unwrap_fixed(r)
        l, dec_l = fl, fdec_l or dec_l or 0
        r, dec_r = fr, fdec_r or dec_r or 0

        if l == nil or r == nil then
            return nil, 0, nil
        end

        if op == '||' then
            return val_to_string(l, dec_l) .. val_to_string(r, dec_r), 0, nil
        elseif op == 'LIKE' or op == 'NOT LIKE' then
            local sl, sr = val_to_string(l, dec_l), val_to_string(r, dec_r)
            local matched = sl:find(sql_like_to_pattern(sr)) ~= nil
            return (op == 'NOT LIKE') and (not matched) or matched, 0, nil
        elseif op == '=' or op == '<>' or op == '!=' or op == '<' or op == '<=' or op == '>' or op == '>=' then
            local cmp = compare_values(l, r)
            if op == '=' then return cmp == 0, 0, nil
            elseif op == '<>' or op == '!=' then return cmp ~= 0, 0, nil
            elseif op == '<' then return cmp < 0, 0, nil
            elseif op == '<=' then return cmp <= 0, 0, nil
            elseif op == '>' then return cmp > 0, 0, nil
            elseif op == '>=' then return cmp >= 0, 0, nil
            end
        elseif op == '+' or op == '-' then
            -- Date arithmetic support
            local dl = type(l) == 'string' and parse_date(l) or nil
            local dr = type(r) == 'string' and parse_date(r) or nil
            if dl or dr then
                if op == '-' and dl and dr then
                    return dl.days - dr.days, 0, nil
                elseif op == '+' and dl and to_num(r) ~= nil then
                    return format_date(dl.days + math.floor(to_num(r)), dl.fmt), 0, nil
                elseif op == '+' and dr and to_num(l) ~= nil then
                    return format_date(dr.days + math.floor(to_num(l)), dr.fmt), 0, nil
                elseif op == '-' and dl and to_num(r) ~= nil then
                    return format_date(dl.days - math.floor(to_num(r)), dl.fmt), 0, nil
                end
                return nil, nil, 'invalid date arithmetic'
            end
            local nl, nr = to_num(l), to_num(r)
            if nl == nil or nr == nil then
                return nil, nil, 'numeric operands required for ' .. op
            end
            local res = (op == '+') and (nl + nr) or (nl - nr)
            return res, math.max(dec_l, dec_r), nil
        elseif op == '*' then
            local nl, nr = to_num(l), to_num(r)
            if nl == nil or nr == nil then
                return nil, nil, 'numeric operands required for *'
            end
            return nl * nr, math.min(6, dec_l + dec_r), nil
        elseif op == '/' or op == 'MOD' or op == '%' then
            local nl, nr = to_num(l), to_num(r)
            if nl == nil or nr == nil then
                return nil, nil, 'numeric operands required for ' .. op
            end
            if nr == 0 then
                return nil, nil, 'division by zero'
            end
            if op == '/' then
                return nl / nr, math.max(dec_l, dec_r, 4), nil
            else
                return math.fmod(nl, nr), math.max(dec_l, dec_r), nil
            end
        end
    end

    return nil, nil, 'unsupported AST node: ' .. tostring(k)
end

local function make_lookup(row_lookup)
    if type(row_lookup) == 'function' then
        return row_lookup
    end
    if type(row_lookup) == 'table' then
        return function(name, quoted)
            if row_lookup[name] ~= nil then return row_lookup[name] end
            if not quoted then
                local up = name:upper()
                if row_lookup[up] ~= nil then return row_lookup[up] end
                local lo = name:lower()
                if row_lookup[lo] ~= nil then return row_lookup[lo] end
                for k, v in pairs(row_lookup) do
                    if type(k) == 'string' and k:upper() == up then
                        return v
                    end
                end
            end
            return nil
        end
    end
    return function() return nil end
end

--- Evaluates `ast` for a single row.
--- @param ast table|string
--- @param row_lookup fun(name: string): string|nil | table<string, string>
--- @return string|nil value  (nil = SQL NULL), string|nil err
function M.eval(ast, row_lookup)
    if type(ast) == 'string' then
        local parsed, perr = M.parse(ast)
        if not parsed then return nil, perr end
        ast = parsed
    end
    if type(ast) ~= 'table' then
        return nil, 'invalid AST'
    end

    local lookup = make_lookup(row_lookup)
    local val, dec, err = eval_node(ast, lookup)
    if err then
        return nil, err
    end
    if val == nil then
        return nil, nil
    end
    if type(val) == 'table' and val.fixed_dec ~= nil then
        local n = val.num
        if n == 0 then n = 0 end
        return string.format('%.' .. val.fixed_dec .. 'f', n), nil
    end
    return val_to_string(val, dec), nil
end

return M
