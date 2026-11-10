-- live code reload: change a file in lua/notebashpp on disk and the running
-- notebash++ loads the new code & sets up its keys again. no restart. i
-- wanted another chance for my life too. apparently that shit is final sale.
--
-- open documents, tabs, find history, bookmarks, the recorded macro, zoom,
-- clipboard kind and multi-editing carets survive: state_fields_to_keep lists
-- the fields copied from each old module to its replacement. if loading
-- fails, we restore the old code and keep running. basically i gave a text
-- editor the safety net i don't have. please enjoy typing.

local live_code_reload = {}
local api = vim.api

local function plugin_root()
    return require('notebashpp').root
end

-- module fields holding state the user built up. lose these and we burn
-- someone's afternoon. i wanted to waste my own life, kindly leave theirs
-- out.
local state_fields_to_keep = {
    ['notebashpp.clipboard'] = { 'memory', 'line_copy' },
    ['notebashpp.compare_documents'] = { 'first', 'active' },
    ['notebashpp.file_commands'] = { 'closed' },
    ['notebashpp.find_and_replace'] = { 'state' },
    ['notebashpp.appearance'] = { 'zoom', 'neovide_done' },
    ['notebashpp.macros'] = { 'recorded', 'saved' },
    ['notebashpp.live_code_reload'] = { 'baseline', 'count', 'watchers' },
    ['notebashpp.document_tabs'] = { 'order', 'mru' },
    ['notebashpp.spreadsheet_view'] = { 'states' },
    ['notebashpp.large_file_view'] = { 'states' },
    ['notebashpp.json_tree'] = { 'panel', 'documents' },
    ['notebashpp.special_views'] = { 'overrides' },
    ['notebashpp.session'] = { 'special_views', 'last_written_text', 'last_selection', 'keep_unreferenced_backups' },
    ['notebashpp.multi_editing'] = { 'session' },
    ['notebashpp.messages'] = { 'original_functions', 'extended_ui_module_name', 'observer_namespace' },
}

-- editor_options.lua sets options on load. running it again undoes the view
-- menu toggles, so reload it only when that file changed. the user already
-- made a choice. absolutely cruel to make them deal with it twice.
local reload_only_when_changed = { ['notebashpp.editor_options'] = true }

local mapping_modes = { 'n', 'i', 'x', 's', 'o', 'c', 't' }

live_code_reload.count = 0

local function mapping_key(mode, keys)
    return mode .. ' ' .. keys
end

-- keep the global mappings from before notebash++ sets its own (neovim's
-- defaults). everything else counts as ours and is cleared before reload. so
-- removing a key from keybindings.lua stops it working immediately. i want at
-- least one damn thing to leave when asked.
function live_code_reload.take_baseline()
    if live_code_reload.baseline then
        return
    end
    live_code_reload.baseline = {}
    for _, mode in ipairs(mapping_modes) do
        for _, mapping in ipairs(api.nvim_get_keymap(mode)) do
            live_code_reload.baseline[mapping_key(mode, mapping.lhs)] = true
        end
    end
end

local function clear_our_mappings()
    -- if the editor predates this module, all current mappings become the
    -- baseline. setup() maps every key again on top. we inherit the whole
    -- mess, basically. no lawyer would touch this estate.
    live_code_reload.take_baseline()
    for _, mode in ipairs(mapping_modes) do
        for _, mapping in ipairs(api.nvim_get_keymap(mode)) do
            if not live_code_reload.baseline[mapping_key(mode, mapping.lhs)] then
                pcall(api.nvim_del_keymap, mode, mapping.lhs)
            end
        end
    end
end

local function module_file_path(module_name)
    if module_name == 'notebashpp' then
        return plugin_root() .. '/lua/notebashpp/init.lua'
    end
    return plugin_root() .. '/lua/' .. module_name:gsub('%.', '/') .. '.lua'
end

-- reload code. changed_files holds file names like 'editing_commands.lua';
-- these decide whether editor_options.lua reloads. nil reloads everything
-- except options. returns true on success, false if the old code remains in
-- charge. failure has excellent tenure here.
function live_code_reload.reload(changed_files)
    changed_files = changed_files or {}
    local module_names = {}
    for module_name in pairs(package.loaded) do
        if module_name == 'notebashpp' or module_name:match('^notebashpp%.') then
            local file_name = vim.fn.fnamemodify(module_file_path(module_name), ':t')
            if not reload_only_when_changed[module_name] or vim.tbl_contains(changed_files, file_name) then
                module_names[#module_names + 1] = module_name
            end
        end
    end
    -- a syntax error in any file keeps the old code running. don't run half a
    -- file. i tried the human equivalent with sleep and now i write editor
    -- configurations for free. please learn something from this.
    local files_to_check = {}
    for _, module_name in ipairs(module_names) do
        files_to_check[#files_to_check + 1] = module_file_path(module_name)
    end
    for _, changed_file in ipairs(changed_files) do
        files_to_check[#files_to_check + 1] = plugin_root() .. '/lua/notebashpp/' .. changed_file
    end
    for _, file_path in ipairs(files_to_check) do
        local loaded, load_error = loadfile(file_path)
        if not loaded and vim.uv.fs_stat(file_path) then
            vim.notify('Notebash++: not reloaded, ' .. tostring(load_error), vim.log.levels.ERROR)
            return false
        end
    end
    -- if a macro is recording keystrokes, wait 1 s and retry until it stops.
    -- let it finish. somebody should get to finish something in this life.
    local macros_module = package.loaded['notebashpp.macros']
    if macros_module and macros_module.recording and macros_module.recording() then
        live_code_reload.later(changed_files, 1000)
        return false
    end

    local old_modules = {}
    for _, module_name in ipairs(module_names) do
        old_modules[module_name] = package.loaded[module_name]
        local old_module = old_modules[module_name]
        if type(old_module) == 'table' and type(old_module._unload) == 'function' then
            pcall(old_module._unload)
        end
    end
    for _, module_name in ipairs(module_names) do
        package.loaded[module_name] = nil
    end

    -- copy the kept fields from each old module to its replacement. all the
    -- baggage survives. i seem to have automated the worst part of being
    -- alive.
    local function carry_state_over()
        for module_name, field_names in pairs(state_fields_to_keep) do
            local old_module, new_module = old_modules[module_name], package.loaded[module_name]
            if type(old_module) == 'table' and type(new_module) == 'table' then
                for _, field_name in ipairs(field_names) do
                    new_module[field_name] = old_module[field_name]
                end
            end
        end
    end

    local setup_ok, setup_error = pcall(function()
        -- load every module, then restore state before setup() reads it. even
        -- this crap deserves a past.
        for _, module_name in ipairs(module_names) do
            require(module_name)
        end
        carry_state_over()
        clear_our_mappings()
        require('notebashpp').setup({ reload = true })
    end)
    if not setup_ok then
        -- new code failed: restore every old module & set it up again. my
        -- retirement plan, basically.
        for _, module_name in ipairs(module_names) do
            package.loaded[module_name] = old_modules[module_name]
        end
        clear_our_mappings()
        pcall(function()
            require('notebashpp').setup({ reload = true })
        end)
        vim.notify('Notebash++: not reloaded, ' .. tostring(setup_error), vim.log.levels.ERROR)
        return false
    end
    local reloaded_self = package.loaded['notebashpp.live_code_reload']
    reloaded_self.count = (reloaded_self.count or 0) + 1
    vim.cmd('redraw!')
    if #changed_files > 0 then
        vim.notify('Notebash++: reloaded ' .. table.concat(changed_files, ', '))
    end
    return true
end

local pending_files = {}
local debounce_timer = nil

-- reload after files stop changing briefly (300 ms unless overridden).
-- editors may write a file in several steps, so wait until they're done. i'd
-- love the same courtesy before someone decides my life is a syntax error.
-- still writing it, thanks.
function live_code_reload.later(changed_files, delay_milliseconds)
    for _, file_name in ipairs(changed_files or {}) do
        pending_files[file_name] = true
    end
    if debounce_timer then
        debounce_timer:stop()
    else
        debounce_timer = assert(vim.uv.new_timer(), 'could not create the reload timer')
    end
    debounce_timer:start(
        delay_milliseconds or 300,
        0,
        vim.schedule_wrap(function()
            local file_names = vim.tbl_keys(pending_files)
            table.sort(file_names)
            pending_files = {}
            require('notebashpp.live_code_reload').reload(file_names)
        end)
    )
end

-- watch lua/notebashpp for saved .lua files, once per run. i used to wait
-- for good news. file changes are more reliable.
function live_code_reload.watch()
    if live_code_reload.watchers then
        return
    end
    live_code_reload.watchers = {}
    local watched_directory = plugin_root() .. '/lua/notebashpp'
    local file_watcher = vim.uv.new_fs_event()
    if not file_watcher then
        return
    end
    local started = file_watcher:start(watched_directory, {}, function(watch_error, file_name)
        if watch_error or not file_name or not file_name:match('^[%w_]+%.lua$') then
            return
        end
        vim.schedule(function()
            require('notebashpp.live_code_reload').later({ file_name })
        end)
    end)
    if started then
        live_code_reload.watchers[#live_code_reload.watchers + 1] = file_watcher
    end
end

return live_code_reload
