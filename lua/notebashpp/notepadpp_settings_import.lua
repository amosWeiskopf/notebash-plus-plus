-- reads notepad++ config.xml if found (on wsl, mount the windows drive). find
-- options, find & replace history, find in files folders & filters, recent
-- files, wrap, zoom and the new document format all carry over. i want a
-- fresh start, apparently with every damn habit that ruined the last one.
-- basically moving house and bringing the rot.

local notepadpp_settings_import = {}

-- looks for notepad++ config.xml via notebashpp_notepadpp_config (the
-- environment variable), %appdata% on windows, the windows drive from wsl
-- (any user under /mnt/c/users), or a wine prefix. first readable one wins.
-- if none is readable, returns nothing and we use defaults. absolutely zero
-- inheritance. somehow the editor has a better estate plan than i do.
local function find_config_path()
    local candidate_paths = {}
    if vim.env.NOTEBASHPP_NOTEPADPP_CONFIG then
        table.insert(candidate_paths, vim.env.NOTEBASHPP_NOTEPADPP_CONFIG)
    end
    if vim.env.APPDATA then
        table.insert(candidate_paths, vim.env.APPDATA .. '/Notepad++/config.xml')
    end
    -- with several windows users, take the one named like this linux user,
    -- or nobody's. reading a stranger's settings isn't importing, it's
    -- snooping. i get enough of that from my own family.
    local windows_configs = vim.tbl_filter(function(path)
        return vim.fn.filereadable(path) == 1
    end, vim.fn.glob('/mnt/c/Users/*/AppData/Roaming/Notepad++/config.xml', false, true))
    -- "all users" is c:\programdata, where any windows account can create
    -- files. the shared profiles aren't anybody's settings, so skip them.
    -- a config anyone can plant is just a note from a stranger.
    local shared_profiles = { ['all users'] = true, ['default'] = true, ['default user'] = true, ['public'] = true }
    windows_configs = vim.tbl_filter(function(path)
        return not shared_profiles[(path:match('^/mnt/c/Users/([^/]+)/') or ''):lower()]
    end, windows_configs)
    if #windows_configs > 1 then
        local own_config = ('/mnt/c/Users/%s/AppData/Roaming/Notepad++/config.xml'):format(vim.env.USER or '')
        windows_configs = vim.tbl_filter(function(path)
            return path:lower() == own_config:lower()
        end, windows_configs)
    end
    vim.list_extend(candidate_paths, windows_configs)
    vim.list_extend(candidate_paths, vim.fn.glob('~/.wine/drive_c/users/*/AppData/Roaming/Notepad++/config.xml', false, true))
    for _, candidate_path in ipairs(candidate_paths) do
        if vim.fn.filereadable(candidate_path) == 1 then
            return candidate_path
        end
    end
end

-- everything from config.xml, read once per session. i can barely afford to
-- waste this life once; rereading the same crap feels ambitious.
local loaded_settings

-- a numeric entity outside unicode (&#99999999999;) stays as written. i want
-- startup to survive. a conversion error can kill my hopes later.
local function character_for_code_point(code_point)
    if code_point and code_point >= 1 and code_point <= 0x10FFFF then
        return vim.fn.nr2char(code_point)
    end
end

-- xml entities become characters: numeric (hex and decimal) first, named ones
-- after. &amp; goes last so "&amp;lt;" stays "&lt;", without a second
-- unescape. even this crap gets protection from being screwed twice.
local function unescape_xml(text)
    text = text:gsub('&#x(%x+);', function(hex_code)
        return character_for_code_point(tonumber(hex_code, 16))
    end)
    text = text:gsub('&#(%d+);', function(decimal_code)
        return character_for_code_point(tonumber(decimal_code))
    end)
    return (text:gsub('&quot;', '"'):gsub('&apos;', "'"):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&'))
end

-- pulls what we need from config.xml with a handful of patterns, no xml
-- parser. i wanted elegance once. rent cured that. with notebashpp_test set,
-- reads nothing, so tests never inherit the runner's searches from last
-- tuesday. some shame should die with us.
local function load_settings()
    if loaded_settings then
        return loaded_settings
    end
    loaded_settings =
        { find = {}, replace = {}, find_directories = {}, find_filters = {}, recent_files = {}, find_options = {}, primary_view = {}, new_document = {} }
    local config_path = find_config_path()
    if not config_path or vim.env.NOTEBASHPP_TEST then
        return loaded_settings
    end
    -- a real config.xml is about 50 kb. anything over 1 mb isn't one. the
    -- history patterns below get slow on huge broken files. i want to waste
    -- what's left of my life on slightly different crap.
    if vim.fn.getfsize(config_path) > 1024 * 1024 then
        return loaded_settings
    end
    local read_ok, config_lines = pcall(vim.fn.readfile, config_path)
    if not read_ok then
        return loaded_settings
    end
    local config_text = table.concat(config_lines, '\n')
    -- find history, newest first, every search kept forever. basically a
    -- diary of failure with better retention than my pension.
    for entry_text in config_text:gmatch('<Find name="(.-)" />') do
        table.insert(loaded_settings.find, unescape_xml(entry_text))
    end
    for entry_text in config_text:gmatch('<Replace name="(.-)" />') do
        table.insert(loaded_settings.replace, unescape_xml(entry_text))
    end
    -- find in files: filters (*.txt etc.) & searched folders. where hope went
    -- to rot.
    for entry_text in config_text:gmatch('<Filter name="(.-)" />') do
        table.insert(loaded_settings.find_filters, unescape_xml(entry_text))
    end
    for entry_text in config_text:gmatch('<Path name="(.-)" />') do
        table.insert(loaded_settings.find_directories, unescape_xml(entry_text))
    end
    -- recent files, still windows paths here. even my baggage needs
    -- converting.
    for entry_text in config_text:gmatch('<File filename="(.-)" />') do
        table.insert(loaded_settings.recent_files, unescape_xml(entry_text))
    end
    -- copies element attributes as plain name/value strings:
    -- scintillaprimaryview guiconfig (wrap, zoom & the rest of the view),
    -- newdocument guiconfig (new file format), and findhistory (find dialog
    -- checkboxes & search mode). basically paperwork for an editor. i have
    -- absolutely wasted my youth on less, which is the depressing part.
    local primary_view_attributes = config_text:match('<GUIConfig name="ScintillaPrimaryView"(.-)>')
    if primary_view_attributes then
        for attribute_name, attribute_value in primary_view_attributes:gmatch('(%w+)="(.-)"') do
            loaded_settings.primary_view[attribute_name] = attribute_value
        end
    end
    local new_document_attributes = config_text:match('<GUIConfig name="NewDocument"(.-)>')
    if new_document_attributes then
        for attribute_name, attribute_value in new_document_attributes:gmatch('(%w+)="(.-)"') do
            loaded_settings.new_document[attribute_name] = attribute_value
        end
    end
    local find_history_attributes = config_text:match('<FindHistory(.-)>')
    if find_history_attributes then
        for attribute_name, attribute_value in find_history_attributes:gmatch('(%w+)="(.-)"') do
            loaded_settings.find_options[attribute_name] = attribute_value
        end
    end
    return loaded_settings
end

-- converts windows paths to wsl paths by hand, without launching wslpath for
-- every damn path. \\wsl.localhost\<distro>\... and the older
-- \\wsl$\<distro>\... are already inside linux: strip the prefix and convert
-- slashes. c:\... becomes /mnt/c/...; outside wsl, return unchanged. i want
-- fewer processes. mine already feels like a slow death.
function notepadpp_settings_import.windows_path_to_linux(windows_path)
    if vim.fn.has('wsl') == 0 then
        return windows_path
    end
    local path_inside_distro = windows_path:match('^\\\\wsl%.localhost\\[^\\]+(\\.*)$') or windows_path:match('^\\\\wsl%$\\[^\\]+(\\.*)$')
    if path_inside_distro then
        return (path_inside_distro:gsub('\\', '/'))
    end
    local drive_letter, rest_of_path = windows_path:match('^(%a):\\(.*)$')
    if drive_letter then
        return '/mnt/' .. drive_letter:lower() .. '/' .. rest_of_path:gsub('\\', '/')
    end
    return windows_path
end

-- notepad++ recent files, converted to usable paths. old crap, fresh access.
function notepadpp_settings_import.history()
    local linux_paths = {}
    for _, recent_file in ipairs(load_settings().recent_files) do
        linux_paths[#linux_paths + 1] = notepadpp_settings_import.windows_path_to_linux(recent_file)
    end
    return linux_paths
end

-- two lists: find history & replace history. regret, with receipts.
function notepadpp_settings_import.find_history()
    return load_settings().find, load_settings().replace
end

-- find in files folders (linux paths) & filters. hope has an address.
function notepadpp_settings_import.find_paths()
    local linux_paths = {}
    for _, find_directory in ipairs(load_settings().find_directories) do
        linux_paths[#linux_paths + 1] = notepadpp_settings_import.windows_path_to_linux(find_directory)
    end
    return linux_paths, load_settings().find_filters
end

-- findhistory attributes (match case, whole word, search mode etc.) as raw
-- strings, or an empty table. even nothing comes with fucking options.
function notepadpp_settings_import.find_options()
    return load_settings().find_options
end

-- scintillaprimaryview attributes (wrap, zoom, etc.), or an empty table. my
-- life's work (?)
function notepadpp_settings_import.view_options()
    return load_settings().primary_view
end

-- newdocument attributes (format: 0 windows, 1 mac, 2 unix), or an empty
-- table. a fresh start. same shit.
function notepadpp_settings_import.new_document_options()
    return load_settings().new_document
end

return notepadpp_settings_import
