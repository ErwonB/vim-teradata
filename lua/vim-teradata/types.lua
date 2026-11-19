--- Teradata column type helpers: formatting of DBC.ColumnsV attributes,
--- categories and (de)serialization of catalog entries.
local M = {}

M.CHARSETS = { [1] = 'LATIN', [2] = 'UNICODE', [3] = 'KANJISJIS', [4] = 'GRAPHIC', [5] = 'KANJI1' }

-- DBC.ColumnsV.ColumnLength is expressed in bytes; declared CHAR/VARCHAR/CLOB/JSON
-- lengths are in characters. UNICODE and GRAPHIC use 2 bytes per character.
local BYTES_PER_CHAR = { [2] = 2, [4] = 2 }

M.CATEGORY = {
    CF = 'char', CV = 'char', CO = 'char',
    I1 = 'numeric', I2 = 'numeric', I = 'numeric', I8 = 'numeric',
    D = 'numeric', F = 'numeric', N = 'numeric',
    DA = 'date',
    AT = 'time', TZ = 'time',
    TS = 'timestamp', SZ = 'timestamp',
    YR = 'interval', YM = 'interval', MO = 'interval', DY = 'interval', DH = 'interval',
    DM = 'interval', DS = 'interval', HR = 'interval', HM = 'interval', HS = 'interval',
    MI = 'interval', MS = 'interval', SC = 'interval',
    BF = 'byte', BV = 'byte', BO = 'byte',
    PD = 'period', PS = 'period', PM = 'period', PT = 'period', PZ = 'period',
    JN = 'json', XM = 'xml', DT = 'dataset',
    UT = 'udt', A1 = 'array', AN = 'array',
    ['++'] = 'any',
}

--- "(a,b)" or "" when any argument is nil.
local function paren(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        if v == nil then return '' end
        parts[i] = tostring(v)
    end
    return '(' .. table.concat(parts, ',') .. ')'
end

local function udt_or(r, fallback) return r.udt or fallback end
local function sysudt_or(r, fallback) return r.udt and ('SYSUDTLIB.' .. r.udt) or fallback end

local FMT = {
    BF   = function(r) return 'BYTE' .. paren(r.len) end,
    BV   = function(r) return 'VARBYTE' .. paren(r.len) end,
    BO   = function(r) return 'BLOB' .. paren(r.len) end,
    CF   = function(r) return 'CHAR' .. paren(r.chars) end,
    CV   = function(r) return 'VARCHAR' .. paren(r.chars) end,
    CO   = function(r) return 'CLOB' .. paren(r.chars) end,
    D    = function(r) return 'DECIMAL' .. paren(r.tot, r.frac) end,
    DA   = function() return 'DATE' end,
    F    = function() return 'FLOAT' end,
    I1   = function() return 'BYTEINT' end,
    I2   = function() return 'SMALLINT' end,
    I    = function() return 'INTEGER' end,
    I8   = function() return 'BIGINT' end,
    AT   = function(r) return 'TIME' .. paren(r.frac) end,
    TS   = function(r) return 'TIMESTAMP' .. paren(r.frac) end,
    TZ   = function(r) return 'TIME' .. paren(r.frac) .. ' WITH TIME ZONE' end,
    SZ   = function(r) return 'TIMESTAMP' .. paren(r.frac) .. ' WITH TIME ZONE' end,
    YR   = function(r) return 'INTERVAL YEAR' .. paren(r.tot) end,
    YM   = function(r) return 'INTERVAL YEAR' .. paren(r.tot) .. ' TO MONTH' end,
    MO   = function(r) return 'INTERVAL MONTH' .. paren(r.tot) end,
    DY   = function(r) return 'INTERVAL DAY' .. paren(r.tot) end,
    DH   = function(r) return 'INTERVAL DAY' .. paren(r.tot) .. ' TO HOUR' end,
    DM   = function(r) return 'INTERVAL DAY' .. paren(r.tot) .. ' TO MINUTE' end,
    DS   = function(r) return 'INTERVAL DAY' .. paren(r.tot) .. ' TO SECOND' .. paren(r.frac) end,
    HR   = function(r) return 'INTERVAL HOUR' .. paren(r.tot) end,
    HM   = function(r) return 'INTERVAL HOUR' .. paren(r.tot) .. ' TO MINUTE' end,
    HS   = function(r) return 'INTERVAL HOUR' .. paren(r.tot) .. ' TO SECOND' .. paren(r.frac) end,
    MI   = function(r) return 'INTERVAL MINUTE' .. paren(r.tot) end,
    MS   = function(r) return 'INTERVAL MINUTE' .. paren(r.tot) .. ' TO SECOND' .. paren(r.frac) end,
    SC   = function(r) return 'INTERVAL SECOND' .. paren(r.tot, r.frac) end,
    PD   = function() return 'PERIOD(DATE)' end,
    PS   = function(r) return 'PERIOD(TIMESTAMP' .. paren(r.frac) .. ')' end,
    PM   = function(r) return 'PERIOD(TIMESTAMP' .. paren(r.frac) .. ' WITH TIME ZONE)' end,
    PT   = function(r) return 'PERIOD(TIME' .. paren(r.frac) .. ')' end,
    PZ   = function(r) return 'PERIOD(TIME' .. paren(r.frac) .. ' WITH TIME ZONE)' end,
    JN   = function(r) return 'JSON' .. paren(r.chars) end,
    XM   = function() return 'XML' end,
    DT   = function() return 'DATASET' end,
    UT   = function(r) return udt_or(r, 'UDT') end,
    A1   = function(r) return sysudt_or(r, 'ARRAY') end,
    AN   = function(r) return sysudt_or(r, 'ARRAY') end,
    ['++'] = function() return 'TD_ANYTYPE' end,
    N    = function(r)
        if r.tot == nil then return 'NUMBER' end
        local p = (r.tot == -128) and '*' or tostring(r.tot)
        local s = (r.frac ~= nil and r.frac ~= 0 and r.frac ~= -128) and (',' .. r.frac) or ''
        return 'NUMBER(' .. p .. s .. ')'
    end,
}

local function nonempty(s)
    if s == nil then return nil end
    s = vim.trim(tostring(s))
    return s ~= '' and s or nil
end

--- Builds a TDColumnInfo from the raw export fields (strings, possibly empty).
--- @param raw { code:string?, len:string?, tot:string?, frac:string?, chartype:string?, nullable:string?, udt:string? }
--- @return TDColumnInfo|nil  nil when there is no type code (e.g. view columns)
function M.build_info(raw)
    local code = nonempty(raw.code)
    if not code then return nil end
    code = code:upper()

    local ct = tonumber(nonempty(raw.chartype) or '')
    local len = tonumber(nonempty(raw.len) or '')
    local cat = M.CATEGORY[code]
    local r = {
        len  = len,
        tot  = tonumber(nonempty(raw.tot) or ''),
        frac = tonumber(nonempty(raw.frac) or ''),
        udt  = nonempty(raw.udt),
    }
    if len and (cat == 'char' or code == 'JN') then
        r.chars = math.floor(len / (BYTES_PER_CHAR[ct] or 1))
    end

    local fmt = FMT[code]
    local typ = fmt and fmt(r) or nil
    local charset
    if cat == 'char' then
        charset = M.CHARSETS[ct]
        if typ and charset then typ = typ .. ' CHARACTER SET ' .. charset end
    end

    local n = nonempty(raw.nullable)
    local nullable
    if n == 'Y' then nullable = true elseif n == 'N' then nullable = false end

    return {
        code     = code,
        type     = typ,
        nullable = nullable,
        char_len = (cat == 'char') and r.chars or nil,
        charset  = charset,
    }
end

--- Builds a TDColumnInfo from a DDL type string in CREATE VOLATILE TABLE (§8.1).
--- @param type_text string|nil
--- @return TDColumnInfo|nil
function M.from_ddl(type_text)
    local t = nonempty(type_text)
    if not t then return nil end
    t = t:gsub('%s+', ' '):upper()

    local code
    if t:match('^BYTEINT%f[%W]') then code = 'I1'
    elseif t:match('^SMALLINT%f[%W]') then code = 'I2'
    elseif t:match('^BIGINT%f[%W]') then code = 'I8'
    elseif t:match('^INTEGER%f[%W]') or t:match('^INT%f[%W]') then code = 'I'
    elseif t:match('^DECIMAL%f[%W]') or t:match('^DEC%f[%W]') or t:match('^NUMERIC%f[%W]') then code = 'D'
    elseif t:match('^NUMBER%f[%W]') then code = 'N'
    elseif t:match('^FLOAT%f[%W]') or t:match('^REAL%f[%W]') or t:match('^DOUBLE%s+PRECISION%f[%W]') then code = 'F'
    elseif t:match('^VARCHAR%f[%W]') or t:match('^CHAR%s+VARYING%f[%W]') or t:match('^CHARACTER%s+VARYING%f[%W]') then code = 'CV'
    elseif t:match('^CLOB%f[%W]') then code = 'CO'
    elseif t:match('^CHAR%f[%W]') or t:match('^CHARACTER%f[%W]') then code = 'CF'
    elseif t:match('^VARBYTE%f[%W]') then code = 'BV'
    elseif t:match('^BLOB%f[%W]') then code = 'BO'
    elseif t:match('^BYTE%f[%W]') then code = 'BF'
    elseif t:match('^DATE%f[%W]') then code = 'DA'
    elseif t:match('^TIMESTAMP%f[%W]') then
        code = t:find('WITH TIME ZONE', 1, true) and 'SZ' or 'TS'
    elseif t:match('^TIME%f[%W]') then
        code = t:find('WITH TIME ZONE', 1, true) and 'TZ' or 'AT'
    elseif t:match('^PERIOD%s*%(%s*DATE') then code = 'PD'
    elseif t:match('^PERIOD%s*%(%s*TIMESTAMP') then
        code = t:find('WITH TIME ZONE', 1, true) and 'PM' or 'PS'
    elseif t:match('^PERIOD%s*%(%s*TIME') then
        code = t:find('WITH TIME ZONE', 1, true) and 'PZ' or 'PT'
    elseif t:match('^JSON%f[%W]') then code = 'JN'
    elseif t:match('^XML%f[%W]') then code = 'XM'
    elseif t:match('^INTERVAL%f[%W]') then
        if t:find('YEAR', 1, true) and t:find('MONTH', 1, true) then code = 'YM'
        elseif t:find('YEAR', 1, true) then code = 'YR'
        elseif t:find('MONTH', 1, true) then code = 'MO'
        elseif t:find('DAY', 1, true) and t:find('HOUR', 1, true) then code = 'DH'
        elseif t:find('DAY', 1, true) and t:find('MINUTE', 1, true) then code = 'DM'
        elseif t:find('DAY', 1, true) and t:find('SECOND', 1, true) then code = 'DS'
        elseif t:find('DAY', 1, true) then code = 'DY'
        elseif t:find('HOUR', 1, true) and t:find('MINUTE', 1, true) then code = 'HM'
        elseif t:find('HOUR', 1, true) and t:find('SECOND', 1, true) then code = 'HS'
        elseif t:find('HOUR', 1, true) then code = 'HR'
        elseif t:find('MINUTE', 1, true) and t:find('SECOND', 1, true) then code = 'MS'
        elseif t:find('MINUTE', 1, true) then code = 'MI'
        else code = 'SC'
        end
    else
        code = 'UT'
    end

    local cat = M.CATEGORY[code]
    local char_len, charset
    if cat == 'char' then
        local n_str = t:match('%((%d+)%)')
        char_len = n_str and tonumber(n_str) or (code == 'CF' and 1 or nil)
        charset = t:match('CHARACTER%s+SET%s+([%w_]+)')
    end

    return {
        code     = code,
        type     = t,
        nullable = nil,
        char_len = char_len,
        charset  = charset,
    }
end

--- @param info_or_code TDColumnInfo|string|nil
--- @return string|nil 'char'|'numeric'|'date'|'time'|'timestamp'|'interval'|'byte'|'period'|...
function M.category(info_or_code)
    if info_or_code == nil then return nil end
    local code = type(info_or_code) == 'table' and info_or_code.code or info_or_code
    return code and M.CATEGORY[code] or nil
end

--- Human readable type ("VARCHAR(30) CHARACTER SET LATIN", "? (ZZ)"), nil if no info.
function M.display(info)
    if not info then return nil end
    if info.type and info.type ~= '' then return info.type end
    if info.code and info.code ~= '' then return '? (' .. info.code .. ')' end
    return nil
end

-- Pairs of categories whose comparison needs an implicit conversion that is worth
-- flagging. Deliberately conservative: DATE vs numeric (integer dates) and
-- DATE vs TIMESTAMP are valid Teradata comparisons and are NOT listed.
local INCOMPATIBLE = {
    char      = { numeric = true, date = true, time = true, timestamp = true, interval = true, byte = true },
    numeric   = { char = true, byte = true, time = true, timestamp = true, interval = true },
    date      = { char = true, byte = true, time = true },
    time      = { char = true, numeric = true, date = true, byte = true },
    timestamp = { char = true, numeric = true, byte = true },
    interval  = { char = true, numeric = true, byte = true },
    byte      = { char = true, numeric = true, date = true, time = true, timestamp = true, interval = true },
}

--- @return boolean true when comparing values of categories a and b deserves a warning
function M.incompatible(a, b)
    if not a or not b or a == b then return false end
    return (INCOMPATIBLE[a] and INCOMPATIBLE[a][b]) or false
end

--- Serializes an info as a Lua table constructor for the catalog file.
function M.encode(info)
    local vals = { info.code, info.type, info.nullable, info.char_len, info.charset }
    local last = 0
    for i = 1, 5 do if vals[i] ~= nil then last = i end end
    local out = {}
    for i = 1, last do
        local v = vals[i]
        if v == nil then
            out[i] = 'nil'
        elseif type(v) == 'string' then
            out[i] = string.format('%q', v)
        else
            out[i] = tostring(v)
        end
    end
    return '{ ' .. table.concat(out, ', ') .. ' }'
end

--- Accepts a positional catalog entry or an already-decoded info.
--- @return TDColumnInfo|nil
function M.decode(e)
    if type(e) ~= 'table' then return nil end
    if e.code then return e end
    if e[1] == nil then return nil end
    return { code = e[1], type = e[2], nullable = e[3], char_len = e[4], charset = e[5] }
end

return M
