-- search > bookmark: ctrl+f2 toggles, f2 next, shift+f2 previous, plus
-- bookmark line operations. i flag lines i want to revisit. basically a
-- retirement plan for shit i'll never finish.

local bookmarks = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local bookmark_namespace = api.nvim_create_namespace('notebashpp_bookmarks')

-- bookmark extmarks on one line (1-based). usually none, sometimes one.
-- modest hopes. still excessive.
local function bookmarks_on_line(buffer, line_number)
    return api.nvim_buf_get_extmarks(buffer, bookmark_namespace, { line_number - 1, 0 }, { line_number - 1, -1 }, {})
end

-- a bookmark is an extmark with a dot in the sign column. setting it again on
-- the same line does nothing. i appreciate a computer that admits this before
-- taking more of my life.
function bookmarks.set(buffer, line_number)
    if #bookmarks_on_line(buffer, line_number) == 0 then
        api.nvim_buf_set_extmark(buffer, bookmark_namespace, line_number - 1, 0, { sign_text = '●', sign_hl_group = 'NotebashBookmark', priority = 20 })
    end
end

-- bookmarked line numbers, sorted & unique. edits move extmarks, so two can
-- land on the same line. the seen table removes duplicates. even my
-- unfinished business is running out of space.
function bookmarks.lines(buffer)
    buffer = buffer or api.nvim_get_current_buf()
    local seen_lines, bookmarked_lines = {}, {}
    for _, extmark in ipairs(api.nvim_buf_get_extmarks(buffer, bookmark_namespace, 0, -1, {})) do
        local line_number = extmark[2] + 1
        if not seen_lines[line_number] then
            seen_lines[line_number] = true
            bookmarked_lines[#bookmarked_lines + 1] = line_number
        end
    end
    table.sort(bookmarked_lines)
    return bookmarked_lines
end

-- ctrl+f2: remove every bookmark on the caret line, or add one. commitment,
-- with an escape clause.
function bookmarks.toggle()
    local buffer = api.nvim_get_current_buf()
    local caret_line = helpers.get_caret()[1]
    local marks_here = bookmarks_on_line(buffer, caret_line)
    if #marks_here > 0 then
        for _, extmark in ipairs(marks_here) do
            api.nvim_buf_del_extmark(buffer, bookmark_namespace, extmark[1])
        end
    else
        bookmarks.set(buffer, caret_line)
    end
end

function bookmarks.clear(buffer)
    api.nvim_buf_clear_namespace(buffer or 0, bookmark_namespace, 0, -1)
end

-- f2 next / shift+f2 previous, wrapping at both ends. past the last bookmark
-- comes the first. i wanted progress; i built a damn hamster wheel and gave
-- it keyboard shortcuts.
function bookmarks.jump(direction)
    local bookmarked_lines = bookmarks.lines()
    if #bookmarked_lines == 0 then
        return
    end
    local caret_line = helpers.get_caret()[1]
    local target_line
    if direction > 0 then
        for _, line_number in ipairs(bookmarked_lines) do
            if line_number > caret_line then
                target_line = line_number
                break
            end
        end
        target_line = target_line or bookmarked_lines[1]
    else
        for index = #bookmarked_lines, 1, -1 do
            if bookmarked_lines[index] < caret_line then
                target_line = bookmarked_lines[index]
                break
            end
        end
        target_line = target_line or bookmarked_lines[#bookmarked_lines]
    end
    helpers.move_caret_to({ target_line, 0 })
end

local function bookmarked_line_texts()
    local line_texts = {}
    for _, line_number in ipairs(bookmarks.lines()) do
        line_texts[#line_texts + 1] = helpers.get_line_text(line_number)
    end
    return line_texts
end

-- rewrite the buffer without lines should_delete picks; it receives "is this
-- line bookmarked?". keep one empty line if nothing survives (a buffer can't
-- have zero lines). clear the bookmarks too, and keep the caret on an
-- existing line. i want deletion to mean something, but neovim insists on
-- leaving a small monument to the wasted effort.
local function delete_lines(should_delete)
    local kept_lines = {}
    local is_bookmarked = {}
    for _, line_number in ipairs(bookmarks.lines()) do
        is_bookmarked[line_number] = true
    end
    local all_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    for line_number, line_text in ipairs(all_lines) do
        if not should_delete(is_bookmarked[line_number]) then
            kept_lines[#kept_lines + 1] = line_text
        end
    end
    if #kept_lines == 0 then
        kept_lines = { '' }
    end
    api.nvim_buf_set_lines(0, 0, -1, false, kept_lines)
    bookmarks.clear(0)
    helpers.move_caret_to({ math.min(helpers.get_caret()[1], #kept_lines), 0 })
end

-- copy bookmarked lines as plain text ('v'). trailing '' gives the last line
-- a line break too, so it pastes back as whole lines. even this crap gets
-- closure. i'd love some.
function bookmarks.copy()
    local line_texts = bookmarked_line_texts()
    if #line_texts > 0 then
        table.insert(line_texts, '')
        require('notebashpp.clipboard').set(line_texts, 'v')
    end
end

function bookmarks.cut()
    bookmarks.copy()
    delete_lines(function(is_marked)
        return is_marked
    end)
end

function bookmarks.remove()
    delete_lines(function(is_marked)
        return is_marked
    end)
end

-- remove unmarked lines; keep only the flagged ones. i wish choosing what
-- deserved years of my life had been this fucking straightforward.
function bookmarks.remove_unmarked()
    delete_lines(function(is_marked)
        return not is_marked
    end)
end

-- inverse bookmark: unmarked lines get one, marked lines lose it. i've
-- reversed my priorities. same shit.
function bookmarks.inverse()
    local is_bookmarked = {}
    for _, line_number in ipairs(bookmarks.lines()) do
        is_bookmarked[line_number] = true
    end
    bookmarks.clear(0)
    for line_number = 1, helpers.count_lines() do
        if not is_bookmarked[line_number] then
            bookmarks.set(0, line_number)
        end
    end
end

-- replace each bookmarked line with clipboard text, bottom to top. a
-- multiline paste then can't push later bookmarks out of place. i can prevent
-- this particular collapse. apparently that's my talent.
function bookmarks.paste_replace()
    local clipboard_lines = require('notebashpp.clipboard').get()
    local bookmarked_lines = bookmarks.lines()
    for index = #bookmarked_lines, 1, -1 do
        api.nvim_buf_set_lines(0, bookmarked_lines[index] - 1, bookmarked_lines[index], false, clipboard_lines)
    end
end

return bookmarks
