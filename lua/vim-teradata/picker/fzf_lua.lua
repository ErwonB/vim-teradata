local M = {}

function M.grep_queries(queries_dir, on_select)
    require('fzf-lua').grep({
        cwd = queries_dir,
        prompt = 'Grep Queries> ',
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local parts = vim.split(selected[1], ':', { plain = true })
                local filename = vim.fn.fnamemodify(parts[1], ':t:r')
                on_select(filename)
            end
        }
    })
end

function M.pick_completion(items, context, opts, on_select)
    local fzf_options = opts.fzf_options or ''
    -- convert vim's --multi flag to fzf-lua's format if present
    local is_multi = string.find(fzf_options, '%-%-multi') ~= nil

    require('fzf-lua').fzf_exec(items, {
        prompt = 'SQL> ',
        winopts = {
            height = 0.4,
            width = 0.5,
            border = 'rounded',
            preview = { hidden = 'hidden' }
        },
        fzf_opts = {
            ['--multi'] = is_multi and '' or nil,
        },
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    on_select(selected, context)
                end
            end
        }
    })
end

function M.pick_basic(columns, callback)
    require('fzf-lua').fzf_exec(columns, {
        prompt = 'Select Columns (Tab to multi-select)> ',
        fzf_opts = { ['-m'] = true },     -- Enable multi-selection
        actions = {
            ['default'] = function(selected)
                callback(selected)
            end
        }
    })
end

return M
