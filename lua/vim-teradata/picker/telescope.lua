local M = {}

local conf = require('telescope.config').values
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local action_state = require('telescope.actions.state')
local actions = require('telescope.actions')

function M.grep_queries(queries_dir, on_select)
    require('telescope.builtin').live_grep({
        search_dirs = { queries_dir },
        prompt_title = 'Grep Queries',
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local filename = vim.fn.fnamemodify(selection.filename, ':t:r')
                    on_select(filename)
                end
            end)
            return true
        end,
    })
end

function M.pick_completion(items, context, opts, on_select)
    local fzf_options = opts.fzf_options or ''
    local is_multi = string.find(fzf_options, '%-%-multi') ~= nil

    pickers.new({}, {
        prompt_title = 'SQL Completion',
        finder = finders.new_table({
            results = items,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                local picker = action_state.get_current_picker(prompt_bufnr)
                local multi_selections = picker:get_multi_selection()
                
                local selected = {}
                if is_multi and #multi_selections > 0 then
                    for _, selection in ipairs(multi_selections) do
                        table.insert(selected, selection[1])
                    end
                else
                    local selection = action_state.get_selected_entry()
                    if selection then
                        table.insert(selected, selection[1])
                    end
                end
                
                actions.close(prompt_bufnr)
                if #selected > 0 then
                    on_select(selected, context)
                end
            end)
            return true
        end,
    }):find()
end

return M
