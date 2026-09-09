-- vim-teradata: in-grid editing of result sets.
--
-- Turns the `Teradata Result - <id>` buffer into an editable grid and generates
-- UPDATE statements from the modified cells.
--
--   * simple SELECT (single relation)  -> "matchall" WHERE: every eligible column
--                                        compared against its ORIGINAL value
--                                        (IS NULL when the original was NULL).
--   * SELECT with joins               -> the user is asked, once per table owning
--                                        edited columns, which columns form the
--                                        WHERE condition.
--
-- A column is eligible only when its select item is `X`, `a.x`, `a.x AS X` or
-- `a.x X`. Every other shape (functions, literals, expressions, `*`, window
-- functions, ...) is neither editable nor usable in the WHERE clause.

local config = require('vim-teradata.config')
local tsu    = require('vim-teradata.ts-util')

local M = {}

local SEP = ' | '          -- must match ui.populate_buffer's visual_separator
local HEADER_LINES = 2     -- header + dashes

-- =============================================================================
-- Per-buffer state (kept module-local: buffer vars deep-copy on every access)
-- =============================================================================

---@class TDEditColumn
---@field result_name string
---@field eligible boolean
---@field source_column string|nil
---@field table_key string|nil
---@field alias string|nil

---@class TDEditMeta
---@field editable boolean
---@field reason string|nil
---@field mode "simple"|"join"|nil
---@field columns TDEditColumn[]                            -- indexed by original column position
---@field tables table<string,{display:string,update_name:string}>

---@class TDEditState
---@field meta TDEditMeta
---@field original string[][]
---@field populate function
---@field editing boolean
---@field keys table<string,integer[]>                      -- table_key -> original column indexes
---@field saved_maps table<string,function>

---@type table<integer,TDEditState>
local state = {}

local ns = vim.api.nvim_create_namespace('vim-teradata-edit')

local function notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = 'Teradata Edit' })
end

local function null_token()
    return config.options.null_token or 'NULL'
end

-- =============================================================================
-- Query analysis
-- =============================================================================

local function node_text(node, source)
    if not node then return nil end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    return ok and text or nil
end

--- Collects every descendant of `node` with one of `types`, without descending
--- into nodes listed in `stop` (used to keep out of nested subqueries).
local function collect(node, types, stop, acc)
    acc = acc or {}
    for child in node:iter_children() do
        local t = child:type()
        if types[t] then table.insert(acc, child) end
        if not (stop and stop[t]) then
            collect(child, types, stop, acc)
        end
    end
    return acc
end

--- Resolves an `object_reference` into { db, name } following the same rules as
--- sql-autocomplete/treesitter.lua:find_all_tables_in_scope.
local function resolve_object_reference(obj_ref, source)
    local db_node     = tsu.child_by_field(obj_ref, 'database')
    local schema_node = tsu.child_by_field(obj_ref, 'schema')
    local name_node   = tsu.child_by_field(obj_ref, 'name')

    local db   = schema_node and node_text(schema_node, source) or nil
    local name = name_node and node_text(name_node, source) or nil

    if not db_node and not schema_node and not name_node then
        local ids = {}
        for child in obj_ref:iter_children() do
            if child:type() == 'identifier' then table.insert(ids, child) end
        end
        if #ids == 1 then
            name = node_text(ids[1], source)
        elseif #ids == 2 then
            db, name = node_text(ids[1], source), node_text(ids[2], source)
        elseif #ids >= 3 then
            db, name = node_text(ids[#ids - 1], source), node_text(ids[#ids], source)
        end
    end
    return db, name
end

--- Builds the relation list of the statement's own FROM clause.
--- @return table|nil relations, string|nil reason
local function collect_relations(from_node, source)
    if not from_node then return nil, 'no FROM clause' end

    local relations = collect(from_node, { relation = true }, { subquery = true })
    if #relations == 0 then return nil, 'no relation found in FROM' end

    local list = {}
    for _, rel in ipairs(relations) do
        local obj_ref, bad = nil, nil
        for child in rel:iter_children() do
            local t = child:type()
            if t == 'subquery' then bad = 'derived table (subquery) in FROM' end
            if t == 'table_function' then bad = 'table function in FROM' end
            if t == 'object_reference' and not obj_ref then obj_ref = child end
        end
        if bad then return nil, bad end
        if not obj_ref then return nil, 'unsupported relation in FROM' end

        local alias_node = tsu.child_by_field(rel, 'alias')
        if not alias_node then
            for child in rel:iter_children() do
                if child:type() == 'identifier' then alias_node = child break end
            end
        end

        local db, name = resolve_object_reference(obj_ref, source)
        if not name then return nil, 'could not resolve a table name' end

        local update_name = db and (db .. '.' .. name) or name
        local alias       = alias_node and node_text(alias_node, source) or nil
        local key         = (alias or name):upper()

        table.insert(list, {
            key         = key,
            alias       = alias,
            update_name = update_name,
            display     = update_name .. (alias and (' ' .. alias) or ''),
        })
    end
    return list, nil
end

--- Classifies one `term` of the select list.
local function classify_term(term, source, relations)
    local alias_node = tsu.child_by_field(term, 'alias')
    local value      = tsu.child_by_field(term, 'value')

    if not value then
        -- older grammar shape: (term (field ...)) without the `value:` field
        for child in term:iter_children() do
            if child ~= alias_node and child:named() then value = child break end
        end
    end

    local result_name = node_text(alias_node, source)

    if not value or value:type() ~= 'field' then
        return {
            result_name = result_name or (node_text(term, source) or '?'),
            eligible    = false,
        }
    end

    local name_node = tsu.child_by_field(value, 'name')
    local qualifier = tsu.child_by_type(value, 'object_reference')

    if not name_node then
        -- e.g. (field (identifier)) unlabeled: take the last identifier child
        local ids = {}
        for child in value:iter_children() do
            if child:type() == 'identifier' then table.insert(ids, child) end
        end
        name_node = ids[#ids]
    end

    local source_column = node_text(name_node, source)
    if not source_column then
        return { result_name = result_name or '?', eligible = false }
    end
    result_name = result_name or source_column

    -- qualified: a.x [[AS] X]
    if qualifier then
        local qual_ids = {}
        for child in qualifier:iter_children() do
            if child:type() == 'identifier' then table.insert(qual_ids, child) end
        end
        local qual = node_text(qual_ids[#qual_ids], source)
        local key  = qual and qual:upper() or nil
        for _, rel in ipairs(relations) do
            if rel.key == key then
                return {
                    result_name   = result_name,
                    eligible      = true,
                    source_column = source_column,
                    table_key     = rel.key,
                    alias         = qual,
                }
            end
        end
        return { result_name = result_name, eligible = false }
    end

    -- unqualified: X [[AS] Y] -- only unambiguous with a single relation
    if #relations == 1 then
        return {
            result_name   = result_name,
            eligible      = true,
            source_column = source_column,
            table_key     = relations[1].key,
        }
    end
    return { result_name = result_name, eligible = false }
end

--- Analyzes the executed SQL and reports which result columns can be edited.
--- @param sql string
--- @return TDEditMeta
function M.analyze(sql)
    local function no(reason) return { editable = false, reason = reason, columns = {} } end

    local ok, parser = pcall(vim.treesitter.get_string_parser, sql, 'teradata')
    if not ok or not parser then return no('tree-sitter parser unavailable') end
    local tree = parser:parse()[1]
    if not tree then return no('could not parse the query') end
    local root = tree:root()

    local statements = {}
    for child in root:iter_children() do
        if child:type() == 'statement' then table.insert(statements, child) end
    end
    if #statements == 0 then return no('no statement found') end
    if #statements > 1 then return no('multistatement results are not editable') end

    local stmt = statements[1]
    if tsu.any_capture and root:has_error() then
        -- keep going: BTEQ accepted the query, a grammar hiccup should not block us
    end

    local select_node = tsu.child_by_type(stmt, 'select')
    if not select_node then return no('not a SELECT statement') end

    local blockers = collect(stmt, {
        set_operation = true,
        cte           = true,
        group_by      = true,
        having        = true,
    }, { subquery = true })
    if #blockers > 0 then
        return no(blockers[1]:type():gsub('_', ' ') .. ' queries are not editable')
    end

    for child in select_node:iter_children() do
        if child:type() == 'keyword_distinct' then
            return no('SELECT DISTINCT is not editable')
        end
    end

    local select_expr = tsu.child_by_type(select_node, 'select_expression')
    if not select_expr then return no('empty select list') end

    if tsu.descendant(select_expr, 'all_fields') then
        return no("SELECT * is not editable - expand '*' (:TDCodeAction) and re-run")
    end

    local relations, reason = collect_relations(tsu.child_by_type(stmt, 'from'), sql)
    if not relations then return no(reason) end

    local columns = {}
    for term in select_expr:iter_children() do
        if term:type() == 'term' then
            table.insert(columns, classify_term(term, sql, relations))
        end
    end
    if #columns == 0 then return no('no select item recognised') end

    local eligible = 0
    for _, c in ipairs(columns) do if c.eligible then eligible = eligible + 1 end end
    if eligible == 0 then
        return no('no column of the select list has an updatable form (X, a.x, a.x AS X)')
    end

    local tables = {}
    for _, rel in ipairs(relations) do
        tables[rel.key] = { display = rel.display, update_name = rel.update_name }
    end

    return {
        editable = true,
        mode     = (#relations == 1) and 'simple' or 'join',
        columns  = columns,
        tables   = tables,
    }
end

-- =============================================================================
-- SQL generation
-- =============================================================================

-- Returns true when `value` represents SQL NULL (either Lua nil, or the
-- configured null_token string, e.g. "NULL").
-- An empty string '' is NOT NULL — it is an empty string value.
local function sql_null(value)
    if value == nil then return true end
    local tok = null_token()
    return tok ~= '' and value == tok
end

local function quote_literal(value)
    -- nil or null_token -> SQL NULL keyword (used in SET clause)
    if sql_null(value) then return 'NULL' end
    -- numeric literals: emit unquoted
    if value:match('^%-?%d+$') or value:match('^%-?%d*%.%d+$') then return value end
    -- everything else: single-quoted, with internal single-quotes doubled
    return "'" .. value:gsub("'", "''") .. "'"
end

local function predicate(column, value)
    -- nil or null_token -> IS NULL (never `= NULL`)
    if sql_null(value) then
        return column .. ' IS NULL'
    end
    return column .. ' = ' .. quote_literal(value)
end

--- Builds the UPDATE statements for a diff.
--- @param st TDEditState
--- @param diffs table<integer, table<integer,string>>  row_id -> col_id -> new value
--- @return string[] statements
function M.build_statements(st, diffs)
    local meta = st.meta
    local statements = {}

    local row_ids = {}
    for row_id in pairs(diffs) do table.insert(row_ids, row_id) end
    table.sort(row_ids)

    for _, row_id in ipairs(row_ids) do
        local original = st.original[row_id]
        -- group the row's changes by owning table
        local per_table, order = {}, {}
        for col_id, new_value in pairs(diffs[row_id]) do
            local col = meta.columns[col_id]
            if not per_table[col.table_key] then
                per_table[col.table_key] = {}
                table.insert(order, col.table_key)
            end
            table.insert(per_table[col.table_key], { col_id = col_id, value = new_value })
        end
        table.sort(order)

        for _, table_key in ipairs(order) do
            local changes = per_table[table_key]
            table.sort(changes, function(a, b) return a.col_id < b.col_id end)

            local sets = {}
            for _, ch in ipairs(changes) do
                local col = meta.columns[ch.col_id]
                table.insert(sets, col.source_column .. ' = ' .. quote_literal(ch.value))
            end

            -- WHERE: matchall (simple) or the user-chosen keys (join).
            -- original[col_id] is the raw stored value: nil/"" for empty string,
            -- null_token for SQL NULL.  predicate() / is_null() must see the real
            -- value – never coerce nil to '' here, or NULL becomes 'col = ''' instead
            -- of 'col IS NULL'.
            local where = {}
            if meta.mode == 'simple' then
                for col_id, col in ipairs(meta.columns) do
                    if col.eligible then
                        table.insert(where, predicate(col.source_column, original[col_id]))
                    end
                end
            else
                for _, col_id in ipairs(st.keys[table_key] or {}) do
                    local col = meta.columns[col_id]
                    table.insert(where, predicate(col.source_column, original[col_id]))
                end
            end

            assert(#where > 0, 'vim-teradata: refusing to build an UPDATE without a WHERE clause')

            table.insert(statements, table.concat({
                'UPDATE ' .. meta.tables[table_key].update_name,
                'SET ' .. table.concat(sets, ', '),
                'WHERE ' .. table.concat(where, '\n  AND '),
            }, '\n'))
        end
    end

    return statements
end

-- =============================================================================
-- Grid <-> data
-- =============================================================================

local function buf_var(bufnr, name, default)
    local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
    if ok then return value end
    return default
end

--- Splits one rendered grid line into its cell values using the ' | ' separator
--- as a boundary anchor between columns.
--
-- Why not slice by col_widths?
-- col_widths are computed from the original (pre-edit) data at render time.
-- If the user types a value longer than the original (e.g. 'NULL' into a 0-wide
-- NULL cell, or any longer string), the excess spills past the stored width
-- boundary and the slice-based approach picks up part of the separator (' | ')
-- as cell content.  Splitting on the separator is safe because the separator
-- string ' | ' (space-pipe-space) is chosen so that it cannot appear inside a
-- value: BTEQ uses '~' as the field delimiter in the CSV, so pipe characters
-- in data would have caused problems there already; more importantly the
-- separator always sits between exactly-padded columns, so even if '|' appears
-- in data the surrounding spaces make an unambiguous boundary.
--
-- For the last column there is no trailing separator, so we just take
-- everything after the last separator occurrence and trim whitespace.
--- Locates the cell under the cursor.
--- Returns the DISPLAYED indexes (i = row on screen, j = column on screen) plus
--- the ORIGINAL ids they map to.
--- @return table|nil { i, j, row_id, col_id } , string|nil error
local function cell_at_cursor(bufnr)
    local st = state[bufnr]
    local widths  = buf_var(bufnr, 'teradata_column_widths')
    local row_ids = buf_var(bufnr, 'teradata_displayed_ids')
    local col_ids = buf_var(bufnr, 'teradata_displayed_col_ids')
    if not (widths and row_ids and col_ids) then return nil, 'grid metadata missing' end

    local lnum = vim.fn.line('.')
    local i = lnum - HEADER_LINES
    if i < 1 or i > #row_ids then return nil, 'place the cursor on a data row' end

    -- same arithmetic as ui.get_column_from_cursor
    local col = vim.fn.virtcol('.') - 1
    local pos, j = 0, nil
    for k, width in ipairs(widths) do
        if col >= pos and col < pos + width then j = k break end
        pos = pos + width + #SEP
    end
    if not j then return nil, 'place the cursor inside a column' end

    return { i = i, j = j, row_id = row_ids[i], col_id = col_ids[j] }
end

--- The value currently shown for a cell: the pending edit if any, else the original.
local function effective_value(st, row_id, col_id)
    local pending = st.pending[row_id]
    if pending and pending[col_id] ~= nil then return pending[col_id] end
    return st.original[row_id][col_id]
end

--- Writes a value into the rendered grid data so populate_buffer redraws it with
--- correct alignment (widths are recomputed from the data on every render).
local function apply_to_grid(bufnr, i, j, value)
    local displayed = buf_var(bufnr, 'teradata_displayed_data')
    if not displayed or not displayed[i] then return end
    displayed[i][j] = value
    vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', displayed)
end

--- Computes the byte offset at which displayed column `j` starts.
local function col_offset(widths, j)
    local pos = 0
    for k = 1, j - 1 do pos = pos + (widths[k] or 0) + #SEP end
    return pos
end

--- Dims non-updatable columns and highlights cells with a pending edit.
local function highlight_cells(bufnr)
    local st = state[bufnr]
    local widths  = buf_var(bufnr, 'teradata_column_widths')
    local row_ids = buf_var(bufnr, 'teradata_displayed_ids')
    local col_ids = buf_var(bufnr, 'teradata_displayed_col_ids')
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    if not (widths and row_ids and col_ids) then return end
    if not st.editing then return end

    for j, col_id in ipairs(col_ids) do
        local col = st.meta.columns[col_id]
        local pos = col_offset(widths, j)
        local width = widths[j] or 0

        -- read-only columns: dim header + all rows
        if not (col and col.eligible) then
            for i = 0, #row_ids do
                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, HEADER_LINES + i - 1, pos, {
                    end_col = pos + width,
                    hl_group = 'Comment',
                })
            end
        else
            -- editable columns: highlight the cells carrying a pending change
            for i, row_id in ipairs(row_ids) do
                local pending = st.pending[row_id]
                if pending and pending[col_id] ~= nil then
                    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, HEADER_LINES + i - 1, pos, {
                        end_col = pos + width,
                        hl_group = 'DiffText',
                    })
                end
            end
        end
    end
end

--- Prompts for a new value for the cell under the cursor and records it as a
--- pending edit. No buffer text is parsed: the grid is re-rendered from data,
--- so column alignment can never corrupt a value.
function M.edit_cell(bufnr)
    local st = state[bufnr]
    if not st or not st.editing then
        return notify('Press ' .. config.options.edit_keymaps.toggle .. ' to enter edit mode first.',
            vim.log.levels.WARN)
    end

    local cell, err = cell_at_cursor(bufnr)
    if not cell then return notify(err, vim.log.levels.WARN) end

    local col = st.meta.columns[cell.col_id]
    if not (col and col.eligible) then
        return notify(string.format(
            "Column '%s' is not updatable (only X, a.x, a.x AS X can be edited).",
            (col and col.result_name) or ('#' .. cell.col_id)), vim.log.levels.WARN)
    end

    local current = effective_value(st, cell.row_id, cell.col_id) or ''

    vim.ui.input({
        prompt = string.format('%s = ', col.source_column),
        default = current,
    }, function(input)
        if input == nil then return end          -- cancelled: nothing changes
        input = (input:gsub('^%s+', ''):gsub('%s+$', ''))

        local original = st.original[cell.row_id][cell.col_id]
        local orig_str = original or ''

        st.pending[cell.row_id] = st.pending[cell.row_id] or {}
        if input == orig_str then
            st.pending[cell.row_id][cell.col_id] = nil   -- back to the original value
            if next(st.pending[cell.row_id]) == nil then
                st.pending[cell.row_id] = nil
            end
        else
            st.pending[cell.row_id][cell.col_id] = input
        end

        apply_to_grid(bufnr, cell.i, cell.j, input)
        st.populate()
        highlight_cells(bufnr)
        M.set_edit_hint(bufnr)
    end)
end

--- Sets the cell under the cursor to SQL NULL without typing the token.
function M.set_cell_null(bufnr)
    local st = state[bufnr]
    if not st or not st.editing then return end

    local cell, err = cell_at_cursor(bufnr)
    if not cell then return notify(err, vim.log.levels.WARN) end

    local col = st.meta.columns[cell.col_id]
    if not (col and col.eligible) then
        return notify(string.format("Column '%s' is not updatable.",
            (col and col.result_name) or ('#' .. cell.col_id)), vim.log.levels.WARN)
    end

    local token = null_token()
    st.pending[cell.row_id] = st.pending[cell.row_id] or {}
    if (st.original[cell.row_id][cell.col_id] or '') == token then
        st.pending[cell.row_id][cell.col_id] = nil
        if next(st.pending[cell.row_id]) == nil then st.pending[cell.row_id] = nil end
    else
        st.pending[cell.row_id][cell.col_id] = token
    end

    apply_to_grid(bufnr, cell.i, cell.j, token)
    st.populate()
    highlight_cells(bufnr)
    M.set_edit_hint(bufnr)
end

--- Counts the pending changes.
local function pending_count(st)
    local rows, cells = 0, 0
    for _, changes in pairs(st.pending) do
        rows = rows + 1
        for _ in pairs(changes) do cells = cells + 1 end
    end
    return rows, cells
end

-- =============================================================================
-- Join mode: per-table WHERE key prompting
-- =============================================================================

--- Asks the user which columns to use in the WHERE clause, one table at a time.
--- @param bufnr integer
--- @param table_keys string[]
--- @param on_done function called with no argument on success, nil on abort
local function prompt_keys(bufnr, table_keys, on_done)
    local st = state[bufnr]

    local function next_table(index)
        if index > #table_keys then return on_done() end
        local table_key = table_keys[index]

        if st.keys[table_key] and #st.keys[table_key] > 0 then
            return next_table(index + 1)
        end

        local candidates = {}
        for col_id, col in ipairs(st.meta.columns) do
            if col.eligible and col.table_key == table_key then
                table.insert(candidates, { col_id = col_id, label = col.source_column })
            end
        end
        if #candidates == 0 then
            notify(string.format(
                'No updatable column available as WHERE key for %s - qualify more of its columns in the SELECT.',
                st.meta.tables[table_key].display), vim.log.levels.ERROR)
            return
        end

        local picked = {}
        local function pick()
            local items, map = {}, {}
            for _, cand in ipairs(candidates) do
                if not picked[cand.col_id] then
                    local label = cand.label
                    table.insert(items, label)
                    map[label] = cand.col_id
                end
            end
            if next(picked) then table.insert(items, '[Done]') end

            vim.ui.select(items, {
                prompt = string.format('WHERE key columns for %s (%d/%d)',
                    st.meta.tables[table_key].display, index, #table_keys),
            }, function(choice)
                if not choice then
                    notify('Save aborted.', vim.log.levels.WARN)
                    return
                end
                if choice == '[Done]' then
                    local ids = {}
                    for col_id in pairs(picked) do table.insert(ids, col_id) end
                    table.sort(ids)
                    st.keys[table_key] = ids
                    return next_table(index + 1)
                end
                picked[map[choice]] = true
                if #items == 1 then -- nothing left to pick
                    local ids = {}
                    for col_id in pairs(picked) do table.insert(ids, col_id) end
                    table.sort(ids)
                    st.keys[table_key] = ids
                    return next_table(index + 1)
                end
                pick()
            end)
        end
        pick()
    end

    next_table(1)
end

-- =============================================================================
-- Preview buffer
-- =============================================================================

local function show_preview(statements, on_accept)
    local lines = {}
    for _, stmt in ipairs(statements) do
        for _, line in ipairs(vim.split(stmt, '\n')) do table.insert(lines, line) end
        table.insert(lines, ';')
        table.insert(lines, '')
    end
    table.insert(lines, '')

    vim.cmd('belowright split')
    vim.cmd.enew()
    vim.bo.buftype   = 'nofile'
    vim.bo.bufhidden = 'wipe'
    vim.bo.swapfile  = false
    local bufnr = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_name, bufnr, 'Teradata Update Preview')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo.filetype = 'teradata'

    local hint_ns = vim.api.nvim_create_namespace('HelperBuffer')
    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, #lines - 1, 0, {
        virt_text = { { '<CR> Execute  <q> Abort', 'Comment' } },
        virt_text_pos = 'eol',
    })
    vim.bo.modifiable = false

    local function close()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end

    vim.keymap.set('n', '<cr>', function()
        close()
        on_accept()
    end, { buffer = bufnr, silent = true, nowait = true })

    vim.keymap.set('n', 'q', function()
        close()
        notify('Update aborted - your edits are still in the result buffer.', vim.log.levels.WARN)
    end, { buffer = bufnr, silent = true, nowait = true })
end

-- =============================================================================
-- Save / cancel / toggle
-- =============================================================================

local function set_hint(bufnr, text)
    local hint_ns = vim.api.nvim_create_namespace('HelperBuffer')
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, last, -1)
    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, last, 0, {
        virt_text = { { text, 'Comment' } },
        virt_text_pos = 'eol',
    })
end

--- Neutralises the grid mappings that would rebuild the buffer mid-edit.
--- `<cr>` is repurposed as "edit the cell under the cursor".
local GRID_MAPS = { '<cr>', '-', '<bs>', 'u', '<Up>', '<Down>' }

local function is_cr(key)
    if not key then return false end
    local k = key:lower()
    return k == '<cr>' or k == '<enter>' or k == '<return>'
end

local function lock_grid_maps(bufnr)
    local maps = config.options.edit_keymaps
    for _, lhs in ipairs(GRID_MAPS) do
        if lhs == '<cr>' then
            vim.keymap.set('n', lhs, function() M.edit_cell(bufnr) end,
                { buffer = bufnr, silent = true, nowait = true })
        else
            vim.keymap.set('n', lhs, function()
                notify(string.format('Save (%s) or cancel (%s) your edits first.',
                    maps.save, maps.cancel), vim.log.levels.WARN)
            end, { buffer = bufnr, silent = true, nowait = true })
        end
    end
    if maps.edit_cell and not is_cr(maps.edit_cell) then
        vim.keymap.set('n', maps.edit_cell, function() M.edit_cell(bufnr) end,
            { buffer = bufnr, silent = true, nowait = true })
    end
end

local function unlock_grid_maps(bufnr)
    -- ui.display_output re-registers the grid mappings through populate_buffer's
    -- owner; simply deleting ours restores nothing, so ui exposes a re-bind hook.
    local st = state[bufnr]
    local maps = config.options.edit_keymaps
    for _, lhs in ipairs(GRID_MAPS) do
        pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
    end
    if maps.edit_cell and not is_cr(maps.edit_cell) then
        pcall(vim.keymap.del, 'n', maps.edit_cell, { buffer = bufnr })
    end
    if st and st.rebind_grid_maps then st.rebind_grid_maps() end
end

--- Renders the edit-mode hint line, including the pending-change count.
function M.set_edit_hint(bufnr)
    local st = state[bufnr]
    if not st or not st.editing then return end
    local maps = config.options.edit_keymaps
    local rows, cells = pending_count(st)
    local pending = (cells > 0)
        and string.format('%d change(s) on %d row(s)', cells, rows)
        or 'no change yet'
    set_hint(bufnr, string.format(
        '-- EDIT MODE (%s) --  <%s> Edit cell  <%s> Set NULL  <%s> Save  <%s> Cancel',
        pending, maps.edit_cell, maps.set_null, maps.save, maps.cancel))
end

function M.cancel(bufnr)
    local st = state[bufnr]
    if not st or not st.editing then return end
    local _, cells = pending_count(st)

    st.editing = false
    st.pending = {}
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    unlock_grid_maps(bufnr)

    -- restore the grid data as it was when edit mode was entered
    if st.grid_snapshot then
        vim.api.nvim_buf_set_var(bufnr, 'teradata_displayed_data', st.grid_snapshot)
        st.grid_snapshot = nil
    end

    st.populate()
    M.decorate(bufnr)
    if cells > 0 then
        notify(string.format('%d pending change(s) discarded.', cells))
    end
end

local function execute(bufnr, statements)
    local bteq = require('vim-teradata.bteq')
    bteq.run_updates(statements, function(res, counts)
        if res.rc ~= 0 then
            require('vim-teradata.ui').display_error(res.msg)
            return
        end
        local parts = {}
        for i, n in ipairs(counts) do
            table.insert(parts, string.format('#%d: %s row(s)', i, n == nil and '?' or n))
        end
        notify(string.format('%d statement(s) executed (%s).',
            #statements, table.concat(parts, ', ')))

        for i, n in ipairs(counts) do
            if n == 0 then
                notify(string.format('Statement #%d changed no row - the data may have changed since the SELECT.', i),
                    vim.log.levels.WARN)
            elseif n and n > 1 then
                notify(string.format('Statement #%d changed %d rows - the WHERE clause was not unique.', i, n),
                    vim.log.levels.WARN)
            end
        end

        local st = state[bufnr]
        if st and vim.api.nvim_buf_is_valid(bufnr) then
            local all_data = buf_var(bufnr, 'teradata_all_data')
            for row_id, changes in pairs(st.pending) do
                for col_id, new_val in pairs(changes) do
                    if st.original[row_id] then
                        st.original[row_id][col_id] = new_val
                    end
                    if all_data and all_data[row_id] then
                        all_data[row_id][col_id] = new_val
                    end
                end
            end
            if all_data then
                vim.api.nvim_buf_set_var(bufnr, 'teradata_all_data', all_data)
            end

            st.editing = false
            st.pending = {}
            st.grid_snapshot = nil
            unlock_grid_maps(bufnr)
            vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
            st.populate()
            M.decorate(bufnr)
        end
    end)
end

function M.save(bufnr)
    local st = state[bufnr]
    if not st or not st.editing then
        return notify('Not in edit mode.', vim.log.levels.WARN)
    end

    local _, cells = pending_count(st)
    if cells == 0 then
        return notify('No change to save.', vim.log.levels.WARN)
    end

    -- The pending table is already keyed by ORIGINAL row/column ids and holds
    -- only eligible columns, so it is the diff: no text parsing involved.
    local diffs = st.pending

    local function finish()
        local statements = M.build_statements(st, diffs)
        if config.options.preview_updates then
            show_preview(statements, function() execute(bufnr, statements) end)
        else
            execute(bufnr, statements)
        end
    end

    if st.meta.mode == 'join' then
        local seen, keys = {}, {}
        for _, changes in pairs(diffs) do
            for col_id in pairs(changes) do
                local tk = st.meta.columns[col_id].table_key
                if not seen[tk] then
                    seen[tk] = true
                    table.insert(keys, tk)
                end
            end
        end
        table.sort(keys)
        prompt_keys(bufnr, keys, finish)
    else
        finish()
    end
end

function M.toggle(bufnr)
    local st = state[bufnr]
    if not st then return end
    if not st.meta.editable then
        return notify('This result is not editable: ' .. (st.meta.reason or 'unsupported query'),
            vim.log.levels.WARN)
    end

    if st.editing then
        return M.cancel(bufnr)
    end

    st.editing = true
    st.pending = {}
    -- The buffer deliberately stays NON-modifiable: values are changed through a
    -- prompt and the grid is redrawn from data, so alignment can never corrupt a
    -- value the way free-text editing of a fixed-width grid would.
    vim.bo[bufnr].modifiable = false
    st.grid_snapshot = vim.deepcopy(buf_var(bufnr, 'teradata_displayed_data') or {})

    lock_grid_maps(bufnr)
    highlight_cells(bufnr)
    M.set_edit_hint(bufnr)
    notify(string.format('Edit mode on (%s). Press %s on a cell to change it.',
        st.meta.mode, config.options.edit_keymaps.edit_cell))
end

--- Appends the "<E> Edit" affordance to the grid hint line. Called by ui after
--- every populate_buffer().
function M.decorate(bufnr)
    local st = state[bufnr]
    if not st or st.editing then return end
    local maps = config.options.edit_keymaps
    if st.meta.editable then
        set_hint(bufnr, string.format(
            '<Enter> Filter  <-> Remove Col  <BS> Restore Col  <u> Unfilter  <Up/Down> Sort  <%s> Edit',
            maps.toggle))
    end
end

-- =============================================================================
-- Attach
-- =============================================================================

--- Enables result editing for a result buffer.
--- @param bufnr integer
--- @param sql string the SQL that produced the result
--- @param opts table { data = string[][], populate = fun(),
---                     rebind_grid_maps = fun()|nil }
function M.attach(bufnr, sql, opts)
    if not config.options.edit_enabled then return end

    local meta = M.analyze(sql)
    state[bufnr] = {
        meta             = meta,
        original         = opts.data,
        populate         = opts.populate,
        rebind_grid_maps = opts.rebind_grid_maps,
        editing          = false,
        pending          = {},
        keys             = {},
    }

    local maps = config.options.edit_keymaps
    vim.keymap.set('n', maps.toggle, function() M.toggle(bufnr) end,
        { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set('n', maps.save, function() M.save(bufnr) end,
        { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set('n', maps.cancel, function() M.cancel(bufnr) end,
        { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set('n', maps.set_null, function() M.set_cell_null(bufnr) end,
        { buffer = bufnr, silent = true, nowait = true })

    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        buffer = bufnr,
        once = true,
        callback = function() state[bufnr] = nil end,
    })

    M.decorate(bufnr)
end

--- Exposed for tests.
function M._state(bufnr) return state[bufnr] end

return M
