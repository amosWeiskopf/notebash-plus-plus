-- auto-completion as in notepad++ (config.xml auto-completion:
-- autocaction="3" triggerfromnbchar="1" autocignorenumbers="yes"). while
-- typing a word, get a list of document words starting with it. enter or tab
-- accepts the highlighted word. moving the caret does not open the list. you
-- have to actually type. apparently even help needs proof that you're still
-- producing something before you die.

local word_completion = {}
local api = vim.api

local word_list_cache = {}
local max_lines_scanned = 50000

-- every buffer word, sorted, with its occurrence count. single letters &
-- plain numbers are excluded. i finally have standards (for this crap).
local function document_words(buffer)
    local cached = word_list_cache[buffer]
    local now_milliseconds = vim.uv.now()
    local line_count = api.nvim_buf_line_count(buffer)
    local change_tick = api.nvim_buf_get_changedtick(buffer)
    -- small files are rescanned on every change. over 5000 lines, rescan at
    -- most every 1.5 s. reading 50000 lines per keystroke would burn through
    -- the laptop & my remaining life. i paid for one of those.
    if cached and (cached.change_tick == change_tick or (line_count > 5000 and now_milliseconds - cached.scanned_at < 1500)) then
        return cached.words, cached.occurrences
    end
    local occurrences, sorted_words = {}, {}
    for _, line_text in ipairs(api.nvim_buf_get_lines(buffer, 0, math.min(line_count, max_lines_scanned), false)) do
        for word in line_text:gmatch('[%w_\128-\255]+') do
            if #word > 1 and not word:match('^%d+$') then
                if not occurrences[word] then
                    occurrences[word] = 0
                    sorted_words[#sorted_words + 1] = word
                end
                occurrences[word] = occurrences[word] + 1
            end
        end
    end
    table.sort(sorted_words)
    word_list_cache[buffer] = { scanned_at = now_milliseconds, change_tick = change_tick, words = sorted_words, occurrences = occurrences }
    return sorted_words, occurrences
end

-- show the list for the word before the caret. force handles ctrl+space &
-- ctrl+enter, including on a number or right after a space. you explicitly
-- asked for help. i want at least one damn thing to answer.
function word_completion.trigger(force)
    if vim.fn.mode() ~= 'i' then
        return
    end
    local buffer = api.nvim_get_current_buf()
    local caret = api.nvim_win_get_cursor(0)
    local line_text = api.nvim_get_current_line()
    local text_before_caret = line_text:sub(1, caret[2])
    local typed_prefix = text_before_caret:match('[%w_\128-\255]+$') or ''
    if not force then
        if #typed_prefix < 1 or typed_prefix:match('^%d+$') then
            return
        end
    end
    -- the word under the caret only suggests itself if it also occurs
    -- elsewhere. i already hear myself in my head all day. absolutely no need
    -- for a list.
    local word_under_caret = typed_prefix .. (line_text:sub(caret[2] + 1):match('^[%w_\128-\255]+') or '')
    local all_words, occurrences = document_words(buffer)
    local suggestions = {}
    for _, word in ipairs(all_words) do
        if word ~= typed_prefix and word:sub(1, #typed_prefix) == typed_prefix and not (word == word_under_caret and occurrences[word] <= 1) then
            suggestions[#suggestions + 1] = word
        end
    end
    if #suggestions == 0 then
        if vim.fn.pumvisible() == 1 then
            api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, false, true), 'n', false)
        end
        return
    end
    vim.fn.complete(caret[2] - #typed_prefix + 1, suggestions)
end

-- open the list only just after typing a word character. skip other text
-- changes (paste, undo), column mode, multi-editing, special buffers &
-- buffers with vim.b.completion set to false. i want one damn boundary
-- respected in my life, even if it's only by a completion list.
function word_completion.setup()
    local autocommand_group = api.nvim_create_augroup('notebashpp_complete', { clear = true })
    local typed_word_character = false
    api.nvim_create_autocmd('InsertCharPre', {
        group = autocommand_group,
        callback = function()
            typed_word_character = vim.v.char:match('^[%w_\128-\255]') ~= nil
        end,
    })
    api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP' }, {
        group = autocommand_group,
        callback = function(event)
            if
                not typed_word_character
                or not require('notebashpp.helpers').is_document_buffer(event.buf)
                or require('notebashpp.column_mode').active()
                or require('notebashpp.multi_editing').active()
            then
                return
            end
            typed_word_character = false
            if vim.b[event.buf].completion == false then
                return
            end
            word_completion.trigger(false)
        end,
    })
end

return word_completion
