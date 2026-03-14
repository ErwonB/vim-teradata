local utils = require('vim-teradata.util')
local ts = require('vim-teradata.sql-autocomplete.treesitter')

-- LSP CompletionItemKind integers (protocol-neutral)
local Kind = {
    Text     = 1,
    Function = 3,
    Field    = 5,
    Module   = 9,
    Keyword  = 14,
    Struct   = 22,
}

local M = {}


--- Analyzes SQL context around the cursor to determine completion type and relevant tables or databases.
--- @return table A context table containing completion type and metadata.
local function analyze_sql_context()
    local context
    local buf = vim.api.nvim_get_current_buf()

    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'sql')
    if not ok or not parser then
        vim.notify('Could not load sql treesitter parser to enable sql autocompletion', vim.log.levels.INFO)
    else
        context = ts.analyze_sql_context()
    end

    return context or {}
end




--- Provides manual SQL completion items or the start column for completion.
--- @param findstart number Indicates whether to find the start column (1) or return completion items (0).
--- @return number | table Start column or completion result table.
function M.complete_manual(findstart)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        while col > 0 and line:sub(col, col):match('%w') do
            col = col - 1
        end
        return col
    else
        local context = analyze_sql_context()

        local items = {}
        local res
        local fzf_options = ""

        if context.type == 'columns' then
            if context.alias_prefix then
                context.tables = vim.tbl_filter(function(item)
                    return item.alias == string.upper(context.alias_prefix)
                end, context.tables)
            end
            res = utils.get_columns(context.tables)
            local candidate_entries

            if context.alias_prefix and context.alias_prefix ~= "" then
                candidate_entries = vim.tbl_filter(function(item)
                    return string.upper(item.alias) == string.upper(context.alias_prefix)
                end, context.buffer_fields)
            else
                candidate_entries = context.buffer_fields
            end

            local seen_lists = {}
            local unique_field_lists = {}

            for _, entry in ipairs(candidate_entries) do
                local list = entry.field_list
                if not seen_lists[list] then
                    seen_lists[list] = true
                    table.insert(unique_field_lists, list)
                end
            end

            local seen_fields = {}
            local final_flat_list = {}

            for _, list in ipairs(unique_field_lists) do
                for _, field_name in ipairs(list) do
                    if not seen_fields[field_name] then
                        seen_fields[field_name] = true
                        table.insert(final_flat_list, field_name)
                    end
                end
            end

            res = res or {}
            vim.list_extend(res, final_flat_list)
            fzf_options = "--multi"
        elseif context.type == 'tables' then
            res = utils.get_tables(context.db_name)
        elseif context.type == 'databases' then
            res = utils.get_databases()
        elseif context.type == 'keywords' then
            res = context.candidates
        end
        items = res and res or {}

        return {
            items = items,
            fzf_options = fzf_options,
            context = context,
        }
    end
end

--- Provides filtered SQL completion items based on the current context and input base.
--- @return table Filtered completion items.
function M.complete_items()
    local context = analyze_sql_context()

    local raw_items = {}

    local context_results
    local context_kind = Kind.Text

    if context.type == 'columns' then
        context_kind = Kind.Field
        if context.alias_prefix then
            context.tables = vim.tbl_filter(function(item)
                return item.alias == string.upper(context.alias_prefix)
            end, context.tables)
        end
        context_results = utils.get_columns(context.tables)
        local candidate_entries

        if context.alias_prefix and context.alias_prefix ~= "" then
            candidate_entries = vim.tbl_filter(function(item)
                return string.upper(item.alias) == string.upper(context.alias_prefix)
            end, context.buffer_fields)
        else
            candidate_entries = context.buffer_fields
        end

        local seen_lists = {}
        local unique_field_lists = {}
        for _, entry in ipairs(candidate_entries) do
            local list = entry.field_list
            if not seen_lists[list] then
                seen_lists[list] = true
                table.insert(unique_field_lists, list)
            end
        end

        local seen_fields = {}
        local final_flat_list = {}
        for _, list in ipairs(unique_field_lists) do
            for _, field_name in ipairs(list) do
                if not seen_fields[field_name] then
                    seen_fields[field_name] = true
                    table.insert(final_flat_list, field_name)
                end
            end
        end

        context_results = context_results or {}
        vim.list_extend(context_results, final_flat_list)
    elseif context.type == 'tables' then
        context_kind = Kind.Struct
        context_results = utils.get_tables(context.db_name)
    elseif context.type == 'databases' then
        context_kind = Kind.Module
        context_results = utils.get_databases()
    elseif context.type == 'keywords' then
        context_kind = Kind.Keyword
        context_results = context.candidates
    end

    context_results = context_results or {}
    for _, item_str in ipairs(context_results) do
        table.insert(raw_items, {
            kind = context_kind,
            sortText = "1_" .. item_str,
            label = item_str,
        })
    end

    -- If Context is Columns, Inject Keywords and functions with Lower Priority
    if context.type == 'columns' then
        local keywords = ts.get_sql_keywords()
        for _, kw in ipairs(keywords) do
            table.insert(raw_items, {
                kind = Kind.Keyword,
                sortText = "2_" .. kw,
                label = kw,
            })
        end
        local td_functions = require("vim-teradata.sql-autocomplete.td_functions")
        for _, kw in ipairs(td_functions) do
            table.insert(raw_items, kw)
        end
    end

    return raw_items
end

--- Inserts selected items into the buffer based on SQL context.
--- @param selected table List of selected completion items.
--- @param context table Context metadata for insertion.
--- @return nil
local function handle_selection(selected, context)
    if not vim.api.nvim_buf_is_valid(context.buf) or #selected == 0 then
        return
    end

    local final_text
    if context.type == 'columns' then
        local alias = (context.alias_prefix and context.alias_prefix ~= "") and (context.alias_prefix .. ".") or ""
        local separator = context.is_where and " and " or ", "
        local prefixed_items = {}
        for i, item in ipairs(selected) do
            local prefix = (i == 1 and "") or alias
            table.insert(prefixed_items, prefix .. item)
        end
        final_text = table.concat(prefixed_items, separator)
    else
        final_text = table.concat(selected, "")
    end

    vim.api.nvim_buf_set_text(context.buf, context.start_row, context.start_col, context.end_row, context.end_col,
        { final_text })

    local current_line = vim.api.nvim_buf_get_lines(context.buf, context.start_row, context.start_row + 1, false)[1]
    local target_col = context.start_col + #final_text

    -- Check if we are at the end of the line
    if target_col >= #current_line and #current_line > 0 then
        vim.api.nvim_win_set_cursor(0, { context.start_row + 1, #current_line - 1 })
        vim.api.nvim_feedkeys('a', 'n', false)
    else
        vim.api.nvim_win_set_cursor(0, { context.start_row + 1, target_col })
        vim.api.nvim_feedkeys('i', 'n', false)
    end
end


--- Triggers SQL completion and handles user selection.
--- @return nil
function M.trigger_completion()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local start_col = M.complete_manual(1)

    local completion_data = M.complete_manual(0)
    if not completion_data or not next(completion_data.items) then
        print("No completions found.")
        return
    end

    completion_data.context.buf = vim.api.nvim_get_current_buf()
    completion_data.context.start_row = cursor_pos[1] - 1
    completion_data.context.end_row = cursor_pos[1] - 1
    completion_data.context.start_col = start_col
    completion_data.context.end_col = cursor_pos[2]

    local picker = require('vim-teradata.picker').get()
    picker.pick_completion(
        completion_data.items,
        completion_data.context,
        { fzf_options = completion_data.fzf_options },
        handle_selection
    )
end

return M
