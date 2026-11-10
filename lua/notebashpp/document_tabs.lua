-- documents as notepad++ tabs: one tab bar per view (the window bar),
-- rearrangeable tab order, unsaved names "new 1", "new 2", and ctrl+tab in
-- most-recently-used order. basically i built a filing system for things i
-- haven't named. my failures now have a fucking interface.

local document_tabs = {}
local api = vim.api

-- tab order runs left to right; mru runs most recent first. both live on the
-- module table so reloading code doesn't erase your day. i want that kind of
-- protection for the rest of my shit.
document_tabs.order = {}
document_tabs.mru = {}

-- documents only: listed buffers holding text. search results, help and
-- terminals are panels, even when neovim lists them. its shit has boundaries.
-- mine just gets older.
local function is_listed(buffer)
    if not api.nvim_buf_is_valid(buffer) or not vim.bo[buffer].buflisted then
        return false
    end
    local buffer_type = vim.bo[buffer].buftype
    return buffer_type == ''
        or vim.b[buffer].notebashpp_special_view ~= nil
        or (buffer_type == 'acwrite' and (vim.b[buffer].notebashpp_hex_source ~= nil or vim.b[buffer].notebashpp_remote == true))
end

-- an untouched document: no file, no changes, one empty line. absolutely
-- perfect. all i have to do now is keep myself out of it.
function document_tabs.is_pristine(buffer)
    return is_listed(buffer)
        and api.nvim_buf_get_name(buffer) == ''
        and not vim.bo[buffer].modified
        and api.nvim_buf_line_count(buffer) == 1
        and api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == ''
end

-- use the lowest unused "new n" number. close "new 2" and the next new
-- document gets 2. even my unfinished shit gets replaced immediately.
local function next_new_number()
    local used_numbers = {}
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        local new_document_number = is_listed(buffer) and vim.b[buffer].notebashpp_new
        if new_document_number then
            used_numbers[new_document_number] = true
        end
    end
    local candidate_number = 1
    while used_numbers[candidate_number] do
        candidate_number = candidate_number + 1
    end
    return candidate_number
end

-- give a nameless, ordinary, listed buffer its "new n" number once. basically
-- a case number for another failure.
function document_tabs.name_new(buffer)
    if api.nvim_buf_get_name(buffer) == '' and is_listed(buffer) and vim.bo[buffer].buftype == '' and not vim.b[buffer].notebashpp_new then
        vim.b[buffer].notebashpp_new = next_new_number()
    end
end

-- update tab order & mru: remove closed documents, append anything neovim
-- opened behind our back to tab order, and return that order. i'm doing
-- unpaid bookkeeping for a bastard that opens its own files.
function document_tabs.sync()
    local seen_buffers, tab_order = {}, {}
    for _, buffer in ipairs(document_tabs.order) do
        if is_listed(buffer) and not seen_buffers[buffer] then
            seen_buffers[buffer] = true
            tab_order[#tab_order + 1] = buffer
        end
    end
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        if is_listed(buffer) and not seen_buffers[buffer] then
            seen_buffers[buffer] = true
            tab_order[#tab_order + 1] = buffer
        end
    end
    document_tabs.order = tab_order
    local recent_buffers = {}
    for _, buffer in ipairs(document_tabs.mru) do
        if is_listed(buffer) then
            recent_buffers[#recent_buffers + 1] = buffer
        end
    end
    document_tabs.mru = recent_buffers
    return tab_order
end

-- tab label: file name, "new n" if unsaved, or "[no name]" if it has no
-- number. even my neglect has a fallback. absolutely professional.
function document_tabs.name(buffer)
    local file_path = api.nvim_buf_get_name(buffer)
    if file_path == '' then
        local new_document_number = vim.b[buffer].notebashpp_new
        return new_document_number and ('new ' .. new_document_number) or '[No Name]'
    end
    return vim.fn.fnamemodify(file_path, ':t')
end

-- full path, or tab label without a file. no buffer means the current one.
-- apparently even being lost requires a default.
function document_tabs.full_name(buffer)
    local file_path = api.nvim_buf_get_name(buffer or 0)
    if file_path == '' then
        return document_tabs.name(buffer or api.nvim_get_current_buf())
    end
    return file_path
end

-- 'titlestring' reads this to put your work in the window title. i want to
-- know what i'm wasting my life on (specifically).
function document_tabs.title()
    return document_tabs.full_name(api.nvim_get_current_buf())
end

-------------------------------------------------------------- tab bar

function document_tabs.click(buffer)
    if is_listed(buffer) then
        api.nvim_set_current_buf(buffer)
    end
end

-- schedule the close after click handling finishes. even deleting my crap
-- requires waiting for the computer to finish talking.
function document_tabs.click_close(buffer)
    if is_listed(buffer) then
        vim.schedule(function()
            require('notebashpp.file_commands').close(buffer)
        end)
    end
end

-- winbar click targets (%@...@) only reach global functions, so these two
-- must be global. neovim passes the buffer number as minwid. basically my
-- failures need global access. local shame wasn't enough.
-- selene: allow(global_usage)
_G.NotebashTabClick = function(buffer_number)
    document_tabs.click(buffer_number)
end
-- selene: allow(global_usage)
_G.NotebashTabClose = function(buffer_number)
    document_tabs.click_close(buffer_number)
end

-- one window's tabs in its winbar: name, " [ro]" if read-only or
-- unmodifiable, and a closing x. i gave every document an exit. very generous
-- of me, considering.
function document_tabs.winbar()
    local window = vim.g.statusline_winid or api.nvim_get_current_win()
    local current_buffer = api.nvim_win_get_buf(window)
    local tab_order = document_tabs.sync()
    local window_width = api.nvim_win_get_width(window)
    local tab_texts, tab_widths = {}, {}
    local current_index = 1
    for index, buffer in ipairs(tab_order) do
        local is_selected = buffer == current_buffer
        if is_selected then
            current_index = index
        end
        local is_modified = vim.bo[buffer].modified
        local tab_highlight = is_selected and (is_modified and 'NotebashTabSelMod' or 'NotebashTabSel') or (is_modified and 'NotebashTabMod' or 'NotebashTab')
        local close_highlight = is_selected and 'NotebashTabSelClose' or 'NotebashTabClose'
        local label = document_tabs.name(buffer):gsub('%%', '%%%%')
        -- a spreadsheet is drawn in a locked buffer but stays editable.
        -- bullshit lock.
        local special_view = vim.b[buffer].notebashpp_special_view
        local locked = vim.bo[buffer].readonly or (not vim.bo[buffer].modifiable and special_view ~= 'spreadsheet_view')
        local read_only_suffix = locked and ' [RO]' or ''
        tab_texts[index] = ('%%#%s#%%%d@v:lua.NotebashTabClick@ %s%s %%X%%#%s#%%%d@v:lua.NotebashTabClose@x%%X%%#WinBar# '):format(
            tab_highlight,
            buffer,
            label,
            read_only_suffix,
            close_highlight,
            buffer
        )
        tab_widths[index] = vim.fn.strdisplaywidth(label .. read_only_suffix) + 5
    end
    -- keep the current tab visible: walk left from it until the window is
    -- full, then fill right. '<' at the left edge means more tabs are hidden
    -- there. i paid for this screen to hide my problems on.
    local first_visible_index, used_width = 1, 0
    for index = current_index, 1, -1 do
        used_width = used_width + tab_widths[index]
        if used_width > window_width then
            break
        end
        first_visible_index = index
    end
    local visible_tabs = {}
    used_width = 0
    for index = first_visible_index, #tab_texts do
        used_width = used_width + tab_widths[index]
        if used_width > window_width and index > current_index then
            break
        end
        visible_tabs[#visible_tabs + 1] = tab_texts[index]
    end
    return (first_visible_index > 1 and '%#NotebashTab#<' or '') .. table.concat(visible_tabs) .. '%#WinBar#'
end

------------------------------------------------------------ navigation

-- jump to a bar position, counting from 1 at the left. at least something in
-- my life has a known starting point.
function document_tabs.goto_index(tab_index)
    local tab_order = document_tabs.sync()
    if tab_order[tab_index] then
        api.nvim_set_current_buf(tab_order[tab_index])
    end
end

local function index_of(wanted_buffer, tab_order)
    for index, buffer in ipairs(tab_order) do
        if buffer == wanted_buffer then
            return index
        end
    end
end

-- ctrl+pagedown / ctrl+pageup: next / previous tab, wrapping at the ends. i
-- mistook going in circles for progress again (my mistake).
function document_tabs.step(direction)
    local tab_order = document_tabs.sync()
    local index = index_of(api.nvim_get_current_buf(), tab_order)
    if not index or #tab_order < 2 then
        return
    end
    index = (index - 1 + direction) % #tab_order + 1
    api.nvim_set_current_buf(tab_order[index])
end

-- ctrl+shift+pagedown / pageup: move the current tab one place. no wrapping;
-- it stays put at either end. i know the feeling. years of effort, same damn
-- position.
function document_tabs.move(direction)
    local tab_order = document_tabs.sync()
    local current_buffer = api.nvim_get_current_buf()
    local index = index_of(current_buffer, tab_order)
    local neighbour_index = index and index + direction
    if not index or neighbour_index < 1 or neighbour_index > #tab_order then
        return
    end
    tab_order[index], tab_order[neighbour_index] = tab_order[neighbour_index], tab_order[index]
    document_tabs.order = tab_order
    vim.cmd('redrawstatus!')
end

-- ctrl+tab follows most-recently-used order. quick repeated presses go
-- further back, like holding ctrl in notepad++. while browsing, keep a frozen
-- mru copy, the current position, an end-of-browse timer and the little popup
-- window. all this machinery to revisit my mistakes.
local switcher = { documents = nil, position = 1, timer = nil, window = nil }

local function close_switcher()
    if switcher.window and api.nvim_win_is_valid(switcher.window) then
        api.nvim_win_close(switcher.window, true)
    end
    switcher.window = nil
    switcher.documents = nil
    if switcher.timer then
        switcher.timer:stop()
        switcher.timer:close()
        switcher.timer = nil
    end
end

-- center the document-list popup on screen, highlighting the document you're
-- about to land on. create its buffer once and reuse it. i'd love to stop
-- producing garbage somewhere.
local function show_switcher()
    local popup_lines = {}
    for index, buffer in ipairs(switcher.documents) do
        popup_lines[index] = ' ' .. document_tabs.name(buffer) .. ' '
    end
    local popup_width = 20
    for _, popup_line in ipairs(popup_lines) do
        popup_width = math.max(popup_width, vim.fn.strdisplaywidth(popup_line))
    end
    local popup_buffer = switcher.buffer
    if not popup_buffer or not api.nvim_buf_is_valid(popup_buffer) then
        popup_buffer = api.nvim_create_buf(false, true)
        switcher.buffer = popup_buffer
    end
    api.nvim_buf_set_lines(popup_buffer, 0, -1, false, popup_lines)
    api.nvim_buf_clear_namespace(popup_buffer, -1, 0, -1)
    vim.hl.range(popup_buffer, api.nvim_create_namespace('notebashpp_switch'), 'NotebashMenuSel', { switcher.position - 1, 0 }, { switcher.position - 1, -1 })
    local window_config = {
        relative = 'editor',
        width = popup_width,
        height = #popup_lines,
        row = math.floor((vim.o.lines - #popup_lines) / 2) - 1,
        col = math.floor((vim.o.columns - popup_width) / 2),
        style = 'minimal',
        border = 'single',
        focusable = false,
        zindex = 200,
    }
    if switcher.window and api.nvim_win_is_valid(switcher.window) then
        api.nvim_win_set_config(switcher.window, window_config)
    else
        switcher.window = api.nvim_open_win(popup_buffer, false, window_config)
        vim.wo[switcher.window].winhighlight = 'Normal:NotebashMenu,FloatBorder:NotebashMenuSep'
    end
end

function document_tabs.ctrl_tab(direction)
    document_tabs.sync()
    if not switcher.documents then
        if #document_tabs.mru < 2 then
            return
        end
        switcher.documents = vim.deepcopy(document_tabs.mru)
        switcher.position = 1
    end
    local document_count = #switcher.documents
    switcher.position = (switcher.position - 1 + direction) % document_count + 1
    local target_buffer = switcher.documents[switcher.position]
    -- raise switching during the hop so the bufenter autocmd's touch() leaves
    -- mru alone. otherwise looking at the list fucks up the list. excellent
    -- design, reality.
    switcher.switching = true
    if is_listed(target_buffer) then
        api.nvim_set_current_buf(target_buffer)
    end
    switcher.switching = false
    show_switcher()
    -- notepad++ commits on ctrl release. neovim never hears that release, so
    -- after 900 ms without another press we assume you've chosen, close the
    -- popup and move that document to the front of mru. basically silence
    -- counts as commitment. my marriage advice is free (and should absolutely
    -- stay that way).
    if switcher.timer then
        switcher.timer:stop()
        switcher.timer:close()
    end
    switcher.timer = vim.uv.new_timer()
    switcher.timer:start(
        900,
        0,
        vim.schedule_wrap(function()
            local chosen_buffer = switcher.documents and switcher.documents[switcher.position]
            close_switcher()
            if chosen_buffer then
                document_tabs.touch(chosen_buffer)
            end
        end)
    )
end

-- move a document to the front of mru. ignore this while the switcher is
-- open, or browsing reshuffles the list being browsed. i want one decision
-- without the floor moving. please please ?
function document_tabs.touch(buffer)
    if switcher.switching or switcher.documents then
        return
    end
    if not is_listed(buffer) then
        return
    end
    for index, recent_buffer in ipairs(document_tabs.mru) do
        if recent_buffer == buffer then
            table.remove(document_tabs.mru, index)
            break
        end
    end
    table.insert(document_tabs.mru, 1, buffer)
end

-- previous document in mru order fills the gap when a tab closes; fall back
-- to tab order. everyone gets replaced eventually. here i even wrote the
-- bastard's selection criteria.
function document_tabs.previous(excluded_buffer)
    document_tabs.sync()
    for _, buffer in ipairs(document_tabs.mru) do
        if buffer ~= excluded_buffer and is_listed(buffer) then
            return buffer
        end
    end
    for _, buffer in ipairs(document_tabs.order) do
        if buffer ~= excluded_buffer and is_listed(buffer) then
            return buffer
        end
    end
end

function document_tabs.setup()
    local tabs_augroup = api.nvim_create_augroup('notebashpp_tabs', { clear = true })
    -- give arriving buffers "new n" if needed; entering one moves it to the
    -- front of mru, then sync tab order. i keep better records of these
    -- documents than of the years they cost me.
    api.nvim_create_autocmd({ 'BufAdd', 'BufNew', 'BufEnter', 'VimEnter' }, {
        group = tabs_augroup,
        callback = function(event)
            document_tabs.name_new(event.buf)
            if event.event == 'BufEnter' then
                document_tabs.touch(event.buf)
            end
            document_tabs.sync()
        end,
    })
    -- once "new n" gets a real file name, release its number. i saved
    -- something. the number can go suffer elsewhere.
    api.nvim_create_autocmd('BufFilePost', {
        group = tabs_augroup,
        callback = function(event)
            if api.nvim_buf_get_name(event.buf) ~= '' then
                vim.b[event.buf].notebashpp_new = nil
            end
        end,
    })
    -- quickfix, help & our own panels get no tab bar. even this shit has
    -- overhead i refuse to pay.
    api.nvim_create_autocmd('FileType', {
        group = tabs_augroup,
        pattern = { 'qf', 'help', 'notebashpp*' },
        callback = function()
            vim.wo.winbar = ''
        end,
    })
    vim.o.winbar = '%{%v:lua.require("notebashpp.document_tabs").winbar()%}'
end

return document_tabs
