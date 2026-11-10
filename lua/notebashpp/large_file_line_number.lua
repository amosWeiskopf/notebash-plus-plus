-- large file view: each line's file number goes on its first screen row,
-- including wrapped lines. 'statuscolumn' is drawn with its window current.
-- even this shit knows where it belongs. i'd love that.

local large_file_line_number = {}

function large_file_line_number.text()
    local state = require('notebashpp.large_file_view').states[vim.api.nvim_get_current_buf()]
    if not state or vim.v.virtnum ~= 0 then
        return ''
    end
    return tostring(state.top_line + vim.v.lnum)
end

return large_file_line_number
