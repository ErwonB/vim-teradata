-- vim-teradata: virtual answerset (Patch 1 — summary footer + selection quick-calc;
-- Patch 2 — computed virtual columns; Patch 3 — SQL pushdown + volatile-table
-- materialization).
--
-- Note on numeric precision:
-- In-memory calculations in this module use standard Lua numbers (IEEE-754
-- double-precision floats), which lose precision beyond ~15–17 significant
-- digits (for example on large BIGINT or high-precision DECIMAL(38, s) columns).
-- Patch 3 (`gD`, `:TDColPush`, `:TDMaterialize`) executes aggregations and
-- expressions directly in Teradata for exact database precision.

local config = require('vim-teradata.config')
local grid   = require('vim-teradata.grid_state')
local util   = require('vim-teradata.util')

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

--- session_buf -> { [query_key] = vt_name }
--- @type table<integer, table<string, string>>
local materialized = {}
local session_hook_registered = false

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function ensure_hl()
    vim.api.nvim_set_hl(0, 'TeradataVirtual', { link = 'Special', default = true })
end

local function null_token()
    return (config.options and config.options.null_token)
        or (config.defaults and config.defaults.null_token)
        or 'NULL'
end

local function virt_cfg()
    return (config.options and config.options.virtual)
        or (config.defaults and config.defaults.virtual)
        or {}
end

local function header_prefix()
    local p = virt_cfg().header_prefix
    return p ~= nil and p or 'ƒ '
end

local function refresh_grid_view(bufnr)
    local pop = grid.get(bufnr, 'populate_fn')
    if type(pop) == 'function' then
        pop()
    end
end

local function on_session_closed(closed_sbuf)
    materialized[closed_sbuf] = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
            local vt = grid.get(b, 'virtual_materialized')
            if vt and vt.session_buf == closed_sbuf then
                grid.set(b, 'virtual_materialized', nil)
                if grid.get(b, 'virtual_edit_target') == 'volatile' then
                    grid.set(b, 'virtual_edit_target', 'table')
                end
                refresh_grid_view(b)
            end
        end
    end
end

local function ensure_session_hook()
    if session_hook_registered then return end
    session_hook_registered = true
    local ok_s, sess = pcall(require, 'vim-teradata.session')
    if ok_s and sess and sess.on_close then
        sess.on_close(on_session_closed)
    end
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
    local trimmed = trim(s)
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
    local trimmed = trim(s):gsub('%-$', '')
    local mant, exp = trimmed:match('^[^%.]*(%.?%d*)[eE]([+-]?%d+)$')
    if mant and exp then
        local d = math.max(0, #mant - 1) - (tonumber(exp) or 0)
        return math.max(0, d)
    end
    local frac = trimmed:match('%.(%d+)$')
    return frac and #frac or 0
end

local function significant_digits(s)
    local cleaned = trim(s):gsub('%-$', ''):gsub('^%-', ''):gsub(',', ''):gsub('[eE].*$', ''):gsub('%.', ''):gsub('^0+', '')
    return #cleaned
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
---                 sum, avg, min, max, min_str, max_str, all_numeric, max_decimals, approx }
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
    local approx = false

    for i = 1, count do
        local raw = values[i]
        local trimmed = type(raw) == 'string' and trim(raw) or ''
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
                if significant_digits(trimmed) > 15 then
                    approx = true
                end
            end
        end
    end

    if count_num > 0 and math.abs(sum) >= 1e15 then
        approx = true
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
        approx         = approx,
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
        local vvals    = grid.get(bufnr, 'virtual_values') or {}
        if all_data and col_id ~= nil then
            local vals = {}
            if type(col_id) == 'string' and vvals[col_id] then
                for i = 1, #all_data do
                    vals[i] = vvals[col_id][i] or ''
                end
                return vals
            end
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

local function current_col_key(bufnr)
    local col_ids = grid.get(bufnr, 'displayed_col_ids') or {}
    local parts = {}
    for i, cid in ipairs(col_ids) do parts[i] = tostring(cid) end
    return table.concat(parts, ',')
end

--- Invalidates any cached DB pushdown footer on `bufnr`.
--- @param bufnr integer
function M.invalidate_footer_db(bufnr)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        grid.set(bufnr, 'virtual_footer_db', nil)
    end
end

--- Renders (or clears when mode == 'off') the virtual summary footer below the
--- last data row of `bufnr`.
--- @param bufnr integer
function M.render_footer(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    local vcfg = virt_cfg()
    local mode = grid.get(bufnr, 'virtual_footer_mode') or vcfg.footer_default or 'off'
    if mode == 'off' or not MODE_LABELS[mode] then return end

    local widths         = grid.get(bufnr, 'column_widths') or {}
    local displayed_data = grid.get(bufnr, 'displayed_data') or {}
    local all_data       = grid.get(bufnr, 'all_data') or displayed_data
    if #widths == 0 or #displayed_data == 0 then return end

    ensure_hl()
    local sep_parts = {}
    for j, w in ipairs(widths) do
        sep_parts[j] = string.rep('-', w)
    end
    local sep_line = table.concat(sep_parts, '-+-')

    local val_line
    if grid.get(bufnr, 'virtual_footer_loading') then
        val_line = MODE_LABELS[mode] .. '… computing in Teradata'
    else
        local db_cache = grid.get(bufnr, 'virtual_footer_db')
        local col_key  = current_col_key(bufnr)
        if db_cache and (db_cache.mode ~= mode or (db_cache.col_key and db_cache.col_key ~= col_key)) then
            grid.set(bufnr, 'virtual_footer_db', nil)
            db_cache = nil
        end

        local sym = trim(MODE_LABELS[mode])
        local full_label = MODE_LABELS[mode]
        local raw_vals = {}

        if db_cache and type(db_cache.values) == 'table' then
            local is_filtered = (#displayed_data ~= #all_data)
            full_label = is_filtered and (sym .. ' db (unfiltered) ') or (sym .. ' db ')
            for j = 1, #widths do
                raw_vals[j] = db_cache.values[j] or ''
            end
        else
            local scope = vcfg.footer_scope or 'displayed'
            local any_approx = false
            -- Patch 2: virtual columns are registered in displayed_col_ids and displayed_data
            for j = 1, #widths do
                local st = M.stats(column_values(bufnr, j, scope))
                if st.approx and (mode == 'sum' or mode == 'avg') then
                    any_approx = true
                end
                raw_vals[j] = format_stat_for_mode(st, mode)
            end

            if vcfg.engine ~= 'lua' then
                local rows_found = grid.get(bufnr, 'rows_found')
                local retlimit_applied = grid.get(bufnr, 'retlimit_applied')
                local is_partial = (retlimit_applied ~= false)
                    and type(rows_found) == 'number'
                    and rows_found > #all_data
                if is_partial then
                    if not grid.get(bufnr, 'virtual_partial_warned') then
                        grid.set(bufnr, 'virtual_partial_warned', true)
                        local db_key = (vcfg.keymaps or {}).footer_db or 'gD'
                        vim.notify(string.format('%s computes the exact total in Teradata', db_key),
                            vim.log.levels.INFO, { title = 'Teradata' })
                    end
                end
                if is_partial and any_approx then
                    full_label = sym .. ' (partial) (≈) '
                elseif is_partial then
                    full_label = sym .. ' (partial) '
                elseif any_approx then
                    full_label = sym .. ' (≈) '
                end
            end
        end

        local val_parts = {}
        local suffix_tag = nil
        for j, w in ipairs(widths) do
            local rv = raw_vals[j] or ''
            if j == 1 then
                if vim.fn.strdisplaywidth(full_label .. rv) <= w then
                    val_parts[1] = fit_cell(full_label .. rv, w)
                else
                    val_parts[1] = fit_cell(MODE_LABELS[mode] .. rv, w)
                    if full_label ~= MODE_LABELS[mode] then
                        suffix_tag = '  ' .. trim(full_label)
                    end
                end
            else
                val_parts[j] = fit_cell(rv, w)
            end
        end
        val_line = table.concat(val_parts, SEP) .. (suffix_tag or '')
    end

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
    local vcfg = virt_cfg()
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
    grid.set(bufnr, 'virtual_footer_db', nil)
    M.render_footer(bufnr)
    if next_mode ~= 'off' and vcfg.engine == 'db' then
        M.footer_pushdown(bufnr)
    end
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

-- =============================================================================
-- Patch 2 — Virtual computed columns & persistence
-- =============================================================================

local function strip_sql_comments_and_collapse(sql)
    local out = {}
    local i, n = 1, #sql
    while i <= n do
        local c = sql:sub(i, i)
        local two = sql:sub(i, i + 1)
        if c == "'" or c == '"' then
            local start = i
            i = i + 1
            while i <= n do
                if sql:sub(i, i) == c then
                    if sql:sub(i + 1, i + 1) == c then
                        i = i + 2
                    else
                        i = i + 1
                        break
                    end
                else
                    i = i + 1
                end
            end
            out[#out + 1] = sql:sub(start, i - 1)
        elseif two == '--' then
            local nl = sql:find('\n', i + 2, true)
            i = nl and (nl + 1) or (n + 1)
            out[#out + 1] = ' '
        elseif two == '/*' then
            local _, e = sql:find('*/', i + 2, true)
            i = e and (e + 1) or (n + 1)
            out[#out + 1] = ' '
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    local s = table.concat(out):gsub('%s+', ' ')
    return trim(s)
end

--- Computes a stable SHA-256 hash of a SQL statement with comments stripped
--- and whitespace collapsed.
--- @param sql string
--- @return string|nil
function M.normalize_sql_hash(sql)
    if type(sql) ~= 'string' or sql == '' then return nil end
    local norm = strip_sql_comments_and_collapse(sql)
    if norm == '' then return nil end
    return vim.fn.sha256(norm)
end

local function persistence_path()
    local data_dir = (config.options and config.options.data_dir)
        or (config.defaults and config.defaults.data_dir)
        or (vim.fn.stdpath('data') .. '/teradata/sql-autocomplete')
    return data_dir .. '/virtual_columns.json'
end

local function load_persistence_store()
    local path = persistence_path()
    if vim.fn.filereadable(path) == 0 then return {} end
    local ok_r, lines = pcall(vim.fn.readfile, path)
    if not ok_r or not lines or #lines == 0 then return {} end
    local raw = table.concat(lines, '\n')
    if trim(raw) == '' then return {} end
    local ok_d, decoded = pcall(vim.json.decode, raw)
    if not ok_d or type(decoded) ~= 'table' then
        vim.notify('[vim-teradata] Corrupt virtual_columns.json ignored.', vim.log.levels.WARN)
        return {}
    end
    return decoded
end

local function save_persistence_store(store)
    local path = persistence_path()
    local dir = vim.fn.fnamemodify(path, ':h')
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, 'p', 448)
    end
    local tmp = path .. '.tmp'
    local ok_e, encoded = pcall(vim.json.encode, store)
    if not ok_e then return end
    vim.fn.writefile({ encoded }, tmp)
    local ok_mv = vim.uv.fs_rename(tmp, path)
    if not ok_mv then
        pcall(vim.uv.fs_copyfile, tmp, path)
        pcall(vim.fn.delete, tmp)
    end
end

local function persist_buffer_columns(bufnr)
    if virt_cfg().persist_columns == false then return end
    local hash = grid.get(bufnr, 'query_sql_hash')
    if not hash then return end
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    local store = load_persistence_store()
    if #vcols == 0 then
        store[hash] = nil
    else
        local list = {}
        for _, vc in ipairs(vcols) do
            list[#list + 1] = { name = vc.name, expr = vc.expr }
        end
        store[hash] = list
    end
    save_persistence_store(store)
end

local function ensure_grid_basics(bufnr)
    local all_header       = grid.get(bufnr, 'all_header')
    local displayed_header = grid.get(bufnr, 'displayed_header') or {}
    if not all_header then
        all_header = vim.deepcopy(displayed_header)
        grid.set(bufnr, 'all_header', all_header)
    end
    local all_data       = grid.get(bufnr, 'all_data')
    local displayed_data = grid.get(bufnr, 'displayed_data') or {}
    if not all_data then
        all_data = vim.deepcopy(displayed_data)
        grid.set(bufnr, 'all_data', all_data)
    end
    local displayed_ids = grid.get(bufnr, 'displayed_ids')
    if not displayed_ids then
        displayed_ids = {}
        for i = 1, #displayed_data do displayed_ids[i] = i end
        grid.set(bufnr, 'displayed_ids', displayed_ids)
    end
    local displayed_col_ids = grid.get(bufnr, 'displayed_col_ids')
    if not displayed_col_ids then
        displayed_col_ids = {}
        for i = 1, #displayed_header do displayed_col_ids[i] = i end
        grid.set(bufnr, 'displayed_col_ids', displayed_col_ids)
    end
    return all_header, all_data, displayed_header, displayed_data, displayed_ids, displayed_col_ids
end

--- Splits a user specification into `(name, expr)`.
--- Accepts `"margin = (price - cost) * qty"` or `"(price - cost) * qty"`.
--- @param spec string
--- @return string|nil name, string expr
function M.split_col_spec(spec)
    spec = trim(spec or '')
    local q_name, q_rhs = spec:match('^"([^"]+)"%s*=%s*(.+)$')
    if q_name and not q_rhs:match('^=') then
        return q_name, trim(q_rhs)
    end
    local ident, rhs = spec:match('^([%a_][%w_]*)%s*=%s*(.+)$')
    if ident and ident:upper() ~= 'CASE' and not rhs:match('^=') then
        return ident, trim(rhs)
    end
    return nil, spec
end

--- Re-inserts virtual column values into `displayed_data` rows for every
--- virtual column id currently present in `displayed_col_ids`.
--- @param bufnr integer
function M.reapply(bufnr)
    local displayed_data    = grid.get(bufnr, 'displayed_data') or {}
    local displayed_ids     = grid.get(bufnr, 'displayed_ids') or {}
    local displayed_col_ids = grid.get(bufnr, 'displayed_col_ids') or {}
    local vvals             = grid.get(bufnr, 'virtual_values') or {}
    local tok               = null_token()

    for j, cid in ipairs(displayed_col_ids) do
        if type(cid) == 'string' and vvals[cid] then
            local col_vals = vvals[cid]
            for i = 1, #displayed_data do
                local row = displayed_data[i]
                if row then
                    local row_id = displayed_ids[i] or i
                    row[j] = col_vals[row_id] or tok
                end
            end
        end
    end
    grid.set(bufnr, 'displayed_data', displayed_data)
end

--- Recomputes every virtual column for every row in `all_data` (accounting for
--- pending in-grid edits when edit mode is active) and updates `displayed_data`.
--- @param bufnr integer
--- @return table<string, { div_zero: integer, errors: integer }>
function M.recompute(bufnr)
    local all_header, all_data = ensure_grid_basics(bufnr)
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    local vvals = grid.get(bufnr, 'virtual_values') or {}
    local tok   = null_token()

    if #vcols == 0 then
        grid.set(bufnr, 'virtual_values', {})
        return {}
    end

    local expr_mod = require('vim-teradata.virtual_expr')

    -- Map real column names -> index in all_header
    local real_exact, real_upper = {}, {}
    for idx, h in ipairs(all_header) do
        real_exact[h] = idx
        real_upper[h:upper()] = idx
    end

    local ok_e, edit_mod = pcall(require, 'vim-teradata.edit')
    local edit_st = (ok_e and edit_mod._state) and edit_mod._state(bufnr) or nil
    local pending = (edit_st and edit_st.editing and edit_st.pending) or nil

    local stats_err = {}
    local evaluated_vcols = {}

    for _, vc in ipairs(vcols) do
        local col_vals = {}
        local div_zero = 0
        local errs = 0

        for row_id = 1, #all_data do
            local row = all_data[row_id] or {}
            local row_pend = pending and pending[row_id] or nil

            local function lookup(col_name, quoted)
                if not quoted then
                    local up = col_name:upper()
                    local ev_id = evaluated_vcols[up]
                    if ev_id and vvals[ev_id] then
                        return vvals[ev_id][row_id]
                    end
                    local r_idx = real_upper[up]
                    if r_idx then
                        if row_pend and row_pend[r_idx] ~= nil then
                            return row_pend[r_idx]
                        end
                        return row[r_idx]
                    end
                else
                    local ev_id = evaluated_vcols[col_name] or evaluated_vcols[col_name:upper()]
                    if ev_id and vvals[ev_id] then
                        return vvals[ev_id][row_id]
                    end
                    local r_idx = real_exact[col_name] or real_upper[col_name:upper()]
                    if r_idx then
                        if row_pend and row_pend[r_idx] ~= nil then
                            return row_pend[r_idx]
                        end
                        return row[r_idx]
                    end
                end
                return nil
            end

            local val, err = expr_mod.eval(vc.ast, lookup)
            if err then
                if err == 'division by zero' then
                    div_zero = div_zero + 1
                else
                    errs = errs + 1
                end
            end
            col_vals[row_id] = (val ~= nil) and val or tok
        end

        vvals[vc.id] = col_vals
        evaluated_vcols[vc.name:upper()] = vc.id
        evaluated_vcols[vc.name] = vc.id
        stats_err[vc.name] = { div_zero = div_zero, errors = errs }
    end

    grid.set(bufnr, 'virtual_values', vvals)
    M.reapply(bufnr)
    return stats_err
end

local function next_auto_name(all_header, vcols)
    local taken = {}
    for _, h in ipairs(all_header) do taken[h:upper()] = true end
    for _, vc in ipairs(vcols) do taken[vc.name:upper()] = true end
    local k = 1
    while taken['EXPR' .. k] do k = k + 1 end
    return 'EXPR' .. k
end

local function validate_refs(refs, all_header, vcols, max_vcol_idx, self_name)
    local known = {}
    for _, h in ipairs(all_header) do
        known[h] = true
        known[h:upper()] = true
    end
    local limit = max_vcol_idx or #vcols
    for i = 1, limit do
        local vc = vcols[i]
        if vc then
            known[vc.name] = true
            known[vc.name:upper()] = true
        end
    end
    local self_up = self_name and self_name:upper() or nil
    for _, r in ipairs(refs) do
        if self_up and r:upper() == self_up then
            return false, string.format("virtual column '%s' cannot reference itself", self_name)
        end
        if not known[r] and not known[r:upper()] then
            return false, string.format("unknown column '%s'", r)
        end
    end
    return true, nil
end

local function cursor_column_index(bufnr)
    local widths = grid.get(bufnr, 'column_widths')
    if not widths then return nil end
    local col = vim.fn.virtcol('.') - 1
    local pos = 0
    for i, w in ipairs(widths) do
        if col >= pos and col < pos + w then return i end
        pos = pos + w + #SEP
    end
    return nil
end

--- Adds a computed virtual column to `bufnr`.
--- Can be called as `add_column(bufnr, name, expr, opts)` or
--- `add_column(bufnr, "name = expr", nil, opts)`.
--- @param bufnr integer
--- @param name string|nil
--- @param expr string|nil
--- @param opts table|nil { position = 'end'|'after_cursor', silent = boolean, from_persist = boolean }
--- @return table|nil col_def, string|nil err
function M.add_column(bufnr, name, expr, opts)
    opts = opts or {}
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    if grid.get(bufnr, 'is_explain_or_show') then
        if not opts.silent then
            vim.notify('Virtual columns are only available in Teradata result grids.',
                vim.log.levels.WARN, { title = 'Teradata' })
        end
        return nil, 'not a result grid'
    end

    if expr == nil and type(name) == 'string' then
        name, expr = M.split_col_spec(name)
    end

    local all_header, _, displayed_header, displayed_data, displayed_ids, displayed_col_ids =
        ensure_grid_basics(bufnr)
    local vcols = grid.get(bufnr, 'virtual_columns') or {}

    if not name or trim(name) == '' then
        name = next_auto_name(all_header, vcols)
    else
        name = trim(name)
        if name:match('^".*"$') then
            name = name:sub(2, -2):gsub('""', '"')
        else
            name = name:upper()
        end
    end

    if name == '' then
        if not opts.silent then
            vim.notify('Invalid virtual column name.', vim.log.levels.ERROR, { title = 'Teradata' })
        end
        return nil, 'invalid column name'
    end

    for _, h in ipairs(all_header) do
        if h:upper() == name:upper() then
            local msg = string.format("Column '%s' already exists in result.", name)
            if not opts.silent then vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' }) end
            return nil, msg
        end
    end
    for _, vc in ipairs(vcols) do
        if vc.name:upper() == name:upper() then
            local msg = string.format("Virtual column '%s' already exists.", name)
            if not opts.silent then vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' }) end
            return nil, msg
        end
    end

    local expr_mod = require('vim-teradata.virtual_expr')
    local ast, perr = expr_mod.parse(expr or '')
    if not ast then
        local msg = 'Invalid expression: ' .. tostring(perr)
        if not opts.silent then vim.notify(msg, vim.log.levels.ERROR, { title = 'Teradata' }) end
        return nil, msg
    end

    local refs = expr_mod.references(ast)
    local ok_ref, rerr = validate_refs(refs, all_header, vcols, #vcols, name)
    if not ok_ref then
        if not opts.silent then vim.notify(rerr, vim.log.levels.ERROR, { title = 'Teradata' }) end
        return nil, rerr
    end

    local seq = (grid.get(bufnr, 'virtual_seq') or 0) + 1
    grid.set(bufnr, 'virtual_seq', seq)
    local vid = 'v' .. seq

    local entry = {
        id   = vid,
        name = name,
        expr = trim(expr),
        ast  = ast,
        refs = refs,
    }
    vcols[#vcols + 1] = entry
    grid.set(bufnr, 'virtual_columns', vcols)

    local err_stats = M.recompute(bufnr)
    local vvals = grid.get(bufnr, 'virtual_values') or {}
    local tok = null_token()

    local ins_idx = #displayed_header + 1
    if opts.position == 'after_cursor' then
        local cidx = cursor_column_index(bufnr)
        if cidx then ins_idx = math.min(#displayed_header + 1, cidx + 1) end
    end

    table.insert(displayed_header, ins_idx, header_prefix() .. name)
    table.insert(displayed_col_ids, ins_idx, vid)
    for i = 1, #displayed_data do
        local row_id = displayed_ids[i] or i
        local val = (vvals[vid] and vvals[vid][row_id]) or tok
        table.insert(displayed_data[i], ins_idx, val)
    end

    grid.set(bufnr, 'displayed_header', displayed_header)
    grid.set(bufnr, 'displayed_col_ids', displayed_col_ids)
    grid.set(bufnr, 'displayed_data', displayed_data)
    grid.set(bufnr, 'virtual_footer_db', nil)

    if not opts.from_persist then
        persist_buffer_columns(bufnr)
    end
    refresh_grid_view(bufnr)

    local st = err_stats[name]
    if st and st.div_zero > 0 and not opts.silent then
        vim.notify(string.format('%s: %d row(s) divided by zero', name, st.div_zero),
            vim.log.levels.WARN, { title = 'Teradata' })
    end

    return entry, nil
end

local function normalize_lookup_name(name)
    name = trim(name or '')
    local pref = header_prefix()
    if pref ~= '' and name:sub(1, #pref) == pref then
        name = trim(name:sub(#pref + 1))
    end
    if name:match('^".*"$') then
        name = name:sub(2, -2):gsub('""', '"')
    end
    return name:upper()
end

--- Removes a virtual column by name. Refuses if another virtual column depends on it.
--- @param bufnr integer
--- @param name string
--- @return boolean ok, string|nil err
function M.remove_column(bufnr, name)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    local target_up = normalize_lookup_name(name)
    if target_up == '' then
        vim.notify('Specify a virtual column name to remove.', vim.log.levels.WARN, { title = 'Teradata' })
        return false, 'missing column name'
    end

    local found_idx, target = nil, nil
    for i, vc in ipairs(vcols) do
        if vc.name:upper() == target_up or vc.id:upper() == target_up then
            found_idx, target = i, vc
            break
        end
    end
    if not target then
        local msg = string.format("Virtual column '%s' not found.", tostring(name))
        vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' })
        return false, msg
    end

    for i, vc in ipairs(vcols) do
        if i ~= found_idx then
            for _, r in ipairs(vc.refs or {}) do
                if r:upper() == target.name:upper() then
                    local msg = string.format(
                        "Cannot remove '%s': referenced by virtual column '%s'.",
                        target.name, vc.name)
                    vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' })
                    return false, msg
                end
            end
        end
    end

    table.remove(vcols, found_idx)
    grid.set(bufnr, 'virtual_columns', vcols)

    local vvals = grid.get(bufnr, 'virtual_values') or {}
    vvals[target.id] = nil
    grid.set(bufnr, 'virtual_values', vvals)

    local displayed_header  = grid.get(bufnr, 'displayed_header') or {}
    local displayed_data    = grid.get(bufnr, 'displayed_data') or {}
    local displayed_col_ids = grid.get(bufnr, 'displayed_col_ids') or {}
    for j = #displayed_col_ids, 1, -1 do
        if displayed_col_ids[j] == target.id then
            table.remove(displayed_col_ids, j)
            table.remove(displayed_header, j)
            for _, row in ipairs(displayed_data) do
                table.remove(row, j)
            end
        end
    end
    grid.set(bufnr, 'displayed_header', displayed_header)
    grid.set(bufnr, 'displayed_col_ids', displayed_col_ids)
    grid.set(bufnr, 'displayed_data', displayed_data)
    grid.set(bufnr, 'virtual_footer_db', nil)

    local removed_cols = grid.get(bufnr, 'removed_columns') or {}
    for i = #removed_cols, 1, -1 do
        if removed_cols[i].col_id == target.id then
            table.remove(removed_cols, i)
        end
    end
    grid.set(bufnr, 'removed_columns', removed_cols)

    local sort_spec = grid.get(bufnr, 'sort_spec') or {}
    for i = #sort_spec, 1, -1 do
        if sort_spec[i].col_id == target.id then
            table.remove(sort_spec, i)
        end
    end
    grid.set(bufnr, 'sort_spec', sort_spec)

    persist_buffer_columns(bufnr)
    refresh_grid_view(bufnr)
    return true, nil
end

--- Lists the virtual columns currently registered on `bufnr`.
--- @param bufnr integer
--- @return table[]
function M.list_columns(bufnr)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    local out = {}
    for i, vc in ipairs(vcols) do
        out[i] = {
            id   = vc.id,
            name = vc.name,
            expr = vc.expr,
            refs = vim.deepcopy(vc.refs),
        }
    end
    return out
end

--- Edits the expression of an existing virtual column.
--- If `new_expr` is omitted, prompts with `vim.ui.input` pre-filled with the current expression.
--- @param bufnr integer
--- @param name string|nil
--- @param new_expr string|nil
--- @return boolean ok, string|nil err
function M.edit_column(bufnr, name, new_expr)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local all_header = ensure_grid_basics(bufnr)
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    if #vcols == 0 then
        vim.notify('No virtual columns defined on this buffer.', vim.log.levels.WARN, { title = 'Teradata' })
        return false, 'no virtual columns'
    end

    local target_up = normalize_lookup_name(name or '')
    if target_up == '' then
        local cidx = cursor_column_index(bufnr)
        local col_ids = grid.get(bufnr, 'displayed_col_ids') or {}
        local cid = cidx and col_ids[cidx] or nil
        if type(cid) == 'string' then
            target_up = cid:upper()
        elseif #vcols == 1 then
            target_up = vcols[1].name:upper()
        end
    end

    local found_idx, target = nil, nil
    for i, vc in ipairs(vcols) do
        if vc.name:upper() == target_up or vc.id:upper() == target_up then
            found_idx, target = i, vc
            break
        end
    end
    if not target then
        local msg = string.format("Virtual column '%s' not found.", tostring(name or ''))
        vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' })
        return false, msg
    end

    local function apply_edit(input)
        if not input or trim(input) == '' then return false, 'cancelled' end
        input = trim(input)
        local _, rhs = M.split_col_spec(input)
        local expr_str = rhs or input

        local expr_mod = require('vim-teradata.virtual_expr')
        local ast, perr = expr_mod.parse(expr_str)
        if not ast then
            local msg = 'Invalid expression: ' .. tostring(perr)
            vim.notify(msg, vim.log.levels.ERROR, { title = 'Teradata' })
            return false, msg
        end

        local refs = expr_mod.references(ast)
        local ok_ref, rerr = validate_refs(refs, all_header, vcols, found_idx - 1, target.name)
        if not ok_ref then
            vim.notify(rerr, vim.log.levels.ERROR, { title = 'Teradata' })
            return false, rerr
        end

        target.expr = expr_str
        target.ast  = ast
        target.refs = refs

        local err_stats = M.recompute(bufnr)
        grid.set(bufnr, 'virtual_footer_db', nil)
        persist_buffer_columns(bufnr)
        refresh_grid_view(bufnr)

        local st = err_stats[target.name]
        if st and st.div_zero > 0 then
            vim.notify(string.format('%s: %d row(s) divided by zero', target.name, st.div_zero),
                vim.log.levels.WARN, { title = 'Teradata' })
        end
        return true, nil
    end

    if new_expr ~= nil then
        return apply_edit(new_expr)
    end

    local ok_res, err_res = true, nil
    vim.ui.input({
        prompt  = string.format('Virtual column %s = ', target.name),
        default = target.expr,
    }, function(input)
        if input == nil then return end
        ok_res, err_res = apply_edit(input)
    end)
    return ok_res, err_res
end

--- Prompts the user to add a virtual column via `vim.ui.input`.
--- @param bufnr integer
function M.prompt_add_column(bufnr)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    vim.ui.input({ prompt = 'Virtual column (name = expr): ' }, function(input)
        if not input or trim(input) == '' then return end
        M.add_column(bufnr, input, nil)
    end)
end

--- Opens a scratch split listing the virtual columns of `bufnr` as `name = expr`.
--- @param bufnr integer
--- @return integer scratch_bufnr
function M.show_columns(bufnr)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vcols = M.list_columns(bufnr)
    local lines = {}
    if #vcols == 0 then
        lines[1] = '(no virtual columns)'
    else
        for _, vc in ipairs(vcols) do
            lines[#lines + 1] = string.format('%s = %s', vc.name, vc.expr)
        end
    end
    local sbuf = require('vim-teradata.ui').open_scratch('Teradata Virtual Columns', math.max(5, #lines + 2))
    vim.bo[sbuf].modifiable = true
    vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
    vim.bo[sbuf].modifiable = false
    vim.keymap.set('n', 'q', function()
        if vim.api.nvim_buf_is_valid(sbuf) then
            vim.api.nvim_buf_delete(sbuf, { force = true })
        end
    end, { buffer = sbuf, silent = true, nowait = true })
    return sbuf
end

--- Restores persisted virtual columns for `bufnr` when `original_query` matches
--- a previously saved normalized SQL hash.
--- @param bufnr integer
--- @param original_query string|nil
function M.restore_persisted_columns(bufnr, original_query)
    if not original_query or original_query == '' then return end
    grid.set(bufnr, 'original_query', original_query)
    local hash = M.normalize_sql_hash(original_query)
    if not hash then return end
    grid.set(bufnr, 'query_sql_hash', hash)

    if virt_cfg().persist_columns == false then return end
    local store = load_persistence_store()
    local saved = store[hash]
    if type(saved) ~= 'table' or #saved == 0 then return end

    local skipped = {}
    for _, item in ipairs(saved) do
        if type(item) == 'table' and item.name and item.expr then
            local entry = M.add_column(bufnr, item.name, item.expr, {
                silent       = true,
                from_persist = true,
            })
            if not entry then
                skipped[#skipped + 1] = item.name
            end
        end
    end
    if #skipped > 0 then
        vim.notify(
            string.format('Skipped persisted virtual column(s) with missing references: %s',
                table.concat(skipped, ', ')),
            vim.log.levels.WARN,
            { title = 'Teradata' }
        )
    end
end

--- Command-line completion for `:TDCol` and `:TDColEdit`.
--- @param bufnr integer
--- @param arg_lead string
--- @param only_virtual boolean|nil
--- @return string[]
function M.complete(bufnr, arg_lead, only_virtual)
    arg_lead = arg_lead or ''
    local prefix, token = arg_lead:match('^(.*[^%w_])([%w_]*)$')
    if not prefix then
        prefix, token = '', arg_lead
    end
    local token_up = token:upper()
    local candidates, seen = {}, {}

    local function push(w)
        if w and not seen[w] and w:upper():find(token_up, 1, true) == 1 then
            seen[w] = true
            candidates[#candidates + 1] = prefix .. w
        end
    end

    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    for _, vc in ipairs(vcols) do
        push(vc.name)
    end

    if not only_virtual then
        local all_header = grid.get(bufnr, 'all_header') or grid.get(bufnr, 'displayed_header') or {}
        for _, h in ipairs(all_header) do
            push(h)
        end
        local expr_mod = require('vim-teradata.virtual_expr')
        for _, fn in ipairs(expr_mod.FUNCTIONS or {}) do
            push(fn)
        end
    end

    table.sort(candidates)
    return candidates
end

-- =============================================================================
-- Patch 3 — SQL pushdown & volatile-table materialization
-- =============================================================================

local function get_original_query(bufnr)
    local q = grid.get(bufnr, 'original_query')
    if q and q ~= '' then return q end
    local qid = grid.get(bufnr, 'query_id')
    if not qid then return nil end
    local qpath = util.get_history_path('queries_dir_name') .. '/' .. qid .. '.sql'
    if vim.fn.filereadable(qpath) == 1 then
        local lines = vim.fn.readfile(qpath)
        q = table.concat(lines, '\n')
        grid.set(bufnr, 'original_query', q)
        return q
    end
    return nil
end

--- Returns true when `name` is registered in the `materialized` volatile-table registry.
--- @param name string
--- @param session_buf integer|nil
--- @return boolean
function M.is_materialized_table(name, session_buf)
    if type(name) ~= 'string' or name == '' then return false end
    local up = name:upper()
    if session_buf then
        for _, n in pairs(materialized[session_buf] or {}) do
            if n:upper() == up then return true end
        end
        return false
    end
    for _, per_sess in pairs(materialized) do
        for _, n in pairs(per_sess) do
            if n:upper() == up then return true end
        end
    end
    return false
end

--- Exposed for tests to register or inspect materialized volatile tables.
function M._register_materialized(session_buf, query_id, name)
    ensure_session_hook()
    materialized[session_buf] = materialized[session_buf] or {}
    materialized[session_buf][tostring(query_id)] = name
end

function M._materialized()
    return materialized
end

--- Builds the override `meta` passed to `edit.build_statements` when editing
--- against a materialized volatile table (`edit_target = 'volatile'`).
--- @param vt_name string
--- @param header string[]
--- @return table meta
function M.volatile_edit_meta(vt_name, header)
    local vsql = require('vim-teradata.virtual_sql')
    local cols = {}
    for i, h in ipairs(header or {}) do
        cols[i] = {
            result_name   = h,
            eligible      = true,
            source_column = vsql.quote_ident(h),
            table_key     = 'VT',
        }
    end
    return {
        editable = true,
        mode     = 'simple',
        columns  = cols,
        tables   = {
            VT = { display = vt_name, update_name = vt_name },
        },
    }
end

--- Runs an exact database pushdown for the current summary footer mode on `bufnr`.
--- @param bufnr integer|nil
--- @param cb fun(err: string|nil, values: string[]|nil)|nil
function M.footer_pushdown(bufnr, cb)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vcfg = virt_cfg()
    local mode = grid.get(bufnr, 'virtual_footer_mode') or vcfg.footer_default or 'off'
    if mode == 'off' or not MODE_LABELS[mode] then
        vim.notify('Enable a totals footer with gS first.', vim.log.levels.INFO, { title = 'Teradata' })
        if cb then cb('footer is off', nil) end
        return
    end

    local all_header, _, _, _, _, displayed_col_ids = ensure_grid_basics(bufnr)
    if #displayed_col_ids == 0 then
        if cb then cb('no columns', nil) end
        return
    end

    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    local vcol_by_id = {}
    for _, vc in ipairs(vcols) do vcol_by_id[vc.id] = vc end

    local cols = {}
    for j, cid in ipairs(displayed_col_ids) do
        local st = M.stats(column_values(bufnr, j, 'all'))
        local is_num = st.count_num > 0 and st.all_numeric
        if type(cid) == 'string' and vcol_by_id[cid] then
            local vc = vcol_by_id[cid]
            cols[j] = { name = vc.name, is_numeric = is_num, expr = vc.ast and vc.ast.src or vc.expr }
        else
            local h = all_header[cid] or ('col' .. tostring(cid))
            cols[j] = { name = h, is_numeric = is_num }
        end
    end

    local vt = grid.get(bufnr, 'virtual_materialized')
    local orig_sql = get_original_query(bufnr)
    local vsql = require('vim-teradata.virtual_sql')
    local push_sql, serr = vsql.build_footer_sql({
        sql     = orig_sql,
        header  = all_header,
        columns = cols,
        vcols   = vcols,
        mode    = mode,
        vt_name = vt and vt.name or nil,
    })
    if not push_sql then
        vim.notify('Cannot push footer to Teradata: ' .. tostring(serr),
            vim.log.levels.WARN, { title = 'Teradata' })
        if cb then cb(serr, nil) end
        return
    end

    local bteq = require('vim-teradata.bteq')
    local session = require('vim-teradata.session')
    local qid = grid.get(bufnr, 'query_id')
    local sbuf = (vt and vt.session_buf) or bteq.session_buf_for(qid)
    if sbuf and not session.get(sbuf) then sbuf = nil end

    local col_key = current_col_key(bufnr)
    grid.set(bufnr, 'virtual_footer_loading', true)
    M.render_footer(bufnr)

    bteq.run_virtual(push_sql, {
        session_buf   = sbuf,
        label         = 'virtual: ' .. mode:upper() .. ' pushdown',
        skip_retlimit = true,
    }, function(err, res)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        grid.set(bufnr, 'virtual_footer_loading', false)
        if err or not res or not res.rows or not res.rows[1] then
            M.render_footer(bufnr)
            require('vim-teradata.ui').display_error(err or 'Footer pushdown returned no rows.')
            if cb then cb(err or 'no rows', nil) end
            return
        end

        local tok = null_token()
        local row = res.rows[1]
        local formatted = {}
        for j = 1, #cols do
            local cell = row[j] or ''
            if cell == '' or cell == tok then
                formatted[j] = ''
            else
                local n = M.to_number(cell)
                if n ~= nil then
                    formatted[j] = M.format_number(n)
                else
                    formatted[j] = cell
                end
            end
        end

        grid.set(bufnr, 'virtual_footer_db', {
            mode    = mode,
            col_key = col_key,
            values  = formatted,
            at      = os.time(),
        })
        M.render_footer(bufnr)
        if cb then cb(nil, formatted) end
    end)
end

--- Pushes the virtual columns of `bufnr` to Teradata and opens the resulting grid (`:TDColPush`).
--- @param bufnr integer|nil
--- @param cb fun(err: string|nil, res: table|nil)|nil
function M.push_columns(bufnr, cb)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vcols = grid.get(bufnr, 'virtual_columns') or {}
    if #vcols == 0 then
        vim.notify('No virtual columns to push. Add one with = or :TDCol first.',
            vim.log.levels.WARN, { title = 'Teradata' })
        if cb then cb('no virtual columns', nil) end
        return
    end

    local all_header = ensure_grid_basics(bufnr)
    local vt = grid.get(bufnr, 'virtual_materialized')
    local orig_sql = get_original_query(bufnr)
    local vsql = require('vim-teradata.virtual_sql')

    local push_sql, serr, dropped_ob = vsql.build_col_push_sql({
        sql     = orig_sql,
        header  = all_header,
        vcols   = vcols,
        vt_name = vt and vt.name or nil,
    })
    if not push_sql then
        vim.notify('Cannot push virtual columns: ' .. tostring(serr),
            vim.log.levels.ERROR, { title = 'Teradata' })
        if cb then cb(serr, nil) end
        return
    end

    if dropped_ob then
        vim.notify('Dropped ORDER BY that references non-result columns.',
            vim.log.levels.INFO, { title = 'Teradata' })
    end

    local bteq = require('vim-teradata.bteq')
    local session = require('vim-teradata.session')
    local qid = grid.get(bufnr, 'query_id')
    local sbuf = (vt and vt.session_buf) or bteq.session_buf_for(qid)
    if sbuf and not session.get(sbuf) then sbuf = nil end

    local pushed_desc = {}
    for _, vc in ipairs(vcols) do
        pushed_desc[#pushed_desc + 1] = string.format('%s = %s', vc.name, vc.ast and vc.ast.src or vc.expr)
    end

    bteq.run_virtual(push_sql, {
        session_buf = sbuf,
        display     = true,
        label       = 'virtual: push columns',
    }, function(err, res)
        if err then
            local msg = err
            if res and res.query_path then
                msg = msg .. '\nGenerated SQL: ' .. res.query_path
            end
            require('vim-teradata.ui').display_error(msg)
            if cb then cb(err, res) end
            return
        end
        vim.notify('Pushed virtual column(s): ' .. table.concat(pushed_desc, ', '),
            vim.log.levels.INFO, { title = 'Teradata' })
        if cb then cb(nil, res) end
    end)
end

local function resolve_materialize_session(bufnr)
    local bteq = require('vim-teradata.bteq')
    local session = require('vim-teradata.session')
    local qid = grid.get(bufnr, 'query_id')
    local sbuf = bteq.session_buf_for(qid)
    if sbuf and session.get(sbuf) then
        return sbuf
    end
    local prev_win = vim.fn.win_getid(vim.fn.winnr('#'))
    if prev_win and prev_win ~= 0 and vim.api.nvim_win_is_valid(prev_win) then
        local prev_buf = vim.api.nvim_win_get_buf(prev_win)
        if prev_buf and session.get(prev_buf) then
            return prev_buf
        end
    end
    return nil
end

--- Materializes the current result buffer into a volatile table in a persistent session (`:TDMaterialize`).
--- @param bufnr integer|nil
--- @param custom_name string|nil
--- @param cb fun(err: string|nil, vt_name: string|nil)|nil
function M.materialize(bufnr, custom_name, cb)
    ensure_session_hook()
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local sbuf = resolve_materialize_session(bufnr)
    if not sbuf then
        local msg = 'Open a persistent session with :TDSession first.'
        vim.notify(msg, vim.log.levels.WARN, { title = 'Teradata' })
        if cb then cb(msg, nil) end
        return
    end

    local all_header = ensure_grid_basics(bufnr)
    local qid = grid.get(bufnr, 'query_id')
    local orig_sql = get_original_query(bufnr)
    local vsql = require('vim-teradata.virtual_sql')
    local name_arg = (custom_name and trim(custom_name) ~= '') and trim(custom_name) or vsql.default_vt_name(qid)

    local ddl, derr, vt_name = vsql.build_materialize_sql(orig_sql or '', all_header, name_arg)
    if not ddl then
        vim.notify('Cannot materialize result: ' .. tostring(derr),
            vim.log.levels.ERROR, { title = 'Teradata' })
        if cb then cb(derr, nil) end
        return
    end

    local bteq = require('vim-teradata.bteq')
    local session = require('vim-teradata.session')
    local ui = require('vim-teradata.ui')

    local function run_create()
        bteq.run_virtual(ddl, {
            session_buf   = sbuf,
            label         = 'virtual: materialize ' .. vt_name,
            skip_retlimit = true,
        }, function(err)
            if err then
                ui.display_error(err)
                if cb then cb(err, nil) end
                return
            end
            M._register_materialized(sbuf, qid or tostring(bufnr), vt_name)
            grid.set(bufnr, 'virtual_materialized', {
                name        = vt_name,
                session_buf = sbuf,
                query_id    = qid,
            })
            refresh_grid_view(bufnr)

            bteq.run_virtual('SELECT COUNT(*) FROM ' .. vt_name .. ';', {
                session_buf   = sbuf,
                label         = 'virtual: count ' .. vt_name,
                skip_retlimit = true,
            }, function(cerr, cres)
                local cnt = (not cerr and cres and cres.rows and cres.rows[1] and cres.rows[1][1]) or '?'
                local sess = session.get(sbuf)
                local u_str = (sess and sess.user) and (sess.user.user .. '@' .. sess.user.tdpid) or '?'
                vim.notify(string.format('%s rows materialized in %s (session %s)', cnt, vt_name, u_str),
                    vim.log.levels.INFO, { title = 'Teradata' })
                if cb then cb(nil, vt_name) end
            end)
        end)
    end

    if M.is_materialized_table(vt_name, sbuf) then
        vim.ui.select({ 'Replace', 'Cancel' }, {
            prompt = string.format('Volatile table %s already exists in session:', vt_name),
        }, function(choice)
            if choice ~= 'Replace' then
                if cb then cb('cancelled', nil) end
                return
            end
            assert(M.is_materialized_table(vt_name, sbuf),
                'vim-teradata: refusing to DROP unregistered table ' .. tostring(vt_name))
            bteq.run_virtual('DROP TABLE ' .. vt_name .. ';', {
                session_buf   = sbuf,
                label         = 'virtual: drop ' .. vt_name,
                skip_retlimit = true,
            }, function(drop_err)
                if drop_err then
                    ui.display_error(drop_err)
                    if cb then cb(drop_err, nil) end
                    return
                end
                run_create()
            end)
        end)
    else
        run_create()
    end
end

--- Drops the volatile table materialized for `bufnr` (`:TDMaterialize!`).
--- @param bufnr integer|nil
--- @param cb fun(err: string|nil)|nil
function M.unmaterialize(bufnr, cb)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vt = grid.get(bufnr, 'virtual_materialized')
    if not vt or not vt.name then
        vim.notify('This result is not materialized.', vim.log.levels.WARN, { title = 'Teradata' })
        if cb then cb('not materialized') end
        return
    end

    assert(M.is_materialized_table(vt.name, vt.session_buf),
        'vim-teradata: refusing to DROP unregistered table ' .. tostring(vt.name))

    local bteq = require('vim-teradata.bteq')
    local session = require('vim-teradata.session')
    local sbuf = vt.session_buf
    local name = vt.name
    local qkey = tostring(vt.query_id or bufnr)

    local function clear_local()
        if materialized[sbuf] then
            materialized[sbuf][qkey] = nil
        end
        grid.set(bufnr, 'virtual_materialized', nil)
        if grid.get(bufnr, 'virtual_edit_target') == 'volatile' then
            grid.set(bufnr, 'virtual_edit_target', 'table')
        end
        refresh_grid_view(bufnr)
    end

    if not (sbuf and session.get(sbuf)) then
        clear_local()
        if cb then cb(nil) end
        return
    end

    bteq.run_virtual('DROP TABLE ' .. name .. ';', {
        session_buf   = sbuf,
        label         = 'virtual: drop ' .. name,
        skip_retlimit = true,
    }, function(err)
        if err then
            require('vim-teradata.ui').display_error(err)
            if cb then cb(err) end
            return
        end
        clear_local()
        vim.notify('Dropped volatile table ' .. name .. '.', vim.log.levels.INFO, { title = 'Teradata' })
        if cb then cb(nil) end
    end)
end

--- Focuses (or opens) the session SQL buffer of a materialized result and appends
--- `SELECT * FROM <name>;` on a new line at the end (`:TDVQuery`).
--- @param bufnr integer|nil
function M.vquery(bufnr)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local vt = grid.get(bufnr, 'virtual_materialized')
    if not vt or not vt.name or not vt.session_buf then
        vim.notify('Materialize this result with :TDMaterialize first.',
            vim.log.levels.WARN, { title = 'Teradata' })
        return
    end
    local sbuf = vt.session_buf
    if not vim.api.nvim_buf_is_valid(sbuf) then
        vim.notify('The session SQL buffer is no longer valid.',
            vim.log.levels.WARN, { title = 'Teradata' })
        return
    end

    local target_win = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == sbuf then
            target_win = w
            break
        end
    end
    if target_win then
        vim.api.nvim_set_current_win(target_win)
    else
        vim.cmd('aboveleft split')
        vim.api.nvim_win_set_buf(0, sbuf)
    end

    local line_count = vim.api.nvim_buf_line_count(sbuf)
    local stmt = 'SELECT * FROM ' .. vt.name .. ';'
    vim.api.nvim_buf_set_lines(sbuf, line_count, line_count, false, { stmt })
    vim.api.nvim_win_set_cursor(0, { line_count + 1, 0 })
end

--- Sets or toggles the buffer-local edit target (`'table'` or `'volatile'`).
--- @param bufnr integer|nil
--- @param target string|nil
function M.set_edit_target(bufnr, target)
    bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
    local cur = grid.get(bufnr, 'virtual_edit_target') or virt_cfg().edit_target or 'table'
    target = (target and trim(target) ~= '') and trim(target):lower()
        or (cur == 'volatile' and 'table' or 'volatile')
    if target ~= 'table' and target ~= 'volatile' then
        vim.notify("Edit target must be 'table' or 'volatile'.",
            vim.log.levels.WARN, { title = 'Teradata' })
        return
    end
    if target == 'volatile' and not grid.get(bufnr, 'virtual_materialized') then
        vim.notify('Materialize this result with :TDMaterialize before switching edit target to volatile.',
            vim.log.levels.WARN, { title = 'Teradata' })
        return
    end
    grid.set(bufnr, 'virtual_edit_target', target)
    vim.notify('Edit target set to: ' .. target, vim.log.levels.INFO, { title = 'Teradata' })
    refresh_grid_view(bufnr)
end

-- =============================================================================
-- Patch 1 — Selection quick-calc
-- =============================================================================

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

    local vcfg = virt_cfg()
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
