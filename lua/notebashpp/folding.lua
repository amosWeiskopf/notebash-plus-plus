-- view > fold all (alt+0), unfold all (alt+shift+0), fold / unfold current
-- level (ctrl+alt+f, ctrl+alt+shift+f), fold / unfold level 1 to 8 (alt+1 to
-- 8, alt+shift+1 to 8), and hide lines (alt+h). basically i built an entire
-- menu for avoidance. therapy costs money.

local folding = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local hidden_lines_namespace = api.nvim_create_namespace('notebashpp_hidden')

-- folds follow the syntax tree if neovim has a treesitter parser for the
-- language; otherwise use indentation. when understanding fails, count
-- spaces. basically my entire career.
function folding.setup_buffer(buffer)
    local language = vim.treesitter.language.get_lang(vim.bo[buffer].filetype)
    local has_parser = false
    if language then
        local call_ok, parser_added = pcall(vim.treesitter.language.add, language)
        has_parser = call_ok and parser_added == true
    end
    for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
        if has_parser then
            vim.wo[window].foldmethod = 'expr'
            vim.wo[window].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
        else
            vim.wo[window].foldmethod = 'indent'
        end
    end
end

-- run `action`, then restore the caret: folding moves it, notepad++ doesn't.
-- pcall in case its line is gone. even the caret has abandonment issues.
local function keep_caret_while(action)
    local caret_position = helpers.get_caret()
    action()
    pcall(api.nvim_win_set_cursor, 0, caret_position)
end

function folding.fold_all()
    keep_caret_while(function()
        vim.cmd('normal! zM')
    end)
end

-- unfold all restores hidden lines too, like notepad++. shit comes back.
function folding.unfold_all()
    keep_caret_while(function()
        vim.cmd('normal! zR')
    end)
    folding.show_all()
end

-- pcall on both: no fold under the caret makes neovim complain. notepad++
-- quietly does nothing. i want that level of inner death.
function folding.fold_current()
    pcall(vim.api.nvim_command, 'normal! zc')
end

function folding.unfold_current()
    pcall(vim.api.nvim_command, 'normal! zO')
end

-- fold level n: close every fold at depth n, keep shallower ones open.
-- selective cowardice.
function folding.fold_level(level)
    keep_caret_while(function()
        vim.wo.foldlevel = level - 1
    end)
end

-- unfold level n: open everything down to depth n; leave already-open folds
-- open. i refuse to do the same damn work twice (outside my career).
function folding.unfold_level(level)
    keep_caret_while(function()
        vim.wo.foldlevel = math.max(vim.wo.foldlevel, level)
    end)
end

------------------------------------------------------------- hide lines

-- alt+h hides selected lines (or the caret line). a margin marker shows
-- where; alt+h on that line, or unfold all, brings them back. an extmark
-- (conceal_lines) conceals them. all text remains and is saved. absolutely
-- nothing is gone. i wrote a hiding place that keeps receipts.
function folding.hide()
    local first_line, last_line = helpers.selected_line_range()
    local buffer = api.nvim_get_current_buf()
    -- marker line, no selection: unhide. avoidance has expired.
    if not helpers.get_selection() then
        for _, extmark in ipairs(api.nvim_buf_get_extmarks(buffer, hidden_lines_namespace, { first_line - 1, 0 }, { first_line - 1, -1 }, { details = true })) do
            if extmark[4].sign_text then
                folding.unhide(extmark[1])
                return
            end
        end
    end
    -- refuse to hide every line: nothing would remain to look at or hold the
    -- marker. apparently complete surrender isn't supported.
    local line_count = helpers.count_lines()
    if first_line == 1 and last_line == line_count then
        return
    end
    local conceal_id = api.nvim_buf_set_extmark(buffer, hidden_lines_namespace, first_line - 1, 0, { end_row = last_line - 1, end_col = 0, conceal_lines = '' })
    -- marker just above the hidden block (or below). even buried crap needs
    -- an address.
    local marker_line = first_line > 1 and first_line - 1 or last_line + 1
    api.nvim_buf_set_extmark(buffer, hidden_lines_namespace, marker_line - 1, 0, {
        sign_text = '+',
        sign_hl_group = 'NotebashHidden',
        priority = 30,
    })
    -- store each conceal id in a buffer variable, keyed by marker line number
    -- as a string. read, change, write back: vim.b returns copies. changing a
    -- copy does absolutely nothing. i call that a working day.
    vim.b[buffer].notebashpp_hidden = vim.b[buffer].notebashpp_hidden or {}
    local hidden_ranges = vim.b[buffer].notebashpp_hidden
    hidden_ranges[tostring(marker_line)] = conceal_id
    vim.b[buffer].notebashpp_hidden = hidden_ranges
    helpers.move_caret_to({ marker_line, 0 })
end

-- unhide a marker's block: find its line, look up its conceal, delete both.
-- the lines return as if nothing happened. i'd love that for a few years of
-- my life (no api for this, apparently).
function folding.unhide(marker_id)
    local buffer = api.nvim_get_current_buf()
    local marker_position = api.nvim_buf_get_extmark_by_id(buffer, hidden_lines_namespace, marker_id, {})
    local hidden_ranges = vim.b[buffer].notebashpp_hidden or {}
    local marker_key = marker_position[1] and tostring(marker_position[1] + 1)
    local conceal_id = marker_key and hidden_ranges[marker_key]
    if conceal_id then
        api.nvim_buf_del_extmark(buffer, hidden_lines_namespace, conceal_id)
        hidden_ranges[marker_key] = nil
        vim.b[buffer].notebashpp_hidden = hidden_ranges
    end
    api.nvim_buf_del_extmark(buffer, hidden_lines_namespace, marker_id)
end

-- restore every hidden line in the current buffer, remove the markers. so
-- much for repression.
function folding.show_all()
    api.nvim_buf_clear_namespace(0, hidden_lines_namespace, 0, -1)
    vim.b.notebashpp_hidden = {}
end

---------------------------------------------------------- session state

-- the session scan reads every line once (about 4 ms per 50,000 lines).
-- bigger documents keep their fold level, lose their closed folds. basically
-- we save time by forgetting your work.
local largest_scanned_line_count = 100000
-- look this many lines up and down for a restored fold's moved first line.
-- even my patience has a search limit.
local moved_fold_search_distance = 200

-- a short line fingerprint lets the session recognise a fold's first line
-- without storing the text itself. i want recognition without baggage. good
-- luck with that.
local function line_fingerprint(buffer, line_number)
    return vim.fn.sha256(helpers.get_line_text(line_number, buffer)):sub(1, 16)
end

local function can_scan_folds(window)
    return vim.wo[window].foldenable and api.nvim_buf_line_count(api.nvim_win_get_buf(window)) <= largest_scanned_line_count
end

-- save the window's fold level & its outermost closed folds for the session,
-- as { line, end_line, fingerprint }. the inner ones can bury themselves.
function folding.session_state(window)
    local fold_state = { level = vim.wo[window].foldlevel }
    if not can_scan_folds(window) then
        return fold_state
    end
    local buffer = api.nvim_win_get_buf(window)
    local closed_folds = {}
    api.nvim_win_call(window, function()
        local line_number, last_line = 1, api.nvim_buf_line_count(buffer)
        while line_number <= last_line do
            local fold_start = vim.fn.foldclosed(line_number)
            if fold_start == -1 then
                line_number = line_number + 1
            else
                local fold_end = vim.fn.foldclosedend(line_number)
                closed_folds[#closed_folds + 1] = { line = fold_start, end_line = fold_end, fingerprint = line_fingerprint(buffer, fold_start) }
                line_number = fold_end + 1
            end
        end
    end)
    if #closed_folds > 0 then
        fold_state.closed = closed_folds
    end
    return fold_state
end

-- find the saved fold's start: use its old line if the text still matches,
-- else the nearest matching line within the search distance, else nil.
-- changed text leaves the fold open. apparently even this bastard needs
-- something familiar before it can shut down.
local function find_saved_fold_start(buffer, saved_fold)
    local line_count = api.nvim_buf_line_count(buffer)
    for distance = 0, moved_fold_search_distance do
        for _, candidate_line in ipairs({ saved_fold.line - distance, saved_fold.line + distance }) do
            if candidate_line >= 1 and candidate_line <= line_count and line_fingerprint(buffer, candidate_line) == saved_fold.fingerprint then
                return candidate_line
            end
        end
    end
end

local function fold_command(command_name, line_number)
    pcall(api.nvim_cmd, { cmd = command_name, range = { line_number } }, {})
end

-- close one level at a time until the closed fold at fold_start reaches
-- fold_end. if we go too far (a fold starting above), open it again. i wish
-- failure was always this reversible.
local function close_fold_at(fold_start, fold_end)
    for _ = 1, 20 do
        local closed_start = vim.fn.foldclosed(fold_start)
        if closed_start ~= -1 and closed_start < fold_start then
            fold_command('foldopen', fold_start)
            return
        end
        if closed_start == fold_start and vim.fn.foldclosedend(fold_start) >= fold_end then
            return
        end
        if vim.fn.foldlevel(fold_start) == 0 then
            return
        end
        local closed_end = vim.fn.foldclosedend(fold_start)
        fold_command('foldclose', fold_start)
        if vim.fn.foldclosed(fold_start) == closed_start and vim.fn.foldclosedend(fold_start) == closed_end then
            return
        end
    end
end

-- restore a window's state from folding.session_state(): set its fold level,
-- open folds the session did not have closed, then close the saved ones.
-- return false if a saved fold has no fold to close yet (treesitter folds can
-- still be computing). basically we're ready to remember your work, and the
-- damn editor hasn't finished deciding what exists.
function folding.restore_session_state(window, fold_state)
    if type(fold_state) ~= 'table' then
        return true
    end
    if type(fold_state.level) == 'number' then
        vim.wo[window].foldlevel = fold_state.level
    end
    if not can_scan_folds(window) then
        return true
    end
    local buffer = api.nvim_win_get_buf(window)
    local wanted_fold_ends = {}
    for _, saved_fold in ipairs(type(fold_state.closed) == 'table' and fold_state.closed or {}) do
        if
            type(saved_fold) == 'table'
            and type(saved_fold.line) == 'number'
            and type(saved_fold.end_line) == 'number'
            and type(saved_fold.fingerprint) == 'string'
        then
            local fold_start = find_saved_fold_start(buffer, saved_fold)
            if fold_start then
                wanted_fold_ends[fold_start] = fold_start + saved_fold.end_line - saved_fold.line
            end
        end
    end
    local all_found = true
    api.nvim_win_call(window, function()
        -- expression folds (treesitter) can be stale in a window never drawn.
        -- zx recomputes them; we restore the open/closed state it resets
        -- below. absolutely no audience, and already falling apart. i
        -- understand.
        if vim.wo[window].foldmethod == 'expr' then
            vim.cmd('normal! zx')
        end
        local line_number, last_line = 1, api.nvim_buf_line_count(buffer)
        while line_number <= last_line do
            local fold_start = vim.fn.foldclosed(line_number)
            if fold_start == -1 then
                line_number = line_number + 1
            elseif wanted_fold_ends[fold_start] then
                line_number = vim.fn.foldclosedend(line_number) + 1
            else
                -- open it & check the same place again: inner folds may still
                -- be closed. even this shit has unresolved shit inside.
                local fold_end = vim.fn.foldclosedend(line_number)
                fold_command('foldopen', fold_start)
                if vim.fn.foldclosed(fold_start) == fold_start then
                    line_number = fold_end + 1
                else
                    line_number = fold_start
                end
            end
        end
        for fold_start, fold_end in pairs(wanted_fold_ends) do
            close_fold_at(fold_start, fold_end)
            if vim.fn.foldclosed(fold_start) == -1 then
                all_found = false
            end
        end
    end)
    return all_found
end

return folding
