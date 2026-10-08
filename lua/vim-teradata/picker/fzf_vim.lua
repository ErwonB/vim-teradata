local M = {}

function M.grep_queries(queries_dir, on_select)
    if vim.fn.executable('rg') == 0 or vim.fn.exists('*fzf#run') == 0 then
        return require('vim-teradata.picker.native').grep_queries(queries_dir, on_select)
    end

    local rg_command = 'rg --column --line-number --no-heading --smart-case "" .'
    local preview_opt = ''
    if vim.fn.executable('bat') == 1 then
        preview_opt = '--preview="bat --style=numbers --color=always --highlight-line {2} -- {1}"'
    end

    local fzf_options = {
        '--ansi',
        '--prompt="Grep Queries> "',
        '--delimiter=:',
        preview_opt,
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
    if vim.fn.exists('*fzf#run') == 0 then
        return require('vim-teradata.picker.native').pick_completion(items, context, opts, on_select)
    end

    local fzf_config = {
        source = items,
        options = (opts and opts.fzf_options) or '',
        window = { width = 0.5, height = 0.4, border = 'rounded' },
        ['sink*'] = function(selected)
            on_select(selected, context)
        end,
    }
    vim.fn['fzf#run'](fzf_config)
end

function M.pick_basic(columns, callback, opts)
    if vim.fn.exists('*fzf#run') == 0 or vim.fn.exists('*fzf#wrap') == 0 then
        return require('vim-teradata.picker.native').pick_basic(columns, callback, opts)
    end

    local prompt = (opts and opts.prompt) or "Select Columns> "
    vim.fn['fzf#run'](vim.fn['fzf#wrap']({
        source = columns,
        options = '-m --prompt=' .. vim.fn.shellescape(prompt),
        ['sink*'] = function(lines)
            -- fzf#run with sink* returns the selected lines directly
            callback(lines)
        end
    }))
end

function M.pick_one(items, callback, opts)
    if vim.fn.exists('*fzf#run') == 0 or vim.fn.exists('*fzf#wrap') == 0 then
        return require('vim-teradata.picker.native').pick_one(items, callback, opts)
    end

    local prompt = (opts and opts.prompt) or "Select Item> "
    vim.fn['fzf#run'](vim.fn['fzf#wrap']({
        source = items,
        options = '+m --prompt=' .. vim.fn.shellescape(prompt),
        sink = function(selected)
            if selected and selected ~= '' then
                callback(selected)
            else
                callback(nil)
            end
        end,
    }))
end

return M
