local M = {}

function M.grep_queries(queries_dir, on_select)
    Snacks.picker.grep({
        cwd = queries_dir,
        prompt_title = 'Grep Queries',
        confirm = function(picker, item)
            picker:close()
            if item and item.file then
                local filename = vim.fn.fnamemodify(item.file, ':t:r')
                on_select(filename)
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

    Snacks.picker.pick({
        title = 'SQL Completion',
        items = picker_items,
        format = 'text',
        layout = {
            preset = 'dropdown',
            preview = false,
        },
        actions = {
            confirm = function(picker, item)
                local selected = {}
                if is_multi then
                    -- Get all selected items if multi-select is on
                    for _, sel_item in ipairs(picker:selected()) do
                        table.insert(selected, sel_item.text)
                    end
                end

                -- Fallback to the current item if nothing specific was multi-selected
                if #selected == 0 and item then
                    table.insert(selected, item.text)
                end

                picker:close()
                if #selected > 0 then
                    on_select(selected, context)
                end
            end
        }
    })
end

return M
