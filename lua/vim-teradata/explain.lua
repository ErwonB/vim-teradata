local M = {}

-- =============================================================================
-- Spool resolver (Robust version - works on your exact output)
-- =============================================================================
local function resolve_spools(lines)
    if #lines == 0 then return lines end

    local spool_map = {} -- spool_num → "Table: xxx" or "Spool Y" or "Final Result"

    -- Normalize multiline steps into one searchable string
    local full_text = table.concat(lines, "\n"):gsub("\n", " ")

    -- Pattern 1: SUM/aggregate steps ("placed in")
    for tbl, into in full_text:gmatch("aggregate from%s+([%w_%.]+).-placed in Spool%s+(%d+)") do
        spool_map[into] = "Table: " .. tbl
    end

    -- Pattern 2: RETRIEVE steps from table ("into Spool")
    for tbl, into in full_text:gmatch("RETRIEVE step .-from%s+([%w_%.]+).-into Spool%s+(%d+)") do
        spool_map[into] = "Table: " .. tbl
    end

    -- Pattern 3: SUM steps from Spool ("placed in")
    for src, into in full_text:gmatch("from Spool%s+(%d+).-placed in Spool%s+(%d+)") do
        spool_map[into] = spool_map[src] or ("Spool " .. src)
    end

    -- Pattern 4: RETRIEVE steps from Spool ("into Spool")
    for src, into in full_text:gmatch("RETRIEVE step .-from Spool%s+(%d+).-into Spool%s+(%d+)") do
        spool_map[into] = spool_map[src] or ("Spool " .. src)
    end

    -- Fallback for final result ("goes into")
    for into in full_text:gmatch("goes into Spool%s+(%d+)") do
        if not spool_map[into] then
            spool_map[into] = "Final Result"
        end
    end

    -- =============================================================================
    -- Enrichment pass – table/spool now stands out clearly
    -- =============================================================================
    local enriched = {}
    for _, line in ipairs(lines) do
        local new_line = line:gsub("Spool%s+(%d+)", function(num)
            local origin = spool_map[num]
            if origin then
                -- ← [Table: xxx] or ← [Spool Y] or ← [Final Result]
                -- The arrow + brackets make every spool instantly visible
                return string.format("Spool %s ← [%s]", num, origin)
            end
            return "Spool " .. num
        end)
        table.insert(enriched, new_line)
    end

    return enriched
end

-- =============================================================================
-- High-cost highlighter + folds
-- =============================================================================
local function setup_highlights_and_folds(bufnr)
    -- Buffer-local option
    vim.api.nvim_set_option_value("filetype", "teradata-explain", { buf = bufnr })

    -- Window-local options (applied to the current window: win = 0)
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
    local fold_expr = "getline(v:lnum) =~ '^[ ]*<Folds:' ? 0 : " ..
        "getline(v:lnum) == '' ? 0 : " ..
        "v:lnum == 1 ? '>1' : " ..
        "getline(v:lnum) =~ '^\\s*\\d\\+)' ? '>1' : " ..
        "'='"

    vim.api.nvim_set_option_value("foldexpr", fold_expr, { win = 0 })
    -- vim.api.nvim_set_option_value("foldexpr", "v:lnum == 1 ? '>1' : getline(v:lnum) =~ '^\\s*\\d\\+)' ? '>1' : '='",
    --     { win = 0 })
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
    }

    -- matchadd is also window-centric, executed in the context of the buffer
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

        vim.notify("EXPLAIN plan formatted with spool resolution + cost highlights", vim.log.levels.INFO)
    elseif lower:match("^show") then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, raw_lines)
        vim.bo[bufnr].filetype = "sql"
        pcall(vim.treesitter.start, bufnr, "sql")

        vim.notify("SHOW output highlighted with SQL Tree-sitter", vim.log.levels.INFO)
    end
    -- else: do nothing (normal results)
end

return M
