local completion = require('vim-teradata.sql-autocomplete.completion')

test("collect_column_candidates with nil or empty alias returns empty table", function()
    local cands = completion._collect_column_candidates({ alias = "" })
    assert(type(cands) == "table")
    assert(#cands == 0)
end)
