-- lua/vim-teradata/session.lua
-- Persistent BTEQ sessions driven over plain pipes (vim.system with an open
-- stdin): no PTY, no terminal emulator, no extra dependency, the same code on
-- Linux, macOS and Windows.
--
-- Protocol: every request is followed by
--     .IF ERRORCODE <> 0 THEN .REMARK '__VTD__<id>:ERR'
--     <post lines, e.g. .EXPORT RESET>
--     .REMARK '__VTD__<id>:END'
-- and completes when the END marker is read back on stdout. BTEQ may write
-- error text to stdout or stderr (.SET ERROROUT STDOUT is not honoured
-- everywhere), so both streams are read and attached to the running request;
-- a failed request whose error text is not there yet waits a few ms for it.
-- Input echo is off (.SET ECHOREQ OFF) and the matcher is anchored, so an
-- echoed `.REMARK '...'` line can never complete a request.
--
-- Callbacks receive the same table as bteq.start_job:
--     { rc = integer, msg = string, log_content = string[], timed_out = boolean }

local config = require('vim-teradata.config')

local M = {}

local TAG = '__VTD__'
local MARK_PAT = '^%s*' .. TAG .. '(%d+):(%u+)%s*$'
local IS_WIN = vim.fn.has('win32') == 1

-- A failed request whose error text has not arrived yet waits this long for
-- stderr (re-armed on every stderr chunk), but never more than GRACE_MAX_MS.
local GRACE_MS = 50
local GRACE_MAX_MS = 500
local NO_MESSAGE = 'BTEQ reported an error (ERRORCODE <> 0) but printed no message.'

-- Lines BTEQ prints in batch mode that carry no information for us.
local NOISE = {
    '^%s*$',
    '^%s*BTEQ %-%- Enter your',
}

---@type table<integer, table> bufnr -> session
local by_buf = {}
local seq = 0

local Session = {}
Session.__index = Session

local function quote(s)
    return "'" .. (s:gsub("'", "''")) .. "'"
end

local function is_noise(line)
    for _, p in ipairs(NOISE) do
        if line:match(p) then return true end
    end
    return false
end

--- Keeps the BTEQ failure/error lines; falls back to the whole log.
local function error_text(lines)
    local out = {}
    for _, l in ipairs(lines) do
        if l:match('^%s*%*%*%* ?[Ff]ailure') or l:match('^%s*%*%*%* ?[Ee]rror') then
            out[#out + 1] = l
        end
    end
    return (#out > 0) and table.concat(out, '\n') or table.concat(lines, '\n')
end

local function has_error_lines(lines)
    for _, l in ipairs(lines) do
        if l:match('^%s*%*%*%* ?[Ff]ailure') or l:match('^%s*%*%*%* ?[Ee]rror') then
            return true
        end
    end
    return false
end

local function result(rc, msg, log, timed_out)
    return { rc = rc, msg = msg or '', log_content = log or {}, timed_out = timed_out or false }
end

--- Result of a request that reached its END marker.
--- Error text comes from stderr when BTEQ wrote it there, from stdout otherwise.
local function request_result(req)
    local log = vim.list_extend(vim.list_extend({}, req.log), req.err)
    if not req.failed then
        return result(0, '', log)
    end
    local msg = (#req.err > 0) and table.concat(req.err, '\n') or error_text(req.log)
    if msg:match('^%s*$') then msg = NO_MESSAGE end
    return result(8, msg, log)
end

--- Completes a request exactly once.
local function finish(req, res)
    if req.done then return end
    req.done = true
    if req.timer then
        req.timer:stop()
        req.timer:close()
        req.timer = nil
    end
    if req.grace then
        req.grace:stop()
        req.grace:close()
        req.grace = nil
    end
    req.on_done(res)
end

local function new_session(user, bufnr)
    return setmetatable({
        bufnr = bufnr,
        user = user,
        alive = true,
        ready = false,
        closing = false,
        queue = {},
        current = nil,
        partial = '',
        partial_err = '',
        opened_at = os.time(),
    }, Session)
end

-----------------------------------------------------------------------
-- Output handling
-----------------------------------------------------------------------

--- Splits raw stdout data into lines (may be called from a fast context).
function Session:_feed(data)
    self.partial = self.partial .. data
    while true do
        local nl = self.partial:find('\n', 1, true)
        if not nl then break end
        local line = self.partial:sub(1, nl - 1)
        self.partial = self.partial:sub(nl + 1)
        self:_on_line(line)
    end
end

function Session:_on_line(line)
    line = line:gsub('\r$', '')
    local req = self.current
    if not req then return end -- noise between requests

    local id, kind = line:match(MARK_PAT)
    if id then
        if tonumber(id) == req.id then
            if kind == 'ERR' then
                req.failed = true
            elseif kind == 'END' then
                if req.failed and #req.err == 0 and not has_error_lines(req.log) then
                    -- the error text is probably still in the stderr pipe
                    self:_complete_after_grace(req)
                else
                    self:_complete(req)
                end
            end
        end
        return
    end
    if not is_noise(line) then
        req.log[#req.log + 1] = line
    end
end

--- Completes the current request and sends the next queued one.
function Session:_complete(req)
    if self.current ~= req then return end
    self.current = nil
    finish(req, request_result(req))
    self:_pump()
end

--- Waits briefly for stderr before completing a failed request. The request
--- stays `current` meanwhile, so late stderr lines are attached to it and the
--- next request is not sent yet.
function Session:_complete_after_grace(req)
    local started = vim.uv.now()
    req.grace = vim.uv.new_timer()
    req.rearm = function()
        if not req.grace then return end
        local left = GRACE_MAX_MS - (vim.uv.now() - started)
        req.grace:stop()
        req.grace:start(math.max(0, math.min(GRACE_MS, left)), 0, function()
            self:_complete(req)
        end)
    end
    req.rearm()
end

--- Splits raw stderr data into lines (may be called from a fast context).
function Session:_feed_err(data)
    self.partial_err = self.partial_err .. data
    while true do
        local nl = self.partial_err:find('\n', 1, true)
        if not nl then break end
        local line = self.partial_err:sub(1, nl - 1)
        self.partial_err = self.partial_err:sub(nl + 1)
        self:_on_err_line(line)
    end
end

function Session:_on_err_line(line)
    line = line:gsub('\r$', '')
    local req = self.current
    if not req or is_noise(line) then return end
    req.err[#req.err + 1] = line
    if req.rearm then req.rearm() end -- more error text may follow
end

-----------------------------------------------------------------------
-- Queue
-----------------------------------------------------------------------

function Session:_pump()
    if self.current or not self.alive then return end
    local req = table.remove(self.queue, 1)
    if not req then return end
    self.current = req

    local lines = vim.list_extend({}, req.body)
    lines[#lines + 1] = '.IF ERRORCODE <> 0 THEN .REMARK ' .. quote(TAG .. req.id .. ':ERR')
    vim.list_extend(lines, req.post or {})
    lines[#lines + 1] = '.REMARK ' .. quote(TAG .. req.id .. ':END')

    local timeout = config.options.timeout_ms
    if timeout and timeout > 0 then
        req.timer = vim.uv.new_timer()
        req.timer:start(timeout, 0, function()
            req.timed_out = true
            -- a stuck request cannot be resynchronised reliably: drop the session
            self:terminate('BTEQ timed out')
        end)
    end

    if req.on_start then pcall(req.on_start) end
    self.proc:write(table.concat(lines, '\n') .. '\n')
end

--- Queues a request.
--- @param body string[] lines up to and including the SQL terminator
--- @param post string[]|nil lines run after the error check (e.g. .EXPORT RESET)
--- @param on_done fun(res: table) same contract as bteq.start_job's callback
--- @param on_start fun()|nil called when the request is actually sent to BTEQ
--- @return table handle with :kill(), compatible with util.jobs_cancel
function Session:submit(body, post, on_done, on_start)
    seq = seq + 1
    local req = {
        id = seq, body = body, post = post,
        on_done = on_done, on_start = on_start,
        log = {}, err = {}, failed = false,
    }
    if not self.alive or self.closing then
        finish(req, result(1, 'BTEQ session is closed'))
    else
        table.insert(self.queue, req)
        self:_pump()
    end
    return { kill = function() self:cancel(req) end }
end

function Session:cancel(req)
    for i, q in ipairs(self.queue) do
        if q == req then
            table.remove(self.queue, i)
            return finish(req, result(130, 'Canceled'))
        end
    end
    if self.current ~= req then return end
    if IS_WIN then
        -- No SIGINT for a pipe-attached child on Windows: the session has to go.
        self:terminate('Canceled (BTEQ session closed)')
    else
        -- BTEQ aborts the running request and keeps the session; the markers
        -- already written then complete the request normally.
        self.proc:kill(2)
    end
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

function Session:terminate(reason)
    self.exit_reason = self.exit_reason or reason
    if self.alive then pcall(self.proc.kill, self.proc, 15) end
end

--- Logs off. A request already sent to BTEQ is allowed to finish first.
function Session:close()
    if not self.alive or self.closing then return end
    self.closing = true
    if by_buf[self.bufnr] == self then by_buf[self.bufnr] = nil end

    local queued = self.queue
    self.queue = {}
    for _, req in ipairs(queued) do
        finish(req, result(1, 'BTEQ session closed'))
    end

    pcall(self.proc.write, self.proc, '.LOGOFF\n.EXIT\n')
    pcall(self.proc.write, self.proc, nil) -- close stdin
    if not self.current then
        vim.defer_fn(function() self:terminate('BTEQ session closed') end, 5000)
    end
end

function Session:_on_exit(code)
    if self.partial ~= '' then
        local last = self.partial
        self.partial = ''
        self:_on_line(last)
    end
    if self.partial_err ~= '' then
        local last = self.partial_err
        self.partial_err = ''
        self:_on_err_line(last)
    end
    self.alive = false

    local reason = self.exit_reason or ('BTEQ session ended (exit code %d)'):format(code)
    local pending = self.queue
    self.queue = {}
    if self.current then table.insert(pending, 1, self.current) end
    self.current = nil

    for _, req in ipairs(pending) do
        local detail = (#req.err > 0) and table.concat(req.err, '\n') or error_text(req.log)
        finish(req, result((code ~= 0) and code or 1,
            reason .. '\n' .. detail, vim.list_extend(vim.list_extend({}, req.log), req.err),
            req.timed_out))
    end

    vim.schedule(function()
        if by_buf[self.bufnr] == self then by_buf[self.bufnr] = nil end
        -- logon failures are reported by the readiness probe (see M.open)
        if not self.closing and self.ready then
            vim.notify(reason, vim.log.levels.WARN, { title = 'Teradata' })
        end
    end)
end

local function describe(s)
    local state
    if not s.ready then
        state = 'logging on'
    else
        state = s.current and 'busy' or 'idle'
    end
    local queued = (#s.queue > 0) and (', %d queued'):format(#s.queue) or ''
    return ('%s@%s - %s%s (opened %s)'):format(
        s.user.user, s.user.tdpid, state, queued, os.date('%H:%M', s.opened_at))
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

--- Opens (or returns) the session attached to `bufnr`.
--- @param bufnr integer
--- @param user table { user, tdpid, log_mech }
--- @param opts table { logon = string[], settings = string[]|nil,
---                     on_ready = fun(s)|nil }
---        logon: the logon lines (charset, logmech, logon), see bteq.build_header
---        settings: session-wide .set commands run once after logon
--- @return table|nil session
function M.open(bufnr, user, opts)
    local existing = M.get(bufnr)
    if existing then return existing end

    local s = new_session(user, bufnr)
    local ok, proc = pcall(vim.system, { 'bteq' }, {
        stdin = true,
        stdout = function(_, data)
            if data then s:_feed(data) end
        end,
        -- BTEQ usually writes *** Failure / *** Error lines to stderr; read it
        -- as a stream too (not only at exit), see Session:_on_err_line.
        stderr = function(_, data)
            if data then s:_feed_err(data) end
        end,
    }, function(r) s:_on_exit(r.code) end)
    if not ok then
        vim.notify('Cannot start bteq: ' .. tostring(proc), vim.log.levels.ERROR, { title = 'Teradata' })
        return nil
    end
    s.proc = proc

    local prelude = vim.list_extend({}, opts.logon)
    vim.list_extend(prelude, {
        '.IF ERRORCODE <> 0 THEN .QUIT 12', -- never run requests unauthenticated
        '.set errorout stdout',             -- best effort: stderr is read too
        '.set echoreq off',                 -- protocol: no input echo
    })
    vim.list_extend(prelude, opts.settings or {})
    s.proc:write(table.concat(prelude, '\n') .. '\n')
    by_buf[bufnr] = s

    -- Readiness probe: an empty request that completes once logon and
    -- settings went through. A failed logon quits BTEQ, which fails the probe.
    s:submit({}, {}, function(res)
        vim.schedule(function()
            if res.rc == 0 then
                s.ready = true
                if opts.on_ready then opts.on_ready(s) end
            elseif not s.closing then
                vim.notify('BTEQ session could not log on:\n' .. (res.msg or ''),
                    vim.log.levels.ERROR, { title = 'Teradata' })
            end
        end)
    end)

    vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = bufnr,
        once = true,
        callback = function() M.close(bufnr) end,
    })
    return s
end

--- @return table|nil the live session attached to `bufnr`
function M.get(bufnr)
    local s = bufnr and by_buf[bufnr]
    return (s and s.alive and not s.closing) and s or nil
end

--- @return boolean true when a session was closed
function M.close(bufnr)
    local s = by_buf[bufnr]
    if not s then return false end
    s:close()
    return true
end

function M.close_all()
    for b in pairs(by_buf) do M.close(b) end
end

--- One-line description of the session of `bufnr`, or nil.
function M.describe(bufnr)
    local s = M.get(bufnr)
    return s and describe(s) or nil
end

--- Statusline helper: '' when the buffer has no session.
function M.statusline(bufnr)
    local s = M.get(bufnr or vim.api.nvim_get_current_buf())
    if not s then return '' end
    return ('TD:%s@%s%s'):format(s.user.user, s.user.tdpid, s.current and '*' or '')
end

--- @return integer number of live sessions
function M.count()
    local n = 0
    for b in pairs(by_buf) do
        if M.get(b) then n = n + 1 end
    end
    return n
end

--- :TDSessions
function M.show()
    local lines = {}
    for b in pairs(by_buf) do
        local s = M.get(b)
        if s then
            local name = vim.api.nvim_buf_is_valid(b)
                and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':~:.') or '?'
            if name == '' then name = '[No Name]' end
            lines[#lines + 1] = ('buf %d  %s  %s'):format(b, name, describe(s))
        end
    end
    table.sort(lines)
    vim.notify(#lines > 0 and table.concat(lines, '\n') or 'No open BTEQ session.',
        vim.log.levels.INFO, { title = 'Teradata' })
end

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('VimTeradataSessions', { clear = true }),
    callback = M.close_all,
})

--- Test helper: a session around a fake process, not registered anywhere.
function M._new(proc, user)
    local s = new_session(user or { user = 'U', tdpid = 'H', log_mech = 'TD2' }, -1)
    s.proc = proc
    s.ready = true
    return s
end

return M
