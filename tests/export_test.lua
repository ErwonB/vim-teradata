local export = require('vim-teradata.export')
local config = require('vim-teradata.config')
local util = require('vim-teradata.util')
config.ensure()

local site = vim.fn.stdpath('data') .. '/site'
if vim.fn.isdirectory(site) == 1 then vim.opt.runtimepath:prepend(site) end
local HAS_PARSER = pcall(vim.treesitter.language.add, 'teradata')

local USER = { user = 'U', tdpid = 'H', log_mech = 'TD2' }

local function jobvars(over)
    local vars = vim.tbl_extend('force', {
        user = USER,
        data_path = 'C:\\data\\exports',
        file_name = '1.csv',
        sep = '~',
        max_sessions = 4,
        select_stmt = 'select 1;',
    }, over or {})
    return export._jobvars_text(vars)
end

test("config defaults for export", function()
    assert(config.defaults.export.keymap == 'F')
    assert(config.defaults.export.operator == 'auto')
    assert(config.defaults.export.confirm == true)
    assert(config.defaults.exports_dir_name == 'exports')
    assert(config.get_tpt_export_script('R') == nil or config.get_tpt_export_script('R'):find('export_query_selector.tpt', 1, true))
end)

test("_wrap_select wraps every column in TRIM with a derived column list", function()
    local w = export._wrap_select("select a, 'x''y' from t;", 3)
    assert(w == "SELECT TRIM(t.c1) AS c1, TRIM(t.c2) AS c2, TRIM(t.c3) AS c3\n"
        .. "FROM (\nselect a, 'x''y' from t\n) AS t (c1, c2, c3);", w)
    assert(w:sub(-1) == ';' and select(2, w:gsub(';', '')) == 1, w)
    assert(select(2, w:gsub('TRIM%(', '')) == 3)
    local c = export._wrap_select('select 1 -- hi\n;', 1)
    assert(c:find('select 1 -- hi\n) AS t (c1);', 1, true), c)
    assert(not export._wrap_select('select 1;', nil))
    assert(not export._wrap_select('select 1;', 0))
end)

test("_wrap_select hoists access locks only", function()
    local a = export._wrap_select('LOCKING ROW FOR ACCESS select x from t;', 1)
    assert(a:find('^LOCKING ROW FOR ACCESS\nSELECT TRIM%(t%.c1%)'), a)
    assert(a:find('\nFROM (\nselect x from t\n) AS t (c1);', 1, true), a)
    local b = export._wrap_select('lock table x for access nowait select x from t;', 1)
    assert(b:find('^lock table x for access nowait\nSELECT'), b)
    local nl, reason = export._wrap_select('LOCKING ROW FOR SHARE select x from access_log;', 1)
    assert(nl == nil and reason)
end)

test("_choose_route covers every fallback", function()
    local function route(sql, n, op)
        local r, e = export._choose_route(sql, n, op)
        return r, e
    end
    assert(route('select 1 from t;', 1, 'auto') == 'W' or not HAS_PARSER)
    assert(route('select 1 from t;', 1, 'selector') == 'R')
    assert(route('select 1 from t;', nil, 'auto') == 'R')
    assert(route('with a as (select 1 x) select x from a;', 1, 'auto') == 'R')
    assert(route('lock row for share select 1 from t;', 1, 'auto') == 'R')
    local r, e = route('with a as (select 1 x) select x from a;', 1, 'export')
    assert(r == nil and e)
    if not HAS_PARSER then
        print('  (teradata parser not found: ORDER BY routing assertions skipped)')
        return
    end
    assert(route('select a from t order by a;', 1, 'auto') == 'R')
    assert(route('select top 5 a from t order by a;', 1, 'auto') == 'R')
    assert(route('select a from t union select a from u order by 1;', 1, 'auto') == 'R')
    assert(route('select * from (select a from t order by a) d;', 1, 'auto') == 'W')
    assert(route('select a, row_number() over (order by a) from t;', 2, 'auto') == 'W')
    assert(route('locking row for access select a from t;', 1, 'auto') == 'W')
    r, e = route('select a from t order by a;', 1, 'export')
    assert(r == nil and e)
end)

test("_should_retry detects data type failures", function()
    assert(export._should_retry({ 'x', 'TPT12108: Output Schema does not match data from SELECT statement' })
        == 'TPT12108: Output Schema does not match data from SELECT statement')
    assert(export._should_retry({ '  TPT02639: Conflicting data type for column(1)' }))
    assert(export._should_retry({ 'Teradata Database error 3532: Conversion between data types makes no sense.' }))
    assert(export._should_retry({ 'Failure 5407: Invalid operand in TRIM function' }))
    assert(not export._should_retry({ 'Failure 3807: Object does not exist', 'Syntax error 3706: expected' }))
    assert(not export._should_retry({}))
end)

test("job variables double quotes and use forward slashes", function()
    local lines = jobvars({ select_stmt = "select 'a''b' from t;" })
    local text = table.concat(lines, '\n')
    assert(text:find("select_stmt  = 'select ''a''''b'' from t;'", 1, true), text)
    assert(text:find("data_path    = 'C:/data/exports'", 1, true), text)
    assert(text:find('max_sessions = 4', 1, true))
end)

test("job variables reject unsafe paths, users and separators", function()
    assert(not jobvars({ data_path = "/tmp/o'brien" }))
    assert(not jobvars({ file_name = "a'b.csv" }))
    assert(not jobvars({ user = { user = "U'", tdpid = 'H', log_mech = 'TD2' } }))
    assert(not jobvars({ sep = "'" }))
    assert(not jobvars({ sep = '\n' }))
end)

test("prepared SQL applies replacements and ends with one semicolon", function()
    local saved = config.options.replacements
    config.options.replacements = { ['${DB}'] = 'MYDB' }
    local sql = export._prepare_sql('-- c\nselect * from ${DB}.t ;;  \n')
    config.options.replacements = saved
    assert(sql == 'select * from MYDB.t;', sql)
    assert(export._prepare_sql('select 1 -- trailing') == 'select 1 -- trailing\n;')
end)

test("statement validation accepts a single SELECT only", function()
    for _, s in ipairs({
        'select 1', 'SEL 1;', 'with a as (select 1) select * from a',
        'locking row for access select 1', '/* c */ -- x\nselect 1;', 'select 1; -- done',
    }) do
        assert(export._validate_statement(s), s)
    end
    for _, s in ipairs({
        'select 1; select 2', 'explain select 1', 'show table t', 'help table t',
        'insert into t values (1)', 'create table t (a int)', '', 'lock table t for access',
    }) do
        assert(not export._validate_statement(s), s)
    end
end)

test("job names are uppercase, safe and unique per run", function()
    local a, b = export._job_name('2026_ab-1#x'), export._job_name('2026_ab-1#x')
    assert(a:match('^[A-Z0-9_]+$'), a)
    assert(a ~= b)
end)

test("rows are parsed from tbuild output", function()
    assert(export._parse_rows({ 'QUERY_SOURCE: Total Rows Exported:  12' }) == 12)
    assert(export._parse_rows({ 'x', 'Rows Exported: 2,340,118' }) == 2340118)
    assert(export._parse_rows({ 'QUERY_SOURCE: Total Rows Exported: 5', 'FILE_WRITER: Total Rows Exported: 7' }) == 7)
    assert(export._parse_rows({ 'nothing' }) == nil)
end)

test("TPT job id and error lines are extracted", function()
    assert(export._parse_job_id({ 'Job id is VTD_EXP_1-42, running on host' }) == 'VTD_EXP_1-42')
    assert(export._parse_job_id({ 'nope' }) == nil)
    local errs = export._error_text({ 'ok line', 'TPT10508: RDBMS error 3524', 'Job terminated with status 12' })
    assert(#errs == 1 and errs[1]:find('TPT10508'))
    local many = {}
    for i = 1, 30 do many[i] = 'plain ' .. i end
    local tail = export._error_text(many)
    assert(#tail == 10 and tail[10] == 'plain 30')
end)

test("size estimate and human_bytes", function()
    local est, avg = export._estimate(1000, 9, 10, 1000)
    assert(avg == 99 and est == 99000)
    assert(export._estimate(1000, 9, 10, nil) == nil)
    assert(export._estimate(nil, 9, 10, 5) == nil)
    assert(util.human_bytes(512) == '512 B')
    assert(util.human_bytes(1536) == '1.5 KB')
    assert(util.human_bytes(412 * 1024 * 1024) == '412 MB')
end)

test("export jobs carry no query_path", function()
    local id = 'exp_test#export1'
    util.jobs_add({ id = id, source_id = 'exp_test', operation = 'export', status = 'ok', query_path = nil })
    assert(util.jobs_get(id).query_path == nil)
    util.jobs_remove(id)
end)

test("dialog lines show conditional rows and warnings", function()
    local lines = export.dialog_lines({
        id = 'q1', user_label = 'U@H (TD2)', rows_found = 50, preview_rows = 50, retlimit = 100,
        target_path = '/very/long/' .. string.rep('d/', 40) .. 'q1.csv', target_exists = true,
        target_mtime = os.time(), target_size = 2048, operator = 'export', max_sessions = 4,
        warnings = { 'careful' },
    }, 60)
    local text = {}
    for _, l in ipairs(lines) do
        text[#text + 1] = l[1]
        if l[1]:find('^ Target') then assert(vim.fn.strchars(l[1]) <= 60, l[1]) end
    end
    text = table.concat(text, '\n')
    assert(text:find('Grid already shows every row', 1, true))
    assert(text:find('Overwrites the existing export', 1, true))
    assert(text:find('…', 1, true))
    assert(lines[#lines][2] == 'WarningMsg')
end)

local function with_history_query(id, fn)
    local qdir = util.get_history_path('queries_dir_name')
    vim.fn.mkdir(qdir, 'p')
    local qpath = qdir .. '/' .. id .. '.sql'
    vim.fn.writefile({ 'select 1;' }, qpath)
    local ok, err = pcall(fn)
    util.remove_files(qpath)
    assert(ok, err)
end

local function close_current_grid()
    local buf = vim.api.nvim_get_current_buf()
    if #vim.api.nvim_list_wins() > 1 then pcall(vim.api.nvim_win_close, 0, true) end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

test("display_output max_lines reads only the head", function()
    local id = 'exp_head_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    local rows = { 'a~b' }
    for i = 1, 9 do rows[#rows + 1] = i .. '~x' .. i end
    vim.fn.writefile(rows, path)
    with_history_query(id, function()
        require('vim-teradata.ui').display_output(path, id, {
            max_lines = 3, editable = false, source = 'tpt', rows_total = 9,
        })
        local grid = require('vim-teradata.grid_state')
        local buf = vim.api.nvim_get_current_buf()
        assert(#grid.get(buf, 'all_data') == 2, 'expected 2 data rows')
        assert(vim.fn.maparg('F', 'n', false, true).buffer ~= 1, 'F must not be bound on export grids')
        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("display_output synthesises col1..colN without a header", function()
    local id = 'exp_nohdr_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({ '1~x~y', '2~z~w' }, path)
    with_history_query(id, function()
        require('vim-teradata.ui').display_output(path, id, { editable = false, has_header = false })
        local grid = require('vim-teradata.grid_state')
        local buf = vim.api.nvim_get_current_buf()
        assert(vim.deep_equal(grid.get(buf, 'all_header'), { 'col1', 'col2', 'col3' }))
        assert(#grid.get(buf, 'all_data') == 2)
        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("display_output aligns UTF-8 accented characters by display width", function()
    local id = 'exp_utf8_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'FIELD_ZONE_NAME~LANG_CD~ADDL_INFO',
        'Amount of payment debt arrears~EN~R',
        "Montant d'encours en arri\195\169r\195\169 de paiement~FR~R",
    }, path)
    with_history_query(id, function()
        require('vim-teradata.ui').display_output(path, id, { editable = false })
        local buf = vim.api.nvim_get_current_buf()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, 4, false)
        local w_hdr = vim.fn.strdisplaywidth(lines[1])
        local w_sep = vim.fn.strdisplaywidth(lines[2])
        local w_en  = vim.fn.strdisplaywidth(lines[3])
        local w_fr  = vim.fn.strdisplaywidth(lines[4])
        assert(w_hdr == w_sep and w_sep == w_en and w_en == w_fr,
            string.format('expected equal display widths, got hdr=%d sep=%d en=%d fr=%d', w_hdr, w_sep, w_en, w_fr))
        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("confirm_box: <CR> is inert, y confirms, q cancels", function()
    local ui = require('vim-teradata.ui')
    local function press(keys)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
    end
    local confirmed, cancelled = 0, 0
    local function open()
        return ui.confirm_box({
            title = ' T ', lines = { { 'hello' }, { 'careful', 'WarningMsg' } },
            on_confirm = function() confirmed = confirmed + 1 end,
            on_cancel = function() cancelled = cancelled + 1 end,
        })
    end
    local win = open()
    press('<CR>')
    assert(vim.api.nvim_win_is_valid(win) and confirmed == 0)
    press('y')
    assert(confirmed == 1 and not vim.api.nvim_win_is_valid(win))
    win = open()
    press('q')
    assert(confirmed == 1 and cancelled == 1 and not vim.api.nvim_win_is_valid(win))

    local custom = 0
    win = ui.confirm_box({ title = ' T ', lines = { { 'x' } }, footer = ' [b] go ', keys = { b = function() custom = custom + 1 end } })
    press('y')
    assert(vim.api.nvim_win_is_valid(win) and custom == 0)
    press('b')
    assert(custom == 1 and not vim.api.nvim_win_is_valid(win))
end)

test("display_output supports cumulative multi-column sorting and reset", function()
    local id = 'multi_sort_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'DEPT~ROLE~SALARY',
        'Sales~Analyst~50',
        'Eng~Dev~100',
        'Sales~Dev~80',
        'Eng~Dev~120',
        'Sales~Analyst~70',
    }, path)

    local function press(keys)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
    end

    with_history_query(id, function()
        require('vim-teradata.ui').display_output(path, id, { editable = false })
        local grid = require('vim-teradata.grid_state')
        local buf = vim.api.nvim_get_current_buf()

        -- Helper to place cursor at start of displayed column `col_idx` (1-based)
        local function goto_col(col_idx)
            local widths = grid.get(buf, 'column_widths')
            local col_pos = 1
            for i = 1, col_idx - 1 do
                col_pos = col_pos + widths[i] + 3 -- ' | '
            end
            vim.fn.cursor(3, 1)
            vim.cmd('normal! ' .. col_pos .. '|')
        end

        -- 1. Sort DEPT ascending (primary: ▲1)
        goto_col(1)
        press('<Up>')
        local data = grid.get(buf, 'displayed_data')
        assert(data[1][1] == 'Eng' and data[2][1] == 'Eng', 'Eng rows should come first')
        assert(data[3][1] == 'Sales' and data[4][1] == 'Sales' and data[5][1] == 'Sales')
        local hdr = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
        assert(hdr:find('DEPT ▲1', 1, true), 'expected DEPT ▲1 in header, got: ' .. hdr)

        -- 2. Sort ROLE ascending (secondary: ▲2)
        goto_col(2)
        press('<Up>')
        data = grid.get(buf, 'displayed_data')
        assert(data[1][1] == 'Eng' and data[2][1] == 'Eng', 'primary sort on DEPT preserved')
        assert(data[3][2] == 'Analyst' and data[4][2] == 'Analyst' and data[5][2] == 'Dev',
            'secondary sort on ROLE should order Analyst before Dev within Sales')
        hdr = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
        assert(hdr:find('DEPT ▲1', 1, true) and hdr:find('ROLE ▲2', 1, true),
            'expected both DEPT ▲1 and ROLE ▲2 in header, got: ' .. hdr)

        -- 3. Sort SALARY descending (tertiary: ▼3)
        goto_col(3)
        press('<Down>')
        data = grid.get(buf, 'displayed_data')
        assert(data[1][1] == 'Eng' and data[1][3] == '120', 'Eng Dev 120 should be first')
        assert(data[2][1] == 'Eng' and data[2][3] == '100', 'Eng Dev 100 should be second')
        assert(data[3][1] == 'Sales' and data[3][2] == 'Analyst' and data[3][3] == '70',
            'Sales Analyst 70 should precede Sales Analyst 50')
        assert(data[4][1] == 'Sales' and data[4][2] == 'Analyst' and data[4][3] == '50')
        assert(data[5][1] == 'Sales' and data[5][2] == 'Dev' and data[5][3] == '80')

        -- 4. Flip primary sort DEPT to descending (▼1) while preserving ROLE ▲2 and SALARY ▼3
        goto_col(1)
        press('<Down>')
        data = grid.get(buf, 'displayed_data')
        assert(data[1][1] == 'Sales' and data[1][2] == 'Analyst' and data[1][3] == '70')
        assert(data[2][1] == 'Sales' and data[2][2] == 'Analyst' and data[2][3] == '50')
        assert(data[3][1] == 'Sales' and data[3][2] == 'Dev' and data[3][3] == '80')
        assert(data[4][1] == 'Eng' and data[4][2] == 'Dev' and data[4][3] == '120')
        assert(data[5][1] == 'Eng' and data[5][2] == 'Dev' and data[5][3] == '100')

        -- 5. Reset sort with 'r' -> restores original row order and clears indicators
        press('r')
        local ids = grid.get(buf, 'displayed_ids')
        assert(vim.deep_equal(ids, { 1, 2, 3, 4, 5 }), 'expected original row order after reset')
        hdr = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
        assert(not hdr:find('▲', 1, true) and not hdr:find('▼', 1, true),
            'expected no sort indicators after reset, got: ' .. hdr)

        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("display_output supports column navigation and winbar indicator", function()
    local id = 'col_nav_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'COL_A~COL_B~COL_C~COL_D',
        '10~b2~c1~d1',
        '20~b1~c2~d2',
    }, path)

    local function press(keys)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
    end

    with_history_query(id, function()
        require('vim-teradata.ui').display_output(path, id, { editable = false })
        local buf = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        assert(vim.api.nvim_buf_is_valid(buf))

        -- Place cursor on first data row, column 1
        vim.fn.cursor(3, 1)
        press('g0')
        assert(vim.wo[win].winbar:find('Col 1/4: COL_A', 1, true), 'expected Col 1/4 in winbar: ' .. vim.wo[win].winbar)

        -- Step 1 column right with <Tab> -> Col 2
        press('<Tab>')
        assert(vim.wo[win].winbar:find('Col 2/4: COL_B', 1, true), 'expected Col 2/4 in winbar: ' .. vim.wo[win].winbar)

        -- Step 2 columns right with 2<Tab> -> Col 4
        press('2<Tab>')
        assert(vim.wo[win].winbar:find('Col 4/4: COL_D', 1, true), 'expected Col 4/4 in winbar: ' .. vim.wo[win].winbar)

        -- Step 1 column left with <S-Tab> -> Col 3
        press('<S-Tab>')
        assert(vim.wo[win].winbar:find('Col 3/4: COL_C', 1, true), 'expected Col 3/4 in winbar: ' .. vim.wo[win].winbar)

        -- Jump to first column with g0 and last column with g$
        press('g0')
        assert(vim.wo[win].winbar:find('Col 1/4: COL_A', 1, true))
        press('g$')
        assert(vim.wo[win].winbar:find('Col 4/4: COL_D', 1, true))

        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)
