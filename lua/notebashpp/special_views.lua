-- decide before neovim reads the file, when it creates the buffer. .csv, .tsv,
-- .tab, .jsonl and .ndjson use spreadsheet_view.lua; text files bigger than
-- large_file_megabytes use the read-only large_file_view.lua. everything else
-- opens as plain text. so a 10 gb file never gets read into memory. i want to
-- edit a file, please. i haven't budgeted for another funeral.

local special_views = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local user_settings = require('notebashpp.user_settings')

-- per path, this session: 'text' opens a csv as text (large file view if
-- big); 'load_fully' reads any file normally. basically i waive my right to
-- complain when memory goes to hell.
special_views.overrides = special_views.overrides or {}

local SPREADSHEET_EXTENSIONS = { csv = true, tsv = true, tab = true, jsonl = true, ndjson = true }

local function large_file_bytes()
    local megabytes = tonumber(user_settings.get('large_file_megabytes')) or 32
    return megabytes * 1024 * 1024
end

-- 'spreadsheet_view', 'large_file_view' or nil for plain text. pick your
-- hell.
function special_views.kind_for(path)
    local override = special_views.overrides[path]
    if override == 'load_fully' then
        return nil
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= 'file' then
        return nil
    end
    local extension = (path:match('%.([^./\\]+)$') or ''):lower()
    if SPREADSHEET_EXTENSIONS[extension] and override ~= 'text' and user_settings.get('open_csv_as_spreadsheet') ~= false then
        -- utf-16 files (excel's "unicode text") aren't byte separated. leave
        -- them to the text editor. excel has done enough damage here.
        local file = io.open(path, 'rb')
        local first_bytes = file and file:read(2) or ''
        if file then
            file:close()
        end
        if first_bytes ~= '\255\254' and first_bytes ~= '\254\255' then
            return 'spreadsheet_view'
        end
    end
    if stat.size > large_file_bytes() then
        return 'large_file_view'
    end
    return nil
end

local function attach(buffer)
    if not api.nvim_buf_is_valid(buffer) or api.nvim_buf_is_loaded(buffer) or vim.b[buffer].notebashpp_view_checked then
        return
    end
    local name = api.nvim_buf_get_name(buffer)
    if name == '' then
        return
    end
    local path = vim.fn.fnamemodify(name, ':p')
    local kind = special_views.kind_for(path)
    if not kind then
        return
    end
    vim.b[buffer].notebashpp_view_checked = true
    api.nvim_create_autocmd('BufReadCmd', {
        buffer = buffer,
        callback = function(event)
            require('notebashpp.' .. kind).open(event.buf, path)
        end,
    })
end

-- close the document & reopen its file using `override`: 'text', 'load_fully'
-- or nil for the default view. close asks about unsaved changes first (i'd
-- love that warning before wasting my life too).
function special_views.reopen(buffer, override)
    local path = vim.fn.fnamemodify(api.nvim_buf_get_name(buffer), ':p')
    if path == '' then
        return
    end
    local file_commands = require('notebashpp.file_commands')
    if not file_commands.close(buffer) then
        return
    end
    special_views.overrides[path] = override
    file_commands.open_path(path)
end

-- plugins > spreadsheet > view as text / open as spreadsheet. same shit.
function special_views.toggle_spreadsheet()
    local buffer = api.nvim_get_current_buf()
    local path = vim.fn.fnamemodify(api.nvim_buf_get_name(buffer), ':p')
    local extension = (path:match('%.([^./\\]+)$') or ''):lower()
    if vim.b[buffer].notebashpp_special_view == 'spreadsheet_view' then
        return special_views.reopen(buffer, 'text')
    end
    if not SPREADSHEET_EXTENSIONS[extension] then
        return helpers.warn('Open as Spreadsheet works on .csv, .tsv, .tab, .jsonl and .ndjson files.')
    end
    if vim.bo[buffer].modified then
        if vim.fn.confirm('Save your changes before opening the file as a spreadsheet?', '&Yes\n&Cancel', 1, 'Question') ~= 1 then
            return
        end
        if not require('notebashpp.file_commands').save(buffer) then
            return
        end
    end
    special_views.reopen(buffer, nil)
end

-- status bar text for a special view, or nil. even silence needs code.
function special_views.status(buffer)
    local view_name = vim.b[buffer].notebashpp_special_view
    -- only views in this folder describe themselves; another module may mark
    -- its buffers with its own name. i have enough of my own crap to account
    -- for.
    if view_name ~= 'spreadsheet_view' and view_name ~= 'large_file_view' then
        return nil
    end
    -- an error here makes neovim drop the whole status bar. absolutely sane
    -- (?)
    local status_ok, status = pcall(function()
        return require('notebashpp.' .. view_name).status(buffer)
    end)
    if not status_ok or type(status) ~= 'table' then
        return nil
    end
    -- the status bar reads % as the start of a format item; double a literal
    -- %. even a percent costs me twice. absolutely fucking typical.
    for field_name, value in pairs(status) do
        if type(value) == 'string' then
            status[field_name] = value:gsub('%%', '%%%%')
        end
    end
    return status
end

function special_views.setup()
    local session = require('notebashpp.session')
    for _, view_name in ipairs({ 'spreadsheet_view', 'large_file_view' }) do
        local view = require('notebashpp.' .. view_name)
        view.setup()
        session.register_special_view(view_name, { save = view.session_state, restore = view.restore_session_state })
    end
    local augroup = api.nvim_create_augroup('notebashpp_special_views', { clear = true })
    api.nvim_create_autocmd('BufNew', {
        group = augroup,
        callback = function(event)
            attach(event.buf)
        end,
    })
    -- attach buffers made before this ran (command-line files). i'm late
    -- again.
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        attach(buffer)
    end
end

return special_views
