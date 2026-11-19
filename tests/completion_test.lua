local completion = require('vim-teradata.sql-autocomplete.completion')
local types = require('vim-teradata.types')

test("collect_column_candidates with nil or empty alias returns empty table", function()
    local cands = completion._collect_column_candidates({ alias = "" })
    assert(type(cands) == "table")
    assert(#cands == 0)
end)

test("column-types §10.6: _build_column_item populates detail, labelDetails, and markdown documentation", function()
    local info = types.build_info({ code = 'CV', len = '10', chartype = '1', nullable = 'Y' })
    local item = completion._build_column_item('CUST_CD', {
        { source = 'EDW.CUST', info = info },
    })
    assert(item.detail == 'VARCHAR(10) CHARACTER SET LATIN', "Unexpected detail: " .. tostring(item.detail))
    assert(item.labelDetails and item.labelDetails.description == 'VARCHAR(10) CHARACTER SET LATIN')
    assert(item.documentation and item.documentation.kind == 'markdown')
    assert(item.documentation.value:find('EDW.CUST', 1, true))
    assert(item.documentation.value:find('NULL', 1, true))

    local plain = completion._build_column_item('X', nil)
    assert(plain.label == 'X')
    assert(plain.sortText == '1_X')
    assert(plain.kind ~= nil)
    assert(plain.detail == nil)
    assert(plain.labelDetails == nil)
    assert(plain.documentation == nil)
end)
