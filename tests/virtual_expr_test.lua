local config = require('vim-teradata.config')
local vexpr  = require('vim-teradata.virtual_expr')

config.ensure()

test("virtual_expr: price * qty and (price - cost) * qty", function()
    local ast, err = vexpr.parse('price * qty')
    assert(ast and not err, 'unexpected parse error: ' .. tostring(err))
    assert(ast.src == 'price * qty', 'expected ast.src to preserve expression text')

    local val, eval_err = vexpr.eval(ast, { PRICE = '2.5', QTY = '4' })
    assert(val == '10' and not eval_err, 'expected "10", got ' .. tostring(val))

    local ast2 = assert(vexpr.parse('(price - cost) * qty'))
    local val2 = vexpr.eval(ast2, { PRICE = '10.5', COST = '3', QTY = '2' })
    assert(val2 == '15', 'expected "15", got ' .. tostring(val2))
end)

test("virtual_expr: division by zero returns nil + error flag", function()
    local ast = assert(vexpr.parse('price / 0'))
    local val, err = vexpr.eval(ast, { PRICE = '10' })
    assert(val == nil and err == 'division by zero',
        string.format('expected nil + division by zero, got val=%s err=%s', tostring(val), tostring(err)))
end)

test("virtual_expr: COALESCE with NULL", function()
    local ast = assert(vexpr.parse('COALESCE(discount, 0)'))
    assert(vexpr.eval(ast, { DISCOUNT = 'NULL' }) == '0')
    assert(vexpr.eval(ast, { DISCOUNT = '' }) == '0')
    assert(vexpr.eval(ast, { DISCOUNT = '12.5' }) == '12.5')
end)

test("virtual_expr: CASE WHEN and predicates (BETWEEN, IN, LIKE, IS NULL)", function()
    local ast = assert(vexpr.parse("CASE WHEN qty > 3 THEN 'big' ELSE 'small' END"))
    assert(vexpr.eval(ast, { QTY = '5' }) == 'big')
    assert(vexpr.eval(ast, { QTY = '2' }) == 'small')

    local ast_pred = assert(vexpr.parse(
        "CASE WHEN code LIKE 'A_%' AND qty BETWEEN 1 AND 10 AND status IN ('OK', 'NEW') AND note IS NULL THEN 'match' ELSE 'no' END"
    ))
    assert(vexpr.eval(ast_pred, { CODE = 'A_12', QTY = '5', STATUS = 'OK', NOTE = 'NULL' }) == 'match')
    assert(vexpr.eval(ast_pred, { CODE = 'B_12', QTY = '5', STATUS = 'OK', NOTE = 'NULL' }) == 'no')
end)

test("virtual_expr: string concatenation || and NULL propagation", function()
    local ast = assert(vexpr.parse("first_name || ' ' || last_name"))
    assert(vexpr.eval(ast, { FIRST_NAME = 'Ada', LAST_NAME = 'Lovelace' }) == 'Ada Lovelace')
    assert(vexpr.eval(ast, { FIRST_NAME = 'Ada', LAST_NAME = 'NULL' }) == nil)
end)

test("virtual_expr: ROUND and CAST(x AS DECIMAL(10,2)) format exact decimals", function()
    local ast_round = assert(vexpr.parse('ROUND(price * 1.21, 2)'))
    assert(vexpr.eval(ast_round, { PRICE = '10.333' }) == '12.50')

    local ast_cast = assert(vexpr.parse('CAST(x AS DECIMAL(10,2))'))
    assert(vexpr.eval(ast_cast, { X = '5' }) == '5.00')
    assert(vexpr.eval(ast_cast, { X = '5.678' }) == '5.68')

    local ast_int = assert(vexpr.parse('CAST(x AS INTEGER)'))
    assert(vexpr.eval(ast_int, { X = '9.9' }) == '9')

    local ast_vc = assert(vexpr.parse('CAST(x AS VARCHAR(3))'))
    assert(vexpr.eval(ast_vc, { X = 'abcdef' }) == 'abc')
end)

test("virtual_expr: date arithmetic and EXTRACT", function()
    local ast_diff = assert(vexpr.parse('end_dt - start_dt'))
    assert(vexpr.eval(ast_diff, { END_DT = '2024-03-01', START_DT = '2024-02-01' }) == '29')

    local ast_add = assert(vexpr.parse('start_dt + 10'))
    assert(vexpr.eval(ast_add, { START_DT = '2024-02-20' }) == '2024-03-01')

    local ast_ext = assert(vexpr.parse('EXTRACT(MONTH FROM start_dt)'))
    assert(vexpr.eval(ast_ext, { START_DT = '2024-02-20' }) == '2')
end)

test("virtual_expr: qualified column references and quoted identifiers", function()
    local ast = assert(vexpr.parse('t.price * 2'))
    assert(vexpr.eval(ast, { PRICE = '7.5' }) == '15')

    local ast_q = assert(vexpr.parse('"Total Amount" + 5'))
    assert(vexpr.eval(ast_q, { ['Total Amount'] = '20' }) == '25')
end)

test("virtual_expr: scalar string and math functions", function()
    assert(vexpr.eval('UPPER( SUBSTR(name, 2, 3) )', { NAME = 'abcdef' }) == 'BCD')
    assert(vexpr.eval('SUBSTRING(name FROM 3 FOR 2)', { NAME = 'abcdef' }) == 'cd')
    assert(vexpr.eval("POSITION('cd' IN name)", { NAME = 'abcdef' }) == '3')
    assert(vexpr.eval("INDEX(name, 'cd')", { NAME = 'abcdef' }) == '3')
    assert(vexpr.eval("OREPLACE(name, 'bc', 'XY')", { NAME = 'abcdef' }) == 'aXYdef')
    assert(vexpr.eval("ZEROIFNULL(x) + COALESCE(NULLIFZERO(y), 5)", { X = 'NULL', Y = '0' }) == '5')
end)

test("virtual_expr: parse errors on invalid, multi-term or subquery expressions", function()
    local a1, e1 = vexpr.parse('price *')
    assert(a1 == nil and type(e1) == 'string', 'expected parse failure on "price *"')

    local a2, e2 = vexpr.parse('SELECT 1')
    assert(a2 == nil and type(e2) == 'string', 'expected parse failure on "SELECT 1"')

    local a3, e3 = vexpr.parse('(SELECT x FROM t)')
    assert(a3 == nil and type(e3) == 'string', 'expected parse failure on subquery')

    local a4, e4 = vexpr.parse('a, b')
    assert(a4 == nil and type(e4) == 'string', 'expected parse failure on multiple terms')
end)

test("virtual_expr: references returns deduplicated upper-cased column names", function()
    local refs = vexpr.references('a + b * COALESCE(c, a)')
    assert(vim.deep_equal(refs, { 'A', 'B', 'C' }),
        'expected {A, B, C}, got ' .. vim.inspect(refs))
end)
