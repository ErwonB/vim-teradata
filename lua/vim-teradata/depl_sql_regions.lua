local M = {}

local function find_marker_rows(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local rows = {}
    for i, s in ipairs(lines) do
        if s:match("^========") then
            rows[#rows + 1] = i - 1
        end
    end
    return rows, #lines
end

local function add_region(regions, srow, erow)
    if srow < erow then
        regions[#regions + 1] = { { srow, 0, erow, 0 } }
    end
end

function M.restrict_sql_regions(buf)
    buf = buf or 0

    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'sql')
    if not ok or not parser then
        return
    end

    local markers, line_count = find_marker_rows(buf)
    local regions = {}

    if #markers == 0 then
        pcall(parser.parse, parser)
        return
    end

    for i = 1, (#markers - 1) do
        add_region(regions, markers[i] + 1, markers[i + 1])
    end

    add_region(regions, markers[#markers] + 1, line_count)


    ---@diagnostic disable-next-line: invisible
    parser:set_included_regions(regions)
    pcall(parser.parse, parser)
end

return M
