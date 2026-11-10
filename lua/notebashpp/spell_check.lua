-- spell check like dspellcheck in notepad++ (6.9 million downloads, the third
-- most installed plugin). apparently we all need help failing to write.
-- misspelled words get a red underline; plugins > spell check jumps between
-- them. right-click one for suggestions at the top of the menu. neovim does
-- the checking and ships english. other languages go in user.lua as
-- spell_languages. i'd love to run out of languages to be wrong in.

local spell_check = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- misspelled word under the caret: text & 0-based byte bounds on the caret
-- line, or nil. basically even my mistakes have boundaries.
---@class notebashpp.misspelled_word
---@field word string
---@field line integer
---@field start_col integer
---@field end_col integer
---@field suggestions? string[]

---@return notebashpp.misspelled_word?
local function misspelled_word_at_caret()
    local caret = api.nvim_win_get_cursor(0)
    local line_text = api.nvim_get_current_line()
    local word_start = caret[2]
    while word_start > 0 and vim.fn.match(line_text:sub(word_start, word_start), [[\k]]) == 0 do
        word_start = word_start - 1
    end
    local word_end = caret[2]
    while word_end < #line_text and vim.fn.match(line_text:sub(word_end + 1, word_end + 1), [[\k]]) == 0 do
        word_end = word_end + 1
    end
    local word = line_text:sub(word_start + 1, word_end)
    if word == '' then
        return nil
    end
    local bad_word = vim.fn.spellbadword(word)[1]
    if bad_word == '' then
        return nil
    end
    return { word = word, line = caret[1], start_col = word_start, end_col = word_end }
end

-- jump to & select the next (direction 1) or previous (-1) misspelling, like
-- dspellcheck's find next misspelling. i revisit failure professionally.
---@param direction integer
function spell_check.jump(direction)
    if not vim.wo.spell then
        return helpers.notify('Spell check is off: Plugins > Spell Check > Spell Check Document.')
    end
    local caret_before = api.nvim_win_get_cursor(0)
    vim.cmd('normal! ' .. (direction > 0 and ']s' or '[s'))
    local caret = api.nvim_win_get_cursor(0)
    local bad_word = vim.fn.spellbadword()[1]
    if bad_word == '' or vim.deep_equal(caret, caret_before) then
        return helpers.notify('No more misspelled words.')
    end
    helpers.select_range({ caret[1], caret[2] }, { caret[1], caret[2] + #bad_word })
end

-- add the caret word (or selected word) to your dictionary, a file of yours
-- in neovim's data folder. cheaper than admitting you're wrong.
function spell_check.add_word()
    local selected = helpers.get_selection() and vim.trim(helpers.selected_text_or_word_at_caret()) or ''
    local word = selected ~= '' and selected or vim.fn.expand('<cword>')
    if word == '' then
        return
    end
    vim.cmd.spellgood(vim.fn.fnameescape(word))
    helpers.notify('Added to your dictionary: ' .. word)
end

-- right-click menu: clicked misspelled word's suggestions first, then "add to
-- dictionary", then usual items. surrender gets its own menu entry.
local popup_entries = {}
---@type notebashpp.misspelled_word?
local popup_target = nil

-- the word comes from the document, so it goes into an ex command as a menu
-- name. control characters (a tab ends the name and the rest would become
-- the menu's command) turn into spaces, then every space, dot, bar,
-- backslash and & is escaped, and it is cut at 40 characters. nobody's word
-- should get to run commands. mine never even got listened to.
local function menu_escape(text)
    text = vim.fn.strcharpart((text:gsub('%c', ' ')), 0, 40)
    return (text:gsub('\\', '\\\\'):gsub('&', '&&'):gsub('([ .|])', '\\%1'))
end

local function clear_popup_entries()
    for _, entry_name in ipairs(popup_entries) do
        pcall(api.nvim_command, 'silent! aunmenu PopUp.' .. entry_name)
    end
    popup_entries = {}
    popup_target = nil
end

function spell_check.use_suggestion(suggestion_index)
    local target = popup_target
    if not target or not target.suggestions[suggestion_index] then
        return
    end
    api.nvim_buf_set_text(0, target.line - 1, target.start_col, target.line - 1, target.end_col, { target.suggestions[suggestion_index] })
    clear_popup_entries()
end

function spell_check.prepare_popup()
    clear_popup_entries()
    if not vim.wo.spell then
        return
    end
    local target = misspelled_word_at_caret()
    if not target then
        return
    end
    target.suggestions = vim.fn.spellsuggest(target.word, 5)
    popup_target = target
    for suggestion_index, suggestion in ipairs(target.suggestions) do
        local entry_name = menu_escape(suggestion)
        vim.cmd(
            ('anoremenu .%d PopUp.%s <Cmd>lua require("notebashpp.spell_check").use_suggestion(%d)<CR>'):format(suggestion_index, entry_name, suggestion_index)
        )
        popup_entries[#popup_entries + 1] = entry_name
    end
    local add_entry = menu_escape('Add "' .. target.word .. '" to Dictionary')
    vim.cmd(('anoremenu .8 PopUp.%s <Cmd>lua require("notebashpp.spell_check").add_word()<CR>'):format(add_entry))
    vim.cmd('anoremenu .9 PopUp.-spell- <Nop>')
    vim.list_extend(popup_entries, { add_entry, '-spell-' })
end

function spell_check.setup()
    local languages = require('notebashpp.user_settings').get('spell_languages') or 'en'
    vim.go.spelllang = languages
    vim.go.spellcapcheck = ''
    vim.go.spelloptions = 'camel'
    local dictionary_folder = vim.fn.stdpath('data') .. '/spell'
    vim.fn.mkdir(dictionary_folder, 'p')
    vim.go.spellfile = dictionary_folder .. '/' .. languages:match('^[^,_]+') .. '.utf-8.add'
    api.nvim_create_autocmd('MenuPopup', {
        group = api.nvim_create_augroup('notebashpp_spell_check', { clear = true }),
        callback = spell_check.prepare_popup,
    })
end

return spell_check
