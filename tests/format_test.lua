local ope = require('vim-teradata.td_ope')

local function format_sql(sql)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sql, "\n"))
    vim.treesitter.get_parser(buf, "teradata")
    ope.format_all_statements()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return table.concat(lines, "\n")
end

test("protect_literals masks string literals and comments", function()
    local sql = "SELECT 'do not modify spaces' AS str -- comment with spaces\nFROM tab"
    local masked, restore = ope._protect_literals(sql)
    assert(masked ~= sql, "masked should differ from original")
    assert(not masked:find("do not modify spaces"), "literal content should be masked")
    local restored = restore(masked)
    assert(restored == sql, "restored should equal original: " .. restored)
end)

test("protect_literals masks block comments", function()
    local sql = "SELECT /* block comment */ col FROM tab"
    local masked, restore = ope._protect_literals(sql)
    assert(not masked:find("block comment"), "comment content should be masked")
    local restored = restore(masked)
    assert(restored == sql, "restored should equal original")
end)

test("regression suite: test_format.sql formats with 0 regressions", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local test_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "tests/"
    local fixture_path = test_dir .. "fixtures/test_format.sql"
    if vim.fn.filereadable(fixture_path) ~= 1 then
        fixture_path = "tests/fixtures/test_format.sql"
    end
    local lines = vim.fn.readfile(fixture_path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.treesitter.get_parser(buf, "teradata")
    ope.format_all_statements()
    local out_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local in_text = table.concat(lines, "\n")
    local out_text = table.concat(out_lines, "\n")
    assert(in_text == out_text, "test_format.sql should have zero regressions")
end)

test("invisible text: CAST with FORMAT string preserved", function()
    local sql = "SELECT CAST(dt AS FORMAT 'YYYYMMDD') FROM tab;"
    local res = format_sql(sql)
    assert(res:find("format 'YYYYMMDD'"), "FORMAT literal string should be preserved: " .. res)
end)

test("invisible text: SAMPLE with comma list trailing tokens preserved", function()
    local sql = "SELECT * FROM tab SAMPLE 0.6, 0.25, 0.15;"
    local res = format_sql(sql)
    assert(res:find("0%.15"), "trailing sample token 0.15 should be preserved: " .. res)
end)

test("invisible text: ESCAPE literal string in LIKE preserved", function()
    local sql = "SELECT * FROM tab WHERE col LIKE 'a%' ESCAPE '\\';"
    local res = format_sql(sql)
    assert(res:find("escape '\\'"), "ESCAPE clause literal should be preserved: " .. res)
end)

test("invisible text: T-SQL @parameter preserved", function()
    local sql = "SELECT @my_param FROM tab;"
    local res = format_sql(sql)
    assert(res:find("@MY_PARAM"), "@parameter should be preserved: " .. res)
end)

test("invisible text: INTERVAL with literal string preserved", function()
    local sql = "SELECT dt + INTERVAL '1' MONTH FROM tab;"
    local res = format_sql(sql)
    assert(res:find("interval '1' month"), "INTERVAL '1' MONTH should be preserved: " .. res)
end)

test("invisible text: macro parameter with data type format preserved", function()
    local sql = "CREATE MACRO m (p1 DATE FORMAT 'YYYY-MM-DD') AS (SELECT 1;);"
    local res = format_sql(sql)
    assert(res:find("format 'YYYY%-MM%-DD'"), "Macro parameter format string should be preserved: " .. res)
end)

test("bugfix: line comment does not swallow subsequent SQL keywords", function()
    local sql = "ALTER TABLE t ADD c1 INT, -- comment\n DROP c2;"
    local res = format_sql(sql)
    assert(res:find("drop C2"), "drop C2 should not be swallowed by line comment: " .. res)
end)

test("bugfix: block comment in column definitions preserved", function()
    local sql = "CREATE TABLE t (/* block */ id INT);"
    local res = format_sql(sql)
    assert(res:find("/%* block %*/"), "marginalia block comment should be preserved: " .. res)
end)

test("bugfix: quoted column names in CREATE TABLE", function()
    local sql = 'CREATE TABLE t ("my_col" INT, other INT);'
    local res = format_sql(sql)
    assert(res:find('"my_col"'), 'quoted column name should be preserved: ' .. res)
end)

test("bugfix: multiple VALUES tuples in INSERT", function()
    local sql = "INSERT INTO t (c1, c2) VALUES (1, 'a'), (2, 'b');"
    local res = format_sql(sql)
    assert(res:find("values\n%(\n   1\n  , 'a'\n%),\n%(\n   2\n  , 'b'\n%);"), "multiple VALUES lists should have comma separator: " .. res)
end)

test("bugfix: MERGE ON predicate spacing and VALUES preservation", function()
    local sql = "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT (id, val) VALUES (s.id, 'NEW');"
    local res = format_sql(sql)
    assert(res:find("on t%.ID = s%.ID"), "ON predicate should have space after on: " .. res)
    assert(res:find("delete"), "DELETE clause in MERGE should be formatted: " .. res)
    assert(res:find("'NEW'"), "'NEW' literal in MERGE VALUES should be preserved: " .. res)
end)

test("bugfix: CREATE VIEW with column list and CHECK OPTION", function()
    local sql = "CREATE VIEW v (a, b) AS SELECT col1, col2 FROM t WITH CHECK OPTION;"
    local res = format_sql(sql)
    assert(res:find("create view V %(A, B%) as"), "View column list should retain parens and commas: " .. res)
    assert(res:find("with check option"), "WITH CHECK OPTION should be formatted: " .. res)
end)

test("bugfix: MINUS set operation", function()
    local sql = "SELECT a FROM t1 MINUS SELECT a FROM t2;"
    local res = format_sql(sql)
    assert(res:find("\nminus\n"), "MINUS operator should be on its own line: " .. res)
end)

test("new formatter: QUALIFY clause", function()
    local sql = "SELECT a FROM t QUALIFY ROW_NUMBER() OVER (ORDER BY a) = 1;"
    local res = format_sql(sql)
    assert(res:find("qualify row_number %(%) over %(order by A%) = 1"), "QUALIFY clause should be formatted: " .. res)
end)

test("new formatter: SAMPLE clause with WHEN ... THEN ... ELSE ... END", function()
    local sql = "SELECT * FROM t SAMPLE WHEN a > 10 THEN 0.25 ELSE 0.50 END;"
    local res = format_sql(sql)
    assert(res:find("sample\n   when A > 10 then 0%.25\n   else 0%.50\n   end"), "SAMPLE WHEN should be indented: " .. res)
end)

test("new formatter: CROSS JOIN", function()
    local sql = "SELECT * FROM t1 CROSS JOIN t2;"
    local res = format_sql(sql)
    assert(res:find("cross join\nT2"), "CROSS JOIN should format relation on newline: " .. res)
end)

test("new formatter: CREATE PROCEDURE with compound statements", function()
    local sql = "CREATE PROCEDURE p (IN x INT, OUT y INT) BEGIN SET y = x * 2; END;"
    local res = format_sql(sql)
    assert(res:find("create procedure P %(\n   in X int\n  , out Y int\n%)"), "procedure arguments should be formatted: " .. res)
    assert(res:find("begin\n   set Y = X %* 2;\nend;"), "compound statement should be formatted: " .. res)
end)

test("new formatter: CREATE FUNCTION with characteristics", function()
    local sql = "CREATE FUNCTION f (x INT) RETURNS INT LANGUAGE SQL CONTAINS SQL DETERMINISTIC RETURN x + 1;"
    local res = format_sql(sql)
    assert(res:find("returns int"), "RETURNS should be formatted: " .. res)
    assert(res:find("language SQL"), "LANGUAGE should be formatted: " .. res)
    assert(res:find("return X %+ 1"), "RETURN should be formatted: " .. res)
end)

test("new formatter: CREATE DATABASE with attributes", function()
    local sql = "CREATE DATABASE db AS PERM = 50e6, SPOOL = 50e6;"
    local res = format_sql(sql)
    assert(res:find("perm = 50e6"), "PERM attribute should be formatted: " .. res)
    assert(res:find(", spool = 50e6"), "SPOOL attribute should be formatted: " .. res)
end)

test("new formatter: ALTER TABLE with multiple specifications", function()
    local sql = "ALTER TABLE t ADD c1 INT, DROP c2;"
    local res = format_sql(sql)
    assert(res:find("add C1 int"), "ADD column should be formatted: " .. res)
    assert(res:find(", drop C2"), "DROP column should be formatted: " .. res)
end)

test("new formatter: CTAS with NO PRIMARY INDEX", function()
    local sql = "CREATE TABLE t (id INT) NO PRIMARY INDEX;"
    local res = format_sql(sql)
    assert(res:find("no primary index"), "NO PRIMARY INDEX should be formatted: " .. res)
end)
