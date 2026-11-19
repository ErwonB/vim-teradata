local config = require('vim-teradata.config')
local vsql   = require('vim-teradata.virtual_sql')

config.ensure()

test("virtual_sql.analyze extracts base and strips top-level ORDER BY", function()
    local w, err = vsql.analyze('SELECT a, b FROM t ORDER BY a;', { 'A', 'B' })
    assert(w and not err, 'unexpected error: ' .. tostring(err))
    assert(w.prefix == '', 'expected empty prefix, got: ' .. tostring(w.prefix))
    assert(w.base == 'SELECT a, b FROM t', 'unexpected base: ' .. tostring(w.base))
    assert(w.order_by == 'ORDER BY a', 'unexpected order_by: ' .. tostring(w.order_by))
end)

test("virtual_sql.analyze hoists top-level WITH clause into prefix", function()
    local w, err = vsql.analyze('WITH c AS (SELECT 1 x) SELECT x FROM c;', { 'X' })
    assert(w and not err, 'unexpected error: ' .. tostring(err))
    assert(w.prefix == 'WITH c AS (SELECT 1 x)', 'unexpected prefix: ' .. tostring(w.prefix))
    assert(w.base == 'SELECT x FROM c', 'unexpected base: ' .. tostring(w.base))
end)

test("virtual_sql.analyze accepts LOCKING ... FOR ACCESS and keeps it in prefix", function()
    local w, err = vsql.analyze('LOCKING ROW FOR ACCESS SELECT a FROM t;', { 'A' })
    assert(w and not err, 'unexpected error: ' .. tostring(err))
    assert(w.prefix == 'LOCKING ROW FOR ACCESS', 'unexpected prefix: ' .. tostring(w.prefix))
    assert(w.base == 'SELECT a FROM t', 'unexpected base: ' .. tostring(w.base))
end)

test("virtual_sql.derived builds explicit quoted column list", function()
    local w = assert(vsql.analyze('SELECT COUNT(*) FROM t;', { 'Count(*)' }))
    local d = vsql.derived(w, { 'Count(*)' })
    assert(d:find('("Count(*)")', 1, true), 'expected ("Count(*)") in derived: ' .. tostring(d))
end)

test("virtual_sql.analyze refuses DML, EXPLAIN, multiple statements, and empty header", function()
    local w1, e1 = vsql.analyze('UPDATE t SET a=1;', { 'A' })
    assert(w1 == nil and type(e1) == 'string', 'expected UPDATE to be refused')

    local w2, e2 = vsql.analyze('EXPLAIN SELECT 1;', { 'Explanation' })
    assert(w2 == nil and type(e2) == 'string', 'expected EXPLAIN to be refused')

    local w3, e3 = vsql.analyze('SELECT 1; SELECT 2;', { '1' })
    assert(w3 == nil and type(e3) == 'string', 'expected two statements to be refused')

    local w4, e4 = vsql.analyze('SELECT 1;', {})
    assert(w4 == nil and type(e4) == 'string', 'expected empty header to be refused')
end)

test("virtual_sql.quote_ident doubles internal double quotes", function()
    assert(vsql.quote_ident('a"b') == '"a""b"')
    assert(vsql.quote_ident('Count(*)') == '"Count(*)"')
end)

test("virtual_sql.rewrite_expr rewrites column refs via tree-sitter and preserves string literals", function()
    local rw, err = vsql.rewrite_expr('(price - t.cost) * qty', { 'PRICE', 'COST', 'QTY' })
    assert(rw and not err, 'unexpected rewrite error: ' .. tostring(err))
    assert(rw == '(vt."PRICE" - vt."COST") * vt."QTY"',
        'unexpected rewritten expression: ' .. tostring(rw))

    local rw_lit = assert(vsql.rewrite_expr("CASE WHEN item = 'price' THEN price ELSE 0 END", { 'ITEM', 'PRICE' }))
    assert(rw_lit == "CASE WHEN vt.\"ITEM\" = 'price' THEN vt.\"PRICE\" ELSE 0 END",
        "string literal 'price' must not be rewritten, got: " .. tostring(rw_lit))
end)

test("virtual_sql.build_footer_sql emits AVG(CAST(\"N\" AS FLOAT)), CAST(NULL AS INTEGER)", function()
    local sql, err = vsql.build_footer_sql({
        sql     = 'SELECT n, t FROM tbl;',
        header  = { 'N', 'T' },
        columns = {
            { name = 'N', is_numeric = true },
            { name = 'T', is_numeric = false },
        },
        mode = 'avg',
    })
    assert(sql and not err, 'unexpected error: ' .. tostring(err))
    assert(sql:find('AVG(CAST("N" AS FLOAT)), CAST(NULL AS INTEGER)', 1, true),
        'unexpected footer SQL: ' .. tostring(sql))
end)

test("virtual_sql.build_materialize_sql generates VAS_<id> with NO PRIMARY INDEX and ON COMMIT PRESERVE ROWS", function()
    local vt_name = vsql.default_vt_name('20261117-1234')
    assert(vt_name == 'VAS_20261117_1234', 'expected VAS_20261117_1234, got ' .. tostring(vt_name))

    local ddl, err = vsql.build_materialize_sql('SELECT a, b FROM t ORDER BY a;', { 'A', 'B' }, vt_name)
    assert(ddl and not err, 'unexpected error: ' .. tostring(err))
    assert(ddl:find('CREATE VOLATILE TABLE VAS_20261117_1234 AS', 1, true), 'missing table name in DDL: ' .. ddl)
    assert(ddl:find('NO PRIMARY INDEX', 1, true), 'missing NO PRIMARY INDEX in DDL: ' .. ddl)
    assert(ddl:find('ON COMMIT PRESERVE ROWS', 1, true), 'missing ON COMMIT PRESERVE ROWS in DDL: ' .. ddl)
    assert(not ddl:find('ORDER BY', 1, true), 'ORDER BY must be stripped inside CREATE TABLE AS: ' .. ddl)
end)
