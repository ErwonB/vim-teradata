-- vim-teradata: minimal Teradata SQL lexer used to make a statement safe to
-- hand to TPT (job variable file -> DEFINE SCHEMA FROM SELECT -> SelectStmt).
--
-- It knows exactly four kinds of "opaque" text, which are never modified:
--   'string'   '...'   with '' as the escaped quote (also date'..', x'..', n'..')
--   'qident'   "..."   with "" as the escaped double quote
--   'line_comment'  -- ... up to (not including) the newline
--   'block_comment' /* ... */
-- Everything else is split into words, whitespace and single punctuation chars.
-- Pure Lua (no vim.*), so it can be unit-tested outside Neovim.

local M = {}

---@class VtdSqlToken
---@field t 'ws'|'line_comment'|'block_comment'|'string'|'qident'|'word'|'punct'
---@field s string
---@field pos integer byte offset in the source

--- 1-based line number of byte offset `pos`, for error messages.
local function line_of(sql, pos)
    local _, n = sql:sub(1, pos):gsub('\n', '')
    return n + 1
end

---@param sql string
---@return VtdSqlToken[]|nil tokens, string|nil err
function M.tokenize(sql)
    local toks, i, n = {}, 1, #sql
    local function push(t, s, pos) toks[#toks + 1] = { t = t, s = s, pos = pos } end
    while i <= n do
        local c = sql:sub(i, i)
        local c2 = sql:sub(i + 1, i + 1)
        if c:match('%s') then
            local _, e = sql:find('^%s+', i)
            push('ws', sql:sub(i, e), i)
            i = e + 1
        elseif c == '-' and c2 == '-' then
            -- the newline itself stays a whitespace token: it separates tokens
            local e = sql:find('\n', i + 2, true) or (n + 1)
            push('line_comment', sql:sub(i, e - 1), i)
            i = e
        elseif c == '/' and c2 == '*' then
            local _, e = sql:find('*/', i + 2, true)
            if not e then
                return nil, ('Unterminated /* comment (line %d).'):format(line_of(sql, i))
            end
            push('block_comment', sql:sub(i, e), i)
            i = e + 1
        elseif c == "'" or c == '"' then
            local j = i + 1
            while true do
                local k = sql:find(c, j, true)
                if not k then
                    return nil, ('Unterminated %s starting on line %d.'):format(
                        c == "'" and 'string literal' or 'quoted identifier', line_of(sql, i))
                end
                if sql:sub(k + 1, k + 1) == c then
                    j = k + 2 -- doubled quote: still inside
                else
                    j = k
                    break
                end
            end
            push(c == "'" and 'string' or 'qident', sql:sub(i, j), i)
            i = j + 1
        elseif c:match('[%w_$#@]') or c:byte() >= 128 then
            local _, e = sql:find('^[%w_$#@\128-\255]+', i)
            push('word', sql:sub(i, e), i)
            i = e + 1
        else
            push('punct', c, i)
            i = i + 1
        end
    end
    return toks
end

local function is_trivia(tk)
    return tk.t == 'ws' or tk.t == 'line_comment' or tk.t == 'block_comment'
end

--- Drops every comment and turns each run of whitespace/comments between two
--- tokens into a single space. Literals and quoted identifiers are untouched,
--- so a newline inside a string literal survives.
---@param toks VtdSqlToken[]
---@return VtdSqlToken[]
local function compact(toks)
    local out, pending = {}, false
    for _, tk in ipairs(toks) do
        if is_trivia(tk) then
            pending = #out > 0
        else
            if pending then out[#out + 1] = { t = 'ws', s = ' ', pos = tk.pos } end
            pending = false
            out[#out + 1] = tk
        end
    end
    return out
end

M.EMPTY_LITERAL = "CAST('' AS VARCHAR(1))"

-- Tokens after which a bare '' is a value of its own (not 'date ''' etc.).
local VALUE_START_WORD = { select = true, sel = true, distinct = true, all = true, ['then'] = true, ['else'] = true }
local VALUE_START_PUNCT = { [','] = true, ['|'] = true }

--- Teradata types '' as a zero-length character column. TPT derives its
--- schema from the SELECT (DEFINE SCHEMA ... FROM SELECT DELIMITED) and a
--- VARCHAR(0) column is not accepted, so the job fails before exporting a row.
--- Rewrites every bare '' of the outermost select list (paren depth 0, between
--- the first top-level SELECT and its FROM) to CAST('' AS VARCHAR(1)).
--- The exported field is still empty.
---@param toks VtdSqlToken[] compacted tokens (modified in place)
---@return integer count
local function widen_empty_literals(toks)
    local depth, in_list, count = 0, false, 0
    local prev -- last significant token
    for _, tk in ipairs(toks) do
        if tk.t == 'punct' and tk.s == '(' then
            depth = depth + 1
        elseif tk.t == 'punct' and tk.s == ')' then
            depth = depth - 1
        elseif depth == 0 then
            if tk.t == 'word' then
                local w = tk.s:lower()
                if not in_list and (w == 'select' or w == 'sel') then
                    in_list = true
                elseif in_list and w == 'from' then
                    break
                end
            elseif in_list and tk.t == 'string' and tk.s == "''" and prev then
                local ok = (prev.t == 'punct' and VALUE_START_PUNCT[prev.s])
                    or (prev.t == 'word' and VALUE_START_WORD[prev.s:lower()])
                if ok then
                    tk.s = M.EMPTY_LITERAL
                    count = count + 1
                end
            end
        end
        if tk.t ~= 'ws' then prev = tk end
    end
    return count
end

--- Statement as sent to TPT: comments removed, whitespace collapsed to single
--- spaces (one line unless a string literal contains a newline), zero-length
--- literals of the select list widened, no leading/trailing ';'.
---@param sql string a single statement (already validated)
---@return string|nil stmt, string|nil err, integer|nil widened
function M.normalize_for_export(sql)
    local toks, err = M.tokenize(sql or '')
    if not toks then return nil, err end
    toks = compact(toks)
    local widened = widen_empty_literals(toks)
    local parts = {}
    for i, tk in ipairs(toks) do parts[i] = tk.s end
    local stmt = table.concat(parts):gsub('^[%s;]+', ''):gsub('[%s;]+$', '')
    if stmt == '' then return nil, 'The query is empty.' end
    return stmt, nil, widened
end

--- Byte offset of the first invalid UTF-8 sequence, or nil when `s` is valid.
--- TPT reads the job variable file as UTF-8 (USING CHARACTER SET UTF8): a
--- query saved as Latin-1/CP1252 (é, €, ...) breaks the job variable parser.
---@param s string
---@return integer|nil
function M.invalid_utf8_at(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return i end
        for k = i + 1, i + len - 1 do
            local b = s:byte(k)
            if not b or b < 0x80 or b > 0xBF then return i end
        end
        i = i + len
    end
    return nil
end

--- Quotes `s` as a TPT string value ('...' with '' for a quote).
---@param s string
---@return string
function M.tpt_quote(s)
    return "'" .. s:gsub("'", "''") .. "'"
end

return M
