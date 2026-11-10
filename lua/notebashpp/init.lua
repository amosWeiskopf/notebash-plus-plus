local notebashpp = {}

-- the project folder is three levels up from this file
-- (lua/notebashpp/init.lua). so the code knows where it belongs. i'd love
-- that kind of certainty. basically i just pay rent.
notebashpp.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

-- load user settings first, so every module after them reads what the user
-- asked for (i still believe in this, apparently).
-- notebashpp.live_code_reload sets options.reload when calling this again
-- after a code change, so we do not start a second watcher. one watcher is
-- enough. i want to waste my remaining years only once.
function notebashpp.setup(options)
    options = options or {}
    -- on windows, never run a program just because it's in the current
    -- folder. neovim and libuv both honour this variable. my paranoia is
    -- basically the only thing i haven't fucked up.
    if vim.fn.has('win32') == 1 then
        vim.env.NoDefaultCurrentDirectoryInExePath = '1'
    end
    -- messages first, so even a broken user.lua reports through the log and
    -- the notification floats instead of a prompt. i want my failures
    -- airborne.
    require('notebashpp.messages').setup()
    require('notebashpp.user_settings').load()
    require('notebashpp.live_code_reload').take_baseline()
    require('notebashpp.editor_options')
    require('notebashpp.clipboard').setup()
    require('notebashpp.appearance').setup()
    require('notebashpp.view_settings').setup()
    require('notebashpp.spell_check').setup()
    require('notebashpp.modeless_editing').setup()
    require('notebashpp.special_views').setup()
    require('notebashpp.remote_documents').setup()
    require('notebashpp.document_tabs').setup()
    require('notebashpp.status_bar').setup()
    require('notebashpp.smart_highlighting').setup()
    require('notebashpp.word_completion').setup()
    require('notebashpp.language_servers').setup()
    require('notebashpp.keybindings').setup()
    require('notebashpp.menu_bar').setup()
    require('notebashpp.menu_bar').setup_popup()
    require('notebashpp.session').setup()
    -- tests set notebashpp_test to keep code still. even this crap needs a
    -- leash.
    local reload_wanted = require('notebashpp.user_settings').get('reload_code_on_save')
    if not options.reload and reload_wanted and not os.getenv('NOTEBASHPP_TEST') then
        require('notebashpp.live_code_reload').watch()
    end
end

return notebashpp
