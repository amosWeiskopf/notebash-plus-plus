-- the search menu: find / replace / find in files / mark, f3 and relatives,
-- find all results (f7, f4), incremental search & style tokens. i spent my
-- working life looking for shit i wrote earlier. basically this is the
-- pension plan, with checkboxes.

local find_and_replace = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local regex = require('notebashpp.notepadpp_regex')

local found_namespace = api.nvim_create_namespace('notebashpp_found')
local mark_namespace = api.nvim_create_namespace('notebashpp_mark')
local dialog_namespace = api.nvim_create_namespace('notebashpp_dialog')
-- one namespace per style token colour, numbered 1 to 5 like the menu. even
-- the paint needs its own damn property.
find_and_replace.ns_styles = {}
for style_number = 1, 5 do
    find_and_replace.ns_styles[style_number] = api.nvim_create_namespace('notebashpp_style' .. style_number)
end

------------------------------------------------------------------ state

-- config.xml search mode: 0 normal, 1 extended, 2 regex. my mistakes now have
-- a classification system.
local SEARCH_MODES = { 'normal', 'extended', 'regex' }

-- everything the dialog remembers. live_code_reload keeps this table across
-- reloads. i want that kind of loyalty, apparently from a table.
find_and_replace.state = {
    find = '',
    replace = '',
    dir = '',
    filters = '*.*',
    match_case = false,
    whole_word = false,
    wrap = true,
    mode = 'regex',
    dot_nl = false,
    backward = false,
    in_selection = false,
    bookmark = true,
    purge = true,
    subfolders = true,
    hidden = false,
    hist = { find = {}, replace = {}, dir = {}, filters = {} },
}

-- import find dialog options & histories from notepad++'s config.xml, so it
-- opens as you left it in notepad++. i want to leave, with my baggage.
-- "fifrecuisive" is notepad++'s own spelling, wrong for years. i'll be dead
-- and this bastard will still be backwards compatible.
local function seed_from_notepadpp()
    local notepadpp_settings = require('notebashpp.notepadpp_settings_import')
    local find_options = notepadpp_settings.find_options()
    local find_state = find_and_replace.state
    local function option_is_yes(attribute_name, default)
        if find_options[attribute_name] == nil then
            return default
        end
        return find_options[attribute_name] == 'yes'
    end
    find_state.match_case = option_is_yes('matchCase', false)
    find_state.whole_word = option_is_yes('matchWord', false)
    find_state.wrap = option_is_yes('wrap', true)
    find_state.dot_nl = option_is_yes('dotMatchesNewline', false)
    find_state.backward = not option_is_yes('directionDown', true)
    find_state.subfolders = option_is_yes('fifRecuisive', true)
    find_state.hidden = option_is_yes('fifInHiddenFolder', false)
    find_state.bookmark = option_is_yes('bookmarkLine', true)
    find_state.purge = option_is_yes('purge', true)
    if find_options.searchMode then
        find_state.mode = SEARCH_MODES[(tonumber(find_options.searchMode) or 2) + 1] or 'regex'
    end
    local find_history, replace_history = notepadpp_settings.find_history()
    find_state.hist.find = vim.deepcopy(find_history)
    find_state.hist.replace = vim.deepcopy(replace_history)
    local directory_history, filter_history = notepadpp_settings.find_paths()
    find_state.hist.dir = directory_history
    find_state.hist.filters = vim.deepcopy(filter_history)
    if filter_history[1] then
        find_state.filters = filter_history[1]
    end
end
seed_from_notepadpp()

-- put the newest value first in its history, without duplicates; 10 entries
-- at most. entry eleven gets erased. i'd love that service for my twenties.
local function remember(history_kind, value)
    if value == nil or value == '' then
        return
    end
    local history_list = find_and_replace.state.hist[history_kind]
    for index, old_value in ipairs(history_list) do
        if old_value == value then
            table.remove(history_list, index)
            break
        end
    end
    table.insert(history_list, 1, value)
    while #history_list > 10 do
        table.remove(history_list)
    end
end

function find_and_replace.pattern(text)
    return regex.build(text or find_and_replace.state.find, find_and_replace.state)
end

local message = { text = '', is_error = false }

-- dialog status: while open, put the message in the footer, under the buttons
-- like notepad++. otherwise send a notification. basically i paid with my
-- life to build another way to be ignored.
local function show_message(text, is_error)
    message = { text = text, is_error = is_error }
    if find_and_replace.dialog_open() then
        find_and_replace.render()
    else
        if is_error then
            helpers.warn(text)
        else
            helpers.notify(text)
        end
    end
end

---------------------------------------------------------------- engine

-- some patterns take exponential time: (a+)+\1b on 100 a's ran past 40
-- seconds and the editor was gone. every search gets a time limit. a search
-- that comes back empty right at the limit was stopped, not unlucky, so
-- report it. i'd like a timeout like that on some of my decisions.
local SEARCH_TIME_LIMIT_MILLISECONDS = 2000
local TOO_SLOW_MESSAGE = 'the pattern is too slow on this text and was stopped after 2 seconds'

local function timed_searchpos(vim_pattern, search_flags)
    local started = vim.uv.hrtime()
    local position = vim.fn.searchpos(vim_pattern, search_flags, 0, SEARCH_TIME_LIMIT_MILLISECONDS)
    if position[1] == 0 and (vim.uv.hrtime() - started) / 1e6 >= SEARCH_TIME_LIMIT_MILLISECONDS * 0.95 then
        error(TOO_SLOW_MESSAGE, 0)
    end
    return position
end

-- find the end of the match starting at start_position ({line, 0-based col}).
-- searchpos with 'e' stops on the last character; we need the position after
-- it, so advance one utf-8 character. death requires absolutely none of this
-- bookkeeping, which feels like unfair competition.
local function match_end(vim_pattern, start_position)
    api.nvim_win_set_cursor(0, start_position)
    local last_char_position = timed_searchpos(vim_pattern, 'cenW')
    local end_line, end_col = last_char_position[1], last_char_position[2] - 1
    if end_line == 0 then
        return { start_position[1], start_position[2] }
    end
    local line_text = helpers.get_line_text(end_line)
    if end_line == start_position[1] and end_col == start_position[2] then
        -- an empty match and a one-character match look identical from here.
        -- i need another check. apparently nothing is also full of shit.
        local match_info = vim.fn.matchstrpos(line_text:sub(start_position[2] + 1), vim_pattern)
        if match_info[2] == 0 and match_info[1] == '' then
            return { start_position[1], start_position[2] }
        end
    end
    -- a consumed line break ends at the next line's start, or at the last
    -- line's end. even this damn match runs out of future.
    if end_col >= #line_text then
        if end_line < helpers.count_lines() then
            return { end_line + 1, 0 }
        end
        return { end_line, #line_text }
    end
    local first_byte = line_text:byte(end_col + 1)
    local byte_count = first_byte >= 0xF0 and 4 or first_byte >= 0xE0 and 3 or first_byte >= 0xC0 and 2 or 1
    return { end_line, end_col + byte_count }
end

-- search the current window's buffer from from_position; return a range and
-- whether we wrapped. skip_empty_at is the previous empty match's position,
-- so find next cannot find the same nothing forever. i already do that for
-- free, thanks.
local function search(vim_pattern, from_position, backward, wrap, skip_empty_at)
    local saved_view = vim.fn.winsaveview()
    local result, wrapped = nil, false
    local succeeded, error_message = pcall(function()
        local function try_from(position, search_flags)
            api.nvim_win_set_cursor(0, position)
            local match_start = timed_searchpos(vim_pattern, search_flags)
            if match_start[1] == 0 then
                return nil
            end
            local start_position = { match_start[1], match_start[2] - 1 }
            local end_position = match_end(vim_pattern, start_position)
            return { start_line = start_position[1], start_col = start_position[2], end_line = end_position[1], end_col = end_position[2] }
        end
        local search_flags = backward and 'bW' or 'cW'
        local range = try_from(from_position, search_flags)
        if
            range
            and not backward
            and skip_empty_at
            and range.start_line == range.end_line
            and range.start_col == range.end_col
            and range.start_line == skip_empty_at[1]
            and range.start_col == skip_empty_at[2]
        then
            range = try_from(from_position, 'W')
        end
        if not range and wrap then
            wrapped = true
            if backward then
                local last_line = helpers.count_lines()
                range = try_from({ last_line, #helpers.get_line_text(last_line) }, 'bcW')
            else
                range = try_from({ 1, 0 }, 'cW')
            end
        end
        result = range
    end)
    vim.fn.winrestview(saved_view)
    if not succeeded then
        error(error_message, 0)
    end
    return result, wrapped
end

-- call on_match(range) for each current-buffer match, top to bottom. advance
-- one character after an empty match; stop after 1000000 matches. i gave this
-- loop a limit. my own life got no such sensible supervision.
local function each_match(vim_pattern, on_match)
    local saved_view = vim.fn.winsaveview()
    local match_count = 0
    local succeeded, error_message = pcall(function()
        local position = { 1, 0 }
        local last_line = helpers.count_lines()
        local loop_guard = 0
        while true do
            api.nvim_win_set_cursor(0, position)
            local match_start = timed_searchpos(vim_pattern, 'cW')
            if match_start[1] == 0 then
                break
            end
            local start_position = { match_start[1], match_start[2] - 1 }
            local end_position = match_end(vim_pattern, start_position)
            match_count = match_count + 1
            on_match({ start_line = start_position[1], start_col = start_position[2], end_line = end_position[1], end_col = end_position[2] })
            local next_position
            if end_position[1] == start_position[1] and end_position[2] == start_position[2] then
                local line_text = helpers.get_line_text(start_position[1])
                if start_position[2] >= #line_text then
                    if start_position[1] >= last_line then
                        break
                    end
                    next_position = { start_position[1] + 1, 0 }
                else
                    local first_byte = line_text:byte(start_position[2] + 1)
                    local byte_count = first_byte >= 0xF0 and 4 or first_byte >= 0xE0 and 3 or first_byte >= 0xC0 and 2 or 1
                    next_position = { start_position[1], start_position[2] + byte_count }
                end
            else
                next_position = end_position
            end
            if next_position[1] > last_line then
                break
            end
            position = next_position
            loop_guard = loop_guard + 1
            if loop_guard > 1000000 then
                break
            end
        end
    end)
    vim.fn.winrestview(saved_view)
    if not succeeded then
        error(error_message, 0)
    end
    return match_count
end

-- true if range is wholly inside scope_range; no scope means the whole
-- document. absolutely all the crap qualifies without further inspection.
local function range_in_scope(range, scope_range)
    if not scope_range then
        return true
    end
    return not helpers.position_is_before({ range.start_line, range.start_col }, { scope_range.start_line, scope_range.start_col })
        and not helpers.position_is_before({ scope_range.end_line, scope_range.end_col }, { range.end_line, range.end_col })
end

-- use the editor window the dialog opened from, or the current window without
-- a dialog. i can return to the scene of my wasted evening.
local function editor_window()
    if find_and_replace.dialog_open() and api.nvim_win_is_valid(find_and_replace.dialog.editor_window) then
        return find_and_replace.dialog.editor_window
    end
    return api.nvim_get_current_win()
end

local function in_editor(callback)
    local window = editor_window()
    if window == api.nvim_get_current_win() then
        return callback()
    end
    return api.nvim_win_call(window, callback)
end

-- show the match. with the dialog open & focused, the editor cannot hold a
-- real selection: paint an extmark, move the caret to the end, use zv to open
-- hiding folds, and keep the range for later. without the dialog, just select
-- it. i built the complication and now i'm its unpaid staff.
local function show_found(range)
    local window = editor_window()
    local buffer = api.nvim_win_get_buf(window)
    api.nvim_buf_clear_namespace(buffer, found_namespace, 0, -1)
    if not range then
        return
    end
    if find_and_replace.dialog_open() and window ~= api.nvim_get_current_win() then
        if range.start_line ~= range.end_line or range.start_col ~= range.end_col then
            api.nvim_buf_set_extmark(buffer, found_namespace, range.start_line - 1, range.start_col, {
                end_row = range.end_line - 1,
                end_col = range.end_col,
                hl_group = 'NotebashFound',
                priority = 250,
            })
        end
        api.nvim_win_set_cursor(window, { range.end_line, range.end_col })
        api.nvim_win_call(window, function()
            vim.cmd('normal! zv')
        end)
        find_and_replace.dialog.found = { buffer = buffer, range = range }
    else
        if range.start_line == range.end_line and range.start_col == range.end_col then
            helpers.move_caret_to({ range.start_line, range.start_col })
        else
            helpers.select_range({ range.start_line, range.start_col }, { range.end_line, range.end_col })
        end
    end
end

-- the editor selection: while the dialog is open, use show_found's painted
-- match only if it is still in the same buffer. even a fake needs papers.
local function selection_in_editor()
    if find_and_replace.dialog_open() then
        local found = find_and_replace.dialog.found
        if found and found.buffer == api.nvim_win_get_buf(editor_window()) then
            return found.range
        end
        return nil
    end
    return helpers.get_selection()
end

-- find next / previous using dialog settings. start after the selection going
-- forward, before it going backward. remember empty-match positions so the
-- next press skips them. i want at least one part of my life to move.
function find_and_replace.find_next(backward)
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return find_and_replace.open('find')
    end
    if backward == nil then
        backward = find_state.backward
    end
    local vim_pattern = find_and_replace.pattern()
    local found_range, wrapped
    local succeeded, error_message = pcall(in_editor, function()
        local selection = selection_in_editor()
        local caret = helpers.get_caret()
        local from_position
        if backward then
            from_position = selection and { selection.start_line, selection.start_col } or caret
        else
            from_position = selection and { selection.end_line, selection.end_col } or caret
        end
        local skip_empty_at = find_and_replace.last_empty_match_position
        found_range, wrapped = search(vim_pattern, from_position, backward, find_state.wrap, skip_empty_at)
    end)
    if not succeeded then
        return show_message('Find: Invalid regular expression (' .. tostring(error_message):gsub('^.-:', '') .. ')', true)
    end
    remember('find', find_state.find)
    if not found_range then
        show_found(nil)
        return show_message(('Find: Can\'t find the text "%s"'):format(find_state.find), true)
    end
    find_and_replace.last_empty_match_position = (found_range.start_line == found_range.end_line and found_range.start_col == found_range.end_col)
            and { found_range.start_line, found_range.start_col }
        or nil
    if wrapped then
        show_message(
            backward and 'Find: Found the 1st occurrence from the bottom. The beginning of the document has been reached.'
                or 'Find: Found the 1st occurrence from the top. The end of the document has been reached.'
        )
    else
        show_message('')
    end
    show_found(found_range)
    return true
end

-- ctrl+f3 / ctrl+shift+f3 use the selection or caret word as normal-mode
-- search text. ctrl+alt+f3 also turns match case & whole word off, wrap on,
-- then restores the dialog settings; only history retains the change. a clean
-- getaway, except for the evidence. my usual level of planning.
function find_and_replace.set_and_find(backward, volatile)
    local text = helpers.selected_text_or_word_at_caret()
    if text == '' or text:find('\n') then
        return
    end
    local saved_state = vim.deepcopy(find_and_replace.state)
    find_and_replace.state.find = text
    find_and_replace.state.mode = 'normal'
    if volatile then
        find_and_replace.state.match_case = false
        find_and_replace.state.whole_word = false
        find_and_replace.state.wrap = true
    end
    find_and_replace.find_next(backward)
    if volatile then
        saved_state.hist = find_and_replace.state.hist
        find_and_replace.state = saved_state
    else
        remember('find', text)
    end
end

-- count / replace all / mark scope: use the selection if "in selection" is
-- on. without wrap, use caret to end, or caret to top going backward. nil
-- means the whole document. i want every regrettable line accounted for.
local function search_scope()
    local find_state = find_and_replace.state
    if find_state.in_selection and find_and_replace.dialog and find_and_replace.dialog.selection then
        return find_and_replace.dialog.selection
    end
    if not find_state.wrap then
        local caret = in_editor(helpers.get_caret)
        local last_line = in_editor(helpers.count_lines)
        local last_line_length = in_editor(function()
            return #helpers.get_line_text(last_line)
        end)
        if find_state.backward then
            return { start_line = 1, start_col = 0, end_line = caret[1], end_col = caret[2] }
        end
        return { start_line = caret[1], start_col = caret[2], end_line = last_line, end_col = last_line_length }
    end
    return nil
end

-- count occurrences. finally, an exact measurement of my failure to shut up.
function find_and_replace.count()
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    local vim_pattern = find_and_replace.pattern()
    local scope_range = search_scope()
    local match_count = 0
    local succeeded, error_message = pcall(in_editor, function()
        each_match(vim_pattern, function(range)
            if range_in_scope(range, scope_range) then
                match_count = match_count + 1
            end
        end)
    end)
    if not succeeded then
        return show_message('Count: Invalid regular expression (' .. tostring(error_message) .. ')', true)
    end
    remember('find', find_state.find)
    show_message(('Count: %d match%s.'):format(match_count, match_count == 1 and '' or 'es'))
end

-- replacement text, called from :s through v:lua for every match. return
-- out-of-scope matches untouched; count the replacements. i want credit for
-- the damage, apparently.
---@class notebashpp.substitution
---@field replaced_count integer
---@field replacement_template string
---@field scope_range? table

---@type notebashpp.substitution?
local current_substitution = nil
function find_and_replace._substitution_text()
    local substitution = assert(current_substitution, 'no replacement is running')
    local line_number, column = vim.fn.line('.'), vim.fn.col('.') - 1
    local matched_text = vim.fn.submatch(0)
    local matched_lines = vim.split(matched_text, '\n', { plain = true })
    local range = { start_line = line_number, start_col = column }
    local end_position = helpers.position_after_inserted_text(line_number, column, matched_lines)
    range.end_line, range.end_col = end_position[1], end_position[2]
    if not range_in_scope(range, substitution.scope_range) then
        return matched_text
    end
    substitution.replaced_count = substitution.replaced_count + 1
    return regex.replacement(substitution.replacement_template, find_and_replace.state, function(group_number)
        return vim.fn.submatch(group_number)
    end)
end

-- run :s over `line_range` with `vim_pattern` in the search register. the
-- pattern never enters the command text; :s// reads the register. pasting it
-- into a command needs perfect escaping. one wrong slash and find text like
-- x/y/|call system('...') becomes a command that runs. i escaped that slash
-- twice once. two backslashes, absolutely zero protection. basically i paid
-- for the divorce and kept the vulnerability.
local function substitute_with_pattern(line_range, vim_pattern, flags)
    -- :s has no time limit, so walk the matches first with the timed search.
    -- searchcount() takes a timeout too, but ignores it inside one slow
    -- match. if the walk gives up, so do we, before :s takes the editor down
    -- with it. measure twice, ruin once.
    each_match(vim_pattern, function() end)
    local saved_search = vim.fn.getreg('/')
    vim.fn.setreg('/', vim_pattern)
    local substituted, substitute_error = pcall(
        vim.api.nvim_command,
        ('keepjumps keeppatterns silent %ss//\\=v:lua.require("notebashpp.find_and_replace")._substitution_text()/%s'):format(line_range, flags)
    )
    vim.fn.setreg('/', saved_search)
    if not substituted then
        error(substitute_error, 0)
    end
end

-- replace every in-scope buffer match with one :s; return the count. one undo
-- step. i'd love this arrangement for the rest of my mistakes.
local function replace_all_in_buffer(buffer, scope_range)
    local find_state = find_and_replace.state
    local vim_pattern = find_and_replace.pattern()
    current_substitution = { replaced_count = 0, replacement_template = find_state.replace, scope_range = scope_range }
    local first_line, last_line = 1, '$'
    if scope_range then
        first_line, last_line = scope_range.start_line, scope_range.end_line
    end
    local run_substitute = function()
        local saved_view = vim.fn.winsaveview()
        substitute_with_pattern(first_line .. ',' .. last_line, vim_pattern, 'ge')
        vim.fn.winrestview(saved_view)
    end
    local window = vim.fn.bufwinid(buffer)
    if window ~= -1 then
        api.nvim_win_call(window, run_substitute)
    else
        api.nvim_buf_call(buffer, run_substitute)
    end
    return current_substitution.replaced_count
end

-- replace all in this document or every open document. copy notepad++'s
-- message wording & counts exactly, plural "s" included. artisanal misery.
function find_and_replace.replace_all(all_documents)
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    remember('find', find_state.find)
    remember('replace', find_state.replace)
    local total_replaced, documents_changed = 0, 0
    local succeeded, error_message = pcall(function()
        if all_documents then
            for _, buffer in ipairs(require('notebashpp.document_tabs').sync()) do
                local replaced_count = replace_all_in_buffer(buffer, nil)
                total_replaced = total_replaced + replaced_count
                if replaced_count > 0 then
                    documents_changed = documents_changed + 1
                end
            end
        else
            total_replaced = replace_all_in_buffer(api.nvim_win_get_buf(editor_window()), search_scope())
        end
    end)
    if not succeeded then
        return show_message('Replace All: Invalid regular expression (' .. tostring(error_message) .. ')', true)
    end
    show_found(nil)
    if all_documents then
        show_message(
            ('Replace in Opened Files: %d occurrence%s replaced in %d document%s.'):format(
                total_replaced,
                total_replaced == 1 and ' was' or 's were',
                documents_changed,
                documents_changed == 1 and '' or 's'
            )
        )
    else
        show_message(('Replace All: %d occurrence%s replaced.'):format(total_replaced, total_replaced == 1 and ' was' or 's were'))
    end
end

-- replace only when the selection exactly matches, then find the next. a
-- nearly matching selection gets no replacement. i appreciate this editor's
-- commitment to making almost enough feel like absolute shit.
function find_and_replace.replace_one()
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    remember('find', find_state.find)
    remember('replace', find_state.replace)
    local vim_pattern = find_and_replace.pattern()
    local replaced = false
    local new_end
    local succeeded, error_message = pcall(in_editor, function()
        local selection = selection_in_editor()
        if not selection then
            return
        end
        local range = search(vim_pattern, { selection.start_line, selection.start_col }, false, false)
        if
            not range
            or range.start_line ~= selection.start_line
            or range.start_col ~= selection.start_col
            or range.end_line ~= selection.end_line
            or range.end_col ~= selection.end_col
        then
            return
        end
        local saved_view = vim.fn.winsaveview()
        -- pin this one substitution with \%l and \%c so submatches &
        -- lookarounds still see surrounding text. even regex needs context
        -- for its bullshit.
        current_substitution = { replaced_count = 0, replacement_template = find_state.replace, scope_range = selection }
        api.nvim_win_set_cursor(0, { selection.start_line, selection.start_col })
        substitute_with_pattern(
            selection.start_line .. ',' .. selection.start_line,
            ('\\%%%dl\\%%%dc\\%%(%s\\m\\)'):format(selection.start_line, selection.start_col + 1, vim_pattern),
            'e'
        )
        vim.fn.winrestview(saved_view)
        replaced = current_substitution.replaced_count > 0
        if replaced then
            local replacement_text = regex.replacement(find_state.replace, find_state, function()
                return ''
            end)
            new_end = helpers.position_after_inserted_text(selection.start_line, selection.start_col, vim.split(replacement_text, '\n', { plain = true }))
        end
    end)
    if not succeeded then
        return show_message('Replace: Invalid regular expression (' .. tostring(error_message) .. ')', true)
    end
    if replaced and new_end then
        in_editor(function()
            api.nvim_win_set_cursor(0, new_end)
        end)
        if find_and_replace.dialog then
            find_and_replace.dialog.found = nil
        end
    end
    local found_next = find_and_replace.find_next(false)
    if replaced then
        show_message(
            found_next and 'Replace: 1 occurrence was replaced. The next occurrence found.' or 'Replace: 1 occurrence was replaced. No more occurrences.'
        )
    end
end

---------------------------------------------------------- results panel

-- one notepad++ results line: "line 6:  the text" (capital l on screen).
-- prefix the file name for hits from multiple files. even failure needs an
-- address.
local function results_lines(info)
    local list = vim.fn.getqflist({ id = info.id, items = 1 })
    local file_names = {}
    for _, item in ipairs(list.items) do
        file_names[item.bufnr] = true
    end
    local several_files = vim.tbl_count(file_names) > 1
    local lines = {}
    for index = info.start_idx, info.end_idx do
        local item = list.items[index]
        local prefix = several_files and (vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ':t') .. '  ') or ''
        lines[#lines + 1] = ('  %sLine %d:  %s'):format(prefix, item.lnum, vim.trim(item.text))
    end
    return lines
end

-- put quickfix at the bottom, 10 lines high, as notepad++'s search results
-- panel: summary for the title, no line numbers, search term highlighted.
-- select the first hit, then restore the previous focus. i want to call this
-- thrift. basically i put makeup on quickfix instead of fixing my life.
local function open_results(items, title, vim_pattern)
    -- one entry per line regardless of hit count; the title counts all hits,
    -- the highlight shows every hit on that line. failure gets full
    -- accounting.
    local seen_lines, line_items = {}, {}
    for _, item in ipairs(items) do
        local line_key = (item.bufnr or item.filename) .. ':' .. item.lnum
        if not seen_lines[line_key] then
            seen_lines[line_key] = true
            line_items[#line_items + 1] = item
        end
    end
    vim.fn.setqflist({}, ' ', { title = title, items = line_items, quickfixtextfunc = results_lines })
    local previous_window = api.nvim_get_current_win()
    vim.cmd('botright copen 10')
    local results_window = api.nvim_get_current_win()
    vim.bo.buflisted = false
    vim.bo.syntax = ''
    vim.wo[results_window].winbar = '%#NotebashDlgMsg# ' .. title:gsub('%%', '%%%%') .. ' %#NotebashDlgLabel#'
    vim.wo[results_window].number = false
    vim.wo[results_window].signcolumn = 'no'
    vim.wo[results_window].statuscolumn = ''
    vim.wo[results_window].foldcolumn = '0'
    vim.fn.clearmatches(results_window)
    vim.fn.matchadd('LineNr', [[\v^\s+(\S+\s\s)?Line \d+:]], 10, -1, { window = results_window })
    if vim_pattern then
        -- highlight every hit after "line n:". one disappointment was
        -- insufficient.
        pcall(vim.fn.matchadd, 'NotebashFound', [[\v(^\s+(\S+\s\s)?Line \d+:\s\s.*)@<=]] .. vim_pattern, 20, -1, { window = results_window })
    end
    if #items > 0 then
        vim.cmd('cfirst')
    end
    if api.nvim_win_is_valid(previous_window) then
        api.nvim_set_current_win(previous_window)
    end
end

-- other modules (language server references) fill the same panel. shared
-- hell.
function find_and_replace.show_results(items, title, vim_pattern)
    open_results(items, title, vim_pattern)
end

-- append every buffer match to items as quickfix entries, with 1-based
-- columns; return the count. receipts for the time i won't get back.
local function collect_matches(buffer, vim_pattern, items)
    local match_count = 0
    local collect = function()
        each_match(vim_pattern, function(range)
            match_count = match_count + 1
            items[#items + 1] = {
                bufnr = buffer,
                lnum = range.start_line,
                col = range.start_col + 1,
                end_lnum = range.end_line,
                end_col = range.end_col + 1,
                text = helpers.get_line_text(range.start_line, buffer),
            }
        end)
    end
    local window = vim.fn.bufwinid(buffer)
    if window ~= -1 then
        api.nvim_win_call(window, collect)
    else
        api.nvim_buf_call(buffer, collect)
    end
    return match_count
end

-- find all in the current document or all open documents. copy notepad++'s
-- results header, including hit counts. even my despair needs a template.
function find_and_replace.find_all(all_documents)
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    remember('find', find_state.find)
    local vim_pattern = find_and_replace.pattern()
    local items, total_hits, files_with_hits = {}, 0, 0
    local succeeded, error_message = pcall(function()
        local buffers = all_documents and require('notebashpp.document_tabs').sync() or { api.nvim_win_get_buf(editor_window()) }
        for _, buffer in ipairs(buffers) do
            local hit_count = collect_matches(buffer, vim_pattern, items)
            total_hits = total_hits + hit_count
            if hit_count > 0 then
                files_with_hits = files_with_hits + 1
            end
        end
    end)
    if not succeeded then
        return show_message('Find All: Invalid regular expression (' .. tostring(error_message) .. ')', true)
    end
    local title = ('Search "%s" (%d hit%s in %d file%s)'):format(
        find_state.find,
        total_hits,
        total_hits == 1 and '' or 's',
        files_with_hits,
        files_with_hits == 1 and '' or 's'
    )
    find_and_replace.close_dialog()
    open_results(items, title, vim_pattern)
end

-- f4 / shift+f4: next / previous result, wrapping at both ends. f7 enters the
-- results panel. a dead end would at least let me rest.
function find_and_replace.next_result(direction)
    local quickfix = vim.fn.getqflist({ size = 0, idx = 0 })
    if quickfix.size == 0 then
        return
    end
    local target_index = (quickfix.idx - 1 + direction) % quickfix.size + 1
    pcall(vim.api.nvim_command, 'cc ' .. target_index)
end

function find_and_replace.focus_results()
    for _, window in ipairs(api.nvim_list_wins()) do
        if vim.bo[api.nvim_win_get_buf(window)].buftype == 'quickfix' then
            api.nvim_set_current_win(window)
            return
        end
    end
    if vim.fn.getqflist({ size = 0 }).size > 0 then
        vim.cmd('botright copen 10')
    end
end

------------------------------------------------------------ find in files

-- ripgrep arguments for find in files. for_replace requests matching file
-- names only. regex uses pcre2 if this rg supports it; pattern \r\n becomes
-- \r?\n with the multiline flag, accommodating windows & linux line ends.
-- apparently agreeing where a damn line ends was too much to ask. normal &
-- extended modes search literal text. split filters on spaces and semicolons;
-- *.* or * means every file, so add no glob flag. i want to find a word and
-- now i'm negotiating a failed marriage.
local function ripgrep_arguments(for_replace)
    local find_state = find_and_replace.state
    -- files over 20 mb are skipped and long lines cut to 500 characters, so
    -- one minified bundle can't fill the screen (or the ram) by itself.
    local arguments = { 'rg', '--no-ignore', '--color=never', '--no-messages', '--max-filesize', '20M', '--max-columns', '500', '--max-columns-preview' }
    if for_replace then
        -- rg's null flag ends each file name with a zero byte, the one
        -- character a file name can't contain. newline separation lets a
        -- folder called "x<newline>" holding home/you/notes.txt produce two
        -- lines; the second points outside the search. apparently even a file
        -- name wants out of this shit.
        vim.list_extend(arguments, { '--files-with-matches', '--null' })
    else
        -- same zero byte after the file name here, so a name holding
        -- ":12:3:" or a newline can't invent hits in other files.
        vim.list_extend(arguments, { '--vimgrep', '--no-heading', '--null' })
    end
    table.insert(arguments, find_state.match_case and '--case-sensitive' or '--ignore-case')
    if find_state.whole_word then
        table.insert(arguments, '--word-regexp')
    end
    if find_state.hidden then
        table.insert(arguments, '--hidden')
    end
    if not find_state.subfolders then
        vim.list_extend(arguments, { '--max-depth', '1' })
    end
    local search_text = find_state.find
    if find_state.mode == 'regex' then
        if vim.fn.system({ 'rg', '--pcre2-version' }):match('PCRE2') then
            table.insert(arguments, '--pcre2')
        end
        if search_text:find('\\r\\n', 1, true) or search_text:find('\\n', 1, true) then
            table.insert(arguments, '--multiline')
            search_text = search_text:gsub('\\r\\n', '\\r?\\n')
        end
    else
        if find_state.mode == 'extended' then
            search_text = regex.expand_extended(search_text):gsub('\r\n', '\n')
        end
        table.insert(arguments, '--fixed-strings')
        if search_text:find('\n') then
            table.insert(arguments, '--multiline')
        end
    end
    for filter in (find_state.filters or ''):gmatch('[^%s;]+') do
        if filter ~= '*.*' and filter ~= '*' then
            vim.list_extend(arguments, { '--glob', filter })
        end
    end
    vim.list_extend(arguments, { '--regexp', search_text, '--', find_state.dir })
    return arguments
end

local replace_in_matching_files

-- how far one find in files may go before we pull the plug. a search of a
-- home folder for "the" makes about 4.7 gb of results in 20 seconds (we
-- measured, on a real machine, which then died). kept on the module so the
-- tests can lower them.
find_and_replace.ripgrep_limits = { hits = 10000, bytes = 50 * 1024 * 1024, seconds = 120 }

-- read rg output as it arrives, line by line, without hoarding it until rg
-- finishes (i already hoard enough failed potential). hit a limit and we kill
-- rg, keeping what arrived. when_done(lines, stopped_because) runs on the
-- main loop; stopped_because is nil, 'hits', 'bytes' or 'seconds'. separator
-- splits output on newlines, or zero bytes when using rg's null flag. at
-- least this death has a recorded cause.
local function run_ripgrep_with_limits(arguments, when_done, separator)
    separator = separator or '\n'
    local limits = find_and_replace.ripgrep_limits
    local kept_lines, unfinished_line, byte_count = {}, '', 0
    local stopped_because, finished, process = nil, false, nil
    local function stop(reason)
        if not stopped_because then
            stopped_because = reason
            if process then
                pcall(process.kill, process, 15)
            end
        end
    end
    process = vim.system(
        arguments,
        {
            -- text mode turns \r\n into \n, even inside file names.
            -- absolutely helpful, if opening the wrong damn file was my
            -- ambition. zero-byte output contains only file names, so keep it
            -- raw.
            text = separator ~= '\0',
            stdout = function(_, chunk)
                if not chunk or stopped_because then
                    return
                end
                byte_count = byte_count + #chunk
                local text = unfinished_line .. chunk
                local line_start = 1
                while true do
                    local separator_position = text:find(separator, line_start, true)
                    if not separator_position then
                        break
                    end
                    if #kept_lines >= limits.hits then
                        stop('hits')
                        break
                    end
                    kept_lines[#kept_lines + 1] = text:sub(line_start, separator_position - 1)
                    line_start = separator_position + 1
                end
                unfinished_line = text:sub(line_start)
                if byte_count > limits.bytes then
                    stop('bytes')
                end
            end,
        },
        vim.schedule_wrap(function()
            finished = true
            if unfinished_line ~= '' and not stopped_because and #kept_lines < limits.hits then
                kept_lines[#kept_lines + 1] = unfinished_line
            end
            when_done(kept_lines, stopped_because)
        end)
    )
    vim.defer_fn(function()
        if not finished then
            stop('seconds')
        end
    end, limits.seconds * 1000)
end

-- the words for each limit, for the results title and the messages.
local function limit_explanation(stopped_because)
    local limits = find_and_replace.ripgrep_limits
    if stopped_because == 'hits' then
        return ('stopped at %d hits'):format(limits.hits)
    elseif stopped_because == 'bytes' then
        return ('stopped after %d MB of results'):format(math.floor(limits.bytes / 1048576))
    elseif stopped_because == 'seconds' then
        return ('stopped after %d seconds'):format(limits.seconds)
    end
end

-- run rg in the background; fill the results panel when done. an empty
-- directory field means the working directory. convert windows paths to linux
-- paths first. even the address needs therapy before we can begin.
function find_and_replace.find_in_files()
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    -- without ripgrep, warn that search cannot run. i want words explaining
    -- the failure; a lua stack trace is just the computer billing me in
    -- grief.
    if vim.fn.executable('rg') == 0 then
        return helpers.warn('Find in Files needs ripgrep (rg): https://github.com/BurntSushi/ripgrep')
    end
    if find_state.dir == '' then
        find_state.dir = vim.fn.getcwd()
    end
    find_state.dir = helpers.from_windows_path(find_state.dir)
    if vim.fn.isdirectory(find_state.dir) == 0 then
        return show_message('Find in Files: The directory does not exist: ' .. find_state.dir, true)
    end
    remember('find', find_state.find)
    remember('dir', find_state.dir)
    remember('filters', find_state.filters)
    show_message('Find in Files: searching...')
    run_ripgrep_with_limits(ripgrep_arguments(false), function(output_lines, stopped_because)
        local items, files_with_hits = {}, {}
        for _, output_line in ipairs(output_lines) do
            local file_name, line_number, column, line_text = output_line:match('^([^%z]+)%z(%d+):(%d+):(.*)$')
            -- a name with a newline still splits into two lines; the half
            -- after it lacks the folder in front, so it is dropped.
            if file_name and file_name:sub(1, #find_state.dir) == find_state.dir then
                items[#items + 1] = { filename = file_name, lnum = tonumber(line_number), col = tonumber(column), text = line_text }
                files_with_hits[file_name] = true
            end
        end
        local file_count = vim.tbl_count(files_with_hits)
        local title = ('Search "%s" (%d hit%s in %d file%s of %s)'):format(
            find_state.find,
            #items,
            #items == 1 and '' or 's',
            file_count,
            file_count == 1 and '' or 's',
            find_state.dir
        )
        if stopped_because then
            title = title .. ' [' .. limit_explanation(stopped_because) .. '; narrow the directory or the filters]'
        end
        find_and_replace.close_dialog()
        open_results(items, title)
    end)
end

-- replace in files confirms first, like notepad++: this writes to disk, where
-- ctrl+z cannot save my ass. rg lists matching files; load, replace and save
-- each, then close buffers that were not already open. leave the room tidy
-- after the catastrophe. i was raised properly.
function find_and_replace.replace_in_files()
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    if vim.fn.executable('rg') == 0 then
        return helpers.warn('Find in Files needs ripgrep (rg): https://github.com/BurntSushi/ripgrep')
    end
    -- make the path absolute now so a :cd while rg runs can't send
    -- replacements to another folder. i've fucked up enough things on
    -- purpose.
    find_state.dir = vim.fn.fnamemodify(helpers.from_windows_path(find_state.dir ~= '' and find_state.dir or vim.fn.getcwd()), ':p')
    local choice = vim.fn.confirm(('Are you sure you want to replace all occurrences in %s?'):format(find_state.dir), '&OK\n&Cancel', 2)
    if choice ~= 1 then
        return
    end
    remember('find', find_state.find)
    remember('replace', find_state.replace)
    -- run what you confirmed. the dialog stays usable while rg searches, so
    -- copy the settings when you say ok. replacement uses that copy, whatever
    -- the boxes say when rg finishes. consent apparently needs more
    -- protection than my life savings did.
    local confirmed_state = vim.deepcopy(find_state)
    -- at most 1,000 files, and only when rg finished inside the limits. a
    -- replace that stops halfway is worse than one that never starts.
    local saved_limits = find_and_replace.ripgrep_limits
    find_and_replace.ripgrep_limits = vim.tbl_extend('force', saved_limits, { hits = math.min(saved_limits.hits, 1000) })
    run_ripgrep_with_limits(ripgrep_arguments(true), function(matching_files, stopped_because)
        find_and_replace.ripgrep_limits = saved_limits
        if stopped_because then
            return show_message(
                'Replace in Files: nothing replaced, the search ' .. limit_explanation(stopped_because) .. '. Narrow the directory or the filters.',
                true
            )
        end
        local live_state = find_and_replace.state
        find_and_replace.state = confirmed_state
        local replaced, replace_error = pcall(replace_in_matching_files, matching_files, confirmed_state.dir)
        find_and_replace.state = live_state
        if not replaced then
            show_message('Replace in Files: ' .. tostring(replace_error), true)
        end
    end, '\0')
end

-- the second half of replace in files: load, replace, save, one file at a
-- time, and close the ones that weren't open before.
replace_in_matching_files = function(matching_files, search_directory)
    -- compare with forward slashes, ignoring case on windows: c:\work\a.txt
    -- is inside c:/work/. i'd love one less damn identity crisis.
    local function comparable_path(path)
        path = vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ':p')))
        return vim.fn.has('win32') == 1 and path:lower() or path
    end
    local resolved_directory = comparable_path(search_directory):gsub('/*$', '/')

    -- replace in one file; return 'outside', 'unchanged', 'left_unsaved' or
    -- 'saved', plus the occurrence count replaced. i want my failures
    -- itemized.
    local function replace_in_one_file(file_name)
        -- only touch files inside the searched folder, after resolving links.
        -- rg normally doesn't follow links, but somebody's ripgreprc can
        -- enable it. i barely trust my own config files. trusting yours with
        -- writes would basically be paying somebody else to ruin my life.
        local resolved_file = comparable_path(file_name)
        if resolved_file:sub(1, #resolved_directory) ~= resolved_directory then
            return 'outside', 0
        end
        local was_loaded = vim.fn.bufloaded(file_name) == 1
        local buffer = vim.fn.bufadd(file_name)
        vim.fn.bufload(buffer)
        -- rg calls a file binary only when it sees a zero byte early on, so
        -- one with a match first and a zero byte 300 kb later still shows up.
        -- neovim keeps zero bytes as newlines inside a line. skip those files.
        -- i don't edit what i don't understand. i just marry it.
        if not was_loaded then
            for _, line_text in ipairs(api.nvim_buf_get_lines(buffer, 0, -1, false)) do
                if line_text:find('\n', 1, true) then
                    pcall(api.nvim_buf_delete, buffer, { force = true })
                    return 'binary', 0
                end
            end
        end
        -- an open document with unsaved edits gets replacements without
        -- saving. saving would also write edits you never meant to keep. i
        -- want fewer permanent records of my failures, and i'm extending you
        -- that kindness.
        local had_unsaved_edits = was_loaded and vim.bo[buffer].modified
        local replaced_count = replace_all_in_buffer(buffer, nil)
        local outcome = 'unchanged'
        if replaced_count > 0 then
            if had_unsaved_edits then
                outcome = 'left_unsaved'
            elseif comparable_path(file_name) ~= resolved_file then
                -- the path changed since our check (someone swapped in a link
                -- meanwhile). don't write. i've followed enough false
                -- promises into the damn ground.
                outcome, replaced_count = 'outside', 0
            else
                api.nvim_buf_call(buffer, function()
                    vim.cmd('silent write')
                end)
                outcome = 'saved'
            end
        end
        if not was_loaded then
            pcall(api.nvim_buf_delete, buffer, { force = true })
        end
        return outcome, replaced_count
    end

    local total_replaced, files_changed, skipped_outside, left_unsaved, skipped_binary = 0, 0, 0, 0, 0
    for _, file_name in ipairs(matching_files) do
        local outcome, replaced_count = replace_in_one_file(file_name)
        total_replaced = total_replaced + replaced_count
        if outcome == 'saved' or outcome == 'left_unsaved' then
            files_changed = files_changed + 1
        end
        if outcome == 'left_unsaved' then
            left_unsaved = left_unsaved + 1
        elseif outcome == 'outside' then
            skipped_outside = skipped_outside + 1
        elseif outcome == 'binary' then
            skipped_binary = skipped_binary + 1
        end
    end
    local summary = ('Replace in Files: %d occurrence%s replaced in %d file%s.'):format(
        total_replaced,
        total_replaced == 1 and ' was' or 's were',
        files_changed,
        files_changed == 1 and '' or 's'
    )
    if left_unsaved > 0 then
        summary = summary
            .. (' %d open document%s had unsaved changes and %s not saved.'):format(
                left_unsaved,
                left_unsaved == 1 and '' or 's',
                left_unsaved == 1 and 'was' or 'were'
            )
    end
    if skipped_outside > 0 then
        summary = summary .. (' %d file%s outside %s skipped.'):format(skipped_outside, skipped_outside == 1 and '' or 's', search_directory)
    end
    if skipped_binary > 0 then
        summary = summary .. (' %d binary file%s skipped.'):format(skipped_binary, skipped_binary == 1 and '' or 's')
    end
    show_message(summary)
end

------------------------------------------------------------------ marks

-- require late so these two modules need no mutual dependency at load time. i
-- wish my own bad relationships came with a loading order.
local function bookmarks()
    return require('notebashpp.bookmarks')
end

-- mark all paints every in-scope match; "bookmark line" bookmarks its line.
-- "purge for each search" clears old marks & bookmarks first. empty matches
-- get a bookmark with nothing to paint. i even built a memorial to nothing.
function find_and_replace.mark_all()
    local find_state = find_and_replace.state
    if find_state.find == '' then
        return
    end
    remember('find', find_state.find)
    local window = editor_window()
    local buffer = api.nvim_win_get_buf(window)
    if find_state.purge then
        api.nvim_buf_clear_namespace(buffer, mark_namespace, 0, -1)
        if find_state.bookmark then
            bookmarks().clear(buffer)
        end
    end
    local vim_pattern = find_and_replace.pattern()
    local scope_range = search_scope()
    local match_count = 0
    local succeeded, error_message = pcall(in_editor, function()
        each_match(vim_pattern, function(range)
            if range_in_scope(range, scope_range) then
                match_count = match_count + 1
                if range.start_line ~= range.end_line or range.start_col ~= range.end_col then
                    api.nvim_buf_set_extmark(buffer, mark_namespace, range.start_line - 1, range.start_col, {
                        end_row = range.end_line - 1,
                        end_col = range.end_col,
                        hl_group = 'NotebashMark',
                        priority = 150,
                    })
                end
                if find_state.bookmark then
                    bookmarks().set(buffer, range.start_line)
                end
            end
        end)
    end)
    if not succeeded then
        return show_message('Mark: Invalid regular expression (' .. tostring(error_message) .. ')', true)
    end
    show_message(('Mark: %d match%s.'):format(match_count, match_count == 1 and '' or 'es'))
end

-- clear all marks removes paint, leaving bookmarks as notepad++ does. some
-- baggage survives even the button explicitly asking for less baggage.
function find_and_replace.clear_marks()
    local buffer = api.nvim_win_get_buf(editor_window())
    api.nvim_buf_clear_namespace(buffer, mark_namespace, 0, -1)
    show_message('All marks cleared.')
end

-- copy every marked piece to the clipboard, one per line, charwise ('v'). my
-- crap is portable now.
function find_and_replace.copy_marked_text()
    local buffer = api.nvim_win_get_buf(editor_window())
    local marked_texts = {}
    for _, extmark in ipairs(api.nvim_buf_get_extmarks(buffer, mark_namespace, 0, -1, { details = true })) do
        local details = assert(extmark[4], 'mark without details')
        local text_lines = api.nvim_buf_get_text(
            buffer,
            extmark[2],
            extmark[3],
            assert(details.end_row, 'mark without an end'),
            assert(details.end_col, 'mark without an end'),
            {}
        )
        marked_texts[#marked_texts + 1] = table.concat(text_lines, '\n')
    end
    require('notebashpp.clipboard').set(marked_texts, 'v')
end

-- style tokens: search > style all occurrences of token. config.xml markall
-- uses matchcase="no" wholewordonly="yes". only_this_one means "style one
-- token", colouring just the selection. the rest stays grey. i want to
-- improve the world, apparently one pathetic rectangle at a time.
function find_and_replace.style_all(style_number, only_this_one)
    local text, selection = helpers.selected_text_or_word_at_caret()
    if text == '' then
        return
    end
    local buffer = api.nvim_get_current_buf()
    if only_this_one then
        local range = selection
        if range then
            api.nvim_buf_set_extmark(buffer, find_and_replace.ns_styles[style_number], range.start_line - 1, range.start_col, {
                end_row = range.end_line - 1,
                end_col = range.end_col,
                hl_group = 'NotebashStyle' .. style_number,
                priority = 140,
            })
        end
        return
    end
    local vim_pattern = regex.build(text, { mode = 'normal', match_case = false, whole_word = not text:find('\n') })
    each_match(vim_pattern, function(range)
        api.nvim_buf_set_extmark(buffer, find_and_replace.ns_styles[style_number], range.start_line - 1, range.start_col, {
            end_row = range.end_line - 1,
            end_col = range.end_col,
            hl_group = 'NotebashStyle' .. style_number,
            priority = 140,
        })
    end)
end

-- clear one style, or all five if style_number is nil. cheaper than regret.
function find_and_replace.clear_style(style_number)
    local buffer = api.nvim_get_current_buf()
    if style_number then
        api.nvim_buf_clear_namespace(buffer, find_and_replace.ns_styles[style_number], 0, -1)
    else
        for each_style_number = 1, 5 do
            api.nvim_buf_clear_namespace(buffer, find_and_replace.ns_styles[each_style_number], 0, -1)
        end
    end
end

-- ctrl+1..5 / ctrl+shift+1..5 select the next / previous token of a style,
-- wrapping at the ends. style 0 is the find mark style. extmark rows are
-- 0-based; our positions are not, hence + 1. i keep paying this stupid tax on
-- every row of a life i was already spending badly.
function find_and_replace.jump_style(style_number, direction)
    local namespace = style_number == 0 and mark_namespace or find_and_replace.ns_styles[style_number]
    local marks = api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
    if #marks == 0 then
        return
    end
    table.sort(marks, function(first_mark, second_mark)
        return first_mark[2] < second_mark[2] or (first_mark[2] == second_mark[2] and first_mark[3] < second_mark[3])
    end)
    local selection = helpers.get_selection()
    local position = selection and (direction > 0 and { selection.end_line, selection.end_col } or { selection.start_line, selection.start_col })
        or helpers.get_caret()
    local picked_mark
    if direction > 0 then
        for _, extmark in ipairs(marks) do
            if
                helpers.position_is_before(position, { extmark[2] + 1, extmark[3] + 1 })
                or (position[1] == extmark[2] + 1 and position[2] == extmark[3] and not selection)
            then
                picked_mark = extmark
                break
            end
        end
        picked_mark = picked_mark or marks[1]
    else
        for mark_index = #marks, 1, -1 do
            local extmark = marks[mark_index]
            if helpers.position_is_before({ extmark[2] + 1, extmark[3] }, position) then
                picked_mark = extmark
                break
            end
        end
        picked_mark = picked_mark or marks[#marks]
    end
    helpers.select_range({ picked_mark[2] + 1, picked_mark[3] }, { picked_mark[4].end_row + 1, picked_mark[4].end_col })
end

-- copy one style, or all five if style_number is nil, to the clipboard, one
-- piece per line. colour-coded crap is still worth saving, apparently.
function find_and_replace.copy_styled(style_number)
    local styled_texts = {}
    local namespaces = style_number and { find_and_replace.ns_styles[style_number] } or find_and_replace.ns_styles
    for _, namespace in ipairs(namespaces) do
        for _, extmark in ipairs(api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })) do
            local text_lines = api.nvim_buf_get_text(0, extmark[2], extmark[3], extmark[4].end_row, extmark[4].end_col, {})
            styled_texts[#styled_texts + 1] = table.concat(text_lines, '\n')
        end
    end
    require('notebashpp.clipboard').set(styled_texts, 'v')
end

------------------------------------------------------------------ dialog

-- the dialog is a floating buffer with one line per text field. virtual lines
-- below the last field hold checkboxes, radio buttons & key hints. from far
-- enough away it looks like a windows dialog. so does my career, if you stop
-- asking what any of it was for.
local TABS = { 'find', 'replace', 'files', 'mark' }
local TAB_TITLE = { find = 'Find', replace = 'Replace', files = 'Find in Files', mark = 'Mark' }
local TAB_FIELDS = {
    find = { 'find' },
    replace = { 'find', 'replace' },
    files = { 'find', 'replace', 'filters', 'dir' },
    mark = { 'find' },
}
local FIELD_LABEL = { find = 'Find what :', replace = 'Replace with :', filters = 'Filters :', dir = 'Directory :' }
local FIELD_HISTORY = { find = 'find', replace = 'replace', filters = 'filters', dir = 'dir' }

find_and_replace.dialog = nil

-- save dialog fields into state, then close before a code reload. i want
-- something i typed to survive me, however embarrassing.
function find_and_replace._unload()
    if find_and_replace.dialog_open() then
        find_and_replace.close_dialog()
    end
end

function find_and_replace.dialog_open()
    return find_and_replace.dialog ~= nil and api.nvim_win_is_valid(find_and_replace.dialog.window)
end

local function checkbox_text(is_on)
    return is_on and '[x]' or '[ ]'
end

local function radio_button_text(is_selected)
    return is_selected and '(*)' or '( )'
end

-- read typed dialog values into state, line by line; one line per field on
-- the current tab. my legacy fits in a very small buffer.
local function read_fields()
    if not find_and_replace.dialog_open() then
        return
    end
    local field_lines = api.nvim_buf_get_lines(find_and_replace.dialog.buffer, 0, -1, false)
    for row_number, field_name in ipairs(TAB_FIELDS[find_and_replace.dialog.tab]) do
        find_and_replace.state[field_name] = field_lines[row_number] or ''
    end
end

-- virtual lines below the fields: current-tab options, search mode radio
-- buttons, then key hints wrapped to dialog width. each row contains {text,
-- highlight group} chunks. even the instructions need scaffolding.
local function info_rows()
    local find_state = find_and_replace.state
    local tab = find_and_replace.dialog.tab
    local rows = {}
    local function add_row(chunks)
        rows[#rows + 1] = chunks
    end
    local function checkbox_chunks(is_on, label, key_name)
        return { { ' ' .. checkbox_text(is_on) .. ' ' .. label, is_on and 'NotebashDlgOn' or 'NotebashDlgOff' }, { ' ' .. key_name .. ' ', 'NotebashDlgKey' } }
    end
    local function join_chunks(...)
        local joined = {}
        for _, chunk_list in ipairs({ ... }) do
            vim.list_extend(joined, chunk_list)
        end
        return joined
    end
    add_row({ { '', 'NotebashDlgLabel' } })
    if tab == 'files' then
        add_row(
            join_chunks(checkbox_chunks(find_state.subfolders, 'In all sub-folders', 'Alt+B'), checkbox_chunks(find_state.hidden, 'In hidden folders', 'Alt+H'))
        )
    end
    if tab == 'mark' then
        add_row(
            join_chunks(checkbox_chunks(find_state.bookmark, 'Bookmark line', 'Alt+M'), checkbox_chunks(find_state.purge, 'Purge for each search', 'Alt+U'))
        )
    end
    add_row(
        join_chunks(
            checkbox_chunks(find_state.whole_word, 'Match whole word only', 'Alt+W'),
            checkbox_chunks(find_state.match_case, 'Match case', 'Alt+C'),
            tab ~= 'files' and checkbox_chunks(find_state.wrap, 'Wrap around', 'Alt+P') or {}
        )
    )
    if tab ~= 'files' then
        add_row(
            join_chunks(
                checkbox_chunks(find_state.in_selection, 'In selection', 'Alt+I'),
                tab ~= 'mark' and checkbox_chunks(find_state.backward, 'Backward direction', 'Alt+K') or {}
            )
        )
    end
    local function radio_chunks(mode_name, label, key_name)
        local is_selected = find_state.mode == mode_name
        return {
            { ' ' .. radio_button_text(is_selected) .. ' ' .. label, is_selected and 'NotebashDlgOn' or 'NotebashDlgOff' },
            { ' ' .. key_name .. ' ', 'NotebashDlgKey' },
        }
    end
    add_row(
        join_chunks(
            { { ' Search Mode:', 'NotebashDlgLabel' } },
            radio_chunks('normal', 'Normal', 'Alt+N'),
            radio_chunks('extended', 'Extended (\\n, \\r, \\t, \\0, \\x...)', 'Alt+X'),
            radio_chunks('regex', 'Regular expression', 'Alt+G')
        )
    )
    add_row(join_chunks({ { '              ', 'NotebashDlgLabel' } }, checkbox_chunks(find_state.dot_nl, '. matches newline', 'Alt+.')))
    add_row({ { '', 'NotebashDlgLabel' } })
    local action_hints
    if tab == 'find' then
        action_hints = {
            'Enter Find Next',
            'Shift+Enter Find Previous',
            'Alt+T Count',
            'Alt+D Find All in Current Document',
            'Alt+O Find All in All Opened Documents',
        }
    elseif tab == 'replace' then
        action_hints = { 'Enter Find Next', 'Shift+Enter Find Previous', 'Alt+R Replace', 'Alt+A Replace All', 'Alt+O Replace All in All Opened Documents' }
    elseif tab == 'files' then
        action_hints = { 'Enter Find All', 'Alt+R Replace in Files', 'Alt+E Directory', 'Alt+S Filters' }
    else
        action_hints = { 'Enter Mark All', 'Alt+L Clear all marks', 'Alt+Y Copy Marked Text', 'Alt+T Count' }
    end
    table.insert(action_hints, 'Tab next field')
    table.insert(action_hints, 'Up/Down history')
    table.insert(action_hints, 'Ctrl+Tab next tab')
    table.insert(action_hints, 'Esc Close')
    -- wrap action hints to dialog width. each hint's first word is the key;
    -- the rest explains its action. i want my obituary this clear, preferably
    -- with a working shortcut to close the damn thing.
    local available_width = find_and_replace.dialog.width - 2
    local row_chunks = {}
    local row_width = 0
    for _, hint in ipairs(action_hints) do
        local hint_text = ' ' .. hint .. '  '
        if row_width + #hint_text > available_width and #row_chunks > 0 then
            add_row(row_chunks)
            row_chunks, row_width = {}, 0
        end
        local key_name, description = hint:match('^(%S+)%s(.*)$')
        row_chunks[#row_chunks + 1] = { ' ' .. key_name, 'NotebashDlgKey' }
        row_chunks[#row_chunks + 1] = { ' ' .. description .. '  ', 'NotebashDlgLabel' }
        row_width = row_width + #hint_text
    end
    if #row_chunks > 0 then
        add_row(row_chunks)
    end
    return rows
end

-- redraw field lines only when their count changes, preserving typing. also
-- draw inline labels & info rows, tabs in the title, last message in the
-- footer. position top right, one row down, out of the way. i've spent years
-- developing this exact social skill. now it's a window.
function find_and_replace.render()
    if not find_and_replace.dialog_open() then
        return
    end
    local dialog = find_and_replace.dialog
    local field_names = TAB_FIELDS[dialog.tab]
    local field_lines = api.nvim_buf_get_lines(dialog.buffer, 0, -1, false)
    if #field_lines ~= #field_names then
        local new_lines = {}
        for row_number, field_name in ipairs(field_names) do
            new_lines[row_number] = find_and_replace.state[field_name] or ''
        end
        api.nvim_buf_set_lines(dialog.buffer, 0, -1, false, new_lines)
    end
    api.nvim_buf_clear_namespace(dialog.buffer, dialog_namespace, 0, -1)
    for row_number, field_name in ipairs(field_names) do
        api.nvim_buf_set_extmark(dialog.buffer, dialog_namespace, row_number - 1, 0, {
            virt_text = { { (' %-14s'):format(FIELD_LABEL[field_name]), 'NotebashDlgLabel' } },
            virt_text_pos = 'inline',
            right_gravity = false,
        })
        -- on the grey dialog, the field stays white from label to right edge,
        -- even when empty. you can see where to type before typing. i can't
        -- tell you where my life went wrong, but this box is clearly marked.
        api.nvim_buf_set_extmark(dialog.buffer, dialog_namespace, row_number - 1, 0, {
            end_row = row_number,
            end_col = 0,
            hl_group = 'NotebashDlgField',
            hl_eol = true,
            strict = false,
        })
    end
    local info = info_rows()
    api.nvim_buf_set_extmark(dialog.buffer, dialog_namespace, #field_names - 1, 0, { virt_lines = info })
    local title_chunks = {}
    for _, tab_name in ipairs(TABS) do
        local is_current = tab_name == dialog.tab
        title_chunks[#title_chunks + 1] = { ' ' .. TAB_TITLE[tab_name] .. ' ', is_current and 'NotebashMenuSel' or 'FloatTitle' }
    end
    local footer = message.text ~= '' and { { ' ' .. message.text .. ' ', message.is_error and 'NotebashDlgErr' or 'NotebashDlgMsg' } } or ''
    api.nvim_win_set_config(dialog.window, {
        relative = 'editor',
        row = 1,
        col = math.max(0, vim.o.columns - dialog.width - 2),
        width = dialog.width,
        height = #field_names + #info,
        title = title_chunks,
        title_pos = 'left',
        footer = footer,
        footer_pos = 'left',
    })
end

-- current field as a dialog-buffer line number. my whereabouts, for once.
local function focused_row_number()
    return api.nvim_win_get_cursor(find_and_replace.dialog.window)[1]
end

-- put the cursor at the field's end. return true if this tab has the field,
-- otherwise nothing. i appreciate an honest rejection for a damn change.
local function focus_field(field_name)
    for row_number, candidate in ipairs(TAB_FIELDS[find_and_replace.dialog.tab]) do
        if candidate == field_name then
            api.nvim_win_set_cursor(
                find_and_replace.dialog.window,
                { row_number, #(api.nvim_buf_get_lines(find_and_replace.dialog.buffer, row_number - 1, row_number, false)[1] or '') }
            )
            return true
        end
    end
end

-- focus & select field text as notepad++ does on opening: typing replaces it,
-- arrow keys keep it. i wish all my mistakes offered these terms.
local function select_field(field_name)
    focus_field(field_name)
    local row_number = focused_row_number()
    local text = api.nvim_buf_get_lines(find_and_replace.dialog.buffer, row_number - 1, row_number, false)[1] or ''
    if text ~= '' then
        helpers.select_range({ row_number, 0 }, { row_number, #text })
    end
end

-- switch tabs: save typed text, fill the new fields, clear the message. keep
-- focus in the same field if available, otherwise use find what. i changed
-- the scenery and kept my baggage. absolutely convincing escape.
local function switch_tab(tab)
    read_fields()
    local focused_field = TAB_FIELDS[find_and_replace.dialog.tab][focused_row_number()] or 'find'
    find_and_replace.dialog.tab = tab
    local new_lines = {}
    for row_number, field_name in ipairs(TAB_FIELDS[tab]) do
        new_lines[row_number] = find_and_replace.state[field_name] or ''
    end
    api.nvim_buf_set_lines(find_and_replace.dialog.buffer, 0, -1, false, new_lines)
    message = { text = '', is_error = false }
    find_and_replace.render()
    if not focus_field(focused_field) then
        focus_field('find')
    end
end

-- ctrl+tab & friends cycle next / previous tab. even escape wraps around.
local function cycle_tab(direction)
    local current_index = 1
    for tab_index, tab_name in ipairs(TABS) do
        if tab_name == find_and_replace.dialog.tab then
            current_index = tab_index
        end
    end
    switch_tab(TABS[(current_index - 1 + direction) % #TABS + 1])
end

-- up / down move through the focused field's history, newest first. stop at
-- both ends without wrapping. i gave the past a limit here, since it refuses
-- to respect one anywhere else in my damn life.
local function step_history(direction)
    local row_number = focused_row_number()
    local field_name = TAB_FIELDS[find_and_replace.dialog.tab][row_number]
    local history_list = find_and_replace.state.hist[FIELD_HISTORY[field_name]]
    if not history_list or #history_list == 0 then
        return
    end
    find_and_replace.dialog.history_positions = find_and_replace.dialog.history_positions or {}
    local history_index = (find_and_replace.dialog.history_positions[field_name] or 0) + direction
    history_index = math.max(1, math.min(#history_list, history_index))
    find_and_replace.dialog.history_positions[field_name] = history_index
    api.nvim_buf_set_lines(find_and_replace.dialog.buffer, row_number - 1, row_number, false, { history_list[history_index] })
    api.nvim_win_set_cursor(find_and_replace.dialog.window, { row_number, #history_list[history_index] })
end

local function toggle_option(option_name)
    find_and_replace.state[option_name] = not find_and_replace.state[option_name]
    find_and_replace.render()
end

local function set_search_mode(mode_name)
    find_and_replace.state.mode = mode_name
    find_and_replace.render()
end

-- button wrapper: read fields, run the action, redraw if the dialog survived.
-- this is also basically my retirement strategy.
local function dialog_action(action)
    return function()
        read_fields()
        action()
        if find_and_replace.dialog_open() then
            find_and_replace.render()
        end
    end
end

-- close the dialog, return to the editor & clear the found highlight. keep
-- the last match selected so typing replaces it; with no match, restore any
-- selection present on opening. select_range runs through vim.schedule after
-- stopinsert takes effect. even goodbye needs a queue.
function find_and_replace.close_dialog()
    if not find_and_replace.dialog then
        return
    end
    read_fields()
    local dialog = find_and_replace.dialog
    find_and_replace.dialog = nil
    if api.nvim_win_is_valid(dialog.window) then
        api.nvim_win_close(dialog.window, true)
    end
    if api.nvim_win_is_valid(dialog.editor_window) then
        local editor_buffer = api.nvim_win_get_buf(dialog.editor_window)
        api.nvim_buf_clear_namespace(editor_buffer, found_namespace, 0, -1)
        api.nvim_set_current_win(dialog.editor_window)
        vim.cmd('stopinsert')
        local found = dialog.found
        if found and found.buffer == editor_buffer and (found.range.start_line ~= found.range.end_line or found.range.start_col ~= found.range.end_col) then
            vim.schedule(function()
                helpers.select_range({ found.range.start_line, found.range.start_col }, { found.range.end_line, found.range.end_col })
            end)
        elseif dialog.opened_with_selection then
            vim.schedule(function()
                helpers.select_range({ dialog.selection.start_line, dialog.selection.start_col }, { dialog.selection.end_line, dialog.selection.end_col })
            end)
        end
    end
end

-- dialog keys first drop selected field text in select mode, so tab & alt
-- keys leave no selection behind. exit select mode with ctrl+\ ctrl+n, then
-- call the same numbered handler via _press_key_from_select_mode. i wanted a
-- text field. apparently i signed up to manage its damn escape.
local function map_dialog_key(key_sequence, handler)
    local options = { buffer = find_and_replace.dialog.buffer, nowait = true, silent = true }
    vim.keymap.set({ 'i', 'n' }, key_sequence, handler, options)
    find_and_replace.dialog.key_handlers = find_and_replace.dialog.key_handlers or {}
    table.insert(find_and_replace.dialog.key_handlers, handler)
    vim.keymap.set(
        's',
        key_sequence,
        ('<C-\\><C-n><Cmd>lua require("notebashpp.find_and_replace")._press_key_from_select_mode(%d)<CR>'):format(#find_and_replace.dialog.key_handlers),
        options
    )
end

-- run handler_number's handler; return to insert mode if still in the dialog.
-- a field stranded in normal mode is my fault, which narrows nothing.
function find_and_replace._press_key_from_select_mode(handler_number)
    local handler = find_and_replace.dialog and find_and_replace.dialog.key_handlers[handler_number]
    if not handler then
        return
    end
    handler()
    if find_and_replace.dialog_open() and api.nvim_get_current_win() == find_and_replace.dialog.window and vim.fn.mode() == 'n' then
        vim.cmd('startinsert!')
    end
end

-- open a dialog tab: search > find, replace, find in files, mark. if already
-- open, switch tabs & reselect the field text. same damn room, fresh illusion
-- of having gone somewhere.
function find_and_replace.open(tab)
    tab = tab or 'find'
    if find_and_replace.dialog_open() then
        if api.nvim_get_current_win() ~= find_and_replace.dialog.window then
            api.nvim_set_current_win(find_and_replace.dialog.window)
        end
        switch_tab(tab)
        vim.cmd('startinsert!')
        select_field(TAB_FIELDS[tab][focused_row_number()] or 'find')
        return
    end
    -- config.xml fillfindfieldwithselected / fillfindfieldselectcaret: use
    -- the selection or caret word for find what; exclude multiline
    -- selections. i want to carry my mistakes forward, within strict size
    -- restrictions.
    local initial_text = helpers.selected_text_or_word_at_caret()
    local editor_selection = helpers.get_selection()
    if initial_text ~= '' and not initial_text:find('\n') then
        find_and_replace.state.find = initial_text
    end
    -- find in files starts in the current file's directory; unnamed files use
    -- the working directory. even my unsaved crap gets a place to belong.
    if tab == 'files' and find_and_replace.state.dir == '' then
        local file_path = api.nvim_buf_get_name(0)
        find_and_replace.state.dir = file_path ~= '' and vim.fn.fnamemodify(file_path, ':p:h') or vim.fn.getcwd()
    end
    local opened_from_window = api.nvim_get_current_win()
    local dialog_buffer = api.nvim_create_buf(false, true)
    vim.bo[dialog_buffer].filetype = 'notebashpp_find'
    vim.bo[dialog_buffer].bufhidden = 'wipe'
    -- 60 to 110 columns wide, 4 less than the screen when it fits. my
    -- ambitions finally have enforceable limits.
    local dialog_width = math.min(110, math.max(60, vim.o.columns - 4))
    local dialog_window = api.nvim_open_win(dialog_buffer, true, {
        relative = 'editor',
        row = 1,
        col = math.max(0, vim.o.columns - dialog_width - 2),
        width = dialog_width,
        height = 3,
        style = 'minimal',
        border = 'single',
        zindex = 150,
    })
    vim.wo[dialog_window].winhighlight = 'Normal:NotebashDlgLabel,NormalFloat:NotebashDlgLabel,FloatBorder:FloatBorder'
    vim.wo[dialog_window].wrap = false
    vim.wo[dialog_window].winbar = ''
    vim.b[dialog_buffer].completion = false
    find_and_replace.dialog = {
        buffer = dialog_buffer,
        window = dialog_window,
        tab = tab,
        width = dialog_width,
        editor_window = opened_from_window,
        selection = editor_selection and vim.deepcopy(editor_selection) or nil,
        opened_with_selection = editor_selection ~= nil,
    }
    -- like notepad++: multiline selection enables "in selection"; no
    -- selection disables it; a one-line selection leaves the setting
    -- unchanged. i want consistency, so i faithfully copy somebody else's
    -- complications.
    if editor_selection and (editor_selection.end_line > editor_selection.start_line) then
        find_and_replace.state.in_selection = true
    elseif not editor_selection then
        find_and_replace.state.in_selection = false
    end
    message = { text = '', is_error = false }
    local initial_lines = {}
    for row_number, field_name in ipairs(TAB_FIELDS[tab]) do
        initial_lines[row_number] = find_and_replace.state[field_name] or ''
    end
    api.nvim_buf_set_lines(dialog_buffer, 0, -1, false, initial_lines)
    find_and_replace.render()
    focus_field('find')
    vim.cmd('startinsert!')
    select_field('find')

    -- enter runs the tab's main button: find next, find all in files, or mark
    -- all. i put my remaining hope on one key. absolutely sound investment.
    map_dialog_key(
        '<CR>',
        dialog_action(function()
            if find_and_replace.dialog.tab == 'files' then
                find_and_replace.find_in_files()
            elseif find_and_replace.dialog.tab == 'mark' then
                find_and_replace.mark_all()
            else
                find_and_replace.find_next(nil)
            end
        end)
    )
    map_dialog_key(
        '<kEnter>',
        dialog_action(function()
            find_and_replace.find_next(nil)
        end)
    )
    map_dialog_key(
        '<S-CR>',
        dialog_action(function()
            find_and_replace.find_next(not find_and_replace.state.backward)
        end)
    )
    map_dialog_key(
        '<F3>',
        dialog_action(function()
            find_and_replace.find_next(false)
        end)
    )
    map_dialog_key(
        '<S-F3>',
        dialog_action(function()
            find_and_replace.find_next(true)
        end)
    )
    map_dialog_key('<Esc>', find_and_replace.close_dialog)
    map_dialog_key('<C-c>', find_and_replace.close_dialog)
    -- tab / shift+tab cycle fields, wrapping, with the cursor at the end.
    -- another little circuit i'll mistake for progress.
    map_dialog_key('<Tab>', function()
        local field_count = #TAB_FIELDS[find_and_replace.dialog.tab]
        local next_row = focused_row_number() % field_count + 1
        api.nvim_win_set_cursor(find_and_replace.dialog.window, { next_row, #(api.nvim_buf_get_lines(dialog_buffer, next_row - 1, next_row, false)[1] or '') })
    end)
    map_dialog_key('<S-Tab>', function()
        local field_count = #TAB_FIELDS[find_and_replace.dialog.tab]
        local next_row = (focused_row_number() - 2) % field_count + 1
        api.nvim_win_set_cursor(find_and_replace.dialog.window, { next_row, #(api.nvim_buf_get_lines(dialog_buffer, next_row - 1, next_row, false)[1] or '') })
    end)
    map_dialog_key('<Up>', function()
        step_history(-1)
    end)
    map_dialog_key('<Down>', function()
        step_history(1)
    end)
    map_dialog_key('<C-Tab>', function()
        cycle_tab(1)
    end)
    map_dialog_key('<C-S-Tab>', function()
        cycle_tab(-1)
    end)
    map_dialog_key('<C-PageDown>', function()
        cycle_tab(1)
    end)
    map_dialog_key('<C-PageUp>', function()
        cycle_tab(-1)
    end)
    -- menu shortcuts switch tabs inside the dialog. map ctrl+shift+f twice
    -- because terminals disagree on its spelling. my life pays the
    -- difference.
    map_dialog_key('<C-f>', function()
        switch_tab('find')
    end)
    map_dialog_key('<C-h>', function()
        switch_tab('replace')
    end)
    map_dialog_key('<C-S-f>', function()
        switch_tab('files')
    end)
    map_dialog_key('<C-S-F>', function()
        switch_tab('files')
    end)
    map_dialog_key('<C-m>', function()
        switch_tab('mark')
    end)
    -- alt keys follow notepad++'s underlined checkbox & radio button letters.
    -- "in selection" toggles only if there was a selection. even this
    -- checkbox requires evidence that something was there.
    map_dialog_key('<M-w>', function()
        toggle_option('whole_word')
    end)
    map_dialog_key('<M-c>', function()
        toggle_option('match_case')
    end)
    map_dialog_key('<M-p>', function()
        toggle_option('wrap')
    end)
    map_dialog_key('<M-i>', function()
        if find_and_replace.dialog.selection then
            toggle_option('in_selection')
        end
    end)
    map_dialog_key('<M-k>', function()
        toggle_option('backward')
    end)
    map_dialog_key('<M-b>', function()
        toggle_option('subfolders')
    end)
    map_dialog_key('<M-h>', function()
        toggle_option('hidden')
    end)
    map_dialog_key('<M-m>', function()
        toggle_option('bookmark')
    end)
    map_dialog_key('<M-u>', function()
        toggle_option('purge')
    end)
    map_dialog_key('<M-.>', function()
        toggle_option('dot_nl')
    end)
    map_dialog_key('<M-n>', function()
        set_search_mode('normal')
    end)
    map_dialog_key('<M-x>', function()
        set_search_mode('extended')
    end)
    map_dialog_key('<M-g>', function()
        set_search_mode('regex')
    end)
    map_dialog_key('<M-f>', function()
        focus_field('find')
    end)
    map_dialog_key('<M-e>', function()
        focus_field('dir')
    end)
    map_dialog_key('<M-s>', function()
        focus_field('filters')
    end)
    map_dialog_key('<M-t>', dialog_action(find_and_replace.count))
    map_dialog_key(
        '<M-d>',
        dialog_action(function()
            find_and_replace.find_all(false)
        end)
    )
    -- alt+l clears all marks on the mark tab; elsewhere it focuses replace
    -- with. one letter doing two jobs, and somehow i'm still the unpaid one.
    map_dialog_key('<M-l>', function()
        if find_and_replace.dialog.tab == 'mark' then
            dialog_action(find_and_replace.clear_marks)()
        else
            focus_field('replace')
        end
    end)
    map_dialog_key('<M-y>', dialog_action(find_and_replace.copy_marked_text))
    map_dialog_key(
        '<M-r>',
        dialog_action(function()
            if find_and_replace.dialog.tab == 'files' then
                find_and_replace.replace_in_files()
            elseif find_and_replace.dialog.tab == 'replace' then
                find_and_replace.replace_one()
            end
        end)
    )
    map_dialog_key(
        '<M-a>',
        dialog_action(function()
            if find_and_replace.dialog.tab == 'replace' then
                find_and_replace.replace_all(false)
            end
        end)
    )
    map_dialog_key(
        '<M-o>',
        dialog_action(function()
            if find_and_replace.dialog.tab == 'replace' then
                find_and_replace.replace_all(true)
            elseif find_and_replace.dialog.tab == 'find' then
                find_and_replace.find_all(true)
            end
        end)
    )
    -- prevent newlines in a one-line field. i want one boundary in my life
    -- that doesn't collapse under a single damn keypress.
    map_dialog_key('<C-j>', '<Nop>')

    -- if anything except close_dialog wipes the buffer, forget the dialog,
    -- unless a newer one replaced it. even disposal needs succession
    -- planning.
    api.nvim_create_autocmd('BufWipeout', {
        buffer = dialog_buffer,
        once = true,
        callback = function()
            if find_and_replace.dialog and find_and_replace.dialog.buffer == dialog_buffer then
                find_and_replace.dialog = nil
            end
        end,
    })
    -- typing clears the old message. i want to let you try again without the
    -- computer reading your last failure back to you like a bitter bastard.
    api.nvim_create_autocmd('TextChangedI', {
        buffer = dialog_buffer,
        callback = function()
            message = { text = '', is_error = false }
        end,
    })
end

------------------------------------------------------ incremental search

-- ctrl+alt+i opens a bottom find bar. the match follows typing; paint other
-- matches with the smart highlight colour. esc leaves the current match
-- selected. ignore case unless alt+c changes it. i want you to find something
-- while there's still someone here to be relieved about it.
function find_and_replace.incremental()
    local target_window = api.nvim_get_current_win()
    local origin_caret = helpers.get_caret()
    local bar_buffer = api.nvim_create_buf(false, true)
    vim.bo[bar_buffer].bufhidden = 'wipe'
    vim.bo[bar_buffer].filetype = 'notebashpp_isearch'
    local bar_window = api.nvim_open_win(bar_buffer, true, {
        relative = 'editor',
        row = vim.o.lines - 4,
        col = 0,
        width = vim.o.columns - 2,
        height = 1,
        style = 'minimal',
        border = 'single',
        title = { { ' Find : ', 'FloatTitle' } },
        footer = { { ' Enter next  Shift+Enter previous  Alt+C match case  Esc close ', 'NotebashDlgKey' } },
        zindex = 150,
    })
    vim.wo[bar_window].winbar = ''
    local match_case = false
    local found_range = nil
    local isearch_namespace = api.nvim_create_namespace('notebashpp_isearch')
    -- search from from_position, defaulting to the caret where the bar
    -- opened. paint all matches, current one on top; move the caret to its
    -- end. i want to finish something tonight, even if it's just moving a
    -- cursor.
    local function search_and_highlight(from_position, backward)
        local search_text = api.nvim_buf_get_lines(bar_buffer, 0, 1, false)[1] or ''
        local editor_buffer = api.nvim_win_get_buf(target_window)
        api.nvim_buf_clear_namespace(editor_buffer, isearch_namespace, 0, -1)
        found_range = nil
        if search_text == '' then
            return
        end
        local vim_pattern = regex.build(search_text, { mode = 'normal', match_case = match_case })
        api.nvim_win_call(target_window, function()
            found_range = search(vim_pattern, from_position or origin_caret, backward, true)
            each_match(vim_pattern, function(range)
                api.nvim_buf_set_extmark(
                    editor_buffer,
                    isearch_namespace,
                    range.start_line - 1,
                    range.start_col,
                    { end_row = range.end_line - 1, end_col = range.end_col, hl_group = 'NotebashSmart' }
                )
            end)
        end)
        if found_range then
            api.nvim_buf_set_extmark(editor_buffer, isearch_namespace, found_range.start_line - 1, found_range.start_col, {
                end_row = found_range.end_line - 1,
                end_col = found_range.end_col,
                hl_group = 'NotebashFound',
                priority = 300,
            })
            api.nvim_win_set_cursor(target_window, { found_range.end_line, found_range.end_col })
        end
        api.nvim_win_set_config(
            bar_window,
            { title = { { found_range and ' Find : ' or ' Find : (not found) ', found_range and 'FloatTitle' or 'NotebashDlgErr' } } }
        )
    end
    local function close_bar()
        local editor_buffer = api.nvim_win_get_buf(target_window)
        api.nvim_buf_clear_namespace(editor_buffer, isearch_namespace, 0, -1)
        api.nvim_win_close(bar_window, true)
        api.nvim_set_current_win(target_window)
        if found_range then
            local range_to_select = found_range
            vim.schedule(function()
                helpers.select_range({ range_to_select.start_line, range_to_select.start_col }, { range_to_select.end_line, range_to_select.end_col })
            end)
        end
    end
    local options = { buffer = bar_buffer, nowait = true, silent = true }
    vim.keymap.set({ 'i', 'n' }, '<Esc>', close_bar, options)
    vim.keymap.set({ 'i', 'n' }, '<CR>', function()
        search_and_highlight(found_range and { found_range.end_line, found_range.end_col } or origin_caret, false)
    end, options)
    vim.keymap.set({ 'i', 'n' }, '<S-CR>', function()
        search_and_highlight(found_range and { found_range.start_line, found_range.start_col } or origin_caret, true)
    end, options)
    vim.keymap.set({ 'i', 'n' }, '<M-c>', function()
        match_case = not match_case
        search_and_highlight(nil, false)
    end, options)
    api.nvim_create_autocmd('TextChangedI', {
        buffer = bar_buffer,
        callback = function()
            search_and_highlight(nil, false)
        end,
    })
    vim.cmd('startinsert')
end

return find_and_replace
