-- smart highlighting: select a whole word to light its other occurrences. i
-- want to see how often i repeat the same shit. config.xml smarthighlight:
-- matchcase="no" wholewordonly="yes".

local smart_highlighting = {}
local api = vim.api

-- last match: its window, matchadd id & pattern. nil when nothing is lit.
-- basically i gave my failures a search history.
local current_match = nil

local function clear()
    if current_match and api.nvim_win_is_valid(current_match.window) then
        pcall(vim.fn.matchdelete, current_match.match_id, current_match.window)
    end
    current_match = nil
end

-- runs on every cursor move & mode change. highlights only a single-line,
-- charwise selection in visual or select mode, entirely word characters.
-- anything else clears it. even this editor has standards. mine are gone.
local function update()
    local mode = vim.fn.mode()
    if mode ~= 'v' and mode ~= 's' then
        return clear()
    end
    local selection = require('notebashpp.helpers').get_selection()
    if not selection or selection.start_line ~= selection.end_line then
        return clear()
    end
    local text = require('notebashpp.helpers').get_text_in_range(selection)[1]
    if not text or not text:match('^[%w_\128-\255]+$') then
        return clear()
    end
    -- whole word only: no word character may touch either end of the
    -- selection. half a word gets nothing. i apparently run this editor like
    -- a bastard who disputes an invoice over half an hour.
    local line_text = require('notebashpp.helpers').get_line_text(selection.start_line)
    local character_before = line_text:sub(selection.start_col, selection.start_col)
    local character_after = line_text:sub(selection.end_col + 1, selection.end_col + 1)
    if character_before:match('[%w_\128-\255]') or character_after:match('[%w_\128-\255]') then
        return clear()
    end
    -- \c ignores case; very nomagic takes the word literally; \< and \> mark
    -- word edges. leave the same pattern alone if already lit in this window
    -- to avoid flicker. i want to repeat my mistakes without the light show.
    local window = api.nvim_get_current_win()
    local pattern = '\\c\\V\\<' .. text:gsub('\\', '\\\\') .. '\\>'
    if current_match and current_match.window == window and current_match.pattern == pattern then
        return
    end
    clear()
    local ok, match_id = pcall(vim.fn.matchadd, 'NotebashSmart', pattern, 5, -1, { window = window })
    if ok then
        current_match = { window = window, match_id = match_id, pattern = pattern }
    end
end

smart_highlighting._unload = clear

function smart_highlighting.setup()
    local augroup = api.nvim_create_augroup('notebashpp_smarthl', { clear = true })
    api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged' }, {
        group = augroup,
        callback = update,
    })
end

return smart_highlighting
