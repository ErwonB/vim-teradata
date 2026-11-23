local lex = require('vim-teradata.sql_lex')

local function norm(sql)
    local s, err = lex.normalize_for_export(sql)
    assert(s, err)
    return s
end

test("lexer: literals, quoted identifiers and comments are recognised", function()
    local toks = assert(lex.tokenize([[select 'it''s -- not a comment', "a ""b"" /* c */" -- it's one
/* block ' with quote */ from t]]))
    local kinds = {}
    for _, tk in ipairs(toks) do
        if tk.t ~= 'ws' and tk.t ~= 'punct' and tk.t ~= 'word' then kinds[#kinds + 1] = tk.t end
    end
    assert(table.concat(kinds, ',') == 'string,qident,line_comment,block_comment', table.concat(kinds, ','))
end)

test("lexer: unterminated literal, identifier and comment are reported with a line", function()
    local _, e1 = lex.tokenize("select 'abc\nfrom t")
    assert(e1 and e1:find('string literal') and e1:find('line 1'), e1)
    local _, e2 = lex.tokenize('select 1\n, "abc from t')
    assert(e2 and e2:find('quoted identifier') and e2:find('line 2'), e2)
    local _, e3 = lex.tokenize('select 1 /* open')
    assert(e3 and e3:find('comment'), e3)
end)

test("normalize: comments removed, whitespace collapsed, literals kept", function()
    local sql = table.concat({
        '/* header */',
        'Select -- first col',
        "'01' as \"line_type\" -- it's a comment with a quote",
        ",'a--b' as \"x/*y*/\"",
        ",'' as \"AdditionalSeparator\"",
        "from DB.T /* inline */ where d = date'2026-03-31' -- end",
        ';',
    }, '\r\n')
    local expected = [[Select '01' as "line_type" ,'a--b' as "x/*y*/" ,CAST('' AS VARCHAR(1)) as "AdditionalSeparator" from DB.T where d = date'2026-03-31']]
    local got = norm(sql)
    assert(got == expected, got)
end)

test("normalize: a/*c*/b keeps a separator, newlines inside literals survive", function()
    assert(norm('select a/*c*/b from t') == 'select a b from t')
    assert(norm("select 'l1\nl2' from t") == "select 'l1\nl2' from t")
    assert(norm('select 1 -- trailing') == 'select 1')
    assert(norm('select 1 ;; -- done') == 'select 1')
end)

test("normalize: only bare '' of the outer select list is widened", function()
    local W = lex.EMPTY_LITERAL
    assert(norm("select '' from t") == 'select ' .. W .. ' from t')
    assert(norm("sel distinct '' as x, a||'' from t") == 'sel distinct ' .. W .. ' as x, a||' .. W .. ' from t')
    assert(norm("select case when a=1 then '' else '' end from t")
        == 'select case when a=1 then ' .. W .. ' else ' .. W .. ' end from t')
    -- inside parens, WHERE, prefixed literals and other literals: untouched
    assert(norm("select coalesce(a, '') from t where b = ''") == "select coalesce(a, '') from t where b = ''")
    assert(norm("select x'' , 'it''s' from t") == "select x'' , 'it''s' from t")
    assert(norm("select ' ' from t") == "select ' ' from t")
    -- CTE: the main select list is the first one at depth 0
    assert(norm("with c as (select '' x) select '', x from c") == "with c as (select '' x) select " .. W .. ", x from c")
    -- locking modifier in front
    assert(norm("locking row for access select '' from t") == 'locking row for access select ' .. W .. ' from t')
end)

test("utf-8 validation", function()
    assert(lex.invalid_utf8_at("select 'é€' from t") == nil)
    assert(lex.invalid_utf8_at("select '\233' from t") == 9) -- Latin-1 é
    assert(lex.invalid_utf8_at('\226\130') == 1)              -- truncated €
end)

test("tpt_quote doubles single quotes only", function()
    assert(lex.tpt_quote([[select '' as "A" from t]]) == [['select '''' as "A" from t']])
end)
