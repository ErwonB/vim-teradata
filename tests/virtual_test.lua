local config  = require('vim-teradata.config')
local grid    = require('vim-teradata.grid_state')
local ui      = require('vim-teradata.ui')
local util    = require('vim-teradata.util')
local virtual = require('vim-teradata.virtual')

config.ensure()

test("virtual.to_number parses Teradata numbers and rejects non-numbers", function()
    assert(virtual.to_number("12") == 12)
    assert(virtual.to_number(" -3.5 ") == -3.5)
    assert(virtual.to_number("1,234.50") == 1234.50)
    assert(virtual.to_number("123-") == -123)
    assert(virtual.to_number("12.50-") == -12.50)
    assert(virtual.to_number("1.2E+03") == 1200)
    assert(virtual.to_number("") == nil)
    assert(virtual.to_number("NULL") == nil)
    assert(virtual.to_number("abc") == nil)
    assert(virtual.to_number("2024-01-31") == nil)
    assert(virtual.to_number("1,2") == nil)
    assert(virtual.to_number("1 234,50") == nil)
    assert(virtual.to_number("(123)") == nil)
end)

test("virtual.stats computes counts, sum, avg, min, max and all_numeric", function()
    local st = virtual.stats({ "1", "2", "NULL", "x", "3.25" })
    assert(st.count == 5, "expected count 5, got " .. tostring(st.count))
    assert(st.count_null == 1, "expected count_null 1, got " .. tostring(st.count_null))
    assert(st.count_num == 3, "expected count_num 3, got " .. tostring(st.count_num))
    assert(st.count_distinct == 4, "expected count_distinct 4, got " .. tostring(st.count_distinct))
    assert(st.sum == 6.25, "expected sum 6.25, got " .. tostring(st.sum))
    assert(math.abs(st.avg - (6.25 / 3)) < 1e-4, "expected avg ~2.0833, got " .. tostring(st.avg))
    assert(st.min == 1, "expected min 1, got " .. tostring(st.min))
    assert(st.max == 3.25, "expected max 3.25, got " .. tostring(st.max))
    assert(st.all_numeric == false, "expected all_numeric == false")

    local st_num = virtual.stats({ "10", "20", "NULL" })
    assert(st_num.all_numeric == true, "expected all_numeric == true when all non-null cells are numeric")
end)

test("virtual.format_number formats integers and decimals without scientific notation", function()
    assert(virtual.format_number(6.25) == "6.25")
    assert(virtual.format_number(6) == "6")
    assert(virtual.format_number(6.0, 2) == "6")
    assert(virtual.format_number(2.0833333, 2) == "2.08")
    assert(virtual.format_number(100000000000000) == "100000000000000")
end)

test("virtual.columns_in_range maps byte offsets to displayed columns", function()
    local widths = { 3, 5, 2 }
    assert(vim.deep_equal(virtual.columns_in_range(widths, 0, 0), { 1 }))
    assert(vim.deep_equal(virtual.columns_in_range(widths, 4, 9), { 2 }))
    assert(vim.deep_equal(virtual.columns_in_range(widths, 0, 20), { 1, 2, 3 }))
end)

test("virtual.render_footer renders virt_lines extmark in scratch buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "ITEM   | AMOUNT",
        "-------+-------",
        "Alpha  | 10    ",
        "Beta   | 20    ",
        "Gamma  | 30    ",
        "",
    })
    grid.set(buf, 'displayed_header', { 'ITEM', 'AMOUNT' })
    grid.set(buf, 'displayed_data', {
        { 'Alpha', '10' },
        { 'Beta', '20' },
        { 'Gamma', '30' },
    })
    grid.set(buf, 'displayed_col_ids', { 1, 2 })
    grid.set(buf, 'column_widths', { 6, 6 })
    grid.set(buf, 'virtual_footer_mode', 'sum')

    virtual.render_footer(buf)

    local ns = vim.api.nvim_get_namespaces()['vim-teradata-virtual']
    assert(ns ~= nil, "vim-teradata-virtual namespace should exist")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert(#marks == 1, "expected 1 extmark in vim-teradata-virtual, got " .. #marks)
    assert(marks[1][2] == 4, "expected extmark on 0-based line 4 (last data row), got " .. tostring(marks[1][2]))
    local vlines = marks[1][4].virt_lines
    assert(vlines and #vlines == 2, "expected 2 virt_lines")
    local sep_text = vlines[1][1][1]
    local val_text = vlines[2][1][1]
    assert(sep_text == "-------+-------", "unexpected separator line: " .. tostring(sep_text))
    assert(val_text:find("60    ", 1, true), "expected sum '60    ' padded to width 6 in: " .. tostring(val_text))
    assert(vim.fn.strdisplaywidth(val_text) == vim.fn.strdisplaywidth(sep_text),
        "values line display width should match separator line display width")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

local function with_history_query(id, sql, fn)
    local qdir = util.get_history_path('queries_dir_name')
    vim.fn.mkdir(qdir, 'p')
    local qpath = qdir .. '/' .. id .. '.sql'
    vim.fn.writefile({ sql }, qpath)
    local ok, err = pcall(fn)
    vim.fn.delete(qpath)
    if not ok then error(err, 0) end
end

local function close_current_grid()
    local buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

test("display_output integrates gS/gs footer cycling, filters, column removal, edit mode, and quick-calc", function()
    local id = 'virtual_grid_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'DEPT~SALARY~BONUS',
        'Sales~100~10',
        'Sales~200~20',
        'Eng~300~30',
    }, path)

    with_history_query(id, 'SELECT DEPT, SALARY, BONUS FROM EMP;', function()
        ui.display_output(path, id, { editable = true })
        local buf = vim.api.nvim_get_current_buf()
        local ns = vim.api.nvim_get_namespaces()['vim-teradata-virtual']

        -- Hint line includes <gS> Totals
        local h_ns = vim.api.nvim_get_namespaces()['HelperBuffer']
        local h_marks = vim.api.nvim_buf_get_extmarks(buf, h_ns, 0, -1, { details = true })
        assert(#h_marks == 1 and h_marks[1][4].virt_text[1][1]:find('<gS> Totals', 1, true),
            "expected <gS> Totals in grid hint")

        -- Cycle mode with gS -> 'sum'
        press('gS')
        assert(grid.get(buf, 'virtual_footer_mode') == 'sum')
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        assert(#marks == 1)
        local val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('600', 1, true) and val_line:find('60', 1, true),
            "expected sums 600 and 60 in footer: " .. val_line)

        -- Filter on DEPT = 'Sales' (row 1, col 1) with <CR> -> footer updates to 300 and 30
        vim.fn.cursor(3, 1)
        press('<CR>')
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('300', 1, true) and val_line:find('30', 1, true),
            "expected filtered sums 300 and 30 in footer: " .. val_line)

        -- Unfilter with 'u' -> back to 600 and 60
        press('u')
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('600', 1, true), "expected unfiltered sum 600: " .. val_line)

        -- Remove first column with '-' -> footer stays aligned with remaining 2 columns
        vim.fn.cursor(3, 1)
        press('-')
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        local sep_line = marks[1][4].virt_lines[1][1][1]
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(vim.fn.strdisplaywidth(sep_line) == vim.fn.strdisplaywidth(val_line))
        press('<BS>')

        -- Quick calc over columns 2 and 3 (SALARY and BONUS) across all 3 rows
        local widths = grid.get(buf, 'column_widths')
        local col2_start = widths[1] + 3 + 1 -- 1-based virtcol of SALARY
        local col3_end   = widths[1] + 3 + widths[2] + 3 + widths[3]
        local res = virtual.calc_selection(buf, 3, 5, col2_start, col3_end)
        assert(res ~= nil, "expected quick-calc result")
        assert(vim.deep_equal(res.columns, { 2, 3 }))
        assert(res.pooled.count == 6 and res.pooled.sum == 660)
        assert(res.per_column[2].sum == 600 and res.per_column[3].sum == 60)
        if res.win and vim.api.nvim_win_is_valid(res.win) then
            press('q')
            assert(not vim.api.nvim_win_is_valid(res.win), "expected q to close quick-calc float")
        end

        -- Edit mode: changing a cell updates the footer immediately
        press('E')
        local orig_input = vim.ui.input
        vim.ui.input = function(_, cb) cb('500') end
        vim.fn.cursor(3, 1)
        vim.cmd('normal! ' .. col2_start .. '|')
        press('<CR>')
        vim.ui.input = orig_input
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('1000', 1, true), "expected updated sum 1000 in edit mode: " .. val_line)
        press('C')

        -- Cycle backwards with gs back to 'off' -> extmark removed
        press('gs')
        assert(grid.get(buf, 'virtual_footer_mode') == 'off')
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
        assert(#marks == 0, "expected no footer extmark when mode == 'off'")

        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("EXPLAIN buffers are unaffected and refuse quick-calc politely", function()
    local id = 'virtual_explain_test'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'Explanation',
        '1) First, we lock DBC.Users for read.',
    }, path)

    with_history_query(id, 'EXPLAIN SELECT * FROM DBC.Users;', function()
        ui.display_output(path, id)
        local buf = vim.api.nvim_get_current_buf()
        local ns = vim.api.nvim_get_namespaces()['vim-teradata-virtual']
        local marks = ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) or {}
        assert(#marks == 0, "EXPLAIN buffer should have no virtual footer")
        local res = virtual.calc_selection(buf, 1, 2, 1, 5)
        assert(res == nil, "calc_selection should refuse EXPLAIN buffers")
        close_current_grid()
    end)
    vim.fn.delete(dir, 'rf')
end)

test("Patch 2: scratch buffer virtual column registry, filter + reapply, and unknown ref rejection", function()
    local buf = vim.api.nvim_create_buf(false, true)
    grid.set(buf, 'all_header', { 'ITEM', 'PRICE', 'COST', 'QTY' })
    grid.set(buf, 'all_data', {
        { 'A', '10', '4', '2' },  -- margin = 12
        { 'B', '20', '5', '3' },  -- margin = 45
        { 'C', '15', '10', '1' }, -- margin = 5
    })
    grid.set(buf, 'displayed_header', { 'ITEM', 'PRICE', 'COST', 'QTY' })
    grid.set(buf, 'displayed_data', {
        { 'A', '10', '4', '2' },
        { 'B', '20', '5', '3' },
        { 'C', '15', '10', '1' },
    })
    grid.set(buf, 'displayed_ids', { 1, 2, 3 })
    grid.set(buf, 'displayed_col_ids', { 1, 2, 3, 4 })

    -- Reject unknown column reference
    local bad_col, bad_err = virtual.add_column(buf, 'BAD', 'unknown_col + 1', { silent = true })
    assert(bad_col == nil and bad_err ~= nil, 'expected unknown column reference to be rejected')
    assert(#grid.get(buf, 'displayed_header') == 4, 'nothing should be added on error')

    -- Add virtual column MARGIN = (price - cost) * qty
    local col, err = virtual.add_column(buf, 'margin', '(price - cost) * qty', { silent = true })
    assert(col and not err, 'expected virtual column to be added: ' .. tostring(err))
    assert(col.id == 'v1' and col.name == 'MARGIN')

    local d_hdr = grid.get(buf, 'displayed_header')
    local d_cids = grid.get(buf, 'displayed_col_ids')
    local d_data = grid.get(buf, 'displayed_data')
    assert(d_hdr[5] == 'ƒ MARGIN', 'expected ƒ MARGIN header, got ' .. tostring(d_hdr[5]))
    assert(d_cids[5] == 'v1', 'expected col_id v1, got ' .. tostring(d_cids[5]))
    assert(d_data[1][5] == '12' and d_data[2][5] == '45' and d_data[3][5] == '5')

    -- Simulate filtering to rows 2 and 3 and rebuilding from all_data + reapply
    grid.set(buf, 'displayed_ids', { 2, 3 })
    grid.set(buf, 'displayed_data', {
        { 'B', '20', '5', '3', '' },
        { 'C', '15', '10', '1', '' },
    })
    virtual.reapply(buf)
    d_data = grid.get(buf, 'displayed_data')
    assert(d_data[1][5] == '45' and d_data[2][5] == '5', 'virtual values should follow displayed_ids after reapply')

    vim.api.nvim_buf_delete(buf, { force = true })
end)

test("Patch 2: full UI sort, remove/restore, footer sum, edit-mode what-if, and persistence", function()
    local id1 = 'vcol_persist_1'
    local id2 = 'vcol_persist_2'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path1 = dir .. '/' .. id1 .. '.csv'
    local path2 = dir .. '/' .. id2 .. '.csv'
    local rows = {
        'ITEM~PRICE~COST~QTY',
        'A~10~4~2',   -- margin = 12
        'B~20~5~3',   -- margin = 45
        'C~15~10~1',  -- margin = 5
    }
    vim.fn.writefile(rows, path1)
    vim.fn.writefile(rows, path2)

    local orig_data_dir = config.options.data_dir
    config.options.data_dir = dir

    local sql = 'SELECT ITEM, PRICE, COST, QTY FROM SALES;'
    with_history_query(id1, sql, function()
        ui.display_output(path1, id1, { editable = true })
        local buf = vim.api.nvim_get_current_buf()

        -- Add virtual column via :TDCol command
        vim.cmd('TDCol margin = (price - cost) * qty')
        local d_hdr = grid.get(buf, 'displayed_header')
        assert(d_hdr[5] == 'ƒ MARGIN', 'expected ƒ MARGIN, got ' .. tostring(d_hdr[5]))

        -- Sort ascending on virtual column 5 -> order should be C (5), A (12), B (45)
        vim.fn.cursor(3, 1)
        press('g$')
        press('<Up>')
        local d_data = grid.get(buf, 'displayed_data')
        assert(d_data[1][1] == 'C' and d_data[2][1] == 'A' and d_data[3][1] == 'B',
            'expected numerical sort on virtual column: C(5), A(12), B(45)')
        press('r')

        -- Remove (-) and restore (<BS>) virtual column
        vim.fn.cursor(3, 1)
        press('g$')
        press('-')
        assert(#grid.get(buf, 'displayed_header') == 4)
        press('<BS>')
        d_data = grid.get(buf, 'displayed_data')
        assert(d_data[1][5] == '12' and d_data[2][5] == '45' and d_data[3][5] == '5')

        -- Patch 1 footer (gS) sums the virtual column (12 + 45 + 5 = 62)
        press('gS')
        local ns = vim.api.nvim_get_namespaces()['vim-teradata-virtual']
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        local val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('62', 1, true), 'expected virtual column sum 62 in footer: ' .. val_line)

        -- Edit mode: changing PRICE on row 1 from 10 to 20 updates MARGIN on row 1 from 12 to 32
        -- and updates footer sum from 62 to 82; UPDATE statements never mention MARGIN; C restores both
        press('E')
        local widths = grid.get(buf, 'column_widths')
        local col2_start = widths[1] + 3 + 1
        local orig_input = vim.ui.input
        vim.ui.input = function(_, cb) cb('20') end
        vim.fn.cursor(3, 1)
        vim.cmd('normal! ' .. col2_start .. '|')
        press('<CR>')
        vim.ui.input = orig_input

        d_data = grid.get(buf, 'displayed_data')
        assert(d_data[1][5] == '32', 'expected what-if MARGIN=32 after editing PRICE to 20, got ' .. tostring(d_data[1][5]))
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('82', 1, true), 'expected updated footer sum 82, got ' .. val_line)

        local edit_mod = require('vim-teradata.edit')
        local st = edit_mod._state(buf)
        local stmts = edit_mod.build_statements(st, st.pending)
        assert(#stmts == 1 and not stmts[1]:find('MARGIN', 1, true),
            'generated UPDATE must never mention virtual column MARGIN: ' .. tostring(stmts[1]))

        -- Cancel edit mode with C -> restores both PRICE (10) and MARGIN (12)
        press('C')
        d_data = grid.get(buf, 'displayed_data')
        assert(d_data[1][2] == '10' and d_data[1][5] == '12',
            'expected cancel to restore PRICE=10 and MARGIN=12')

        close_current_grid()
    end)

    -- Persistence: opening a new result with the same SQL text (different id) restores ƒ MARGIN
    with_history_query(id2, '  SELECT ITEM, PRICE, COST, QTY\n  FROM SALES; -- comment\n', function()
        ui.display_output(path2, id2, { editable = false })
        local buf2 = vim.api.nvim_get_current_buf()
        local d_hdr2 = grid.get(buf2, 'displayed_header')
        local d_data2 = grid.get(buf2, 'displayed_data')
        assert(d_hdr2[5] == 'ƒ MARGIN', 'expected persisted ƒ MARGIN to be restored, got ' .. vim.inspect(d_hdr2))
        assert(d_data2[1][5] == '12' and d_data2[2][5] == '45' and d_data2[3][5] == '5')
        close_current_grid()
    end)

    config.options.data_dir = orig_data_dir
    vim.fn.delete(dir, 'rf')
end)

test("Patch 3: what-if override meta builds UPDATE against volatile table with all-column WHERE", function()
    local edit_mod = require('vim-teradata.edit')
    local override_meta = virtual.volatile_edit_meta('VAS_20261117_1234', { 'DEPT', 'TOTAL_SALES', 'CNT' })
    local fake_st = {
        meta     = override_meta,
        original = {
            [1] = { 'Sales', '100', 'NULL' },
        },
        keys = {},
    }
    local diffs = {
        [1] = { [2] = '250' },
    }
    local stmts = edit_mod.build_statements(fake_st, diffs, override_meta)
    assert(#stmts == 1, 'expected 1 UPDATE statement')
    local u = stmts[1]
    assert(u:find('^UPDATE VAS_20261117_1234\n'), 'expected UPDATE target VAS_20261117_1234, got:\n' .. u)
    assert(u:find('SET "TOTAL_SALES" = 250', 1, true), 'expected SET "TOTAL_SALES" = 250, got:\n' .. u)
    assert(u:find('"DEPT" = \'Sales\'', 1, true)
        and u:find('"TOTAL_SALES" = 100', 1, true)
        and u:find('"CNT" IS NULL', 1, true),
        'expected WHERE to cover all columns of volatile table, got:\n' .. u)
end)

test("Patch 3: truncated result shows Σ (partial) on gS and Σ db on gD pushdown", function()
    local bteq = require('vim-teradata.bteq')
    local id = 'vcol_pushdown_footer'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. id .. '.csv'
    vim.fn.writefile({
        'DEPT~AMOUNT',
        'Sales~10',
        'Eng~20',
    }, path)

    local orig_users = config.options.users
    local orig_idx   = config.options.current_user_index
    local orig_start = bteq._start_job
    config.options.users = { { user = 'U', tdpid = 'H', log_mech = 'TD2' } }
    config.options.current_user_index = 1

    bteq._start_job = function(script_lines, on_done)
        local joined = table.concat(script_lines, '\n')
        local out_file = joined:match("%.EXPORT FILE = '([^']+)'")
        if out_file then
            vim.fn.writefile({ 'col1~Sum(AMOUNT)', 'NULL~999' }, out_file)
        end
        on_done({ rc = 0, msg = '', log_content = { ' *** Query completed. 1 rows found.' } })
        return { kill = function() end }
    end

    with_history_query(id, 'SELECT DEPT, AMOUNT FROM T;', function()
        ui.display_output(path, id, { editable = false })
        local buf = vim.api.nvim_get_current_buf()
        grid.set(buf, 'rows_found', 500)
        grid.set(buf, 'retlimit_applied', true)

        press('gS')
        local ns = vim.api.nvim_get_namespaces()['vim-teradata-virtual']
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        local val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('Σ (partial)', 1, true), 'expected Σ (partial) on truncated result, got: ' .. val_line)

        press('gD')
        vim.wait(200, function() return grid.get(buf, 'virtual_footer_db') ~= nil end)
        marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        val_line = marks[1][4].virt_lines[2][1][1]
        assert(val_line:find('Σ db', 1, true) and val_line:find('999', 1, true),
            'expected Σ db and exact sum 999 after gD, got: ' .. val_line)

        close_current_grid()
    end)

    bteq._start_job = orig_start
    config.options.users = orig_users
    config.options.current_user_index = orig_idx
    vim.fn.delete(dir, 'rf')
end)
