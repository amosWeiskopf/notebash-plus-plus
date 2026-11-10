-- compareplus 1.1.0 on neovim's diff mode, with the same default keys:
-- ctrl+alt+1 set as first, ctrl+alt+c compare, ctrl+alt+x clear active,
-- ctrl+alt+d diff since last save, ctrl+alt+m compare to clipboard,
-- ctrl+alt+g git diff, ctrl+alt+v svn diff, ctrl+alt+n compare selections,
-- ctrl+alt+shift+c / n find unique lines, alt+pgup / alt+pgdn previous / next
-- difference, ctrl+alt+pgup / pgdn first / last difference. i want to know
-- where it all went wrong. apparently i need a plugin.

local compare_documents = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local document_tabs = require('notebashpp.document_tabs')

-- the set-as-first document & on-screen comparison live on the module table
-- so a code reload keeps them. my mistakes also refuse to die.
compare_documents.first = nil
compare_documents.active = nil

function compare_documents.set_first()
    compare_documents.first = api.nvim_get_current_buf()
    helpers.notify('Compare: ' .. document_tabs.name(compare_documents.first) .. ' set as first to compare')
end

-- a throwaway read-only buffer of lines to compare against. wiped when hidden
-- (i'd love that option). pcall sets the name because another buffer may
-- already have it. absolutely no reason to die over a damn name.
local function create_scratch_buffer(buffer_name, lines, filetype)
    local scratch_buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(scratch_buffer, 0, -1, false, lines)
    vim.bo[scratch_buffer].bufhidden = 'wipe'
    vim.bo[scratch_buffer].filetype = filetype or ''
    vim.bo[scratch_buffer].modifiable = false
    pcall(api.nvim_buf_set_name, scratch_buffer, buffer_name)
    return scratch_buffer
end

-- show `other_buffer` left of the current document and diff both. put the
-- caret on the first difference & resume typing. this is notepad++, and i
-- have wasted enough of my life escaping normal mode.
local function show_side_by_side(other_buffer)
    compare_documents.clear()
    local main_window = api.nvim_get_current_win()
    vim.cmd('leftabove vsplit')
    local other_window = api.nvim_get_current_win()
    api.nvim_win_set_buf(other_window, other_buffer)
    vim.cmd('diffthis')
    api.nvim_set_current_win(main_window)
    vim.cmd('diffthis')
    compare_documents.active = { main = main_window, other = other_window }
    vim.cmd('normal! gg]c')
    vim.cmd('startinsert')
end

-- compare with "first", else the left tab, else the right tab (compareplus
-- default_compare_to_prev=1). either way, consume the "first" mark. basically
-- another distinction i couldn't hold on to.
function compare_documents.compare()
    local current_buffer = api.nvim_get_current_buf()
    local other_buffer = compare_documents.first
    if not other_buffer or other_buffer == current_buffer or not api.nvim_buf_is_valid(other_buffer) then
        local tab_order = document_tabs.sync()
        for index, buffer in ipairs(tab_order) do
            if buffer == current_buffer then
                other_buffer = tab_order[index - 1] or tab_order[index + 1]
            end
        end
    end
    compare_documents.first = nil
    if not other_buffer then
        return helpers.warn('Compare: open a second document first')
    end
    show_side_by_side(other_buffer)
end

-- clear active: turn diff off everywhere, close our other-side window (never
-- the last window, neovim needs something to live for), return home.
function compare_documents.clear()
    if not compare_documents.active then
        vim.cmd('diffoff!')
        return
    end
    local comparison = compare_documents.active
    compare_documents.active = nil
    vim.cmd('diffoff!')
    if api.nvim_win_is_valid(comparison.other) and #api.nvim_list_wins() > 1 then
        api.nvim_win_close(comparison.other, true)
    end
    if api.nvim_win_is_valid(comparison.main) then
        api.nvim_set_current_win(comparison.main)
    end
end

-- diff since last save: compare the document with its own file on disk. proof
-- i was better off before i started. in writing, this time.
function compare_documents.last_save()
    local file_path = api.nvim_buf_get_name(0)
    if file_path == '' or vim.fn.filereadable(file_path) == 0 then
        return helpers.warn('Compare: the document has never been saved')
    end
    show_side_by_side(create_scratch_buffer(file_path .. ' (saved)', vim.fn.readfile(file_path), vim.bo.filetype))
end

function compare_documents.clipboard()
    local clipboard_lines = require('notebashpp.clipboard').get()
    show_side_by_side(create_scratch_buffer('Clipboard', clipboard_lines, vim.bo.filetype))
end

-- git diff: compare with head using the repository root & relative path. find
-- where i fucked up, with absolutely precise directions.
function compare_documents.git()
    local file_path = api.nvim_buf_get_name(0)
    if file_path == '' then
        return
    end
    local file_directory = vim.fn.fnamemodify(file_path, ':h')
    local repository_root = vim.trim(vim.fn.system({ 'git', '-C', file_directory, 'rev-parse', '--show-toplevel' }))
    if vim.v.shell_error ~= 0 then
        return helpers.warn('Compare: not in a Git repository')
    end
    local relative_path = file_path:sub(#repository_root + 2)
    local committed_lines = vim.fn.systemlist({ 'git', '-C', repository_root, 'show', 'HEAD:' .. relative_path })
    if vim.v.shell_error ~= 0 then
        return helpers.warn('Compare: file is not in the last commit')
    end
    show_side_by_side(create_scratch_buffer(file_path .. ' (HEAD)', committed_lines, vim.bo.filetype))
end

-- svn diff: `svn cat` gives the base copy. even my regrets use legacy tools.
function compare_documents.svn()
    if vim.fn.executable('svn') == 0 then
        return helpers.warn('Compare: svn is not installed')
    end
    local file_path = api.nvim_buf_get_name(0)
    -- '--' so a name starting with - stays a name, and a final @ so an @ in
    -- the name isn't read as a revision. even my file names need a lawyer.
    local base_lines = vim.fn.systemlist({ 'svn', 'cat', '--', file_path .. '@' })
    if vim.v.shell_error ~= 0 then
        return helpers.warn('Compare: file is not under SVN')
    end
    show_side_by_side(create_scratch_buffer(file_path .. ' (SVN)', base_lines, vim.bo.filetype))
end

-- compare selections across documents. the first press remembers the
-- selection; the second, in another document, opens both side by side in a
-- new tab page. i need two presses to confront my mistakes. one was
-- apparently too merciful.
local previous_selection = nil
function compare_documents.selections()
    local selection = helpers.get_selection()
    if not selection then
        return helpers.warn('Compare: select text first')
    end
    local selected_lines = helpers.get_text_in_range(selection)
    if not previous_selection or previous_selection.buffer == api.nvim_get_current_buf() then
        previous_selection = { buffer = api.nvim_get_current_buf(), lines = selected_lines }
        helpers.collapse_selection()
        return helpers.notify('Compare: now select the text to compare it with in the other document, then press the key again')
    end
    local first_selection_buffer = create_scratch_buffer('Selection 1', previous_selection.lines)
    local second_selection_buffer = create_scratch_buffer('Selection 2', selected_lines)
    previous_selection = nil
    vim.cmd('tabnew')
    api.nvim_win_set_buf(0, first_selection_buffer)
    vim.cmd('diffthis')
    vim.cmd('vsplit')
    api.nvim_win_set_buf(0, second_selection_buffer)
    vim.cmd('diffthis')
end

-- find unique lines: highlight lines each document has and the other lacks
-- with diffadd in both. use "first" if set, else a neighbouring tab. things
-- found nowhere else. mostly my own crap, but i keep looking.
local unique_lines_namespace = api.nvim_create_namespace('notebashpp_unique')
function compare_documents.unique()
    local current_buffer = api.nvim_get_current_buf()
    local other_buffer
    local tab_order = document_tabs.sync()
    for index, buffer in ipairs(tab_order) do
        if buffer == current_buffer then
            other_buffer = compare_documents.first or tab_order[index - 1] or tab_order[index + 1]
        end
    end
    if not other_buffer then
        return helpers.warn('Compare: open a second document first')
    end
    local function line_set(buffer)
        local lines_present = {}
        for _, line_text in ipairs(api.nvim_buf_get_lines(buffer, 0, -1, false)) do
            lines_present[line_text] = true
        end
        return lines_present
    end
    local current_lines, other_lines = line_set(current_buffer), line_set(other_buffer)
    local unique_count = 0
    for _, buffer_and_rival in ipairs({ { current_buffer, other_lines }, { other_buffer, current_lines } }) do
        local buffer, rival_lines = buffer_and_rival[1], buffer_and_rival[2]
        api.nvim_buf_clear_namespace(buffer, unique_lines_namespace, 0, -1)
        for line_number, line_text in ipairs(api.nvim_buf_get_lines(buffer, 0, -1, false)) do
            if not rival_lines[line_text] then
                unique_count = unique_count + 1
                api.nvim_buf_set_extmark(buffer, unique_lines_namespace, line_number - 1, 0, { line_hl_group = 'DiffAdd' })
            end
        end
    end
    helpers.notify(('Compare: %d unique line%s'):format(unique_count, unique_count == 1 and '' or 's'))
end

local function is_in_diff_mode()
    return vim.wo.diff
end

-- alt+pgup / alt+pgdn: previous / next difference, caret at line start. pcall
-- handles no next difference. i'd love to run out of mistakes.
function compare_documents.next(direction)
    if not is_in_diff_mode() then
        return
    end
    pcall(vim.api.nvim_command, 'normal! ' .. (direction > 0 and ']c' or '[c'))
    helpers.move_caret_to({ helpers.get_caret()[1], 0 })
end

-- ctrl+alt+pgup / pgdn: first / last difference. go to the file's top /
-- bottom and find the nearest one from there. my failures have an index.
function compare_documents.edge(direction)
    if not is_in_diff_mode() then
        return
    end
    if direction < 0 then
        vim.cmd('normal! gg')
        pcall(vim.api.nvim_command, 'normal! ]c')
    else
        vim.cmd('normal! G')
        pcall(vim.api.nvim_command, 'normal! [c')
    end
    helpers.move_caret_to({ helpers.get_caret()[1], 0 })
end

return compare_documents
