local bteq = require('vim-teradata.bteq')
require('vim-teradata.config').ensure()

local USER = { user = 'U', tdpid = 'H', log_mech = 'TD2' }

local function index_of(lines, pattern)
    for i, l in ipairs(lines) do
        if l:lower():find(pattern) then return i end
    end
end

test("one-shot script sets the session charset before .logon", function()
    local script = bteq._build_script('select 1;', USER, { operation = 'output' }, '/tmp/x.csv').script
    local charset = index_of(script, 'session charset')
    local logon = index_of(script, '^%.logon')
    assert(charset and logon, "charset and logon lines expected")
    assert(charset < logon, "SESSION CHARSET must precede .LOGON")
end)

test("request lines reset retlimit for EXPLAIN", function()
    local body = bteq._request_lines('explain select 1;', { operation = 'output', skip_retlimit = true }, '/tmp/x.csv')
    assert(index_of(body, '^%.set retlimit 0'), "EXPLAIN must not be truncated")
end)

test("request lines close the export", function()
    local _, post = bteq._request_lines('select 1;', { operation = 'output' }, '/tmp/x.csv')
    assert(post[1] == '.EXPORT RESET')
end)

test("export path quotes are escaped", function()
    local body = bteq._request_lines('select 1;', { operation = 'output' }, "/tmp/o'brien.csv")
    assert(index_of(body, "o''brien"), "single quote must be doubled")
end)
