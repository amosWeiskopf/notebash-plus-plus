-- the + register is the windows clipboard.
--
-- win32yank.exe (in bin/) talks directly to windows and preserves hebrew &
-- other utf-8 text. clip.exe turns it into question marks. basically you lose
-- your grandmother's recipe and get an interrogation from a dead woman. xclip
-- through wslg is the fallback. each call gets 2 seconds maximum so stuck wsl
-- interop cannot freeze the editor. after failure we keep the text in memory
-- instead. i want copy & paste to work before i die. ambitious (?)

local clipboard = {}

local plugin_root = require('notebashpp').root
local win32yank_path = plugin_root .. '/bin/win32yank.exe'
local time_limit_milliseconds = 2000

-- kept on the module table to survive a reload. i'd love that option.
clipboard.memory = { lines = { '' }, regtype = 'v' }

-- run a clipboard program with a 2 second limit. return stdout on success,
-- nil on anything else. kill a stuck process. i gave it a deadline and it
-- chose death over copying text. absolutely understandable.
local function run_with_time_limit(command, input)
    local started, process = pcall(vim.system, command, { stdin = input, text = true, cwd = '/' })
    if not started then
        return nil
    end
    local result = process:wait(time_limit_milliseconds)
    if not result or result.code ~= 0 then
        pcall(function()
            process:kill(9)
        end)
        return nil
    end
    return result.stdout or ''
end

-- try clipboard programs best first. tests use their own clipboard and never
-- touch the real windows one. even this crap has boundaries.
local clipboard_tools = {}
if not vim.env.NOTEBASHPP_TEST then
    if vim.fn.executable(win32yank_path) == 1 then
        table.insert(clipboard_tools, { copy = { win32yank_path, '-i', '--crlf' }, paste = { win32yank_path, '-o', '--lf' } })
    end
    if vim.fn.executable('xclip') == 1 and vim.env.DISPLAY then
        table.insert(clipboard_tools, {
            copy = { 'xclip', '-selection', 'clipboard', '-in' },
            paste = { 'xclip', '-selection', 'clipboard', '-out' },
        })
    end
end

local function copy_to_system_clipboard(lines, register_type)
    clipboard.memory = { lines = vim.deepcopy(lines), regtype = register_type }
    local text = table.concat(lines, '\n')
    if register_type == 'V' then
        text = text .. '\n'
    end
    for _, clipboard_tool in ipairs(clipboard_tools) do
        if run_with_time_limit(clipboard_tool.copy, text) then
            return
        end
    end
end

local function paste_from_system_clipboard()
    for _, clipboard_tool in ipairs(clipboard_tools) do
        local pasted_text = run_with_time_limit(clipboard_tool.paste)
        if pasted_text then
            pasted_text = pasted_text:gsub('\r\n', '\n')
            local lines = vim.split(pasted_text, '\n', { plain = true })
            -- if the text exactly matches our copy, keep our register type so
            -- a column copy pastes as a column. windows forgets the shape. i
            -- wrote code to remember it, which is apparently what i'm doing
            -- with my remaining years.
            local is_our_own_copy = table.concat(lines, '\n') == table.concat(clipboard.memory.lines, '\n')
            if is_our_own_copy then
                return { vim.deepcopy(clipboard.memory.lines), clipboard.memory.regtype }
            end
            return { lines, 'v' }
        end
    end
    return { vim.deepcopy(clipboard.memory.lines), clipboard.memory.regtype }
end

-- wsl: win32yank (or xclip). tests: memory only. elsewhere leave neovim's own
-- clipboard detection alone (pbcopy, wl-copy, xclip, windows). it does better
-- there than we would. i want to recognise at least one limit before death.
function clipboard.setup()
    if not vim.env.NOTEBASHPP_TEST and (vim.fn.has('wsl') == 0 or #clipboard_tools == 0) then
        return
    end
    vim.g.clipboard = {
        name = 'notebashpp',
        copy = { ['+'] = copy_to_system_clipboard, ['*'] = copy_to_system_clipboard },
        paste = { ['+'] = paste_from_system_clipboard, ['*'] = paste_from_system_clipboard },
        cache_enabled = 0,
    }
end

-- clipboard text is a list of lines plus a kind: 'v' plain text, 'b' a column
-- block, 'line' a whole line copied with ctrl+l or ctrl+shift+x. line_copy
-- holds that whole line so we recognise it on return. i built a homecoming
-- for clipboard text. my life is absolutely going according to plan.
clipboard.line_copy = nil

function clipboard.set(lines, kind)
    if kind == 'line' then
        clipboard.line_copy = table.concat(lines, '\n')
        vim.fn.setreg('+', lines, 'v')
        return
    end
    clipboard.line_copy = nil
    vim.fn.setreg('+', lines, kind == 'b' and 'b' or 'v')
end

function clipboard.get()
    local clipboard_lines = vim.fn.getreg('+', 1, true)
    local register_type = vim.fn.getregtype('+')
    if type(clipboard_lines) ~= 'table' then
        clipboard_lines = { clipboard_lines }
    end
    if #clipboard_lines == 0 then
        clipboard_lines = { '' }
    end
    if clipboard.line_copy and table.concat(clipboard_lines, '\n') == clipboard.line_copy then
        return clipboard_lines, 'line'
    end
    if register_type:sub(1, 1) == '\22' then
        return clipboard_lines, 'b'
    end
    if register_type == 'V' then
        table.insert(clipboard_lines, '')
    end
    return clipboard_lines, 'v'
end

return clipboard
