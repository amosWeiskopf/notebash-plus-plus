-- copy notepad++'s session & snapshot: config.xml rememberlastsession="yes",
-- backup issnapshotmode="yes" snapshotbackuptiming="7000". next start brings
-- back open documents, unsaved changes and unsaved "new" documents included.
-- backups refresh every 7 seconds. close the window without saving; nothing
-- is lost. i want this for my life too (apparently that costs more than
-- therapy).

--
-- each document keeps its scroll & closed folds; the current one keeps its
-- selection too. split windows and sizes come back. save about 1 s after
-- typing or movement stops, at most 5 s behind while you keep going, plus on
-- focus loss and exit. a crash or killed terminal loses those last seconds.
-- basically the computer gets to die and i still have homework.

local session = {}
local api = vim.api
local document_tabs = require('notebashpp.document_tabs')
local folding = require('notebashpp.folding')
local helpers = require('notebashpp.helpers')

local session_directory = vim.fn.stdpath('data') .. '/session'
local session_file = session_directory .. '/session.json'
local backup_directory = session_directory .. '/backup'

-- format 3: each document's scroll, folds & selection, plus window layout.
-- still reads formats 1 and 2. my old mistakes have tenure.
local session_format = 3

-- save after the first pause limit, never later than the second limit. the
-- interval timer catches changes with no event (fold commands, say). write
-- only what changed. even this damn editor needs a welfare check.
local idle_milliseconds_before_save = 1000
local longest_milliseconds_before_save = 5000
local snapshot_interval_milliseconds = 7000

-- special views register by b:notebashpp_special_view name here. see
-- session.register_special_view(). paperwork survives everything.
session.special_views = {}

-- on unless notebashpp_no_session=1. if you want absolutely no record of
-- yesterday's failures, set it. mine apparently need persistent storage.
function session.enabled()
    return vim.env.NOTEBASHPP_NO_SESSION ~= '1'
end

-- backup names: new documents get new_<number>_<buffer>.txt; disk files get
-- their name plus the first 12 characters of their full path's sha256. two
-- notes.txt files shouldn't erase each other. i want to ruin my own work,
-- thanks. i don't need assistance.
--
-- cut the name part to 100 bytes: a name at the 255-byte limit plus the hash
-- makes a backup name no file system accepts. the document would quietly get
-- no backup at all. basically insurance that waits until the funeral to
-- explain what wasn't covered.
local function backup_file_name_for(buffer)
    local path = api.nvim_buf_get_name(buffer)
    if path == '' then
        return ('new_%d_%d.txt'):format(vim.b[buffer].notebashpp_new or 0, buffer)
    end
    local name_part = vim.fn.fnamemodify(path, ':t')
    if #name_part > 100 then
        name_part = vim.fn.strcharpart(name_part:sub(1, 100), 0, vim.fn.strchars(name_part:sub(1, 100)) - 1)
    end
    return name_part .. '@' .. vim.fn.sha256(path):sub(1, 12)
end

-- snapshots contain your unsaved documents. only you get to read them (i'd
-- rather keep my failures private). folders are 0700, every file 0600,
-- whatever the umask says. write to a temporary file first, then rename it
-- over the old one. a crash mid-write leaves the previous snapshot whole
-- instead of half a new one. apparently my unfinished crap deserves better
-- protection than my savings.
local function make_private_directory(path)
    vim.fn.mkdir(path, 'p')
    vim.uv.fs_chmod(path, tonumber('700', 8))
end

local function write_file_atomically(lines, path)
    helpers.write_private_file(lines, path, 'b')
end

------------------------------------------------------------ special views

-- a special view (say, a spreadsheet view of a csv file) is a buffer with
-- b:notebashpp_special_view set to its name. its module must register two
-- functions under that name before the session can keep it:
--
-- save(buffer) returns the view's state table (json values only). this goes
-- in the document's special_view.state. restore(state, document) rebuilds the
-- view from that table & returns its buffer, or nil to open document.path as
-- plain text instead.
--
-- the session still saves & restores its path, caret, scroll, folds and
-- selection. there is no unsaved-text backup: the buffer contains the view's
-- rendering, so unsaved work belongs in the view's own state. i want a
-- spreadsheet inside my editor. apparently dying was too simple.
function session.register_special_view(view_name, handlers)
    session.special_views[view_name] = handlers
end

local function special_view_handler(buffer)
    local view_name = vim.b[buffer].notebashpp_special_view
    if view_name == nil then
        return nil, nil
    end
    return view_name, session.special_views[view_name]
end

-- keep plain documents & special views registered through
-- register_special_view(). leave other special views out; we cannot rebuild
-- them. absolutely no afterlife without the correct paperwork.
local function is_session_document(buffer)
    local view_name, handler = special_view_handler(buffer)
    if view_name ~= nil then
        return handler ~= nil
    end
    return require('notebashpp.helpers').is_document_buffer(buffer)
end

------------------------------------------------------------- window views

local function is_position(value)
    return type(value) == 'table' and type(value[1]) == 'number' and type(value[2]) == 'number'
end

-- a window's document view: caret, scroll & folds. my entire estate.
local function capture_window_view(window)
    local view_ok, saved_view = pcall(api.nvim_win_call, window, vim.fn.winsaveview)
    if not view_ok then
        return { cursor = api.nvim_win_get_cursor(window) }
    end
    local folds_ok, fold_state = pcall(folding.session_state, window)
    return {
        cursor = { saved_view.lnum, saved_view.col },
        scroll = {
            topline = saved_view.topline,
            topfill = saved_view.topfill,
            leftcol = saved_view.leftcol,
            skipcol = saved_view.skipcol,
            curswant = saved_view.curswant,
        },
        folds = folds_ok and fold_state or nil,
    }
end

local function restore_scroll_and_caret(window, window_view)
    local line_count = api.nvim_buf_line_count(api.nvim_win_get_buf(window))
    local scroll = type(window_view.scroll) == 'table' and window_view.scroll or {}
    local restored_view = {}
    if is_position(window_view.cursor) then
        restored_view.lnum = math.max(1, math.min(window_view.cursor[1], line_count))
        restored_view.col = math.max(0, window_view.cursor[2])
    end
    for _, field_name in ipairs({ 'topfill', 'leftcol', 'skipcol', 'curswant' }) do
        if type(scroll[field_name]) == 'number' then
            restored_view[field_name] = math.max(0, scroll[field_name])
        end
    end
    if type(scroll.topline) == 'number' then
        restored_view.topline = math.max(1, math.min(scroll.topline, line_count))
    end
    pcall(api.nvim_win_call, window, function()
        vim.fn.winrestview(restored_view)
    end)
end

-- restore folds first (closing one moves the caret), then scroll & caret.
-- retry shortly if folds aren't computed yet (treesitter takes a moment). i'm
-- getting old waiting for a computer to discover where lines end.
local function apply_window_view(window, window_view)
    if type(window_view) ~= 'table' or not api.nvim_win_is_valid(window) then
        return
    end
    local buffer = api.nvim_win_get_buf(window)
    -- loaded without a window: missed fold setup on filetype. born in debt.
    pcall(folding.setup_buffer, buffer)
    local folds_ok, all_folds_found = pcall(folding.restore_session_state, window, window_view.folds)
    restore_scroll_and_caret(window, window_view)
    if folds_ok and all_folds_found == false then
        vim.defer_fn(function()
            if api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == buffer then
                pcall(folding.restore_session_state, window, window_view.folds)
                restore_scroll_and_caret(window, window_view)
            end
        end, 300)
    end
end

-- hidden document: use its restored-but-unshown view, else its last window
-- view, else its last caret mark. even absence has a damn queue.
local function hidden_document_view(buffer)
    local pending_view = vim.b[buffer].notebashpp_pending_view
    if type(pending_view) == 'table' then
        return pending_view
    end
    local last_view = vim.b[buffer].notebashpp_last_view
    if type(last_view) == 'table' then
        return last_view
    end
    local last_caret_mark = api.nvim_buf_get_mark(buffer, '"')
    return { cursor = { math.max(1, last_caret_mark[1]), last_caret_mark[2] } }
end

--------------------------------------------------------------- selection

local selection_kinds = { v = 'stream', s = 'stream', V = 'line', S = 'line' }

-- current window selection: 'stream' (shift+arrows) & 'line' use byte
-- positions { line, column }; 'column' (column mode) uses { line, display
-- column }. two kinds of column. one life wasted.
local function capture_selection()
    local column_mode = package.loaded['notebashpp.column_mode']
    local corners = column_mode and column_mode.corners()
    if corners then
        return { kind = 'column', anchor = corners.anchor, caret = corners.caret }
    end
    local selection_kind = selection_kinds[api.nvim_get_mode().mode]
    if not selection_kind then
        return nil
    end
    local anchor_mark, caret_mark = vim.fn.getpos('v'), vim.fn.getpos('.')
    return { kind = selection_kind, anchor = { anchor_mark[2], anchor_mark[3] - 1 }, caret = { caret_mark[2], caret_mark[3] - 1 } }
end

-- remember the current document's selection across saves: neovim already
-- dropped it on the command line (:qa, say). even quitting costs memory.
local function current_selection(buffer)
    if api.nvim_get_mode().mode:sub(1, 1) == 'c' then
        local remembered = session.last_selection
        return remembered and remembered.buffer == buffer and remembered.selection or nil
    end
    local selection = capture_selection()
    session.last_selection = { buffer = buffer, selection = selection }
    return selection
end

local function clamped_position(position)
    local line_number = math.max(1, math.min(math.floor(position[1]), helpers.count_lines()))
    return { line_number, math.max(0, math.min(math.floor(position[2]), #helpers.get_line_text(line_number))) }
end

-- reselect in the current window using notebash++ select mode: typing
-- replaces the selection. finally, a small failure i can overwrite.
local function apply_selection(selection)
    if type(selection) ~= 'table' or not is_position(selection.anchor) or not is_position(selection.caret) then
        return
    end
    if selection.kind == 'column' then
        require('notebashpp.column_mode').select_display_columns(selection.anchor, selection.caret)
        return
    end
    local anchor, caret = clamped_position(selection.anchor), clamped_position(selection.caret)
    if selection.kind == 'line' then
        helpers.feed_keys(('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>V<Cmd>call cursor(%d,%d)<CR><C-g>'):format(anchor[1], anchor[2] + 1, caret[1], caret[2] + 1))
    else
        helpers.select_range(anchor, caret)
    end
end

-- startup enters insert mode in a scheduled step, undoing any selection made
-- before it. wait for insert mode, checking every 50 ms up to `checks_left`
-- times, then select. i scheduled my own damn sabotage.
local function apply_selection_once_typing(buffer, selection, checks_left)
    vim.defer_fn(function()
        if api.nvim_get_current_buf() ~= buffer then
            return
        end
        if api.nvim_get_mode().mode ~= 'i' and checks_left > 0 then
            apply_selection_once_typing(buffer, selection, checks_left - 1)
            return
        end
        pcall(apply_selection, selection)
    end, 50)
end

-------------------------------------------------------- document state

-- back up the buffer text unless that text (same change count) is already
-- there. return the backup file name. i refuse to bury this shit twice.
local function write_backup(buffer)
    local backup_name = backup_file_name_for(buffer)
    local backup_path = backup_directory .. '/' .. backup_name
    local change_count = vim.b[buffer].changedtick
    local written = vim.b[buffer].notebashpp_backup_written
    if not (type(written) == 'table' and written.name == backup_name and written.change_count == change_count and vim.uv.fs_stat(backup_path)) then
        write_file_atomically(api.nvim_buf_get_lines(buffer, 0, -1, false), backup_path)
        vim.b[buffer].notebashpp_backup_written = { name = backup_name, change_count = change_count }
    end
    return backup_name
end

-- one document as a json-ready table: path or "new n" number, file format &
-- encoding, unsaved-text backup, view (caret, scroll, folds), whether it is
-- current and its selection if so, plus a special view's own state. return
-- nil if there's nothing worth restoring. i want that assessment kept
-- strictly to documents, please.
function session.build_document_state(buffer)
    local path = api.nvim_buf_get_name(buffer)
    local is_current = buffer == api.nvim_get_current_buf()
    local document = { path = path ~= '' and path or nil, new = vim.b[buffer].notebashpp_new, current = is_current }
    if is_current then
        document.view = capture_window_view(api.nvim_get_current_win())
        document.selection = current_selection(buffer)
    else
        local window = vim.fn.bufwinid(buffer)
        document.view = window ~= -1 and capture_window_view(window) or hidden_document_view(buffer)
    end
    document.ff = vim.bo[buffer].fileformat
    document.fenc = vim.bo[buffer].fileencoding
    document.bomb = vim.bo[buffer].bomb
    document.eol = vim.bo[buffer].endofline
    local view_name, handler = special_view_handler(buffer)
    if handler then
        local saved_ok, view_state = pcall(handler.save, buffer)
        document.special_view = { name = view_name, state = saved_ok and view_state or nil }
    elseif (vim.bo[buffer].modified or path == '') and not document_tabs.is_pristine(buffer) and api.nvim_buf_is_loaded(buffer) then
        document.backup = write_backup(buffer)
        -- file time at this buffer's last read or save: the version these
        -- edits depend on. a newer file at restore means somebody changed it
        -- after editing started. even my own damn file found a future without
        -- me.
        if path ~= '' then
            document.disk_time = vim.b[buffer].notebashpp_disk_time or vim.fn.getftime(path)
        end
    end
    if document.path or document.backup then
        return document
    end
end

-- open the saved document's special view, file or new empty buffer. basically
-- choose which unfinished shit comes back to haunt me.
local function open_document_buffer(document)
    if type(document.special_view) == 'table' then
        local handler = session.special_views[document.special_view.name]
        if handler then
            local opened_ok, special_buffer = pcall(handler.restore, document.special_view.state, document)
            if opened_ok and type(special_buffer) == 'number' and api.nvim_buf_is_valid(special_buffer) then
                return special_buffer
            end
        end
        if not document.path or vim.fn.filereadable(document.path) == 0 then
            return nil
        end
    end
    if document.path and require('notebashpp.remote_documents').kind(document.path) then
        -- a web page or ssh file comes back only with unsaved text, and
        -- without a fetch: no network calls while the editor starts.
        if not document.backup then
            return nil
        end
        local buffer = vim.fn.bufadd(document.path)
        require('notebashpp.remote_documents').mark_restored(buffer)
        vim.bo[buffer].buflisted = true
        vim.fn.bufload(buffer)
        return buffer
    end
    if document.path then
        if vim.fn.filereadable(document.path) == 1 or document.backup then
            local buffer = vim.fn.bufadd(document.path)
            vim.bo[buffer].buflisted = true
            vim.fn.bufload(buffer)
            return buffer
        end
        return nil
    end
    local buffer = api.nvim_create_buf(true, false)
    if document.new then
        vim.b[buffer].notebashpp_new = document.new
    end
    return buffer
end

-- reverse build_document_state(): open the document, restore unsaved text &
-- file settings, defer its view until a window shows it. return the buffer
-- (nil if gone) and whether disk changed after the unsaved text was saved.
-- resurrection comes with a conflict report. of course.
function session.apply_document_state(document, saved_format)
    local buffer = open_document_buffer(document)
    if not buffer then
        return nil, false
    end
    local changed_on_disk = false
    -- a backup name is a plain file name inside the backup folder. a session
    -- file saying ../../something gets ignored. i don't take directions from
    -- old paperwork either.
    if type(document.backup) == 'string' and (document.backup:find('[/\\]') or document.backup:find('^%.%.?$')) then
        document.backup = nil
    end
    if document.backup then
        local backup_read_ok, backup_lines = pcall(vim.fn.readfile, backup_directory .. '/' .. document.backup, saved_format >= 2 and 'b' or '')
        if backup_read_ok then
            api.nvim_buf_set_lines(buffer, 0, -1, false, backup_lines)
        end
        if document.ff then
            vim.bo[buffer].fileformat = document.ff
        end
        if document.fenc then
            vim.bo[buffer].fileencoding = document.fenc
        end
        if document.bomb ~= nil then
            vim.bo[buffer].bomb = document.bomb
        end
        if document.eol ~= nil then
            vim.bo[buffer].endofline = document.eol
        end
        if document.path and document.disk_time then
            changed_on_disk = vim.fn.getftime(document.path) > document.disk_time
            -- edits still depend on the old version. nostalgia corrupts shit
            -- too.
            vim.b[buffer].notebashpp_disk_time = document.disk_time
            -- neovim just read the newer file; "changed since reading" stays
            -- quiet. ask when saving instead. basically bad news gets a damn
            -- appointment.
            vim.b[buffer].notebashpp_snapshot_disk_time = document.disk_time
        end
    end
    -- formats 1 and 2 kept only document.cursor (caret). a smaller coffin.
    local document_view = type(document.view) == 'table' and document.view or (is_position(document.cursor) and { cursor = document.cursor })
    if document_view then
        if is_position(document_view.cursor) then
            pcall(api.nvim_buf_set_mark, buffer, '"', document_view.cursor[1], document_view.cursor[2], {})
        end
        vim.b[buffer].notebashpp_pending_view = document_view
    end
    return buffer, changed_on_disk
end

------------------------------------------------------------ window layout

-- current tab page's split windows as a tree: split nodes are { split = 'row'
-- or 'col', children }; windows are { document, width, height, view, current
-- }. exclude windows without session documents (search results, help,
-- compare's scratch side), and the other side of an active compare. even hell
-- has guest limits.
local function capture_layout(document_index_by_buffer)
    local compare_documents = package.loaded['notebashpp.compare_documents']
    local compare_window = compare_documents and type(compare_documents.active) == 'table' and compare_documents.active.other
    local current_window = api.nvim_get_current_win()
    local function capture_node(layout_node)
        if layout_node[1] == 'leaf' then
            local window = layout_node[2]
            local document_index = document_index_by_buffer[api.nvim_win_get_buf(window)]
            if not document_index or window == compare_window then
                return nil
            end
            return {
                document = document_index,
                width = api.nvim_win_get_width(window),
                height = api.nvim_win_get_height(window),
                view = capture_window_view(window),
                current = window == current_window or nil,
            }
        end
        local children = {}
        for _, child_node in ipairs(layout_node[2]) do
            children[#children + 1] = capture_node(child_node)
        end
        if #children < 2 then
            return children[1]
        end
        return { split = layout_node[1], children = children }
    end
    local root = capture_node(vim.fn.winlayout())
    if root then
        return { columns = vim.o.columns, lines = vim.o.lines, root = root }
    end
end

-- drop windows for documents that didn't return; replace a one-child split
-- with its child. grief gets a layout algorithm. lucky bastard.
local function prune_layout_node(layout_node, buffer_by_document_index)
    if type(layout_node) ~= 'table' then
        return nil
    end
    if layout_node.document then
        return buffer_by_document_index[layout_node.document] and layout_node or nil
    end
    if (layout_node.split ~= 'row' and layout_node.split ~= 'col') or type(layout_node.children) ~= 'table' then
        return nil
    end
    local children = {}
    for _, child_node in ipairs(layout_node.children) do
        children[#children + 1] = prune_layout_node(child_node, buffer_by_document_index)
    end
    if #children < 2 then
        return children[1]
    end
    return { split = layout_node.split, children = children }
end

-- rebuild saved windows inside the current window, scaling sizes relative to
-- the saved screen. return the formerly current window, if any. same
-- failures, smaller apartment.
local function restore_layout(layout, buffer_by_document_index)
    local root = type(layout) == 'table' and prune_layout_node(layout.root, buffer_by_document_index)
    if not root then
        return nil
    end
    local window_leaves = {}
    local function build(layout_node, window)
        if layout_node.document then
            window_leaves[#window_leaves + 1] = { window = window, node = layout_node }
            return
        end
        -- make all siblings first, each beside the previous one, then fill
        -- them. splitting an already divided window nests the new one in the
        -- wrong place. i want fewer structural mistakes than my actual life.
        local sibling_windows = { window }
        for child_index = 2, #layout_node.children do
            sibling_windows[child_index] = api.nvim_open_win(api.nvim_win_get_buf(window), false, {
                split = layout_node.split == 'row' and 'right' or 'below',
                win = sibling_windows[child_index - 1],
            })
        end
        for child_index, child_node in ipairs(layout_node.children) do
            build(child_node, sibling_windows[child_index])
        end
    end
    build(root, api.nvim_get_current_win())
    for _, leaf in ipairs(window_leaves) do
        local buffer = buffer_by_document_index[leaf.node.document]
        -- apply this window's own saved view below; the document can damn
        -- well wait.
        vim.b[buffer].notebashpp_pending_view = nil
        vim.b[buffer].notebashpp_restored = true
        api.nvim_win_set_buf(leaf.window, buffer)
    end
    local width_scale = type(layout.columns) == 'number' and layout.columns > 0 and vim.o.columns / layout.columns or 1
    local height_scale = type(layout.lines) == 'number' and layout.lines > 0 and vim.o.lines / layout.lines or 1
    if #window_leaves > 1 then
        -- resize twice: each pass shoves neighbours. rent stays the same.
        for _ = 1, 2 do
            for _, leaf in ipairs(window_leaves) do
                if type(leaf.node.width) == 'number' then
                    pcall(api.nvim_win_set_width, leaf.window, math.max(1, math.floor(leaf.node.width * width_scale + 0.5)))
                end
                if type(leaf.node.height) == 'number' then
                    pcall(api.nvim_win_set_height, leaf.window, math.max(1, math.floor(leaf.node.height * height_scale + 0.5)))
                end
            end
        end
    end
    local current_window
    for _, leaf in ipairs(window_leaves) do
        apply_window_view(leaf.window, leaf.node.view)
        if leaf.node.current then
            current_window = leaf.window
        end
    end
    return current_window or window_leaves[1].window
end

---------------------------------------------------------------- saving

-- write session.json: every open document, its view & current status, plus
-- window layout. back up unsaved changes; skip untouched empty "new"
-- documents and delete obsolete backups. write nothing if nothing changed
-- since the last save. basically my abandoned work has an estate plan and i
-- have a chair that hurts.
function session.save()
    if not session.enabled() or session.restoring then
        return
    end
    make_private_directory(session_directory)
    make_private_directory(backup_directory)
    local backups_to_keep = {}
    local documents = {}
    local document_index_by_buffer = {}
    for _, buffer in ipairs(document_tabs.sync()) do
        if is_session_document(buffer) and (api.nvim_buf_is_loaded(buffer) or api.nvim_buf_get_name(buffer) ~= '') then
            local document = session.build_document_state(buffer)
            if document then
                documents[#documents + 1] = document
                document_index_by_buffer[buffer] = #documents
                if document.backup then
                    backups_to_keep[document.backup] = true
                end
            end
        end
    end
    -- format 1 (no number) wrote text backups with a trailing newline; format
    -- 2 wrote raw bytes. i gave unfinished crap a proper ending.
    local session_text = vim.json.encode({ format = session_format, docs = documents, layout = capture_layout(document_index_by_buffer) })
    if session_text == session.last_written_text and vim.uv.fs_stat(session_file) then
        return
    end
    write_file_atomically({ session_text }, session_file)
    session.last_written_text = session_text
    -- delete backups no document references, unless restore went wrong.
    -- failed-to-open documents may still have work in those backups. i can
    -- hate this damn editor without throwing somebody's hours away.
    if session.keep_unreferenced_backups then
        return
    end
    for _, backup_file in ipairs(vim.fn.readdir(backup_directory)) do
        if not backups_to_keep[backup_file] and not backup_file:match('%.writing$') then
            vim.fn.delete(backup_directory .. '/' .. backup_file)
        end
    end
end

local function save_quietly()
    pcall(session.save)
end
local save_on_main_loop = vim.schedule_wrap(function()
    session.first_unsaved_request_time = nil
    save_quietly()
end)

-- request a save; cheap per keystroke, since it only moves a timer. save
-- after a 1 s pause, or 5 s from the first unsaved change if typing
-- continues. my procrastination needed a limit. apparently code gets one.
function session.request_save()
    local save_timer = session.save_timer
    if not save_timer then
        return
    end
    local now = vim.uv.now()
    session.first_unsaved_request_time = session.first_unsaved_request_time or now
    local delay = math.min(idle_milliseconds_before_save, session.first_unsaved_request_time + longest_milliseconds_before_save - now)
    save_timer:stop()
    save_timer:start(math.max(0, delay), 0, save_on_main_loop)
end

--------------------------------------------------------------- restoring

-- restore the last session: reopen documents & their unsaved-work backups,
-- rebuild splits with each window's caret, scroll & folds, then restore the
-- selection. quietly ignore missing or broken session.json. i'd love that
-- courtesy for my other failures. command-line files win: restored documents
-- then get tabs only, their views applied when shown. remove the empty
-- startup buffer. even a blank page has to justify rent.
function session.restore()
    local read_ok, session_lines = pcall(vim.fn.readfile, session_file)
    if not read_ok then
        return
    end
    local decode_ok, session_data = pcall(vim.json.decode, table.concat(session_lines, '\n'))
    if not decode_ok or type(session_data) ~= 'table' or type(session_data.docs) ~= 'table' then
        return
    end
    local saved_format = type(session_data.format) == 'number' and session_data.format or 1
    local startup_buffer = api.nvim_get_current_buf()
    local opened_with_file_arguments = vim.fn.argc() > 0
    local current_buffer, current_document
    local reopened_buffers = {}
    local buffer_by_document_index = {}
    local changed_on_disk = {}
    for document_index, document in ipairs(session_data.docs) do
        if type(document) == 'table' then
            local applied_ok, buffer, file_changed = pcall(session.apply_document_state, document, saved_format)
            if not applied_ok then
                session.keep_unreferenced_backups = true
                buffer = nil
            end
            if buffer then
                if file_changed then
                    changed_on_disk[#changed_on_disk + 1] = document.path
                end
                buffer_by_document_index[document_index] = buffer
                reopened_buffers[#reopened_buffers + 1] = buffer
                if document.current then
                    current_buffer, current_document = buffer, document
                end
            elseif document.backup then
                session.keep_unreferenced_backups = true
            end
        end
    end
    if #reopened_buffers == 0 then
        return
    end
    document_tabs.order = vim.list_extend(vim.deepcopy(reopened_buffers), document_tabs.order)
    if not opened_with_file_arguments then
        local layout_ok, current_window = pcall(restore_layout, session_data.layout, buffer_by_document_index)
        if layout_ok and current_window then
            api.nvim_set_current_win(current_window)
        else
            api.nvim_set_current_buf(current_buffer or reopened_buffers[1])
        end
        if document_tabs.is_pristine(startup_buffer) and vim.fn.bufwinid(startup_buffer) == -1 then
            pcall(api.nvim_buf_delete, startup_buffer, { force = true })
        end
        if current_document and current_document.selection and api.nvim_get_current_buf() == current_buffer then
            apply_selection_once_typing(current_buffer, current_document.selection, 20)
        end
    end
    document_tabs.sync()
    -- your unsaved edits are back; the disk file changed after them (git
    -- pull, another editor, dropbox). saving throws the newer file away. warn
    -- before somebody presses ctrl+s out of habit. i want to save my work,
    -- and apparently that's a threat now.
    if #changed_on_disk > 0 then
        vim.schedule(function()
            helpers.warn(
                'Changed on disk after your unsaved edits were snapshotted; saving will overwrite the newer file: ' .. table.concat(changed_on_disk, ', ')
            )
        end)
    end
end

-- stop save timers before reloading, or old code keeps saving in the
-- background. dead code still has a job. absolutely reassuring for me.
function session._unload()
    for _, timer_field in ipairs({ 'timer', 'save_timer' }) do
        local timer = session[timer_field]
        if timer then
            timer:stop()
            timer:close()
            session[timer_field] = nil
        end
    end
end

function session.setup()
    if not session.enabled() then
        return
    end
    local autocommand_group = api.nvim_create_augroup('notebashpp_session', { clear = true })
    api.nvim_create_autocmd('VimEnter', {
        group = autocommand_group,
        nested = true,
        callback = function()
            -- no saves during restore: we'd preserve half a session. a shit
            -- autopsy.
            session.restoring = true
            local restored_ok, restore_error = pcall(session.restore)
            session.restoring = false
            if not restored_ok then
                session.keep_unreferenced_backups = true
                helpers.warn('Session restore failed: ' .. tostring(restore_error))
            end
        end,
    })
    -- record the file's time on each buffer read or write: the version
    -- unsaved edits are based on. this runs first; a restored snapshot sets
    -- its own older time after the read. i keep accurate records of my past
    -- mistakes, in case the present ones aren't enough.
    api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
        group = autocommand_group,
        callback = function(event)
            local path = api.nvim_buf_get_name(event.buf)
            if path ~= '' then
                vim.b[event.buf].notebashpp_disk_time = vim.fn.getftime(path)
            end
        end,
    })
    api.nvim_create_autocmd('VimLeavePre', {
        group = autocommand_group,
        callback = function()
            session.save()
        end,
    })
    -- anything affecting the restored view requests a save; the save waits
    -- for a pause (session.request_save). even panic has office hours.
    api.nvim_create_autocmd({
        'TextChanged',
        'TextChangedI',
        'CursorMoved',
        'CursorMovedI',
        'ModeChanged',
        'WinScrolled',
        'WinResized',
        'WinNew',
        'WinClosed',
        'BufEnter',
        'BufAdd',
        'BufDelete',
        'BufFilePost',
        'BufWritePost',
    }, {
        group = autocommand_group,
        callback = function()
            session.request_save()
        end,
    })
    -- a departing document keeps its window's view for saves while hidden. i
    -- wish leaving a room took this much care of me.
    api.nvim_create_autocmd('BufLeave', {
        group = autocommand_group,
        callback = function(event)
            if api.nvim_win_get_buf(0) == event.buf and is_session_document(event.buf) then
                vim.b[event.buf].notebashpp_last_view = capture_window_view(api.nvim_get_current_win())
            end
            session.request_save()
        end,
    })
    -- switching programs or suspending may precede terminal closure: save
    -- now. i want one goodbye that doesn't cost me the whole damn evening.
    api.nvim_create_autocmd({ 'FocusLost', 'VimSuspend' }, {
        group = autocommand_group,
        callback = save_quietly,
    })
    -- also snapshot every 7 s: crashes or closed terminals lose at most 7 s
    -- of work, including changes no event reports. i spent considerably
    -- longer writing this damn thing. your hours still matter, even if this
    -- editor is where you chose to spend them. mine too, apparently.
    session._unload()
    session.save_timer = vim.uv.new_timer()
    session.timer = vim.uv.new_timer()
    session.timer:start(snapshot_interval_milliseconds, snapshot_interval_milliseconds, vim.schedule_wrap(save_quietly))
    -- on a document's first window appearance, apply its saved session view
    -- or fall back to its last caret mark. i want to return where i left off
    -- without explaining where the rest of my damn life went.
    api.nvim_create_autocmd('BufWinEnter', {
        group = autocommand_group,
        callback = function(event)
            local pending_view = vim.b[event.buf].notebashpp_pending_view
            if type(pending_view) == 'table' then
                vim.b[event.buf].notebashpp_pending_view = nil
                vim.b[event.buf].notebashpp_restored = true
                apply_window_view(api.nvim_get_current_win(), pending_view)
                return
            end
            if vim.b[event.buf].notebashpp_restored then
                return
            end
            vim.b[event.buf].notebashpp_restored = true
            local last_caret_mark = api.nvim_buf_get_mark(event.buf, '"')
            if last_caret_mark[1] > 1 and last_caret_mark[1] <= api.nvim_buf_line_count(event.buf) then
                pcall(api.nvim_win_set_cursor, 0, last_caret_mark)
            end
        end,
    })
end

return session
