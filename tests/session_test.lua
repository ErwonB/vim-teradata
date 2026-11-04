local session = require('vim-teradata.session')

local function fake_proc()
    local p = { written = {}, killed = {} }
    function p:write(data) if data then table.insert(self.written, data) end end
    function p:kill(sig) table.insert(self.killed, sig) end
    return p
end

local function last_id(p)
    return tonumber(p.written[#p.written]:match('__VTD__(%d+):END'))
end

local function new_session()
    local p = fake_proc()
    return session._new(p), p
end

test("session: END marker completes the request", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, { '.EXPORT RESET' }, function(r) res = r end)
    local id = last_id(p)
    assert(p.written[1]:find('.EXPORT RESET', 1, true), "post lines must be sent")
    s:_on_line(' *** Query completed. One row found. One column returned.')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(res and res.rc == 0, "request should succeed")
    for _, l in ipairs(res.log_content) do
        assert(not l:find('__VTD__', 1, true), "markers must not leak into the log")
    end
end)

test("session: an echoed .REMARK command does not complete the request", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, {}, function(r) res = r end)
    local id = last_id(p)
    s:_on_line(".REMARK '__VTD__" .. id .. ":END'")
    assert(res == nil, "echoed command must be ignored")
    s:_on_line('__VTD__' .. id .. ':END')
    assert(res ~= nil)
end)

test("session: ERR marker fails the request with the BTEQ message", function()
    local s, p = new_session()
    local res
    s:submit({ 'select * from nope;' }, {}, function(r) res = r end)
    local id = last_id(p)
    s:_on_line(" *** Failure 3807 Object 'nope' does not exist.")
    s:_on_line('__VTD__' .. id .. ':ERR')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(res.rc ~= 0, "request should fail")
    assert(res.msg:find('3807', 1, true), "msg should carry the failure line")
end)

test("session: CRLF output (Windows) is handled", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, {}, function(r) res = r end)
    s:_feed('__VTD__' .. last_id(p) .. ':END\r\n')
    assert(res and res.rc == 0)
end)

test("session: output split across chunks is reassembled", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, {}, function(r) res = r end)
    local marker = '__VTD__' .. last_id(p) .. ':END\n'
    s:_feed(marker:sub(1, 5))
    assert(res == nil)
    s:_feed(marker:sub(6))
    assert(res and res.rc == 0)
end)

test("session: requests are serialized", function()
    local s, p = new_session()
    local done = {}
    s:submit({ 'select 1;' }, {}, function() done[#done + 1] = 1 end)
    s:submit({ 'select 2;' }, {}, function() done[#done + 1] = 2 end)
    assert(#p.written == 1, "second request must wait for the first")
    s:_on_line('__VTD__' .. last_id(p) .. ':END')
    assert(#p.written == 2, "second request is sent once the first completes")
    s:_on_line('__VTD__' .. last_id(p) .. ':END')
    assert(done[1] == 1 and done[2] == 2, "completion order")
end)

test("session: canceling a queued request never sends it", function()
    local s, p = new_session()
    s:submit({ 'select 1;' }, {}, function() end)
    local res
    local h = s:submit({ 'select 2;' }, {}, function(r) res = r end)
    h:kill(15)
    assert(res and res.rc == 130, "queued request is canceled")
    s:_on_line('__VTD__' .. last_id(p) .. ':END')
    assert(#p.written == 1, "canceled request must not be sent")
end)

test("session: process exit fails running and queued requests", function()
    local s = new_session()
    local r1, r2
    s:submit({ 'select 1;' }, {}, function(r) r1 = r end)
    s:submit({ 'select 2;' }, {}, function(r) r2 = r end)
    s:_on_exit(12)
    assert(r1 and r1.rc == 12 and r2 and r2.rc == 12)
    local late
    s:submit({ 'select 3;' }, {}, function(r) late = r end)
    assert(late and late.rc ~= 0, "a dead session rejects new requests")
end)

test("session: error text on stderr is reported", function()
    local s, p = new_session()
    local res
    s:submit({ 'select * from nope;' }, {}, function(r) res = r end)
    local id = last_id(p)
    s:_feed_err(" *** Failure 3807 Object 'nope' does not exist.\n")
    s:_on_line('__VTD__' .. id .. ':ERR')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(res and res.rc ~= 0, "request should fail immediately (message already there)")
    assert(res.msg:find('3807', 1, true), "msg should carry the stderr failure line")
end)

test("session: stderr arriving after the END marker is still attached", function()
    local s, p = new_session()
    local res
    s:submit({ 'select * from nope;' }, {}, function(r) res = r end)
    local id = last_id(p)
    s:_on_line('__VTD__' .. id .. ':ERR')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(res == nil, "failed request without text must wait for stderr")
    s:_feed_err(" *** Failure 3807 Object 'nope' does not exist.\n")
    assert(vim.wait(1000, function() return res ~= nil end), "request should complete")
    assert(res.msg:find('3807', 1, true), "late stderr text must be in msg")
end)

test("session: next request waits for the grace period", function()
    local s, p = new_session()
    s:submit({ 'select * from nope;' }, {}, function() end)
    local id = last_id(p)
    s:submit({ 'select 1;' }, {}, function() end)
    s:_on_line('__VTD__' .. id .. ':ERR')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(#p.written == 1, "second request must not be sent during the grace period")
    assert(vim.wait(1000, function() return #p.written == 2 end), "second request sent afterwards")
end)

test("session: a failure without any text still has a message", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, {}, function(r) res = r end)
    local id = last_id(p)
    s:_on_line('__VTD__' .. id .. ':ERR')
    s:_on_line('__VTD__' .. id .. ':END')
    assert(vim.wait(1000, function() return res ~= nil end))
    assert(res.rc ~= 0 and not res.msg:match('^%s*$'), "msg must never be empty")
end)

test("session: successful requests do not wait", function()
    local s, p = new_session()
    local res
    s:submit({ 'select 1;' }, {}, function(r) res = r end)
    s:_on_line('__VTD__' .. last_id(p) .. ':END')
    assert(res and res.rc == 0, "success completes synchronously")
end)

test("session: logon errors on stderr reach the exit message", function()
    local s = new_session()
    local res
    s:submit({}, {}, function(r) res = r end)
    s:_feed_err(' *** Error: Logon failed!\n')
    s:_on_exit(12)
    assert(res and res.msg:find('Logon failed', 1, true))
end)

test("display_error never shows an empty message", function()
    local ui = require('vim-teradata.ui')
    local shown
    local orig = vim.notify
    vim.notify = function(msg) shown = msg end
    ui.display_error('')
    vim.notify = orig
    assert(shown and not shown:match('^%s*$'), "a fallback message is expected")
end)
