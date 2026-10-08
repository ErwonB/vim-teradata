local M = {}

function M.grep_queries(queries_dir, on_select)
    local files = vim.fn.globpath(queries_dir, "*", false, true)
    if #files == 0 then
        vim.notify("No query history files found.", vim.log.levels.INFO)
        return
    end

    local items = {}
    for _, file in ipairs(files) do
        local name = vim.fn.fnamemodify(file, ":t:r")
        local first_line = ""
        local fd = io.open(file, "r")
        if fd then
            first_line = fd:read("*line") or ""
            fd:close()
        end
        table.insert(items, {
            name = name,
            display = string.format("%-24s │ %s", name, first_line),
        })
    end

    vim.ui.select(items, {
        prompt = "Teradata Queries: ",
        format_item = function(item)
            return item.display
        end,
    }, function(choice)
        if choice then
            on_select(choice.name)
        end
    end)
end

function M.pick_completion(items, context, opts, on_select)
    vim.ui.select(items, {
        prompt = (opts and opts.prompt) or "Completion: ",
    }, function(choice)
        if choice then
            on_select({ choice }, context)
        end
    end)
end

function M.pick_basic(columns, callback, opts)
    vim.ui.select(columns, {
        prompt = (opts and opts.prompt) or "Select Column: ",
    }, function(choice)
        if choice then
            callback({ choice })
        else
            callback({})
        end
    end)
end

function M.pick_one(items, callback, opts)
    vim.ui.select(items, {
        prompt = (opts and opts.prompt) or "Select Item: ",
    }, function(choice)
        callback(choice)
    end)
end

return M
