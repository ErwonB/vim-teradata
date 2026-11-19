local config = require('vim-teradata.config')
local util   = require('vim-teradata.util')
local diag   = require('vim-teradata.diagnostics')

local function run_diag_on_sql(sql)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.split(sql, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    diag.update_diagnostics(buf)
    local ds = vim.diagnostic.get(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    return ds
end

local function filter_msgs(ds, substr)
    local out = {}
    for _, d in ipairs(ds) do
        if d.message and d.message:find(substr, 1, true) then
            out[#out + 1] = d
        end
    end
    return out
end

test("column-types §10.5: type diagnostics T1..T6, derived tables, config flag, and untyped catalog", function()
    local saved = {
        data_dir   = config.options.data_dir,
        users      = config.options.users,
        idx        = config.options.current_user_index,
        diag_types = config.options.diagnostics and config.options.diagnostics.types,
    }
    config.options.data_dir = vim.fn.tempname()
    config.options.users = { { user = 'u', tdpid = 'types_diag_test', log_mech = 'TD2' } }
    config.options.current_user_index = 1
    config.options.diagnostics.types = true

    local dir = util.catalog_root() .. '/' .. util.catalog_key()
    vim.fn.mkdir(dir, 'p')
    local per_db, dbs, per_types = util._parse_export_lines({
        "EDW,CUST,CUST_ID,I,4,,,,N,",
        "EDW,CUST,CUST_CD,CV,10,,,1,Y,",
        "EDW,ORD,CUST_CD,I,4,,,,Y,",
        "EDW,ORD,CODE_U,CV,40,,,2,Y,",
        "EDW,ORD,ORD_DT,DA,4,,,,Y,",
    })
    util._write_db_file(dir .. '/EDW.lua', per_db.EDW, false, per_types.EDW)
    util._write_summary(dir .. '/data.lua', dbs, false)
    diag.invalidate_all()

    -- 1. T1: char column compared with numeric literal
    local ds1 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD = 123;")
    local t1_1 = filter_msgs(ds1, "Numeric literal compared with")
    assert(#t1_1 == 1, "Expected 1 T1 diagnostic, got: " .. vim.inspect(ds1))
    assert(t1_1[1].severity == vim.diagnostic.severity.WARN)

    -- 2. T1 in IN list
    local ds2 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD IN (1, 'A');")
    local t1_2 = filter_msgs(ds2, "Numeric literal compared with")
    assert(#t1_2 == 1, "Expected 1 T1 diagnostic in IN list, got: " .. vim.inspect(ds2))

    -- 3. T2: string literal longer than char_len on '='
    local ds3 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD = 'ABCDEFGHIJKLMNOP';")
    local t2_1 = filter_msgs(ds3, "String literal (16 chars) is longer than")
    assert(#t2_1 == 1, "Expected 1 T2 diagnostic, got: " .. vim.inspect(ds3))

    -- 4. T2 not triggered on '<>'
    local ds4 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD <> 'ABCDEFGHIJKLMNOP';")
    assert(#filter_msgs(ds4, "is longer than") == 0, "Expected no T2 on <>, got: " .. vim.inspect(ds4))

    -- 5. Valid comparison -> no type diagnostic
    local ds5 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD = 'A1';")
    assert(#ds5 == 0, "Expected 0 diagnostics, got: " .. vim.inspect(ds5))

    -- 6. T3: column vs column incompatible categories
    local ds6 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c JOIN EDW.ORD o ON c.CUST_CD = o.CUST_CD;")
    local t3 = filter_msgs(ds6, "requires an implicit conversion")
    assert(#t3 == 1, "Expected 1 T3 diagnostic, got: " .. vim.inspect(ds6))

    -- 7. T4: character set mismatch (INFO)
    local ds7 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c JOIN EDW.ORD o ON c.CUST_CD = o.CODE_U;")
    local t4 = filter_msgs(ds7, "Character set mismatch")
    assert(#t4 == 1, "Expected 1 T4 diagnostic, got: " .. vim.inspect(ds7))
    assert(t4[1].severity == vim.diagnostic.severity.INFO)

    -- 8. T5: LIKE on DATE column
    local ds8 = run_diag_on_sql("SELECT o.CODE_U FROM EDW.ORD o WHERE o.ORD_DT LIKE '2024%';")
    local t5 = filter_msgs(ds8, "LIKE on DATE column")
    assert(#t5 == 1, "Expected 1 T5 diagnostic, got: " .. vim.inspect(ds8))

    -- 9. T6: SUM() on character column
    local ds9 = run_diag_on_sql("SELECT SUM(c.CUST_CD) FROM EDW.CUST c;")
    local t6 = filter_msgs(ds9, "SUM() on VARCHAR(10) CHARACTER SET LATIN column")
    assert(#t6 == 1, "Expected 1 T6 diagnostic, got: " .. vim.inspect(ds9))

    -- 10. Derived table -> no type diagnostic
    local ds10 = run_diag_on_sql("SELECT x.CUST_CD FROM (SELECT CUST_CD FROM EDW.CUST) x WHERE x.CUST_CD = 1;")
    assert(#filter_msgs(ds10, "Numeric literal compared with") == 0,
        "Expected no type diagnostic on derived table, got: " .. vim.inspect(ds10))

    -- 11. diagnostics.types = false -> no type diagnostic
    config.options.diagnostics.types = false
    diag.invalidate_all()
    local ds11 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD = 123;")
    assert(#filter_msgs(ds11, "Numeric literal compared with") == 0,
        "Expected no type diagnostic when diagnostics.types = false, got: " .. vim.inspect(ds11))
    config.options.diagnostics.types = true

    -- 12. Untyped DB file (written without per_types) -> no type diagnostic
    util._write_db_file(dir .. '/EDW.lua', per_db.EDW, false, nil)
    diag.invalidate_all()
    local ds12 = run_diag_on_sql("SELECT c.CUST_ID FROM EDW.CUST c WHERE c.CUST_CD = 123;")
    assert(#filter_msgs(ds12, "Numeric literal compared with") == 0,
        "Expected no type diagnostic on untyped catalog, got: " .. vim.inspect(ds12))

    vim.fn.delete(config.options.data_dir, "rf")
    config.options.data_dir = saved.data_dir
    config.options.users = saved.users
    config.options.current_user_index = saved.idx
    config.options.diagnostics.types = saved.diag_types
    diag.invalidate_all()
end)
