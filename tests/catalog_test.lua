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
