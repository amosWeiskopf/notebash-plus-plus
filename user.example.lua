-- copy this file to user.lua in the same folder. change what you like.
-- user.lua is yours. git ignores it and updates never touch it. nobody else
-- will read it. basically my short fiction, with settings.
--
-- every setting below is at its default. delete the ones you don't change. i
-- want fewer lines to regret maintaining.

return {
    -- ctrl+d with a selection: notepad++ duplicates the selected text
    -- immediately after itself. set this to true to duplicate every line the
    -- selection touches. because apparently one copy of this shit wasn't
    -- enough (i wrote it, i can say that).
    duplicate_whole_lines = false,

    -- delete current line (ctrl+shift+l) deletes only the caret line, even
    -- with five lines selected. set true to delete every selected line. i
    -- want this much control over the years i've wasted.
    line_delete_acts_on_selected_lines = false,

    -- give commands different keys, like notepad++'s shortcut mapper, without
    -- the dialog. command ids are in keys.md. an empty list removes the keys;
    -- the command stays in the menu. basically kept alive at your expense,
    -- which i understand personally.
    keys = {
        -- rtl = { '<s-f10>' },
        -- ltr = { '<s-f9>' },
        -- line_delete = { '<c-l>', '<c-s-l>' },
        -- line_cut = {},
    },

    -- your own commands go at the bottom of the macro menu with keys you
    -- assign. run is plain lua: anything neovim can do. for the caret &
    -- selection, require('notebashpp.helpers'). more power to waste a life.
    commands = {
        -- {
        --     id = 'shout_line',
        --     label = 'shout the current line',
        --     keys = { '<c-m-k1>' },
        --     run = function()
        --         local helpers = require('notebashpp.helpers')
        --         local line_number = helpers.get_caret()[1]
        --         local text = helpers.get_line_text(line_number)
        --         vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, false, { text:upper() })
        --     end,
        -- },
    },

    -- any neovim option, applied after notebash++'s own, so yours win. this
    -- example makes old windows-1255 hebrew files readable. at least the
    -- files get to age with some dignity.
    vim_options = {
        -- fileencodings = 'ucs-bom,utf-8,cp1255,latin1',
    },

    -- spell check languages (plugins > spell check), using neovim's
    -- 'spelllang': 'en', 'en_gb', 'en,de'. neovim ships english; put other
    -- .spl files in the spell folder of neovim's data folder. i can add
    -- languages for free. having a damn thing worth saying apparently costs
    -- extra.
    spell_languages = 'en',

    -- .csv, .tsv, .tab, .jsonl and .ndjson files open as a spreadsheet.
    -- false gives plain text. i want fewer cells in my damn life.
    open_csv_as_spreadsheet = true,

    -- text files above this many megabytes use the read-only large file view.
    -- it reads only what's on screen. basically how i handle my problems.
    large_file_megabytes = 32,

    -- the json tree (plugins > json > show json tree) handles documents up
    -- to this many megabytes, 64 at most. bigger ones get a polite refusal.
    -- i get those too, mostly by email.
    json_tree_megabytes = 20,

    -- reload changes to lua/notebashpp while notebash++ runs. edit a file
    -- and save; the editor you're typing in changes without a restart. i can
    -- rebuild this damn thing while it's running. myself, apparently,
    -- requires a shutdown nobody has figured out how to reverse.
    reload_code_on_save = true,

    -- language servers (plugins > language server). opening a document starts
    -- its usual language server if the program is on the path:
    -- lua-language-server, basedpyright or pyright,
    -- typescript-language-server, clangd, rust-analyzer, gopls,
    -- bash-language-server, the vscode json, html and css servers,
    -- yaml-language-server, marksman, taplo, zls. nothing is ever installed.
    -- false turns them all off. i want advice only from shit i've invited
    -- into my life (a policy i adopted too damn late).
    language_servers = true,

    -- servers to shut the hell up, by name or program, e.g. { 'clangd' } or
    -- { 'lua-language-server' }.
    language_servers_off = {},
}
