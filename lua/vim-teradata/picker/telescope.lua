local M = {}

function M.grep_queries(queries_dir, on_select)
    require('telescope.builtin').live_grep({
        search_dirs = { queries_dir },
        prompt_title = 'Grep Queries',
        attach_mappings = function(prompt_bufnr, _)
            local actions = require('telescope.actions')
            local action_state = require('telescope.actions.state')
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local filename = vim.fn.fnamemodify(selection.filename, ':t:r')
                    vim.schedule(function()
                        on_select(filename)
                    end)
                end
            end)
            return true
        end,
    })
end

function M.pick_completion(items, context, opts, on_select)
    local fzf_options = opts.fzf_options or ''
    local is_multi = string.find(fzf_options, '%-%-multi') ~= nil

    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local finders = require('telescope.finders')
    local pickers = require('telescope.pickers')
    local conf = require('telescope.config').values

    pickers.new({}, {
        prompt_title = 'SQL Completion',
        finder = finders.new_table({
            results = items,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- Disable multi-select keybinding when not in multi mode
            if not is_multi then
                map({ 'i', 'n' }, '<Tab>', function() end)
            end

            actions.select_default:replace(function()
                local picker = action_state.get_current_picker(prompt_bufnr)
                local selected = {}

                if is_multi then
                    local multi_selections = picker:get_multi_selection()
                    if #multi_selections > 0 then
                        for _, selection in ipairs(multi_selections) do
                            table.insert(selected, selection[1])
                        end
                    end
                end

                -- Fallback to current item if nothing was multi-selected
                if #selected == 0 then
                    local selection = action_state.get_selected_entry()
                    if selection then
                        table.insert(selected, selection[1])
                    end
                end

                actions.close(prompt_bufnr)
                if #selected > 0 then
                    vim.schedule(function()
                        on_select(selected, context)
                    end)
                end
            end)
            return true
        end,
    }):find()
end

function M.pick_basic(columns, callback)
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local action_state = require('telescope.actions.state')
    local actions = require('telescope.actions')

    pickers.new({}, {
        prompt_title = "Select Columns",
        finder = finders.new_table({ results = columns }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                local current_picker = action_state.get_current_picker(prompt_bufnr)
                local selections = current_picker:get_multi_selection()

                -- Fallback to single selection if multi-select wasn't used
                if vim.tbl_isempty(selections) then
                    table.insert(selections, action_state.get_selected_entry())
                end

                actions.close(prompt_bufnr)

                local result = {}
                for _, sel in ipairs(selections) do
                    table.insert(result, sel.value or sel[1])
                end
                callback(result)
            end)
            return true
        end,
    }):find()
end

return M
