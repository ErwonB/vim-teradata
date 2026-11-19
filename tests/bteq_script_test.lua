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

test("run_virtual with track_last_run = false does not overwrite bteq.is_latest_query", function()
    local cfg = require('vim-teradata.config')
    local orig_users = cfg.options.users
    local orig_idx   = cfg.options.current_user_index
    local orig_start = bteq._start_job

    cfg.options.users = { USER }
    cfg.options.current_user_index = 1
    bteq._start_job = function(_, on_done)
        on_done({ rc = 0, msg = '', log_content = { ' *** Query completed. 1 rows found.' } })
        return { kill = function() end }
    end

    local orig_id = bteq._run_single_query('SELECT 1;', 'output', function() end, { session_buf = -1 })
    assert(orig_id and bteq.is_latest_query(orig_id), "expected orig_id to be latest query")

    local virt_id = bteq.run_virtual('SELECT 2;', { session_buf = nil, label = 'virtual: test' }, function() end)
    assert(virt_id and virt_id ~= orig_id, "expected distinct virtual job id")
    assert(bteq.is_latest_query(orig_id), "run_virtual must not replace last_run")
    assert(not bteq.is_latest_query(virt_id), "virtual query id must not become latest_id")

    bteq._start_job = orig_start
    cfg.options.users = orig_users
    cfg.options.current_user_index = orig_idx
end)
