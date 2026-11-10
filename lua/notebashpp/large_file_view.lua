-- files bigger than large_file_megabytes (32 mb unless user.lua says
-- otherwise) open read-only, with only the screen's lines loaded. a 20 gb log
-- opens at once, scrolls, jumps to any line & searches without loading the
-- whole bastard into memory. lines longer than 1 mb show their first
-- megabyte. file > load whole file for editing reads files up to 1 gb the
-- normal way. i want to edit a log, apparently having a finite life wasn't
-- enough of a problem.

local large_file_view = {}
local api = vim.api
local file_index = require('notebashpp.file_index')
local helpers = require('notebashpp.helpers')

large_file_view.states = large_file_view.states or {}
local states = large_file_view.states

local namespace = api.nvim_create_namespace('notebashpp_large_file')

-- longest piece of one line shown; mark the rest as cut. even this screen has
-- a limit for how much crap it takes.
local LONGEST_SHOWN_LINE = 20000
large_file_view.LARGEST_FULL_LOAD = 1024 * 1024 * 1024

local function window_for(state)
    local current_window = api.nvim_get_current_win()
    if api.nvim_win_get_buf(current_window) == state.buffer then
        return current_window
    end
    local window = vim.fn.bufwinid(state.buffer)
    return window ~= -1 and window or nil
end

local function human_size(bytes)
    local units = { 'bytes', 'KB', 'MB', 'GB', 'TB' }
    local unit = 1
    while bytes >= 1024 and unit < #units do
        bytes = bytes / 1024
        unit = unit + 1
    end
    return unit == 1 and ('%d bytes'):format(bytes) or ('%.1f %s'):format(bytes, units[unit])
end
large_file_view.human_size = human_size

local function thousands(number)
    local grouped = tostring(number):reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (grouped:gsub('^,', ''))
end

local function apply_window_options(state, window)
    local number_width = math.max(4, #tostring(math.max(state.index.record_count, 1)) + 1)
    for option_name, value in pairs({
        wrap = true,
        number = false,
        relativenumber = false,
        signcolumn = 'no',
        foldcolumn = '0',
        -- v:lua first turns the called module into a vim dictionary. this
        -- module's tables have number keys, so a separate small module draws
        -- the numbers. basically i need another module to count. what a
        -- terrific use of my remaining years.
        statuscolumn = '%=%{v:lua.require("notebashpp.large_file_line_number").text()} ',
        numberwidth = number_width,
        list = false,
        spell = false,
        scrolloff = 0,
    }) do
        api.nvim_set_option_value(option_name, value, { scope = 'local', win = window })
    end
end

-- fill from `top_line` down, with as many lines as fit when wrapped. i want a
-- screenful. the rest of this shit can wait.
function large_file_view.render(state, caret)
    local window = window_for(state)
    if not window or not api.nvim_buf_is_valid(state.buffer) then
        return
    end
    local index = state.index
    local height = api.nvim_win_get_height(window)
    state.top_line = math.max(0, math.min(state.top_line, math.max(0, index.record_count - 1)))
    local text_width = math.max(10, api.nvim_win_get_width(window) - (vim.fn.getwininfo(window)[1] or { textoff = 6 }).textoff)
    local lines, cut_lines = {}, {}
    local screen_rows = 0
    local line_number = state.top_line
    while screen_rows < height and line_number < index.record_count do
        local text, was_cut = index:record(line_number)
        text = text or ''
        if #text > LONGEST_SHOWN_LINE then
            text = text:sub(1, LONGEST_SHOWN_LINE + vim.str_utf_start(text, LONGEST_SHOWN_LINE + 1))
            was_cut = true
        end
        lines[#lines + 1] = text
        if was_cut then
            cut_lines[#lines] = true
        end
        screen_rows = screen_rows + math.max(1, math.ceil(api.nvim_strwidth(text) / text_width))
        line_number = line_number + 1
    end
    if #lines == 0 then
        lines = { '' }
    end
    state.shown_lines = #lines
    local buffer = state.buffer
    vim.bo[buffer].modifiable = true
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].modified = false
    api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    for cut_line in pairs(cut_lines) do
        api.nvim_buf_set_extmark(buffer, namespace, cut_line - 1, 0, {
            virt_text = { { ' [line continues]', 'NotebashMenuHint' } },
            virt_text_pos = 'eol',
        })
    end
    if state.match then
        local match_line = state.match.line - state.top_line
        if match_line >= 0 and match_line < #lines then
            local line_text = lines[match_line + 1]
            local match_end = math.min(#line_text, state.match.column + state.match.length)
            if state.match.column < #line_text then
                api.nvim_buf_set_extmark(buffer, namespace, match_line, state.match.column, { end_col = match_end, hl_group = 'NotebashFound' })
            end
        end
    end
    if caret then
        local caret_line = math.max(1, math.min(caret[1], #lines))
        pcall(api.nvim_win_set_cursor, window, { caret_line, math.min(caret[2], #lines[caret_line]) })
    end
    -- grow the line number column as counting finds more lines. the debt
    -- grows.
    local wanted_width = math.max(4, #tostring(math.max(index.record_count, 1)) + 1)
    if vim.wo[window].numberwidth ~= wanted_width then
        apply_window_options(state, window)
    end
    vim.cmd('redrawstatus')
end

local function render_soon(state)
    if state.render_scheduled then
        return
    end
    state.render_scheduled = true
    vim.schedule(function()
        state.render_scheduled = false
        if states[state.buffer] == state then
            local window = window_for(state)
            large_file_view.render(state, window and api.nvim_win_get_cursor(window) or nil)
        end
    end)
end

local function caret_of(state)
    local window = window_for(state)
    return window and api.nvim_win_get_cursor(window) or { 1, 0 }
end

-- scroll `line_step` lines; keep the caret on screen. i lose enough shit.
local function scroll(state, line_step, caret)
    state.top_line = state.top_line + line_step
    large_file_view.render(state, caret or caret_of(state))
end

-- show `line_number` (0-based) a few lines from the top, caret at byte
-- `column`. one small place in this mess where i know where i am.
local function show_line(state, line_number, column)
    state.top_line = math.max(0, line_number - 3)
    large_file_view.render(state, { line_number - state.top_line + 1, column or 0 })
end

function large_file_view.go_to_line(state)
    local suffix = state.index.complete and '' or ' so far'
    local current_line = state.top_line + caret_of(state)[1]
    local answer = helpers.ask(('Go to line (1 to %d%s): '):format(state.index.record_count, suffix), tostring(current_line))
    local line_number = tonumber(answer)
    if line_number then
        show_line(state, math.max(0, math.min(math.floor(line_number), state.index.record_count) - 1), 0)
    end
end

function large_file_view.find_next(state)
    local needle = state.last_search
    if not needle or needle == '' then
        return large_file_view.find(state)
    end
    local caret = caret_of(state)
    local caret_line = state.top_line + caret[1] - 1
    local from = state.index:record_offset(caret_line) + caret[2] + 1
    local function on_found(offset)
        state.cancel_search = nil
        if states[state.buffer] ~= state then
            return
        end
        if not offset then
            return helpers.notify(('Cannot find "%s".'):format(needle))
        end
        if not state.index.complete and offset >= state.index.indexed_bytes then
            vim.defer_fn(function()
                on_found(offset)
            end, 200)
            return
        end
        local line_number = state.index:record_at_offset(offset)
        local column = offset - state.index:record_offset(line_number)
        state.match = { line = line_number, column = column, length = #needle }
        show_line(state, line_number, column)
    end
    if state.cancel_search then
        state.cancel_search()
    end
    state.cancel_search = state.index:search(needle, from, true, on_found)
end

function large_file_view.find(state)
    local needle = helpers.ask('Find: ', state.last_search or '')
    if needle == '' then
        return
    end
    state.last_search = needle
    large_file_view.find_next(state)
end

-- read the whole file normally for editing. there goes the memory.
function large_file_view.load_fully(state)
    if state.index.size > large_file_view.LARGEST_FULL_LOAD then
        return helpers.warn(
            ('%s is %s. Loading it whole needs more memory than is safe; files up to 1 GB can be loaded.'):format(
                vim.fs.basename(state.path),
                human_size(state.index.size)
            )
        )
    end
    local question = ('Load all %s of %s for editing? Neovim will use about %s of memory, and big files are slow to edit.'):format(
        human_size(state.index.size),
        vim.fs.basename(state.path),
        human_size(state.index.size * 2)
    )
    if vim.fn.confirm(question, '&Yes\n&No', 2, 'Question') ~= 1 then
        return
    end
    require('notebashpp.special_views').reopen(state.buffer, 'load_fully')
end

local function set_view_keys(buffer)
    local function map(keys, action)
        vim.keymap.set({ 'n', 'x', 's' }, keys, function()
            local state = states[buffer]
            if state then
                action(state)
            end
        end, { buffer = buffer, nowait = true, silent = true })
    end
    map('<Down>', function(state)
        local caret = caret_of(state)
        if caret[1] >= state.shown_lines - 1 and state.top_line + caret[1] < state.index.record_count then
            scroll(state, 1, caret)
        else
            vim.cmd('normal! j')
        end
    end)
    map('<Up>', function(state)
        local caret = caret_of(state)
        if caret[1] == 1 and state.top_line > 0 then
            scroll(state, -1, caret)
        else
            vim.cmd('normal! k')
        end
    end)
    map('<PageDown>', function(state)
        scroll(state, math.max(1, state.shown_lines - 1), { 1, 0 })
    end)
    map('<PageUp>', function(state)
        local window = window_for(state)
        scroll(state, -math.max(1, (window and api.nvim_win_get_height(window) or 20) - 1), { 1, 0 })
    end)
    map('<C-Home>', function(state)
        state.top_line = 0
        large_file_view.render(state, { 1, 0 })
    end)
    map('<C-End>', function(state)
        local window = window_for(state)
        local height = window and api.nvim_win_get_height(window) or 20
        state.top_line = math.max(0, state.index.record_count - height)
        large_file_view.render(state, { state.index.record_count, 0 })
        local last_shown = state.shown_lines
        large_file_view.render(state, { last_shown, 0 })
        if not state.index.complete then
            helpers.notify(('Still counting lines (%d%%); this is the end so far.'):format(state.index:percent_done()))
        end
    end)
    map('<ScrollWheelDown>', function(state)
        scroll(state, 3)
    end)
    map('<ScrollWheelUp>', function(state)
        scroll(state, -3)
    end)
    map('<C-g>', large_file_view.go_to_line)
    map('<C-f>', large_file_view.find)
    map('<F3>', large_file_view.find_next)
    map('<C-h>', function(state)
        helpers.warn(('Replace needs editing. %s is shown read-only; File > Load Whole File loads it for editing.'):format(vim.fs.basename(state.path)))
    end)
    map('<C-a>', function(state)
        helpers.warn(
            ('Select All is off here: %s is %s. Shift+arrows select what is on screen.'):format(vim.fs.basename(state.path), human_size(state.index.size))
        )
    end)
end

function large_file_view.open(buffer, path)
    local existing = states[buffer]
    if existing then
        existing.index:stop()
    end
    local state = existing or { buffer = buffer, path = path, top_line = 0 }
    state.match = nil
    local index, problem = file_index.open(path, {
        on_progress = function()
            if states[buffer] == state then
                render_soon(state)
            end
        end,
    })
    if not index then
        vim.bo[buffer].buftype = 'nofile'
        api.nvim_buf_set_lines(buffer, 0, -1, false, { 'Cannot open ' .. path .. ': ' .. tostring(problem) })
        vim.bo[buffer].modifiable = false
        return
    end
    state.index = index
    local sample = index:read_bytes(0, 65536)
    state.line_ending = sample:find('\r\n', 1, true) and 'Windows (CR LF)' or 'Unix (LF)'
    states[buffer] = state
    index:start()
    vim.b[buffer].notebashpp_special_view = 'large_file_view'
    vim.bo[buffer].buftype = 'nowrite'
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undolevels = -1
    vim.bo[buffer].modeline = false
    vim.bo[buffer].modifiable = false
    if existing then
        return
    end
    set_view_keys(buffer)
    local augroup = api.nvim_create_augroup('notebashpp_large_file_' .. buffer, { clear = true })
    -- insert mode carried over from a text document makes every key a refused
    -- edit here. i already get enough rejection for free.
    api.nvim_create_autocmd('BufEnter', {
        group = augroup,
        buffer = buffer,
        callback = function()
            vim.cmd.stopinsert()
        end,
    })
    api.nvim_create_autocmd('BufWinEnter', {
        group = augroup,
        buffer = buffer,
        callback = function()
            apply_window_options(states[buffer], api.nvim_get_current_win())
            render_soon(states[buffer])
        end,
    })
    api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        group = augroup,
        buffer = buffer,
        callback = function()
            local current = states[buffer]
            if current then
                current.index:stop()
                if current.cancel_search then
                    current.cancel_search()
                end
            end
            states[buffer] = nil
            pcall(api.nvim_del_augroup_by_id, augroup)
        end,
    })
    local window = vim.fn.bufwinid(buffer)
    if window ~= -1 then
        apply_window_options(state, window)
    end
    render_soon(state)
end

function large_file_view.status(buffer)
    local state = states[buffer]
    if not state then
        return nil
    end
    local window = window_for(state)
    local caret = window and api.nvim_win_get_cursor(window) or { 1, 0 }
    local counting = state.index.complete and '' or ('  counting %d%%'):format(state.index:percent_done())
    return {
        language = 'Large file, read-only',
        position = ('Ln : %s of %s    Col : %d%s'):format(thousands(state.top_line + caret[1]), thousands(state.index.record_count), caret[2] + 1, counting),
        length = ('  size : %s  '):format(human_size(state.index.size)),
        line_ending = state.line_ending,
    }
end

function large_file_view.session_state(buffer)
    local state = states[buffer]
    return state and { top_line = state.top_line } or nil
end

function large_file_view.restore_session_state(saved, document)
    if not document.path or vim.fn.filereadable(document.path) == 0 then
        return nil
    end
    local buffer = vim.fn.bufadd(document.path)
    vim.bo[buffer].buflisted = true
    vim.fn.bufload(buffer)
    local state = states[buffer]
    if state and type(saved) == 'table' and tonumber(saved.top_line) then
        state.top_line = tonumber(saved.top_line)
        render_soon(state)
    end
    return buffer
end

function large_file_view.current_state()
    return states[api.nvim_get_current_buf()]
end

function large_file_view.run(action_name, ...)
    local state = large_file_view.current_state()
    if not state then
        return helpers.warn('This works in a large file opened read-only.')
    end
    return large_file_view[action_name](state, ...)
end

function large_file_view._unload()
    if large_file_view.key_listener then
        vim.on_key(nil, large_file_view.key_listener)
        large_file_view.key_listener = nil
    end
end

function large_file_view.setup()
    -- typing in the read-only view explains why nothing happens, at most
    -- every few seconds, replacing neovim's "cannot make changes" error. even
    -- failure could please stop repeating itself.
    large_file_view._unload()
    local last_notice = 0
    large_file_view.key_listener = vim.on_key(function(_, typed)
        if not typed or typed == '' or not states[api.nvim_get_current_buf()] or api.nvim_get_mode().mode ~= 'n' then
            return
        end
        local first_byte = typed:byte(1)
        local is_character = (first_byte >= 32 and first_byte < 127 and #typed == 1)
            or (first_byte >= 194 and first_byte <= 244 and vim.fn.strchars(typed) == 1)
        if not is_character then
            return
        end
        if vim.uv.now() - last_notice > 3000 then
            last_notice = vim.uv.now()
            vim.schedule(function()
                helpers.notify('This large file is shown read-only. File > Load Whole File for Editing loads it to edit.')
            end)
        end
        return ''
    end)
    local augroup = api.nvim_create_augroup('notebashpp_large_file', { clear = true })
    api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = augroup,
        callback = function()
            for _, state in pairs(states) do
                render_soon(state)
            end
        end,
    })
end

return large_file_view
