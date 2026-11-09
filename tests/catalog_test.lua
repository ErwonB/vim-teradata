local util = require('vim-teradata.util')

test("catalog_key defaults to the sanitized, lowercased tdpid", function()
    assert(util.catalog_key({ user = 'a', tdpid = 'Prod-EDW.corp.com' }) == 'prod-edw_corp_com')
end)

test("users on the same tdpid share one catalog key", function()
    local a = util.catalog_key({ user = 'alice', tdpid = 'prod-edw' })
    local b = util.catalog_key({ user = 'bob', tdpid = 'PROD-EDW' })
    assert(a == b)
end)

test("explicit catalog overrides tdpid", function()
    assert(util.catalog_key({ user = 'etl', tdpid = 'prod-edw', catalog = 'prod-etl' }) == 'prod-etl')
end)

test("different machines get different keys", function()
    assert(util.catalog_key({ user = 'a', tdpid = 'prod' }) ~= util.catalog_key({ user = 'a', tdpid = 'dev' }))
end)

test("missing tdpid yields no key", function()
    assert(util.catalog_key({ user = 'a' }) == nil)
end)

local config = require('vim-teradata.config')
local diag = require('vim-teradata.diagnostics')

test("patch-02: parse_object_names handles 1/2/3-part names, DB.*, commas, quotes, env vars, and rejects SQL injection", function()
    local orig_rep = config.options.replacements
    config.options.replacements = { ['${MY_DB}'] = 'EDW_PROD' }

    local targets, errs = util.parse_object_names({
        'edw.t1, edw.t2',
        '${MY_DB}."my_tbl"',
        'edw_stg.*',
        'sys.edw.three_part',
        'vt_local',
        'edw.t1', -- duplicate
    })
    assert(#errs == 0, "Expected 0 errors, got: " .. vim.inspect(errs))
    assert(#targets == 6, "Expected 6 deduplicated targets, got " .. #targets)
    assert(targets[1].db == 'EDW' and targets[1].name == 'T1')
    assert(targets[2].db == 'EDW' and targets[2].name == 'T2')
    assert(targets[3].db == 'EDW_PROD' and targets[3].name == 'MY_TBL')
    assert(targets[4].db == 'EDW_STG' and targets[4].all == true)
    assert(targets[5].db == 'EDW' and targets[5].name == 'THREE_PART')
    assert(targets[6].session == true and targets[6].name == 'VT_LOCAL')

    local bad_targets, bad_errs = util.parse_object_names({ 'edw.t;drop', "edw.t'1", 'a..b' })
    assert(#bad_targets == 0)
    assert(#bad_errs == 3)

    config.options.replacements = orig_rep
end)

test("patch-02: merge_into_catalog add / update / delete / DB.*", function()
    local cat_dir = vim.fn.tempname()
    local user = { user = 'u', tdpid = 'test_host', log_mech = 'TD2' }

    -- 1. Add table of a new DB -> <DB>.lua created, data.lua lists the DB
    local fetched1 = util._parse_export_lines({
        "EDW,T1,COL_B",
        "EDW,T1,COL_A",
    })
    local req1 = util.parse_object_names({ "edw.t1" })
    local st1 = util._merge_into_catalog(cat_dir, fetched1, req1, 'add', user)
    assert(#st1.added == 1 and st1.added[1] == "EDW.T1")
    local dbs1 = dofile(cat_dir .. "/data.lua")
    assert(dbs1["EDW"] == true)
    local edw1 = dofile(cat_dir .. "/EDW.lua")
    assert(edw1.is_table["T1"] == true)
    assert(vim.deep_equal(edw1["T1"], { "COL_A", "COL_B" }))

    -- 2. Add new table to existing DB -> table present, is_table rebuilt, other tables intact
    local fetched2 = util._parse_export_lines({
        "EDW,T2,ID",
    })
    local req2 = util.parse_object_names({ "edw.t2", "edw.missing_tbl" })
    local st2 = util._merge_into_catalog(cat_dir, fetched2, req2, 'add', user)
    assert(#st2.added == 1 and st2.added[1] == "EDW.T2")
    assert(#st2.missing == 1 and st2.missing[1] == "EDW.MISSING_TBL")
    local edw2 = dofile(cat_dir .. "/EDW.lua")
    assert(edw2.is_table["T1"] == true and edw2.is_table["T2"] == true)
    assert(vim.deep_equal(edw2["T1"], { "COL_A", "COL_B" }))
    assert(vim.deep_equal(edw2["T2"], { "ID" }))

    -- 3. Update with table absent from CSV -> removed
    local fetched3 = util._parse_export_lines({
        "EDW,T1,COL_A",
        "EDW,T1,COL_C",
    })
    local req3 = util.parse_object_names({ "edw.t1", "edw.t2" })
    local st3 = util._merge_into_catalog(cat_dir, fetched3, req3, 'update', user)
    assert(#st3.updated == 1 and st3.updated[1] == "EDW.T1")
    assert(#st3.removed == 1 and st3.removed[1] == "EDW.T2")
    local edw3 = dofile(cat_dir .. "/EDW.lua")
    assert(edw3.is_table["T1"] == true and edw3.is_table["T2"] == nil)
    assert(vim.deep_equal(edw3["T1"], { "COL_A", "COL_C" }))

    -- 4. Update DB.* -> DB content replaced exactly
    local fetched4 = util._parse_export_lines({
        "EDW,T3,X",
    })
    local req4 = util.parse_object_names({ "edw.*" })
    local st4 = util._merge_into_catalog(cat_dir, fetched4, req4, 'update', user)
    assert(#st4.added == 1 and st4.added[1] == "EDW.T3")
    assert(#st4.removed == 1 and st4.removed[1] == "EDW.T1")
    local edw4 = dofile(cat_dir .. "/EDW.lua")
    assert(edw4.is_table["T3"] == true and edw4.is_table["T1"] == nil)

    -- 5. Delete DB.T, unknown name, and DB.* -> DB emptied -> file and data.lua entry gone
    local st5 = util._merge_into_catalog(cat_dir, {}, util.parse_object_names({ "edw.unknown" }), 'delete', user)
    assert(#st5.missing == 1 and st5.missing[1] == "EDW.UNKNOWN")

    local st6 = util._merge_into_catalog(cat_dir, {}, util.parse_object_names({ "edw.t3" }), 'delete', user)
    assert(#st6.removed == 1 and st6.removed[1] == "EDW.T3")
    assert(vim.fn.filereadable(cat_dir .. "/EDW.lua") == 0)
    local dbs6 = dofile(cat_dir .. "/data.lua")
    assert(dbs6["EDW"] == nil)

    vim.fn.delete(cat_dir, "rf")
end)

test("patch-02: full sync output format is preserved", function()
    local tmp_csv = vim.fn.tempname()
    local cat_dir = vim.fn.tempname()
    vim.fn.writefile({
        "DB1,TBL1,C2",
        "DB1,TBL1,C1",
    }, tmp_csv)

    local done_ok = nil
    util._split_data_db_file_to_lua(tmp_csv, cat_dir, { user = 'u', tdpid = 'h' }, function(ok)
        done_ok = ok
    end)
    vim.wait(1000, function() return done_ok ~= nil end)
    assert(done_ok == true)

    local db_lines = vim.fn.readfile(cat_dir .. "/DB1.lua")
    local expected_db = {
        "-- Auto-generated. Do not edit.",
        "return {",
        '  ["TBL1"] = { "C1", "C2" },',
        "is_table = {",
        '  ["TBL1"] = true,',
        "}}",
    }
    assert(vim.deep_equal(db_lines, expected_db), "Unexpected DB1.lua format: " .. vim.inspect(db_lines))

    local sum_lines = vim.fn.readfile(cat_dir .. "/data.lua")
    local expected_sum = {
        "-- Auto-generated. Do not edit.",
        "return {",
        '  ["DB1"] = true,',
        "}",
    }
    assert(vim.deep_equal(sum_lines, expected_sum), "Unexpected data.lua format: " .. vim.inspect(sum_lines))

    vim.fn.delete(tmp_csv)
    vim.fn.delete(cat_dir, "rf")
end)

test("patch-02: session table registered from buffer via :TDSync add vt and validated by diagnostics", function()
    local orig_users = config.options.users
    local orig_idx = config.options.current_user_index
    config.options.users = { { user = 'u', tdpid = 'sess_test_tdpid', log_mech = 'TD2' } }
    config.options.current_user_index = 1

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "CREATE VOLATILE TABLE vt (a INT, b INT);",
    })

    util.sync_command({ fargs = { "add", "vt" }, range = 0 })

    local st = util.get_session_table("VT")
    assert(st ~= nil, "Expected VT in session table registry")
    assert(vim.deep_equal(st.columns, { "A", "B" }), "Expected columns {A, B}, got: " .. vim.inspect(st.columns))

    -- Now test in ANOTHER buffer (where vt is not locally defined in buffer text, only in session registry)
    local buf2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf2, 0, -1, false, {
        "SELECT x.a FROM vt x;",
        "SELECT x.c FROM vt x;",
    })
    diag.update_diagnostics(buf2)
    local ds = vim.diagnostic.get(buf2)
    assert(#ds == 1, "Expected 1 error on x.c, got: " .. vim.inspect(ds))
    assert(ds[1].lnum == 1, "Expected error on line 2 (0-indexed 1)")
    assert(ds[1].message:find('Column "c" not found in volatile table "vt"', 1, true))

    -- Delete session table
    util.sync_command({ fargs = { "delete", "vt" }, range = 0 })
    assert(util.get_session_table("VT") == nil)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
    config.options.users = orig_users
    config.options.current_user_index = orig_idx
end)
