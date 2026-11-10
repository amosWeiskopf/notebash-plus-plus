-- macro menu: ctrl+shift+r starts and stops recording; ctrl+shift+p plays
-- back. record keystrokes as typed, replay through the same notepad++ keys
-- and dialogs they were typed into. i want the computer to repeat my mistakes
-- for me. apparently wasting my own life wasn't efficient enough.

local macros = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- this namespace owns our vim.on_key listener so we can switch it off.
-- something in my life has to stop.
local key_listener_namespace = api.nvim_create_namespace('notebashpp_macro')
-- keys being recorded now, or nil when nothing is recording. the last
-- finished recording & named saved macros live on the module table, so a code
-- reload keeps them. my mistakes have better housing security than i do.
local recorded_keys = nil
macros.recorded = nil
macros.saved = {}

local saved_macros_file = vim.fn.stdpath('data') .. '/macros.json'

-- read saved macros from disk at load time. missing or broken file means no
-- saved macros, no error. basically bankruptcy without the paperwork.
local function load_saved()
    local read_ok, file_lines = pcall(vim.fn.readfile, saved_macros_file)
    if read_ok then
        local decode_ok, decoded_macros = pcall(vim.json.decode, table.concat(file_lines, '\n'))
        if decode_ok and type(decoded_macros) == 'table' then
            macros.saved = decoded_macros
        end
    end
end
load_saved()

function macros.recording()
    return recorded_keys ~= nil
end

-- the same key starts and stops recording. append every typed key while
-- recording; the status bar says "recording". finally an honest warning that
-- my poor decisions are being kept.
function macros.toggle_record()
    if recorded_keys then
        -- drop the key that stopped recording. let something go.
        table.remove(recorded_keys)
        macros.recorded = table.concat(recorded_keys)
        recorded_keys = nil
        vim.on_key(nil, key_listener_namespace)
        vim.cmd('redrawstatus')
        return
    end
    recorded_keys = {}
    vim.on_key(function(_, typed_keys)
        if recorded_keys and typed_keys and typed_keys ~= '' then
            recorded_keys[#recorded_keys + 1] = typed_keys
        end
    end, key_listener_namespace)
    vim.cmd('redrawstatus')
end

-- play a key sequence (last recording by default) `repeat_count` times as one
-- undo step. never while recording, or it records itself playing itself. i
-- already have a brain that repeats useless shit for free.
function macros.play(repeat_count, key_sequence)
    key_sequence = key_sequence or macros.recorded
    if not key_sequence or key_sequence == '' or recorded_keys then
        return
    end
    repeat_count = math.floor(repeat_count or 1)
    -- all runs reach neovim as one long key string. 16 mb holds millions of
    -- runs. beyond that, a typo like 9999999999 would eat the memory before
    -- the first key gets typed. basically bankruptcy before opening the shop.
    if repeat_count < 1 or #key_sequence * repeat_count > 16 * 1024 * 1024 then
        return helpers.warn('Too many runs for this macro; try a smaller number.')
    end
    helpers.start_new_undo_step()
    api.nvim_feedkeys(string.rep(key_sequence, repeat_count), 'mt', false)
end

-- ask how many times to run the macro. put a number on the futility.
function macros.play_many()
    if not macros.recorded then
        return
    end
    local answer = helpers.ask('Run the macro how many times? (empty: until the end of file) ', '1')
    if answer == '' then
        -- until end of file means stopping when the caret no longer moves
        -- down. in practice, play once per line left below the caret (at
        -- least once), trusting each run to move down one line. absolutely
        -- blind faith. i'd love to see my retirement plan checked this
        -- carefully.
        local line_count = helpers.count_lines()
        local repeat_count = math.max(1, line_count - helpers.get_caret()[1])
        macros.play(repeat_count)
        return
    end
    local repeat_count = tonumber(answer)
    if repeat_count and repeat_count > 0 then
        macros.play(repeat_count)
    end
end

-- save the current recording under a name, in keytrans form so the json stays
-- readable text. write to disk immediately. preserve the evidence before i
-- decide this was a good use of my life.
function macros.save_current()
    if not macros.recorded then
        return
    end
    local macro_name = helpers.ask('Name of the macro: ')
    if macro_name == '' then
        return
    end
    macros.saved[macro_name] = vim.fn.keytrans(macros.recorded)
    local saved, save_error = pcall(helpers.write_private_file, { vim.json.encode(macros.saved) }, saved_macros_file)
    if not saved then
        helpers.warn('Could not save the macro: ' .. tostring(save_error))
    end
end

-- play a saved menu macro, converting text back into keys. resurrect the
-- mistake.
function macros.play_saved(macro_name)
    local saved_keys = macros.saved[macro_name]
    if saved_keys then
        macros.play(1, helpers.replace_termcodes(saved_keys))
    end
end

------------------------------------------------- the stock saved macro

-- "trim trailing space and save" (alt+shift+s), shipped with notepad++.
-- everybody gets this macro to trim the spaces we leave at line ends. i can't
-- put my life in order, but these damn lines will die clean.
function macros.trim_and_save()
    require('notebashpp.editing_commands').trim_trailing()
    require('notebashpp.file_commands').save()
end

return macros
