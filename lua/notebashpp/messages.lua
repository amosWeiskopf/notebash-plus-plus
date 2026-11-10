-- messages never block typing. i want to finish something before i die. every
-- vim.notify call, every error caught in a key action and every error or
-- warning neovim reports goes to a private log file and a small float in the
-- bottom-right corner. the float never takes the cursor or focus, fades after
-- a few seconds, and several stack upwards. help > message log opens the log.
-- basically a diary of this crap.
--
-- neovim 0.12 and later ship an experimental message ui (vim._core.ui2, first
-- called vim._extui) without hit-enter prompts. we enable it once a ui is
-- attached. without it (neovim 0.11), we read neovim's own errors from
-- v:errmsg and v:warningmsg when neovim goes idle. nvim_echo calls with
-- errors or several lines become notifications.

local messages = {}
local api = vim.api
local levels = vim.log.levels

local LOG_FILE_NAME = 'notebashpp-messages.log'
-- at this size, move the log to <name>.1, replacing the previous one, and
-- start a new log. both files stay under about 2 mb together. even my
-- failures have a budget.
local LOG_SIZE_LIMIT_BYTES = 1024 * 1024
local PRIVATE_FILE_MODE = tonumber('600', 8)
local NOTIFICATION_WIDTH_LIMIT = 60
local NOTIFICATION_LINE_LIMIT = 8
local NOTIFICATIONS_SHOWN_AT_MOST = 5
local FADE_STEP_MILLISECONDS = 50
local FADE_STEP_COUNT = 8
local DEFAULT_VISIBLE_MILLISECONDS = 4000
local VISIBLE_MILLISECONDS_BY_LEVEL = { [levels.ERROR] = 8000, [levels.WARN] = 6000 }

local level_names = {
    [levels.TRACE] = 'TRACE',
    [levels.DEBUG] = 'DEBUG',
    [levels.INFO] = 'INFO',
    [levels.WARN] = 'WARN',
    [levels.ERROR] = 'ERROR',
}
local level_titles = { [levels.ERROR] = 'Error', [levels.WARN] = 'Warning' }
local level_title_highlights = { [levels.ERROR] = 'NotebashNoteError', [levels.WARN] = 'NotebashNoteWarn' }

-- neovim ui protocol kinds counted as errors or warnings. named misery.
local neovim_message_kind_levels = {
    emsg = levels.ERROR,
    echoerr = levels.ERROR,
    lua_error = levels.ERROR,
    rpc_error = levels.ERROR,
    wmsg = levels.WARN,
}

-- keep across live code reload (see live_code_reload.lua): the replaced
-- functions, active message ui module and ui observer namespace. i'd love my
-- own memory to survive this well.
messages.original_functions = nil
messages.extended_ui_module_name = nil
messages.observer_namespace = nil

-- on-screen notifications, oldest first. age wins fuck all else.
messages.visible = {}
local fade_timer = nil

------------------------------------------------------------------- log

function messages.log_path()
    return vim.fs.joinpath(tostring(vim.fn.stdpath('log')), LOG_FILE_NAME)
end

-- "2026-11-13 14:02:11 error first line" (level as written), with later lines
-- indented by four spaces. create the file with mode 0600 and reset it to
-- 0600 on every write in case something loosened it. my failures are private.
-- i still have this tiny bit of dignity (?).
local function create_log_directory(path)
    local directory = vim.fs.dirname(path)
    if not vim.uv.fs_stat(directory) then
        vim.fn.mkdir(directory, 'p')
        vim.uv.fs_chmod(directory, tonumber('700', 8))
    end
end

function messages.write_to_log(text, level)
    local path = messages.log_path()
    create_log_directory(path)
    local existing_file = vim.uv.fs_stat(path)
    if existing_file and existing_file.size >= LOG_SIZE_LIMIT_BYTES then
        vim.uv.fs_rename(path, path .. '.1')
    end
    local file_descriptor = vim.uv.fs_open(path, 'a', PRIVATE_FILE_MODE)
    if not file_descriptor then
        return false
    end
    vim.uv.fs_fchmod(file_descriptor, PRIVATE_FILE_MODE)
    local text_lines = vim.split(tostring(text):gsub('\r', ''), '\n', { plain = true })
    local entry_lines = { ('%s %s %s'):format(os.date('%Y-%m-%d %H:%M:%S'), level_names[level] or 'INFO', text_lines[1]) }
    for line_index = 2, #text_lines do
        entry_lines[#entry_lines + 1] = '    ' .. text_lines[line_index]
    end
    vim.uv.fs_write(file_descriptor, table.concat(entry_lines, '\n') .. '\n')
    vim.uv.fs_close(file_descriptor)
    return true
end

-- help > message log opens a read-only tab. create an empty log first if
-- nothing was logged yet. enjoy that brief absence of shit.
function messages.open_log()
    local path = messages.log_path()
    if not vim.uv.fs_stat(path) then
        create_log_directory(path)
        local file_descriptor = vim.uv.fs_open(path, 'a', PRIVATE_FILE_MODE)
        if file_descriptor then
            vim.uv.fs_close(file_descriptor)
        end
    end
    require('notebashpp.file_commands').open_path(path)
    if api.nvim_buf_get_name(0) == path then
        -- already open? read entries written since. failure kept working.
        vim.bo.modifiable = true
        vim.cmd('silent! checktime')
        messages.make_log_buffer_read_only(0)
        api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(0), 0 })
    end
end

-- keep the log read-only via help, file > open or a restored session. i want
-- to rewrite my failures too. absolutely no.
function messages.make_log_buffer_read_only(buffer)
    if api.nvim_buf_get_name(buffer) == messages.log_path() then
        vim.bo[buffer].readonly = true
        vim.bo[buffer].modifiable = false
    end
end

---------------------------------------------------------- notifications

local function close_window(notification)
    if notification.window and api.nvim_win_is_valid(notification.window) then
        pcall(api.nvim_win_close, notification.window, true)
    end
    notification.window = nil
end

-- stack upwards just above the status bar, newest at the bottom. close any
-- that won't fit below the menu bar. even this shit has a housing problem.
local function arrange_notifications()
    local bottom_row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
    local top_limit = vim.o.showtabline > 0 and 1 or 0
    local still_visible = {}
    for notification_index = #messages.visible, 1, -1 do
        local notification = messages.visible[notification_index]
        local outer_height = notification.height + 2
        local top_row = bottom_row - outer_height
        local fits = top_row >= top_limit and #still_visible < NOTIFICATIONS_SHOWN_AT_MOST
        if fits and notification.window and api.nvim_win_is_valid(notification.window) then
            api.nvim_win_set_config(notification.window, {
                relative = 'editor',
                row = top_row,
                col = math.max(0, vim.o.columns - notification.width - 2),
            })
            table.insert(still_visible, 1, notification)
            bottom_row = top_row
        else
            close_window(notification)
        end
    end
    messages.visible = still_visible
end

local function stop_fade_timer()
    if fade_timer then
        fade_timer:stop()
        fade_timer:close()
        fade_timer = nil
    end
end

-- one timer runs while any notification is on screen. after its time, each
-- notification gets more transparent per step, then closes. getting old, with
-- a reliable exit.
local function fade_tick()
    local current_time = vim.uv.now()
    local closed_any = false
    for _, notification in ipairs(messages.visible) do
        if notification.visible_until and current_time >= notification.visible_until then
            notification.fade_step = notification.fade_step + 1
            if notification.fade_step >= FADE_STEP_COUNT or not (notification.window and api.nvim_win_is_valid(notification.window)) then
                close_window(notification)
                closed_any = true
            else
                vim.wo[notification.window].winblend = math.floor(notification.fade_step * 100 / FADE_STEP_COUNT)
            end
        end
    end
    if closed_any then
        arrange_notifications()
    end
    if #messages.visible == 0 then
        stop_fade_timer()
    end
end

local function start_fade_timer()
    if fade_timer then
        return
    end
    fade_timer = vim.uv.new_timer()
    if fade_timer then
        fade_timer:start(FADE_STEP_MILLISECONDS, FADE_STEP_MILLISECONDS, vim.schedule_wrap(fade_tick))
    end
end

local function title_chunks(notification)
    local title = notification.title or level_titles[notification.level]
    if not title then
        return nil
    end
    if notification.repeat_count > 1 then
        title = ('%s (%d)'):format(title, notification.repeat_count)
    end
    return { { ' ' .. title .. ' ', level_title_highlights[notification.level] or 'NotebashNoteTitle' } }
end

-- display lines: drop carriage returns, cap at notification_line_limit. the
-- log keeps the rest. shit doesn't disappear because i stop looking.
local function display_lines(text)
    local text_lines = vim.split(tostring(text):gsub('\r', ''), '\n', { plain = true })
    while #text_lines > 1 and vim.trim(text_lines[#text_lines]) == '' do
        table.remove(text_lines)
    end
    if #text_lines > NOTIFICATION_LINE_LIMIT then
        text_lines = vim.list_slice(text_lines, 1, NOTIFICATION_LINE_LIMIT)
        text_lines[#text_lines] = text_lines[#text_lines] .. ' ...'
    end
    return text_lines
end

local function open_notification_window(notification)
    local text_lines = display_lines(notification.text)
    local width_limit = math.max(10, math.min(NOTIFICATION_WIDTH_LIMIT, vim.o.columns - 4))
    local width = 0
    for _, text_line in ipairs(text_lines) do
        width = math.max(width, vim.fn.strdisplaywidth(text_line))
    end
    local title = title_chunks(notification)
    if title then
        width = math.max(width, vim.fn.strdisplaywidth(title[1][1]) + 2)
    end
    width = math.max(1, math.min(width, width_limit))
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buffer, 0, -1, false, text_lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].bufhidden = 'wipe'
    local opened, window = pcall(api.nvim_open_win, buffer, false, {
        relative = 'editor',
        row = 0,
        col = math.max(0, vim.o.columns - width - 2),
        width = width,
        height = 1,
        style = 'minimal',
        border = 'single',
        title = title,
        title_pos = title and 'left' or nil,
        focusable = false,
        noautocmd = true,
        zindex = 240,
    })
    if not opened then
        pcall(api.nvim_buf_delete, buffer, { force = true })
        error(window)
    end
    vim.w[window].notebashpp_notification = true
    vim.wo[window].winhighlight = 'Normal:NotebashNote,NormalFloat:NotebashNote,FloatBorder:NotebashNoteBorder'
    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    vim.wo[window].winblend = 0
    local text_height = api.nvim_win_text_height(window, {}).all
    notification.height = math.max(1, math.min(text_height, NOTIFICATION_LINE_LIMIT))
    api.nvim_win_set_config(window, { height = notification.height })
    notification.window = window
    notification.width = width
end

local function visible_milliseconds(options, level)
    if options.timeout == false then
        return nil
    end
    return tonumber(options.timeout) or VISIBLE_MILLISECONDS_BY_LEVEL[level] or DEFAULT_VISIBLE_MILLISECONDS
end

-- show `text` in a float without logging it. options.level uses
-- vim.log.levels (default info) to pick title and colour; options.title
-- replaces the title. options.timeout is milliseconds on screen, or false to
-- stay until messages.dismiss(). some crap needs evicting. return the
-- notification, or nil if a fast event or locked text made it wait for neovim
-- to be free. i'd love that kind of job security.
function messages.show(text, options)
    options = options or {}
    local level = options.level or levels.INFO
    if vim.in_fast_event() then
        vim.schedule(function()
            messages.show(text, options)
        end)
        return nil
    end
    -- same message still on screen? count repeats in its title and keep it
    -- longer instead of stacking a copy. one failure, compound interest.
    local newest = messages.visible[#messages.visible]
    if newest and newest.text == text and newest.level == level and newest.title == options.title and newest.fade_step == 0 then
        newest.repeat_count = newest.repeat_count + 1
        local milliseconds = visible_milliseconds(options, level)
        newest.visible_until = milliseconds and (vim.uv.now() + milliseconds) or nil
        if newest.window and api.nvim_win_is_valid(newest.window) then
            pcall(api.nvim_win_set_config, newest.window, { title = title_chunks(newest), title_pos = 'left' })
        end
        return newest
    end
    local milliseconds = visible_milliseconds(options, level)
    local notification = {
        text = text,
        level = level,
        title = options.title,
        repeat_count = 1,
        fade_step = 0,
        visible_until = milliseconds and (vim.uv.now() + milliseconds) or nil,
    }
    local opened = pcall(open_notification_window, notification)
    if not opened then
        -- locked text (an expression mapping, completion) refuses a new
        -- window. try once more when neovim is free. give up on a second
        -- failure; the log already has the message. i wish i gave up this
        -- sensibly.
        if not options.is_second_attempt then
            vim.schedule(function()
                messages.show(text, vim.tbl_extend('force', options, { is_second_attempt = true }))
            end)
        end
        return nil
    end
    table.insert(messages.visible, notification)
    arrange_notifications()
    start_fade_timer()
    return notification
end

function messages.dismiss(notification)
    if not notification then
        return
    end
    close_window(notification)
    arrange_notifications()
end

-- on-screen notification texts, oldest first. my failure chronology.
function messages.visible_texts()
    local texts = {}
    for _, notification in ipairs(messages.visible) do
        if notification.window and api.nvim_win_is_valid(notification.window) then
            texts[#texts + 1] = notification.text
        end
    end
    return texts
end

---------------------------------------------------------------- notify

local function level_number(level)
    if type(level) == 'string' then
        return levels[level:upper()] or levels.INFO
    end
    return tonumber(level) or levels.INFO
end

-- vim.notify replacement: log, then show. in a fast event (a libuv callback),
-- both wait until neovim is free. fast is a cruel name.
function messages.notify(text, level, options)
    level = level_number(level)
    if level == levels.OFF then
        return
    end
    text = tostring(text)
    if vim.in_fast_event() then
        vim.schedule(function()
            messages.notify(text, level, options)
        end)
        return
    end
    pcall(messages.write_to_log, text, level)
    local title = type(options) == 'table' and type(options.title) == 'string' and options.title or nil
    messages.show(text, { level = level, title = title })
end

-- error caught in a key action or menu item: log the stack trace; show the
-- message in a float, prefixed with the command name. i want to know which
-- bastard did it (usually me).
function messages.report_error(command_name, error_message, stack_trace)
    if vim.in_fast_event() then
        vim.schedule(function()
            messages.report_error(command_name, error_message, stack_trace)
        end)
        return
    end
    local text = tostring(error_message)
    if command_name and command_name ~= '' then
        text = command_name .. ': ' .. text
    end
    pcall(messages.write_to_log, stack_trace and (text .. '\n' .. stack_trace) or text, levels.ERROR)
    messages.show(text, { level = levels.ERROR })
end

-- run action(...), return true and its results. on a lua error, report it and
-- return false. command_name names the command in the message.
-- accountability, for the crap i wrote voluntarily.
function messages.call(command_name, action, ...)
    local results = vim.F.pack_len(xpcall(action, function(error_value)
        return { message = error_value, stack_trace = (debug.traceback('', 2):gsub('^\n', '')) }
    end, ...))
    if not results[1] then
        local caught = results[2]
        messages.report_error(command_name, type(caught) == 'table' and caught.message or caught, type(caught) == 'table' and caught.stack_trace or nil)
        return false
    end
    return unpack(results, 1, results.n)
end

---------------------------------------------------------------- neovim

local function message_text_from_chunks(chunks)
    local pieces = {}
    for _, chunk in ipairs(chunks or {}) do
        if type(chunk) == 'table' then
            pieces[#pieces + 1] = tostring(chunk[2] or chunk[1] or '')
        end
    end
    return table.concat(pieces)
end

-- with the message ui enabled, a second ui observer sees every message neovim
-- shows and reports its errors and warnings. the message ui still draws the
-- cmdline and other messages. i hired myself another unpaid job watching this
-- shit.
local function attach_message_observer()
    if messages.observer_namespace then
        return
    end
    local namespace = api.nvim_create_namespace('notebashpp_message_observer')
    local attached = pcall(vim.ui_attach, namespace, { ext_messages = true, set_cmdheight = false }, function(event, kind, content)
        if event ~= 'msg_show' or not neovim_message_kind_levels[kind] then
            return
        end
        local text = message_text_from_chunks(content)
        local level = neovim_message_kind_levels[kind]
        vim.schedule(function()
            local current_module = package.loaded['notebashpp.messages']
            if current_module and text ~= '' then
                current_module.notify(text, level)
            end
        end)
    end)
    if attached then
        messages.observer_namespace = namespace
    end
end

-- enable neovim's experimental message ui once a ui attaches; without one it
-- does nothing. the module moved in neovim 0.12, so try both names. even the
-- damn module wanted to leave.
function messages.enable_extended_ui()
    if messages.extended_ui_module_name or #api.nvim_list_uis() == 0 then
        return
    end
    for _, module_name in ipairs({ 'vim._core.ui2', 'vim._extui' }) do
        local found, extended_ui = pcall(require, module_name)
        if found and type(extended_ui) == 'table' and type(extended_ui.enable) == 'function' then
            if pcall(extended_ui.enable, { enable = true }) then
                messages.extended_ui_module_name = module_name
                attach_message_observer()
                return
            end
        end
    end
end

-- without the message ui, read neovim's last error and warning on idle.
-- errors deliberately hidden with silent! also set v:errmsg, but never reach
-- message history. report only ones near the end of that history. then clear
-- the message line: the float already shows the message. with 'showmode' off,
-- nothing else clears it, so the next error would scroll it into a hit-enter
-- prompt. i refuse to press enter to confirm that my afternoon is fucked. i'm
-- here, i noticed.
local function report_neovim_errors_without_extended_ui()
    if messages.extended_ui_module_name then
        return
    end
    local reported_any = false
    for _, variable_and_level in ipairs({ { 'errmsg', levels.ERROR }, { 'warningmsg', levels.WARN } }) do
        local variable_name, level = variable_and_level[1], variable_and_level[2]
        local text = vim.v[variable_name]
        if text ~= '' then
            vim.v[variable_name] = ''
            local history = vim.fn.execute('messages')
            if history:sub(-4000):find(text, 1, true) then
                messages.notify(text, level)
                reported_any = true
            end
        end
    end
    if reported_any then
        vim.cmd('echo ""')
    end
end

-- without the message ui, turn nvim_echo into a notification for err = true,
-- an error or warning highlight, or more than one line. otherwise a long echo
-- ends in "press enter". failure needs applause (?).
local function echo_replacement(chunks, history, options)
    local current_module = package.loaded['notebashpp.messages'] or messages
    local original_echo = (current_module.original_functions or messages.original_functions).nvim_echo
    if current_module.extended_ui_module_name or vim.in_fast_event() then
        return original_echo(chunks, history, options)
    end
    local level = nil
    if type(options) == 'table' and options.err then
        level = levels.ERROR
    end
    local text = message_text_from_chunks(chunks)
    for _, chunk in ipairs(type(chunks) == 'table' and chunks or {}) do
        if type(chunk) == 'table' and (chunk[2] == 'ErrorMsg' or chunk[2] == 'WarningMsg') then
            level = level or (chunk[2] == 'ErrorMsg' and levels.ERROR or levels.WARN)
        end
    end
    if not level and not text:find('\n', 1, true) then
        return original_echo(chunks, history, options)
    end
    current_module.notify(text, level or levels.INFO)
end

local function notify_replacement(text, level, options)
    return require('notebashpp.messages').notify(text, level, options)
end

-- log and floats replace neovim's message area for all vim.notify output.
-- keep replaced functions once so live reload never wraps a wrapper. i've
-- wasted enough life without making recursion out of it.
function messages.setup()
    if not messages.original_functions then
        messages.original_functions = { notify = vim.notify, nvim_echo = api.nvim_echo }
        vim.notify = notify_replacement
        api.nvim_echo = echo_replacement
    end
    local augroup = api.nvim_create_augroup('notebashpp_messages', { clear = true })
    api.nvim_create_autocmd('SafeState', {
        group = augroup,
        callback = function()
            require('notebashpp.messages').report_neovim_errors()
        end,
    })
    api.nvim_create_autocmd('UIEnter', {
        group = augroup,
        callback = function()
            vim.schedule(function()
                require('notebashpp.messages').enable_extended_ui()
            end)
        end,
    })
    api.nvim_create_autocmd('BufReadPost', {
        group = augroup,
        callback = function(event)
            require('notebashpp.messages').make_log_buffer_read_only(event.buf)
        end,
    })
    api.nvim_create_autocmd({ 'VimResized', 'OptionSet' }, {
        group = augroup,
        callback = function(event)
            if event.event == 'VimResized' or event.match == 'cmdheight' or event.match == 'laststatus' or event.match == 'showtabline' then
                require('notebashpp.messages').arrange()
            end
        end,
    })
    messages.enable_extended_ui()
end

function messages.report_neovim_errors()
    report_neovim_errors_without_extended_ui()
end

function messages.arrange()
    arrange_notifications()
end

-- live reload: close this copy's floats and stop its timer so none outlive
-- the code that closes them. someone should stay to clean up.
function messages._unload()
    stop_fade_timer()
    for _, notification in ipairs(messages.visible) do
        close_window(notification)
    end
    messages.visible = {}
end

return messages
