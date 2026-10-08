local ope = require('vim-teradata.td_ope')

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
