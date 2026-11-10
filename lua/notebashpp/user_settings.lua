-- settings you can change in user.lua, in the config folder nvim_appname
-- points at. see user.example.lua. i want you to have choices, basically
-- because i spent forty years making shit ones and would hate to keep that
-- opportunity entirely to myself.

local user_settings = {}

user_settings.defaults = {
    -- ctrl+d duplicates every line the selection touches; notepad++
    -- duplicates only the selected text. i wanted more crap, apparently.
    duplicate_whole_lines = false,
    -- delete current line deletes every line the selection touches. notepad++
    -- deletes only the caret line. i prefer a wider blast radius.
    line_delete_acts_on_selected_lines = false,
    -- command id to keys, replacing its default keys. ids are in keys.md. an
    -- empty list leaves the command in its menu without a key. basically
    -- still employed, absolutely no way to get ahead. familiar.
    keys = {},
    -- extra commands: { id = ..., label = ..., keys = { ... }, run =
    -- function() end }. they appear in the macro menu. a small place for your
    -- own ideas to fail (i wanted you to have somewhere).
    commands = {},
    -- load saved changes in lua/notebashpp while running. edit the editor
    -- from inside itself. basically my entire life spent fixing the damn
    -- thing i need to fix my life. this part mostly works, somehow.
    reload_code_on_save = true,
    -- any neovim options, set after notebash++'s own, so yours win. enjoy
    -- that. e.g. { fileencodings = 'ucs-bom,utf-8,cp1255,latin1' }.
    vim_options = {},
    -- spell languages use neovim's 'spelllang': 'en', 'en_gb', or several,
    -- 'en,de'. neovim ships english; put other dictionaries in the spell
    -- folder inside neovim's data folder. basically i can spell failure in
    -- several languages now. my parents must be thrilled.
    spell_languages = 'en',
    -- .csv, .tsv, .tab, .jsonl and .ndjson files open as a spreadsheet. false
    -- opens them as text. my debts look shit in both.
    open_csv_as_spreadsheet = true,
    -- text files bigger than this many megabytes open in the read-only large
    -- file view. it shows only what's on screen (my approach to life's
    -- problems).
    large_file_megabytes = 32,
    -- the json tree (plugins > json > show json tree) builds trees of
    -- documents up to this many megabytes, 64 at most. past that it says
    -- the file is too large. some things are too big to look at. i have a
    -- drawer like that.
    json_tree_megabytes = 20,
    -- start a language server when a document of its language opens and its
    -- program is on the path. false turns every server off. i'd love that
    -- option for my regrets.
    language_servers = true,
    -- servers to leave off, by name or program: { 'clangd', 'lua_ls' }. the
    -- names are in lua/notebashpp/language_servers.lua. even my software has
    -- a shit list.
    language_servers_off = {},
}

-- notebashpp_user_file names the file outright when set, even in tests.
-- otherwise notebashpp_test means no user file. i want tests independent of
-- anybody's taste. mine already did enough damage.
local function user_file_path()
    if vim.env.NOTEBASHPP_USER_FILE then
        return vim.env.NOTEBASHPP_USER_FILE
    end
    if vim.env.NOTEBASHPP_TEST then
        return nil
    end
    return vim.fn.stdpath('config') .. '/user.lua'
end

-- read user.lua over a fresh copy of the defaults. if user.lua throws an
-- error, report it & ignore it; keep the defaults. i wish the rest of my bad
-- decisions came with this much protection.
function user_settings.load()
    local values = vim.deepcopy(user_settings.defaults)
    local path = user_file_path()
    if path and vim.uv.fs_stat(path) then
        local loaded_ok, from_user = pcall(dofile, path)
        if not loaded_ok then
            vim.schedule(function()
                vim.notify('Notebash++: user.lua not loaded, ' .. tostring(from_user), vim.log.levels.ERROR)
            end)
        elseif type(from_user) == 'table' then
            values = vim.tbl_extend('force', values, from_user)
        end
    end
    user_settings.values = values
    return values
end

-- get one setting by name; load user.lua on first request. even my
-- preferences need waking.
---@param name string
---@return any
function user_settings.get(name)
    if not user_settings.values then
        user_settings.load()
    end
    return user_settings.values[name]
end

return user_settings
