local M = {}

--- Trailing-edge debounce backed by a libuv timer.
---@param ms integer
---@param fn fun(...)
---@return { call: fun(...), close: fun() }
function M.new(ms, fn)
    local timer = assert(vim.uv.new_timer())
    local unpack = table.unpack or unpack
    local d = {}

    function d.call(...)
        local args = { n = select('#', ...), ... }
        timer:stop()
        timer:start(ms, 0, vim.schedule_wrap(function()
            fn(unpack(args, 1, args.n))
        end))
    end

    function d.close()
        if not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end

    return d
end

return M
