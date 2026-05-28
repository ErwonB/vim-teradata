local M = {}

-- =============================================================================
-- Configuration
-- =============================================================================
local SLOW_STEP_THRESHOLD = 60     -- seconds; steps slower than this get flagged
local INLINE_TABLE_LIMIT  = 4      -- max tables to list inline before "+N more"
local TOP_N_EXPENSIVE     = 5      -- how many slow steps to highlight in summary

-- =============================================================================
-- Small utilities
-- =============================================================================
local function uniq_push(list, seen, val)
    if val ~= nil and not seen[val] then
        seen[val] = true
        table.insert(list, val)
    end
end

local function normalize_table(t)
    -- Teradata identifiers are at most DB.TABLE — anything beyond is a column ref.
    local parts = {}
    for p in t:gmatch("[^%.]+") do table.insert(parts, p) end
    if #parts >= 2 then return parts[1] .. "." .. parts[2] end
    return t
end

local function short_table(t)
    -- For inline display, drop the database prefix.
    return (t:match("%.([%w_]+)$")) or t
end

local function parse_time_to_seconds(text)
    local m, sec = text:match("(%d+)%s+minutes?%s+and%s+([%d%.]+)%s+seconds?")
    if m then return tonumber(m) * 60 + tonumber(sec) end
    m = text:match("(%d+)%s+minutes?")
    if m then return tonumber(m) * 60 end
    sec = text:match("([%d%.]+)%s+seconds?")
    if sec then return tonumber(sec) end
    return nil
end

local function format_seconds(s)
    if not s then return nil end
    if s < 1 then return string.format("%.2fs", s) end
    if s < 60 then return string.format("%.1fs", s) end
    local m = math.floor(s / 60)
    local r = math.floor(s - m * 60 + 0.5)
    return string.format("%dm%02ds", m, r)
end

local function parse_rows(text)
    local r = text:match("estimated[^.]-be%s+([%d,]+)%s+rows")
    if not r then
        r = text:match("size is estimated[^.]-be%s+([%d,]+)%s+rows")
    end
    if not r then return nil end
    return tonumber((r:gsub(",", "")))
end

local function format_rows(n)
    if not n then return nil end
    if n >= 1e9 then return string.format("%.1fB rows", n / 1e9) end
    if n >= 1e6 then return string.format("%.1fM rows", n / 1e6) end
    if n >= 1e3 then return string.format("%.0fk rows", n / 1e3) end
    return tostring(n) .. " rows"
end

-- =============================================================================
-- Step splitter: group raw lines into logical steps (top-level or sub-step).
-- A step starts at a line whose first non-space char is "<digit>+)".
--
-- Teradata explain plans don't reliably indent sub-steps, so we detect them
-- by numbering: top-level steps are monotonically increasing, so a "N)" header
-- whose N is less than the running max-top-level number is a sub-step.
--
-- Sub-steps get hierarchical labels like "25.1)", "25.2)" so they're
-- distinguishable in the summary.
-- =============================================================================
local function split_into_steps(lines)
    local steps  = {}
    local current
    local max_top = 0         -- highest top-level step number seen so far
    local current_top         -- label of the most recent top-level step
    local sub_counter = 0     -- nth sub-step inside the current top-level

    for line_idx, ln in ipairs(lines) do
        local stripped = ln:gsub("%s+$", "")
        local indent, num_str = stripped:match("^(%s*)(%d+)%)%s")
        if num_str then
            if current then table.insert(steps, current) end
            local n = tonumber(num_str)

            local label
            if n <= max_top and current_top then
                sub_counter = sub_counter + 1
                label = current_top .. "." .. sub_counter .. ")"
            else
                label = num_str .. ")"
                current_top = num_str
                sub_counter = 0
                max_top = n
            end

            current = {
                label       = label,
                indent      = #indent,
                first_line  = line_idx,
                last_line   = line_idx,
                raw_lines   = { ln },
                text        = stripped,
            }
        elseif current then
            current.last_line = line_idx
            table.insert(current.raw_lines, ln)
            current.text = current.text .. " " .. stripped:gsub("^%s+", "")
        end
    end
    if current then table.insert(steps, current) end
    for _, s in ipairs(steps) do s.text = s.text:gsub("%s+", " ") end
    return steps
end

-- =============================================================================
-- Per-step parser: from a step's normalized text, extract
--   * produced spool number (string), if any
--   * input table identifiers
--   * input spool numbers (strings)
--   * estimated time in seconds
--   * estimated row count
-- =============================================================================
local NOOP_PATTERNS = {
    "^%s*%d+%)%s+First, we lock",
    "^%s*%d+%)%s+Next, we lock",
    "^%s*%d+%)%s+We lock",
    "^%s*%d+%)%s+Finally,",
    "^%s*%d+%)%s+We execute the following steps in parallel%.?%s*$",
}

local function is_noop(text)
    for _, p in ipairs(NOOP_PATTERNS) do
        if text:match(p) then return true end
    end
    return false
end

-- Producer-phrase patterns, in priority order. The first phrase found in the
-- step text wins, even if a later (lower-priority) phrase appears earlier
-- textually. This matters for STAT FUNCTION steps where the text reads:
--   "...scan into Spool 53 (Last Use)... The result rows are put into Spool 51"
-- The output is Spool 51, not Spool 53 (which is the intermediate sort step).
local PRODUCED_PATTERNS = {
    "results? rows are put into Spool%s+(%d+)",   -- STAT FUNCTION final output
    "result goes into Spool%s+(%d+)",             -- JOIN output
    "placed in Spool%s+(%d+)",                    -- aggregate output
    " into Spool%s+(%d+)",                        -- RETRIEVE catch-all
}

local function find_produced(text)
    -- First pattern that matches wins. Return (spool_num, byte_pos_for_cut).
    for _, pat in ipairs(PRODUCED_PATTERNS) do
        local s, _, num = text:find(pat)
        if s then return num, s end
    end
    return nil, nil
end

local function parse_step(step)
    local t = step.text
    step.is_noop = is_noop(t)
    if step.is_noop then return end

    -- Producer + cut
    local produced, cut_pos = find_produced(t)
    step.produced = produced
    local input_seg = cut_pos and t:sub(1, cut_pos - 1) or t

    -- Strip quoted segments so column refs in conditions don't pollute table list
    input_seg = input_seg:gsub('"[^"]*"', "")

    -- Tables: must look like an SQL identifier — each dot-segment must start
    -- with a letter or underscore. This rejects numeric noise like "0.00" or
    -- "12.5" that would otherwise match a naive [%w_]+%.[%w_%.]+ pattern.
    -- An identifier segment is: [letter or underscore] followed by word chars.
    step.tables = {}
    local seen_t = {}
    for raw_tbl in input_seg:gmatch("([%a_][%w_]*%.[%a_][%w_%.]*)") do
        uniq_push(step.tables, seen_t, normalize_table(raw_tbl))
    end

    -- Input spools
    step.input_spools = {}
    local seen_s = {}
    for n in input_seg:gmatch("Spool%s+(%d+)") do
        uniq_push(step.input_spools, seen_s, n)
    end

    -- Cost extraction over the full step text
    step.time_sec = parse_time_to_seconds(t)
    step.rows     = parse_rows(t)
end

-- =============================================================================
-- Build the production graph & resolve ultimate source tables
-- =============================================================================
local function build_graph_and_resolve(steps)
    local productions = {}
    for _, s in ipairs(steps) do
        if s.produced then
            -- A spool can be produced by exactly one step in a valid plan;
            -- if duplicates appear, last write wins (rare).
            productions[s.produced] = {
                tables = s.tables or {},
                spools = s.input_spools or {},
            }
        end
    end

    local cache = {}
    local function resolve(spool, stack)
        if cache[spool] then return cache[spool] end
        stack = stack or {}
        if stack[spool] then return {} end
        stack[spool] = true

        local prod = productions[spool]
        local result, seen = {}, {}
        if prod then
            for _, tbl in ipairs(prod.tables) do uniq_push(result, seen, tbl) end
            for _, src in ipairs(prod.spools) do
                for _, tbl in ipairs(resolve(src, stack)) do
                    uniq_push(result, seen, tbl)
                end
            end
        end

        stack[spool] = nil
        cache[spool] = result
        return result
    end

    return productions, resolve
end

-- =============================================================================
-- Spool → label string for inline annotation
-- Rules:
--   * If sources are empty: "Spool N" (no annotation)
--   * If 1..INLINE_TABLE_LIMIT sources: "Spool N ← [t1, t2, ...]"
--   * Otherwise: "Spool N ← [t1, t2, t3, +K more]"
-- The "Final Result" label is added on top by the caller for the terminal spool.
-- =============================================================================
local function spool_label(spool, sources, is_final)
    if is_final then
        return string.format("Spool %s ← [Final Result]", spool)
    end
    if not sources or #sources == 0 then
        return "Spool " .. spool
    end
    local shorts = {}
    for _, t in ipairs(sources) do table.insert(shorts, short_table(t)) end
    if #shorts <= INLINE_TABLE_LIMIT then
        return string.format("Spool %s ← [%s]", spool, table.concat(shorts, ", "))
    end
    local head = {}
    for i = 1, INLINE_TABLE_LIMIT do head[i] = shorts[i] end
    return string.format("Spool %s ← [%s, +%d more]",
        spool, table.concat(head, ", "), #shorts - INLINE_TABLE_LIMIT)
end

-- =============================================================================
-- Identify the terminal spool: the one sent back to the user.
-- Look for "contents of Spool N are sent back to the user" in any line.
-- =============================================================================
local function find_final_spool(lines)
    for _, ln in ipairs(lines) do
        local n = ln:match("contents of Spool%s+(%d+)%s+are sent back to the user")
        if n then return n end
    end
    return nil
end

-- =============================================================================
-- Build the summary block (printed at the top of the formatted output)
-- =============================================================================
local function build_summary(steps, resolve, final_spool, productions)
    local lines = {}
    table.insert(lines, "═══════════════════════════════════════════════════════════════════════")
    table.insert(lines, "  PLAN SUMMARY")
    table.insert(lines, "═══════════════════════════════════════════════════════════════════════")

    -- Total estimated time (sum of step times; note: parallel steps would be
    -- over-counted, but Teradata's own per-step times are conservative and
    -- this matches what users expect from "explain plan total cost").
    local total = 0
    local n_steps_with_time = 0
    for _, s in ipairs(steps) do
        if s.time_sec then
            total = total + s.time_sec
            n_steps_with_time = n_steps_with_time + 1
        end
    end
    if n_steps_with_time > 0 then
        table.insert(lines, string.format("  Total estimated time: %s  (sum of %d steps)",
            format_seconds(total), n_steps_with_time))
    end

    -- All base tables touched
    local all_tables, seen = {}, {}
    for _, s in ipairs(steps) do
        if s.tables then
            for _, t in ipairs(s.tables) do uniq_push(all_tables, seen, t) end
        end
    end
    if #all_tables > 0 then
        table.insert(lines, string.format("  Tables touched (%d):", #all_tables))
        for _, t in ipairs(all_tables) do
            table.insert(lines, "    • " .. t)
        end
    end

    -- Top-N expensive steps
    local timed = {}
    for _, s in ipairs(steps) do
        if s.time_sec and s.time_sec >= 1 then
            table.insert(timed, s)
        end
    end
    table.sort(timed, function(a, b) return a.time_sec > b.time_sec end)
    if #timed > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("  Top %d most expensive steps:", math.min(TOP_N_EXPENSIVE, #timed)))
        for i = 1, math.min(TOP_N_EXPENSIVE, #timed) do
            local s = timed[i]
            local rowstr = s.rows and (" · " .. format_rows(s.rows)) or ""
            local produced_str = s.produced and (" → Spool " .. s.produced) or ""
            table.insert(lines, string.format("    %s  ⏱ %s%s%s",
                s.label, format_seconds(s.time_sec), rowstr, produced_str))
        end
    end

    -- Final spool lineage
    if final_spool then
        local srcs = resolve(final_spool)
        table.insert(lines, "")
        table.insert(lines, string.format("  Final result: Spool %s (returned to user)", final_spool))
        if #srcs > 0 then
            table.insert(lines, string.format("    Derived from %d base table(s):", #srcs))
            for _, t in ipairs(srcs) do
                table.insert(lines, "      ← " .. t)
            end
        end
    end

    table.insert(lines, "═══════════════════════════════════════════════════════════════════════")
    table.insert(lines, "")
    return lines
end

-- =============================================================================
-- Enrich step lines: prepend cost badges to step headers and rewrite Spool refs
-- =============================================================================
local function build_spool_label_map(steps, resolve, final_spool)
    local map = {}
    for _, s in ipairs(steps) do
        if s.produced then
            local is_final = (s.produced == final_spool)
            map[s.produced] = spool_label(s.produced, resolve(s.produced), is_final)
        end
    end
    return map
end

local function make_badge(step)
    local parts = {}
    if step.time_sec then
        local marker = (step.time_sec >= SLOW_STEP_THRESHOLD) and "⚠ ⏱" or "⏱"
        table.insert(parts, marker .. " " .. format_seconds(step.time_sec))
    end
    if step.rows then
        table.insert(parts, "📊 " .. format_rows(step.rows))
    end
    if #parts == 0 then return nil end
    return "[" .. table.concat(parts, " · ") .. "]"
end

-- =============================================================================
-- Main resolver: parse, build graph, render
-- =============================================================================
local function resolve_spools(lines)
    if #lines == 0 then return lines end

    local steps = split_into_steps(lines)
    for _, s in ipairs(steps) do parse_step(s) end

    local productions, resolve = build_graph_and_resolve(steps)
    local final_spool = find_final_spool(lines)
    local label_map = build_spool_label_map(steps, resolve, final_spool)

    -- Map every raw line to its owning step so we can:
    --   * attach a badge to the step header line
    --   * track which spool numbers have already been annotated in this step
    local line_to_step = {}
    for _, s in ipairs(steps) do
        for ln_idx = s.first_line, s.last_line do
            line_to_step[ln_idx] = s
        end
    end

    -- Build the summary first.
    local out = build_summary(steps, resolve, final_spool, productions)

    -- Per-step tracker of which spool numbers have been annotated already.
    local annotated_per_step = setmetatable({}, { __index = function(t, k)
        local v = {}; t[k] = v; return v
    end })

    -- A step is a sub-step iff its label contains a dot (e.g. "25.1)").
    local function is_substep(step)
        return step and step.label and step.label:find("%.")
    end

    for i, line in ipairs(lines) do
        local step = line_to_step[i]
        local step_key = step or "ROOT"
        local seen = annotated_per_step[step_key]

        -- Rewrite spool refs: only the first occurrence of each number within
        -- the step gets the "← [tables]" annotation; subsequent ones stay bare.
        local rewritten = (line:gsub("Spool%s+(%d+)", function(num)
            if seen[num] then
                return "Spool " .. num
            end
            seen[num] = true
            return label_map[num] or ("Spool " .. num)
        end))

        -- Attach cost badge to the step header (the line that contains "N)").
        if step and not step.is_noop and i == step.first_line then
            -- If this is a sub-step, rewrite "1)" to its hierarchical label (e.g. "14.1)").
            if is_substep(step) then
                rewritten = rewritten:gsub("^(%s*)%d+%)", "%1" .. step.label, 1)
            end
            local badge = make_badge(step)
            if badge then
                local slow = step.time_sec and step.time_sec >= SLOW_STEP_THRESHOLD
                local marker = slow and "SLOW_STEP " or ""
                -- Insert the badge directly after the "N)" prefix on the header
                -- line so it visually sits with the step number, not at EOL.
                rewritten = rewritten:gsub("^(%s*[%d%.]+%))(%s)",
                    "%1 " .. marker .. badge .. "%2", 1)
            end
        end

        -- Visually indent sub-step blocks so the parallel grouping is obvious.
        if is_substep(step) then
            rewritten = "    " .. rewritten
        end

        table.insert(out, rewritten)
    end

    return out
end

-- =============================================================================
-- High-cost highlighter + folds
-- =============================================================================
local function setup_highlights_and_folds(bufnr)
    -- Buffer-local option
    vim.api.nvim_set_option_value("filetype", "teradata-explain", { buf = bufnr })

    -- Window-local options (applied to the current window: win = 0)
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
    -- Fold rules:
    --   * The summary banner row (line 1) starts a level-1 fold.
    --   * Top-level steps "N)" start a level-1 fold.
    --   * Sub-steps "N.M)" start a level-2 fold (nested under their parent).
    --   * Lines starting with "<Folds:" or blanks don't fold (stay outside).
    local fold_expr =
        "getline(v:lnum) =~ '^[ ]*<Folds:' ? 0 : " ..
        "getline(v:lnum) == '' ? 0 : " ..
        "v:lnum == 1 ? '>1' : " ..
        "getline(v:lnum) =~ '^\\s*\\d\\+\\.\\d\\+)' ? '>2' : " ..
        "getline(v:lnum) =~ '^\\s*\\d\\+)' ? '>1' : " ..
        "'='"

    vim.api.nvim_set_option_value("foldexpr", fold_expr, { win = 0 })
    vim.api.nvim_set_option_value("foldlevel", 0, { win = 0 })
    vim.api.nvim_set_option_value("foldenable", true, { win = 0 })

    -- High-cost keywords (red background + virtual text)
    local high_cost_patterns = {
        "all%-rows scan",
        "redistribution",
        "full table scan",
        "high confidence",
        "all%-AMPs.*scan",
        "product join",
        -- New: anything we've explicitly flagged as slow
        "SLOW_STEP",
        "⚠ ⏱[^%]]+",
    }

    vim.api.nvim_buf_call(bufnr, function()
        for _, pat in ipairs(high_cost_patterns) do
            vim.fn.matchadd("Error", pat, 10, -1)
        end
    end)

    -- Nice header
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "=== TERADATA EXPLAIN PLAN ===", "" })
end

-- =============================================================================
-- Main formatter
-- =============================================================================
---Processes the results buffer for EXPLAIN or SHOW queries.
---@param bufnr number Results buffer
---@param query string Original query that was executed
---@param raw_lines table Raw output lines from Teradata
function M.process_results(bufnr, query, raw_lines)
    local lower = query:lower():gsub("^%s*", "")

    if lower:match("^explain") then
        local enriched = resolve_spools(raw_lines)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, enriched)
        setup_highlights_and_folds(bufnr)

        vim.notify("EXPLAIN plan formatted with spool resolution + cost highlights",
            vim.log.levels.INFO)
    elseif lower:match("^show") then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, raw_lines)
        vim.bo[bufnr].filetype = "teradata"
        pcall(vim.treesitter.start, bufnr, "teradata")

        vim.notify("SHOW output highlighted with SQL Tree-sitter", vim.log.levels.INFO)
    end
    -- else: do nothing (normal results)
end

-- Export internal helpers for testing
M._internal = {
    resolve_spools         = resolve_spools,
    split_into_steps       = split_into_steps,
    parse_step             = parse_step,
    build_graph_and_resolve = build_graph_and_resolve,
    parse_time_to_seconds  = parse_time_to_seconds,
    format_seconds         = format_seconds,
    parse_rows             = parse_rows,
    format_rows            = format_rows,
}

return M
