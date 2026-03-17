local M = {}

function M.grep_queries(queries_dir, on_select)
    require('snacks').picker.grep({
        cwd = queries_dir,
        title = 'Grep Queries',
        confirm = function(picker, item)
            picker:close()
            if item and item.file then
                local filename = vim.fn.fnamemodify(item.file, ':t:r')
                vim.schedule(function()
                    on_select(filename)
                end)
            end
        end
    })
end

function M.pick_completion(items, context, opts, on_select)
    local fzf_options = opts.fzf_options or ''
    local is_multi = string.find(fzf_options, '%-%-multi') ~= nil

    -- Convert strings to snacks picker items
    local picker_items = {}
    for i, str in ipairs(items) do
        table.insert(picker_items, {
            idx = i,
            text = str,
            label = str,
        })
    end

    require('snacks').picker.pick({
        title = 'SQL Completion',
        items = picker_items,
        format = 'text',
        layout = {
            preset = 'select',
            preview = false,
        },
        win = is_multi and {} or {
            input = { keys = { ["<Tab>"] = false, ["<S-Tab>"] = false, ["<c-a>"] = false } },
            list  = { keys = { ["<Tab>"] = false, ["<S-Tab>"] = false, ["<c-a>"] = false } }
        },
        confirm = function(picker, item)
            local selected = {}
            if is_multi then
                local multi_items = picker:selected()
                for _, sel_item in ipairs(multi_items) do
                    table.insert(selected, sel_item.text)
                end
            end

            -- Fallback to current item if nothing was multi-selected
            if #selected == 0 and item then
                table.insert(selected, item.text)
            end

            picker:close()
            if #selected > 0 then
                vim.schedule(function()
                    on_select(selected, context)
                end)
            end
        end
    })
end

function M.pick_basic(columns, callback)
    local items = {}
    for _, c in ipairs(columns) do
        table.insert(items, { text = c, item = c })
    end
    require("snacks").picker({
        title = "Select Columns (Tab to multi-select)",
        items = items,
        format = "text",
        layout = "select",
        actions = {
            confirm = function(p, item)
                local selections = p:selected()
                p:close()

                local result = {}
                if selections and #selections > 0 then
                    for _, sel in ipairs(selections) do
                        table.insert(result, sel.item)
                    end
                elseif item then
                    table.insert(result, item.item)
                end
                callback(result)
            end,
        }
    })
end

return M
