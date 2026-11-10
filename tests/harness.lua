-- the test harness starts notebash++ inside a hidden neovim and pokes it the
-- way neovide does: keys through nvim_input(), results over rpc. i built an
-- entire puppet show to ask an exit code if i'm a failure. basically cheaper
-- than asking somebody who knows me.
--
-- nvim -l tests/run.lua

local harness = {}

local project_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
harness.project_root = project_root

local failed_test_messages, passed_test_count = {}, 0

function harness.start_editor(options)
    options = options or {}
    local config_directory = harness.config_directory
    -- options.code_root runs another copy of the code for live reload tests.
    -- they need a copy they are allowed to break. i want at least one thing
    -- in my life where the damage is intentional.
    if options.code_root then
        config_directory = harness.temporary_directory .. '/config-copy'
        vim.fn.mkdir(config_directory, 'p')
        vim.uv.fs_symlink(options.code_root, config_directory .. '/notebashpp-test')
    end
    local environment = {
        NVIM_APPNAME = 'notebashpp-test',
        XDG_CONFIG_HOME = config_directory,
        XDG_DATA_HOME = harness.temporary_directory .. '/data',
        XDG_STATE_HOME = harness.temporary_directory .. '/state',
        NOTEBASHPP_TEST = '1',
        NOTEBASHPP_NO_SESSION = options.session and '' or '1',
        NOTEBASHPP_USER_FILE = options.user_file,
    }
    -- every deprecated neovim api call gets recorded here. the last test
    -- fails if the list isn't empty. we all get old, but apparently this
    -- bastard gets a replacement api while i just get tired.
    local command_line = {
        'nvim',
        '--embed',
        '--headless',
        '--cmd',
        'lua _G.deprecated_api_calls = {}; vim.deprecate = function(name) table.insert(_G.deprecated_api_calls, name) end',
    }
    -- options.listen opens a socket that attach_screen() connects to. more
    -- plumbing for this crap.
    if options.listen then
        harness.socket_path = ('%s/screen-%d.sock'):format(harness.temporary_directory, vim.uv.hrtime())
        vim.list_extend(command_line, { '--listen', harness.socket_path })
    end
    for _, argument in ipairs(options.extra_arguments or {}) do
        table.insert(command_line, argument)
    end
    harness.editor_channel = vim.fn.jobstart(command_line, { rpc = true, env = environment, cwd = harness.temporary_directory })
    assert(harness.editor_channel > 0, 'could not start nvim')
    harness.wait_until_idle()
end

function harness.stop_editor()
    if harness.screen_channel then
        pcall(vim.fn.chanclose, harness.screen_channel)
        harness.screen_channel = nil
    end
    pcall(vim.fn.jobstop, harness.editor_channel)
    vim.wait(50)
end

-- attach a screen to an editor started with options.listen, as a terminal or
-- neovide would. some prompts (hit-enter) only happen with a screen.
-- basically neovim needs a witness to make life harder. we read & discard the
-- drawing instructions. the attach request uses raw msgpack, so we throw away
-- its answer too (i wish my failures were this easy to dispose of).
function harness.attach_screen()
    harness.screen_channel = vim.fn.sockconnect('pipe', harness.socket_path, {
        on_data = function() end,
    })
    vim.fn.chansend(harness.screen_channel, vim.mpack.encode({ 0, 1, 'nvim_ui_attach', { 100, 30, { ext_linegrid = true } } }))
    harness.wait_until_idle(300)
end

-- send keys, give the editor time, and return nvim_get_mode(). it answers
-- even while neovim waits at a prompt. dismiss any blocking prompt after
-- reading the mode, so one failure doesn't hang the rest. i'd love to apply
-- this policy to my life.
function harness.mode_after_keys(keys, milliseconds_to_wait)
    harness.request('nvim_input', keys)
    vim.wait(milliseconds_to_wait or 150)
    local mode = harness.request('nvim_get_mode')
    if mode.blocking then
        harness.request('nvim_input', '<CR>')
        vim.wait(50)
    end
    return mode
end

---@return any
function harness.request(method, ...)
    return vim.rpcrequest(harness.editor_channel, method, ...)
end

---@return any
function harness.run_lua(code, ...)
    return harness.request('nvim_exec_lua', code, { ... })
end

function harness.wait_until_idle(milliseconds_to_wait)
    vim.wait(milliseconds_to_wait or 40)
    -- neovim answers requests after queued input and scheduled callbacks run.
    -- so we ask twice: the first answer lets a scheduled startinsert sneak
    -- in, the second is the truth. i want certainty, and apparently my
    -- remaining time on earth is best spent interrogating a text editor.
    harness.request('nvim_eval', '1')
    vim.wait(10)
    harness.request('nvim_eval', '1')
end

function harness.press_keys(keys, milliseconds_to_wait)
    harness.request('nvim_input', keys)
    harness.wait_until_idle(milliseconds_to_wait)
end

-- types plain text without <> key notation. escape a lone '<' as <lt>,
-- because neovim assumes a key name follows. even punctuation needs a damn
-- cover story to get through this thing.
function harness.type_text(text, milliseconds_to_wait)
    harness.request('nvim_input', (text:gsub('<', '<lt>')))
    harness.wait_until_idle(milliseconds_to_wait)
end

function harness.set_buffer_lines(lines)
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, ...)', lines)
    harness.wait_until_idle()
end

---@return string[]
function harness.buffer_lines()
    return harness.run_lua('return vim.api.nvim_buf_get_lines(0, 0, -1, false)')
end

function harness.buffer_text()
    return table.concat(harness.buffer_lines(), '\n')
end

function harness.cursor_position()
    return harness.run_lua('return vim.api.nvim_win_get_cursor(0)')
end

function harness.set_cursor_position(line_number, column)
    harness.run_lua('vim.api.nvim_win_set_cursor(0, {...})', line_number, column)
    harness.wait_until_idle()
end

function harness.current_mode()
    return harness.run_lua('return vim.api.nvim_get_mode().mode')
end

-- the embedded neovim's + register. with notebashpp_test set, the clipboard
-- module never hooks up win32yank or xclip. tests copy & paste privately,
-- leaving the real clipboard alone. maybe your last kind message is still in
-- there. i'd hate to replace it with test crap.
function harness.clipboard_text()
    return harness.run_lua('return table.concat(vim.fn.getreg("+", 1, true), "\\n")')
end

function harness.set_clipboard_text(text)
    harness.run_lua('vim.fn.setreg("+", ...)', text)
end

function harness.selected_text()
    return harness.run_lua([[
        local selection = require('notebashpp.helpers').get_selection()
        if not selection then return '' end
        return table.concat(require('notebashpp.helpers').get_text_in_range(selection), '\n')
    ]])
end

function harness.test_case(name, test_body)
    local succeeded, error_message = pcall(test_body)
    if succeeded then
        passed_test_count = passed_test_count + 1
        io.write('  ok   ', name, '\n')
    else
        table.insert(failed_test_messages, name .. ': ' .. tostring(error_message))
        io.write('  FAIL ', name, '\n       ', tostring(error_message), '\n')
    end
end

function harness.expect_equal(expected, actual, description)
    if not vim.deep_equal(expected, actual) then
        error(('%s: want %s, got %s'):format(description or 'value', vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

function harness.print_summary()
    io.write(('\n%d passed, %d failed\n'):format(passed_test_count, #failed_test_messages))
    return #failed_test_messages == 0
end

-- a throwaway config directory in a temp folder, symlinked to the project.
-- the editor under test loads this code, never your real settings. i want the
-- damage confined to my own work. there's absolutely enough disappointment in
-- opening somebody else's.
harness.temporary_directory = vim.fn.tempname()
vim.fn.mkdir(harness.temporary_directory, 'p')
-- macos gives us /var/... and neovim reports /private/var/... (same folder).
-- use the real path so tests compare names as plain strings. i want one
-- identity crisis at a time. mine is absolutely enough.
harness.temporary_directory = vim.uv.fs_realpath(harness.temporary_directory)
harness.config_directory = harness.temporary_directory .. '/config'
vim.fn.mkdir(harness.config_directory, 'p')
vim.uv.fs_symlink(project_root, harness.config_directory .. '/notebashpp-test')

return harness
