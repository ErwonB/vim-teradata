local types = require('vim-teradata.types')

test("types.build_info formats all DBC.ColumnsV type codes accurately", function()
    local cases = {
        {
            raw = { code = 'CV', len = '40', chartype = '2', nullable = 'Y' },
            type = 'VARCHAR(20) CHARACTER SET UNICODE',
            char_len = 20, charset = 'UNICODE', nullable = true, cat = 'char',
        },
        {
            raw = { code = 'CF', len = '1', chartype = '1', nullable = 'N' },
            type = 'CHAR(1) CHARACTER SET LATIN',
            char_len = 1, charset = 'LATIN', nullable = false, cat = 'char',
        },
        {
            raw = { code = 'D', len = '8', tot = '18', frac = '2' },
            type = 'DECIMAL(18,2)', cat = 'numeric',
        },
        {
            raw = { code = 'TS', frac = '6' },
            type = 'TIMESTAMP(6)', cat = 'timestamp',
        },
        {
            raw = { code = 'SZ', frac = '0' },
            type = 'TIMESTAMP(0) WITH TIME ZONE', cat = 'timestamp',
        },
        {
            raw = { code = 'PM', frac = '6' },
            type = 'PERIOD(TIMESTAMP(6) WITH TIME ZONE)', cat = 'period',
        },
        {
            raw = { code = 'PZ', frac = '3' },
            type = 'PERIOD(TIME(3) WITH TIME ZONE)', cat = 'period',
        },
        {
            raw = { code = 'DS', tot = '4', frac = '6' },
            type = 'INTERVAL DAY(4) TO SECOND(6)', cat = 'interval',
        },
        {
            raw = { code = 'SC', tot = '2', frac = '6' },
            type = 'INTERVAL SECOND(2,6)', cat = 'interval',
        },
        {
            raw = { code = 'N', tot = '-128', frac = '-128' },
            type = 'NUMBER(*)', cat = 'numeric',
        },
        {
            raw = { code = 'N', tot = '10', frac = '2' },
            type = 'NUMBER(10,2)', cat = 'numeric',
        },
        {
            raw = { code = 'N', tot = '10', frac = '0' },
            type = 'NUMBER(10)', cat = 'numeric',
        },
        {
            raw = { code = 'UT', udt = 'ST_GEOMETRY' },
            type = 'ST_GEOMETRY', cat = 'udt',
        },
        {
            raw = { code = 'A1', udt = 'MYARR' },
            type = 'SYSUDTLIB.MYARR', cat = 'array',
        },
        {
            raw = { code = 'AT' },
            type = 'TIME', cat = 'time',
        },
    }

    for _, c in ipairs(cases) do
        local info = types.build_info(c.raw)
        assert(info ~= nil, 'expected non-nil info for ' .. vim.inspect(c.raw))
        assert(info.type == c.type,
            string.format('expected type %q, got %q', tostring(c.type), tostring(info.type)))
        if c.char_len ~= nil then assert(info.char_len == c.char_len) end
        if c.charset ~= nil then assert(info.charset == c.charset) end
        if c.nullable ~= nil then assert(info.nullable == c.nullable) end
        if c.cat ~= nil then assert(types.category(info) == c.cat) end

        -- Round-trip encode / decode
        local encoded = types.encode(info)
        local loaded = assert(load('return ' .. encoded))()
        local decoded = types.decode(loaded)
        assert(vim.deep_equal(decoded, info),
            string.format('encode/decode mismatch: %s -> %s', vim.inspect(info), vim.inspect(decoded)))
    end

    local unk = types.build_info({ code = 'ZZ' })
    assert(unk and unk.type == nil and types.display(unk) == '? (ZZ)')

    assert(types.build_info({ code = '' }) == nil)
    assert(types.build_info({}) == nil)
end)

test("types.incompatible flags cross-category implicit conversions conservatively", function()
    assert(types.incompatible('char', 'numeric') == true)
    assert(types.incompatible('date', 'numeric') == false)
    assert(types.incompatible('date', 'timestamp') == false)
    assert(types.incompatible('char', 'char') == false)
end)
