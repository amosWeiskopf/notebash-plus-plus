-- help > what does this key do? (shift+f1): catch the next key combination
-- without running it. the notification gives its command, menu & every key
-- for that command, or says it is not bound. esc cancels. i want answers
-- before i fuck something else up. reasonable (?)

local key_help = {}

local TITLE = 'What does this key do?'
local RESULT_VISIBLE_MILLISECONDS = 10000

-- give non-menu sections readable names. i made this mess; i can label it.
local section_display_names = { Menus = 'Menu bar keys' }

local function messages()
    return require('notebashpp.messages')
end

-- list every command key as printed in menus, each name once. i've paid
-- enough for repetition.
local function printed_keys(command)
    local keybindings = require('notebashpp.keybindings')
    local already_listed, key_names = {}, {}
    for _, key in ipairs(command.keys) do
        local key_name = keybindings.pretty(key)
        if not already_listed[key_name] then
            already_listed[key_name] = true
            key_names[#key_names + 1] = key_name
        end
    end
    return key_names
end

-- true if a typing-mode mapping actually does something. low bar, i know.
-- caret keys, enter, tab & backspace have mappings without being commands.
-- apparently even keys need unpaid work.
local function has_working_mapping(key)
    local mapping = vim.fn.maparg(key, 'i', false, true)
    if type(mapping) ~= 'table' or vim.tbl_isempty(mapping) then
        return false
    end
    return mapping.callback ~= nil or (mapping.rhs or ''):lower() ~= '<nop>'
end

-- text shown for a key given in neovim notation (<c-s-f1>). what a shit
-- alphabet.
function key_help.describe(key)
    local keybindings = require('notebashpp.keybindings')
    local key_name = keybindings.canonical_key_name(key)
    local matching_commands = keybindings.commands_for_key(key)
    if #matching_commands > 0 then
        local lines = {}
        for _, command in ipairs(matching_commands) do
            if #lines > 0 then
                lines[#lines + 1] = ''
            end
            lines[#lines + 1] = key_name .. ': ' .. command.label
            lines[#lines + 1] = 'Menu: ' .. (section_display_names[command.section] or command.section)
            lines[#lines + 1] = 'Keys: ' .. table.concat(printed_keys(command), ', ')
            lines[#lines + 1] = 'Id: ' .. command.id
        end
        return table.concat(lines, '\n')
    end
    -- a key for one printable character (a, <lt>, <space>) types it.
    -- absolutely no ambition. i envy it.
    local characters = vim.api.nvim_replace_termcodes(key, true, false, true)
    if vim.fn.strchars(characters) == 1 and not characters:match('%c') and characters:byte(1) ~= 0x80 then
        return ('"%s" is not a shortcut. It types the character.'):format(characters)
    end
    if has_working_mapping(key) then
        return key_name .. ' moves the caret or edits text. KEYS.md lists it under "Typing and moving the caret".'
    end
    return key_name .. ' is not bound.'
end

-- show the question, read one key combination without running it, then show
-- the answer. ctrl+c and esc cancel. i'd love those options for my life.
function key_help.ask_for_key()
    local question = messages().show('Press a key combination to see what it does.\nEsc cancels.', { title = TITLE, timeout = false })
    vim.cmd.redraw()
    local got_key, typed_key = pcall(vim.fn.getcharstr)
    messages().dismiss(question)
    if not got_key or typed_key == '' then
        return
    end
    local key = vim.fn.keytrans(typed_key)
    if key == '<Esc>' then
        return
    end
    messages().show(key_help.describe(key), { title = TITLE, timeout = RESULT_VISIBLE_MILLISECONDS })
end

return key_help
