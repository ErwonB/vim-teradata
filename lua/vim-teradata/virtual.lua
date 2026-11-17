-- vim-teradata: virtual answerset (Patch 1 — summary footer + selection quick-calc).
--
-- Note on numeric precision:
-- Calculations in this module use standard Lua numbers (IEEE-754 double-precision
-- floats), which lose precision beyond ~15–17 significant digits (for example on
-- large BIGINT or high-precision DECIMAL(38, s) columns). Patch 3 adds exact
-- database pushdown for full-precision server-side aggregations.

local config = require('vim-teradata.config')
local grid   = require('vim-teradata.grid_state')

local M = {}

local SEP = ' | '
local HEADER_LINES = 2
local ns = vim.api.nvim_create_namespace('vim-teradata-virtual')

--- Ordered list of footer modes; the cycle key walks it.
M.MODES = { 'off', 'sum', 'avg', 'min', 'max', 'count', 'nulls', 'distinct' }

local MODE_LABELS = {
    sum      = 'Σ ',
    avg      = 'x̄ ',
    min      = '↓ ',
    max      = '↑ ',
    count    = '# ',
    nulls    = '∅ ',
    distinct = '≠ ',
}

local function ensure_hl()
    vim.api.nvim_set_hl(0, 'TeradataVirtual', { link = 'Special', default = true })
end

local function null_token()
    return (config.options and config.options.null_token)
        or (config.defaults and config.defaults.null_token)
        or 'NULL'
end

--- Parses a Teradata/BTEQ-rendered cell into a Lua number.
--- Returns nil for empty, NULL token, or non-numeric text.
--- Accepts: "12", "-3.5", "1,234.50", "  42 ", "1.2E+03",
---   "123-" (trailing-sign negative).
--- Rejects (returns nil): "1 234,50", "(123)", "1,2", dates, text.
--- @param s string|nil
--- @return number|nil
function M.to_number(s)
    if type(s) ~= 'string' then return nil end
    local trimmed = s:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed == '' or trimmed == null_token() then return nil end

    if trimmed:find('%s') or trimmed:match('^%-?0[xX]') then return nil end

    -- Trailing-sign negatives (e.g. "123-", "12.50-", "1,234.50-")
    local trailing = trimmed:match('^([^%-]+)%-$')
    if trailing then
        trimmed = '-' .. trailing
    end

    -- Strip ',' thousands separators only when matching ^-?%d[%d,]*%.?%d*$
    -- with valid 3-digit thousands groups (do not treat ',' as a decimal point).
    if trimmed:find(',', 1, true) then
        if not trimmed:match('^%-?%d[%d,]*%.?%d*$') then
            return nil
        end
        local int_part = trimmed:match('^([^%.]+)')
        if not int_part then return nil end
        local rest = int_part:gsub('^%-?%d%d?%d?', '')
        if rest == '' or rest:gsub(',%d%d%d', '') ~= '' then
            return nil
        end
        trimmed = trimmed:gsub(',', '')
    end

    local n = tonumber(trimmed)
    if not n or n ~= n or math.abs(n) == math.huge then
        return nil
    end
    return n
end

local function decimal_places(s)
    local trimmed = s:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%-$', '')
    local mant, exp = trimmed:match('^[^%.]*(%.?%d*)[eE]([+-]?%d+)$')
    if mant and exp then
        local d = math.max(0, #mant - 1) - (tonumber(exp) or 0)
        return math.max(0, d)
    end
    local frac = trimmed:match('%.(%d+)$')
    return frac and #frac or 0
end

--- Formats a number for display: integers without decimals; others with up to
--- `max_decimals` decimal places (trailing zeros stripped), never scientific
--- notation for |n| < 1e15.
--- @param n number|nil
--- @param max_decimals integer|nil
--- @return string
function M.format_number(n, max_decimals)
    if type(n) ~= 'number' or n ~= n or math.abs(n) == math.huge then
        return ''
    end
    if n == 0 then n = 0 end
    if math.abs(n) >= 1e15 then
        return tostring(n)
    end
    if n % 1 == 0 then
        return string.format('%.0f', n)
    end
    local dec = (type(max_decimals) == 'number' and max_decimals > 0) and max_decimals or 4
    if max_decimals == nil then dec = 6 end
    local s = string.format('%.' .. dec .. 'f', n)
    if s:find('.', 1, true) then
        s = s:gsub('0+$', ''):gsub('%.$', '')
    end
    if s == '-0' then s = '0' end
    return s
end

--- Computes descriptive statistics for a list of raw cell strings.
--- Tolerates any column representation (values is a flat array of strings).
--- @param values string[]  raw cells of one column (or pooled selection)
--- @return table { count, count_null, count_num, count_distinct,
---                 sum, avg, min, max, min_str, max_str, all_numeric, max_decimals }
function M.stats(values)
    values = values or {}
    local tok = null_token()
    local count = #values
    local count_null = 0
    local count_num = 0
    local distinct_set = {}
    local count_distinct = 0
    local sum, min_num, max_num = 0, nil, nil
    local min_str, max_str = nil, nil
    local max_decimals = 0

    for i = 1, count do
        local raw = values[i]
        local trimmed = type(raw) == 'string' and (raw:gsub('^%s+', ''):gsub('%s+$', '')) or ''
        if trimmed == '' or trimmed == tok then
            count_null = count_null + 1
        else
            if not distinct_set[trimmed] then
                distinct_set[trimmed] = true
                count_distinct = count_distinct + 1
            end
            if min_str == nil or trimmed < min_str then min_str = trimmed end
            if max_str == nil or trimmed > max_str then max_str = trimmed end

            local n = M.to_number(trimmed)
            if n ~= nil then
                count_num = count_num + 1
                sum = sum + n
                if min_num == nil or n < min_num then min_num = n end
                if max_num == nil or n > max_num then max_num = n end
                local dp = decimal_places(trimmed)
                if dp > max_decimals then max_decimals = dp end
            end
        end
    end

    local non_null = count - count_null
    return {
        count          = count,
        count_null     = count_null,
        count_num      = count_num,
        count_distinct = count_distinct,
        sum            = count_num > 0 and sum or nil,
        avg            = count_num > 0 and (sum / count_num) or nil,
        min            = min_num,
        max            = max_num,
        min_str        = min_str,
        max_str        = max_str,
        all_numeric    = non_null > 0 and count_num == non_null,
        max_decimals   = max_decimals,
    }
end

--- Pads `s` to `width` display columns, or truncates with '…' when wider.
--- @param s string
--- @param width integer
--- @return string
local function fit_cell(s, width)
    s = s or ''
    width = width or 0
    if width <= 0 then return '' end
    local dw = vim.fn.strdisplaywidth(s)
    if dw <= width then
        return s .. string.rep(' ', width - dw)
    end
    if width == 1 then return '…' end
    local nchars = vim.fn.strchars(s)
    local best = ''
    for k = 1, nchars do
        local sub = vim.fn.strcharpart(s, 0, k)
        if vim.fn.strdisplaywidth(sub) <= width - 1 then
            best = sub
        else
            break
        end
    end
    local res = best .. '…'
    local pad = width - vim.fn.strdisplaywidth(res)
    if pad > 0 then res = res .. string.rep(' ', pad) end
    return res
end

local function format_stat_for_mode(st, mode)
    if mode == 'sum' then
        return st.sum ~= nil and M.format_number(st.sum, st.max_decimals) or ''
    elseif mode == 'avg' then
        local dec = math.max(st.max_decimals or 0, 2)
        return st.avg ~= nil and M.format_number(st.avg, dec) or ''
    elseif mode == 'min' then
        if st.all_numeric and st.min ~= nil then
            return M.format_number(st.min, st.max_decimals)
        end
        return st.min_str or (st.min ~= nil and M.format_number(st.min, st.max_decimals)) or ''
    elseif mode == 'max' then
        if st.all_numeric and st.max ~= nil then
            return M.format_number(st.max, st.max_decimals)
        end
        return st.max_str or (st.max ~= nil and M.format_number(st.max, st.max_decimals)) or ''
    elseif mode == 'count' then
        return tostring(st.count)
    elseif mode == 'nulls' then
        return tostring(st.count_null)
    elseif mode == 'distinct' then
        return tostring(st.count_distinct)
    end
    return ''
end

--- Collects raw cell strings for displayed column `j`.
--- Tolerates non-integer column ids (e.g. "v1" in Patch 2).
local function column_values(bufnr, j, scope)
    local displayed_data = grid.get(bufnr, 'displayed_data') or {}
    if scope == 'all' then
        local all_data = grid.get(bufnr, 'all_data')
        local col_ids  = grid.get(bufnr, 'displayed_col_ids') or {}
        local col_id   = col_ids[j]
        if all_data and col_id ~= nil then
            local vals = {}
            for i, row in ipairs(all_data) do
                if row[col_id] ~= nil then
                    vals[#vals + 1] = row[col_id]
                elseif displayed_data[i] and displayed_data[i][j] ~= nil then
                    vals[#vals + 1] = displayed_data[i][j]
                else
                    vals[#vals + 1] = ''
                end
            end
            return vals
        end
    end
    local vals = {}
    for i = 1, #displayed_data do
        local row = displayed_data[i]
        vals[i] = (row and row[j]) or ''
    end
    return vals
end

--- Renders (or clears when mode == 'off') the virtual summary footer below the
--- last data row of `bufnr`.
--- @param bufnr integer
function M.render_footer(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    local vcfg = (config.options and config.options.virtual)
        or (config.defaults and config.defaults.virtual)
        or {}
    local mode = grid.get(bufnr, 'virtual_footer_mode') or vcfg.footer_default or 'off'
    if mode == 'off' or not MODE_LABELS[mode] then return end

    local widths         = grid.get(bufnr, 'column_widths') or {}
    local displayed_data = grid.get(bufnr, 'displayed_data') or {}
    if #widths == 0 or #displayed_data == 0 then return end

    ensure_hl()
    local scope = vcfg.footer_scope or 'displayed'
    local label = MODE_LABELS[mode]

    local sep_parts = {}
    local val_parts = {}
    -- Patch 2: virtual columns will register here
    for j, w in ipairs(widths) do
        sep_parts[j] = string.rep('-', w)
        local st = M.stats(column_values(bufnr, j, scope))
        local raw_val = format_stat_for_mode(st, mode)
        if j == 1 then
            raw_val = label .. raw_val
        end
        val_parts[j] = fit_cell(raw_val, w)
    end

    local sep_line = table.concat(sep_parts, '-+-')
    local val_line = table.concat(val_parts, SEP)

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local target_line = math.max(0, math.min(HEADER_LINES + #displayed_data - 1, line_count - 1))

    vim.api.nvim_buf_set_extmark(bufnr, ns, target_line, 0, {
        virt_lines = {
            { { sep_line, 'TeradataVirtual' } },
            { { val_line, 'TeradataVirtual' } },
        },
        virt_lines_above = false,
    })
end

--- Cycles the summary footer mode forward (`step = 1`) or backward (`step = -1`).
--- @param bufnr integer
--- @param step integer|nil
--- @return string new_mode
function M.cycle_footer(bufnr, step)
    step = step or 1
    local vcfg = (config.options and config.options.virtual)
        or (config.defaults and config.defaults.virtual)
        or {}
    local cur = grid.get(bufnr, 'virtual_footer_mode') or vcfg.footer_default or 'off'
    local idx = 1
    for i, m in ipairs(M.MODES) do
        if m == cur then
            idx = i
            break
        end
    end
    local next_idx = ((idx - 1 + step) % #M.MODES) + 1
    local next_mode = M.MODES[next_idx]
    grid.set(bufnr, 'virtual_footer_mode', next_mode)
    M.render_footer(bufnr)
    return next_mode
end

--- Returns the 1-based displayed column indexes whose `[start, start+width)`
--- range (using offset = Σ(width + #SEP)) intersects `[c1, c2]` (0-based).
--- @param widths integer[]
--- @param c1 integer 0-based start column
--- @param c2 integer 0-based end column
--- @return integer[]
function M.columns_in_range(widths, c1, c2)
    if not widths or #widths == 0 then return {} end
    c1 = c1 or 0
    c2 = c2 or c1
    if c1 > c2 then c1, c2 = c2, c1 end

    local cols = {}
    local pos = 0
    for j, width in ipairs(widths) do
        local start_col = pos
        local end_col = pos + width -- exclusive
        if width == 0 then
            if c1 <= start_col and c2 >= start_col then
                cols[#cols + 1] = j
            end
        else
            if c1 < end_col and c2 >= start_col then
                cols[#cols + 1] = j
            end
        end
        pos = pos + width + #SEP
    end
    return cols
end

local METRIC_ROWS = {
    { key = 'count',    label = 'count' },
    { key = 'nulls',    label = 'nulls' },
    { key = 'sum',      label = 'sum' },
    { key = 'avg',      label = 'avg' },
    { key = 'min',      label = 'min' },
    { key = 'max',      label = 'max' },
    { key = 'distinct', label = 'distinct' },
}

local function build_quick_calc_lines(headers, col_indices, pooled, per_col)
    local function cell_text(st, key)
        local v = format_stat_for_mode(st, key)
        return v ~= '' and v or '-'
    end

    if #col_indices == 1 then
        local c = col_indices[1]
        local title = headers[c] or ('col' .. c)
        local lines = { title, string.rep('-', math.max(16, vim.fn.strdisplaywidth(title))) }
        for _, m in ipairs(METRIC_ROWS) do
            lines[#lines + 1] = string.format('%-9s %s', m.label, cell_text(pooled, m.key))
        end
        return lines
    end

    -- Multi-column: table with Pooled + each selected column
    local col_Specs = { { name = 'Pooled', st = pooled } }
    for _, c in ipairs(col_indices) do
        col_Specs[#col_Specs + 1] = { name = headers[c] or ('col' .. c), st = per_col[c] }
    end

    local label_w = 8
    local col_w = {}
    for k, spec in ipairs(col_Specs) do
        local w = vim.fn.strdisplaywidth(spec.name)
        for _, m in ipairs(METRIC_ROWS) do
            w = math.max(w, vim.fn.strdisplaywidth(cell_text(spec.st, m.key)))
        end
        col_w[k] = w
    end

    local hdr_parts = { fit_cell('', label_w) }
    local sep_parts = { string.rep('-', label_w) }
    for k, spec in ipairs(col_Specs) do
        hdr_parts[#hdr_parts + 1] = fit_cell(spec.name, col_w[k])
        sep_parts[#sep_parts + 1] = string.rep('-', col_w[k])
    end

    local lines = {
        table.concat(hdr_parts, SEP),
        table.concat(sep_parts, '-+-'),
    }
    for _, m in ipairs(METRIC_ROWS) do
        local parts = { fit_cell(m.label, label_w) }
        for k, spec in ipairs(col_Specs) do
            parts[#parts + 1] = fit_cell(cell_text(spec.st, m.key), col_w[k])
        end
        lines[#lines + 1] = table.concat(parts, SEP)
    end
    return lines
end

local active_float = nil

local function close_active_float()
    if not active_float then return end
    local af = active_float
    active_float = nil
    if af.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, af.augroup)
    end
    if af.parent_buf and vim.api.nvim_buf_is_valid(af.parent_buf) then
        for _, lhs in ipairs(af.temp_keys or {}) do
            pcall(vim.keymap.del, 'n', lhs, { buffer = af.parent_buf })
        end
    end
    if af.win and vim.api.nvim_win_is_valid(af.win) then
        pcall(vim.api.nvim_win_close, af.win, true)
    end
end

--- Computes quick-calc statistics over the given line/virtual-column block and
--- displays them in a cursor-relative floating window.
--- @param bufnr integer
--- @param line1 integer 1-based start line
--- @param line2 integer 1-based end line
--- @param vcol1 integer|nil 1-based start virtual column
--- @param vcol2 integer|nil 1-based end virtual column
--- @return table|nil result
function M.calc_selection(bufnr, line1, line2, vcol1, vcol2)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local headers        = grid.get(bufnr, 'displayed_header')
    local displayed_data = grid.get(bufnr, 'displayed_data')
    local widths         = grid.get(bufnr, 'column_widths')
    if not headers or not displayed_data or not widths or grid.get(bufnr, 'is_explain_or_show') then
        vim.notify('Quick calc is only available in Teradata result grids.',
            vim.log.levels.WARN, { title = 'Teradata' })
        return nil
    end

    line1 = line1 or vim.fn.line('.')
    line2 = line2 or line1
    if line1 > line2 then line1, line2 = line2, line1 end

    local r1 = math.max(1, line1 - HEADER_LINES)
    local r2 = math.min(#displayed_data, line2 - HEADER_LINES)
    if #displayed_data == 0 or r1 > r2 then
        vim.notify('No data rows in selection.', vim.log.levels.WARN, { title = 'Teradata' })
        return nil
    end

    local cur_vcol = vim.fn.virtcol('.')
    vcol1 = (vcol1 and vcol1 > 0) and vcol1 or cur_vcol
    vcol2 = (vcol2 and vcol2 > 0) and vcol2 or vcol1
    local cols = M.columns_in_range(widths, vcol1 - 1, vcol2 - 1)
    if #cols == 0 then
        vim.notify('No column in selection.', vim.log.levels.WARN, { title = 'Teradata' })
        return nil
    end

    local pooled_vals = {}
    local per_col_vals = {}
    for _, c in ipairs(cols) do per_col_vals[c] = {} end

    for r = r1, r2 do
        local row = displayed_data[r]
        if row then
            for _, c in ipairs(cols) do
                local val = row[c] or ''
                pooled_vals[#pooled_vals + 1] = val
                local cv = per_col_vals[c]
                cv[#cv + 1] = val
            end
        end
    end

    local pooled = M.stats(pooled_vals)
    local per_col = nil
    if #cols > 1 then
        per_col = {}
        for _, c in ipairs(cols) do
            per_col[c] = M.stats(per_col_vals[c])
        end
    end

    local vcfg = (config.options and config.options.virtual)
        or (config.defaults and config.defaults.virtual)
        or {}
    if vcfg.yank_quick_calc == true then
        local s_sum = format_stat_for_mode(pooled, 'sum')
        local s_avg = format_stat_for_mode(pooled, 'avg')
        local s_min = format_stat_for_mode(pooled, 'min')
        local s_max = format_stat_for_mode(pooled, 'max')
        vim.fn.setreg('"', table.concat({ s_sum, s_avg, s_min, s_max }, '\t'))
    end

    local lines = build_quick_calc_lines(headers, cols, pooled, per_col)

    close_active_float()
    ensure_hl()

    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].buftype = 'nofile'
    vim.bo[float_buf].bufhidden = 'wipe'
    vim.bo[float_buf].swapfile = false
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
    vim.bo[float_buf].modifiable = false

    local width = 10
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width + 1, math.max(10, vim.o.columns - 4))
    local height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 4)))
    local border = (vim.o.winborder and vim.o.winborder ~= '') and vim.o.winborder or 'rounded'

    local ok_win, float_win = pcall(vim.api.nvim_open_win, float_buf, false, {
        relative = 'cursor',
        row      = 1,
        col      = 0,
        width    = width,
        height   = height,
        style    = 'minimal',
        border   = border,
    })

    if ok_win and float_win then
        local aug = vim.api.nvim_create_augroup('VimTeradataQuickCalc', { clear = true })
        local temp_keys = {}
        for _, lhs in ipairs({ 'q', '<Esc>' }) do
            vim.keymap.set('n', lhs, close_active_float, { buffer = float_buf, silent = true, nowait = true })
            if vim.fn.maparg(lhs, 'n', false, true).buffer ~= bufnr then
                temp_keys[#temp_keys + 1] = lhs
                vim.keymap.set('n', lhs, close_active_float, { buffer = bufnr, silent = true, nowait = true })
            end
        end
        active_float = {
            win        = float_win,
            buf        = float_buf,
            parent_buf = bufnr,
            augroup    = aug,
            temp_keys  = temp_keys,
        }
        vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave', 'BufWipeout' }, {
            group    = aug,
            buffer   = bufnr,
            once     = true,
            callback = close_active_float,
        })
    end

    return {
        pooled     = pooled,
        per_column = per_col,
        columns    = cols,
        rows       = { r1, r2 },
        lines      = lines,
        win        = ok_win and float_win or nil,
        buf        = float_buf,
    }
end

return M
