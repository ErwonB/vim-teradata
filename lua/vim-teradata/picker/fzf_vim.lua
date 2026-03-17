local M = {}

function M.grep_queries(queries_dir, on_select)
    local rg_command = 'rg --column --line-number --no-heading --smart-case "" .'
    local fzf_options = {
        '--ansi',
        '--prompt="Grep Queries> "',
        '--delimiter=:',
        '--preview="bat --style=numbers --color=always --highlight-line {2} -- {1}"',
        '--preview-window=right:60%:wrap',
    }

    vim.fn['fzf#run']({
        source = rg_command,
        sink = function(selected_line)
            local parts = vim.fn.split(selected_line, ':', true)
            local filename = vim.fn.fnamemodify(parts[1], ':t:r')
            on_select(filename)
        end,
        options = table.concat(fzf_options, ' '),
        dir = queries_dir,
    })
end

function M.pick_completion(items, context, opts, on_select)
    local fzf_config = {
        source = items,
        options = opts.fzf_options or '',
        window = { width = 0.5, height = 0.4, border = 'rounded' },
        ['sink*'] = function(selected)
            on_select(selected, context)
        end,
    }
    vim.fn['fzf#run'](fzf_config)
end

function M.pick_basic(columns, callback)
    vim.fn['fzf#run'](vim.fn['fzf#wrap']({
        source = columns,
        options = '-m --prompt="Select Columns> "',
        ['sink*'] = function(lines)
            -- fzf#run with sink* returns the selected lines directly
            callback(lines)
        end
    }))
end

return M
