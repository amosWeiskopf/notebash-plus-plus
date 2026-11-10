-- documents that live somewhere else: a web address (http, https) or a file
-- on a server over ssh (ssh://host/path, scp://host//path, or host:/path from
-- the command line). neovim's own netrw is off in this editor, so these get
-- their own bufreadcmd and bufwritecmd. i couldn't keep anything at home
-- either.
--
-- web pages: curl fetches the address. an html page asks html or markdown;
-- markdown goes through pandoc. anything else opens as the text it is. there
-- is nowhere to save back to, so ctrl+s asks for a local file name.
--
-- ssh: the file comes down with `ssh host head -c` and goes back up through a
-- temporary file on the server, then `cat tmp > file`, so the file keeps its
-- owner, permissions and links. ssh runs with batchmode: a key or an agent
-- has to do the logging in, because there's no terminal here for a password
-- prompt. i stopped answering questions years ago anyway.

local remote_documents = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- 64 mb and 30 seconds per transfer. a bigger file over ssh belongs in a
-- real copy, and a page that takes longer is a page that hates you. i know
-- the feeling.
local MAXIMUM_BYTES = 64 * 1024 * 1024
local TIME_LIMIT_MILLISECONDS = 30000

---@param name string
---@return 'web'|'ssh'|nil
function remote_documents.kind(name)
    if name:match('^[Hh][Tt][Tt][Pp][Ss]?://') then
        return 'web'
    end
    if name:match('^ssh://') or name:match('^scp://') then
        return 'ssh'
    end
    return nil
end

-- "user@host:/path" or "host:~/path", the way scp writes it, becomes
-- ssh://user@host/path. only when no local file has that name, the host has
-- at least two characters (c:/ is a windows drive) and the path starts with
-- / or ~. anything else stays a local name. one letter of ambiguity cost me a
-- whole weekend once.
---@param name string
---@return string
function remote_documents.normalize(name)
    if remote_documents.kind(name) or vim.uv.fs_stat(name) then
        return name
    end
    local destination, path = name:match('^([%w._-]+@?[%w._-]*):([/~].*)$')
    if not destination or destination:sub(1, 1) == '-' or #(destination:match('[^@]*$') or '') < 2 then
        return name
    end
    if path:sub(1, 1) == '~' then
        return 'ssh://' .. destination .. '/' .. path
    end
    return 'ssh://' .. destination .. path
end

-- ssh://[user@]host[:port]/path. "/~/x" is x in the home folder. scp:// keeps
-- netrw's habit: "//abs" is absolute, "/x" is home-relative. returns nil for
-- anything that isn't a plain host name; a host starting with - would be an
-- ssh option. i've had enough options pretending to be people.
---@param name string
---@return { destination: string, port: string?, path: string }?
local function parse_ssh(name)
    local scheme, rest = name:match('^(%a+)://(.*)$')
    if not rest then
        return nil
    end
    local authority, path = rest:match('^([^/]+)(/.*)$')
    if not authority then
        return nil
    end
    local destination, port = authority:match('^(.-):(%d+)$')
    destination = destination or authority
    if destination == '' or destination:sub(1, 1) == '-' or not destination:match('^[%w._@-]+$') then
        return nil
    end
    if scheme == 'scp' then
        path = path:sub(1, 2) == '//' and path:sub(2) or ('~' .. path)
    elseif path:sub(1, 3) == '/~/' or path == '/~' then
        path = path:sub(2)
    end
    return { destination = destination, port = port, path = path }
end

-- the server's shell reads the command, so the path goes in single quotes,
-- with every ' as '\''. a leading ~/ stays outside the quotes so the server
-- still expands it. a file named $(rm -rf ~) stays a file name. i'd like it
-- to stay that way.
local function quoted_remote_path(path)
    local function single_quoted(text)
        return "'" .. text:gsub("'", "'\\''") .. "'"
    end
    if path == '~' then
        return '~'
    end
    if path:sub(1, 2) == '~/' then
        return '~/' .. single_quoted(path:sub(3))
    end
    return single_quoted(path)
end

local function ssh_command(target, remote_command)
    local command = { 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10' }
    if target.port then
        vim.list_extend(command, { '-p', target.port })
    end
    vim.list_extend(command, { '--', target.destination, remote_command })
    return command
end

-- run a command with the time limit; a missing program is an error message,
-- not a stack trace. returns the vim.system result or nil plus why not.
local function run(command, options)
    if vim.fn.executable(command[1]) == 0 then
        return nil, command[1] .. ' is not installed'
    end
    local started, process = pcall(vim.system, command, vim.tbl_extend('force', { text = false, timeout = TIME_LIMIT_MILLISECONDS }, options or {}))
    if not started then
        return nil, tostring(process)
    end
    local result = process:wait()
    -- vim.system reports a process it had to stop for time as exit 124.
    if result.code == 124 then
        return nil, ('%s took longer than %d seconds and was stopped'):format(command[1], TIME_LIMIT_MILLISECONDS / 1000)
    end
    return result
end

local function first_line_of(text)
    return vim.trim(((text or ''):match('[^\n]+') or ''):sub(1, 300))
end

-- a private scratch folder for transfers: 0700, files 0600.
local function scratch_file()
    local folder = vim.fn.stdpath('cache') .. '/remote-documents'
    vim.fn.mkdir(folder, 'p')
    vim.uv.fs_chmod(folder, tonumber('700', 8))
    return ('%s/%s'):format(folder, vim.text.hexencode(assert(vim.uv.random(8), 'no random bytes')))
end

local function write_bytes(path, bytes)
    local file_descriptor = assert(vim.uv.fs_open(path, 'w', tonumber('600', 8)))
    local written = vim.uv.fs_write(file_descriptor, bytes)
    vim.uv.fs_close(file_descriptor)
    assert(written == #bytes, 'could not write ' .. path)
end

local function read_bytes(path)
    local file = assert(io.open(path, 'rb'))
    local bytes = file:read('*a')
    file:close()
    return bytes
end

-- put fetched bytes into the buffer the way opening a local file would:
-- neovim reads a private copy (so encoding, line endings, bom and the last
-- line end are detected as usual), then the lines and those settings move
-- over and the copy goes. the copy has no extension and is marked
-- load_fully, so it never turns into a spreadsheet or a large file view.
-- secondhand, but at least it's handled properly.
local function fill_buffer(buffer, bytes, filetype)
    local copy_path = scratch_file()
    write_bytes(copy_path, bytes)
    local special_views = require('notebashpp.special_views')
    special_views.overrides[copy_path] = 'load_fully'
    local copy_buffer = vim.fn.bufadd(copy_path)
    local loaded, load_error = pcall(vim.fn.bufload, copy_buffer)
    local lines = loaded and api.nvim_buf_get_lines(copy_buffer, 0, -1, false) or {}
    local settings = loaded
            and {
                fileformat = vim.bo[copy_buffer].fileformat,
                fileencoding = vim.bo[copy_buffer].fileencoding,
                bomb = vim.bo[copy_buffer].bomb,
                endofline = vim.bo[copy_buffer].endofline,
            }
        or {}
    pcall(api.nvim_buf_delete, copy_buffer, { force = true })
    special_views.overrides[copy_path] = nil
    os.remove(copy_path)
    if not loaded then
        error(load_error, 0)
    end
    local undo_levels = vim.bo[buffer].undolevels
    vim.bo[buffer].undolevels = -1
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].undolevels = undo_levels
    for option_name, value in pairs(settings) do
        vim.bo[buffer][option_name] = value
    end
    vim.bo[buffer].buftype = 'acwrite'
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].modified = false
    vim.b[buffer].notebashpp_remote = true
    local name = api.nvim_buf_get_name(buffer)
    vim.bo[buffer].filetype = filetype or vim.filetype.match({ buf = buffer, filename = name:gsub('[?#].*$', '') }) or ''
end

-- the buffer's bytes as they'd be saved, through a private local copy, so
-- encoding, line endings and bom come out as for a local save.
local function buffer_bytes(buffer)
    local copy_path = scratch_file()
    api.nvim_buf_call(buffer, function()
        vim.cmd.write({ args = { copy_path }, bang = true, mods = { silent = true, keepalt = true, noautocmd = true }, magic = { file = false } })
    end)
    local bytes = read_bytes(copy_path)
    os.remove(copy_path)
    return bytes
end

------------------------------------------------------------------- ssh

local function read_over_ssh(buffer, name)
    local target = parse_ssh(name)
    if not target then
        return helpers.warn('Not an ssh address Notebash++ can open: ' .. name)
    end
    local path = quoted_remote_path(target.path)
    -- exit 3: no such file (a new document, like a local name that doesn't
    -- exist yet); exit 4: a folder.
    local remote_command = ('if [ -d %s ]; then exit 4; elif [ -e %s ]; then head -c %d -- %s; else exit 3; fi'):format(path, path, MAXIMUM_BYTES + 1, path)
    local result, problem = run(ssh_command(target, remote_command))
    if not result then
        return helpers.warn('Could not open ' .. name .. ': ' .. problem)
    end
    if result.code == 3 then
        fill_buffer(buffer, '')
        vim.b[buffer].notebashpp_remote_new = true
        return helpers.notify(name .. ' does not exist yet; Ctrl+S creates it.')
    elseif result.code == 4 then
        return helpers.warn(name .. ' is a folder.')
    elseif result.code ~= 0 then
        return helpers.warn(
            ('Could not open %s: %s'):format(name, first_line_of(result.stderr) ~= '' and first_line_of(result.stderr) or ('ssh exit ' .. result.code))
        )
    end
    if #result.stdout > MAXIMUM_BYTES then
        return helpers.warn(('%s is over %d MB; copy it here to edit it.'):format(name, MAXIMUM_BYTES / 1024 / 1024))
    end
    fill_buffer(buffer, result.stdout)
end

-- upload to a temporary file on the server first, then copy it over the
-- file, so a dropped connection never leaves half a file, and the file keeps
-- its inode, owner and permissions. the temporary file goes either way.
-- burning bridges is my thing. burning config files isn't.
local function write_over_ssh(buffer, name)
    local target = parse_ssh(name)
    if not target then
        helpers.warn('Not an ssh address Notebash++ can save to: ' .. name)
        return false
    end
    local remote_command = ('temporary_file=$(mktemp) || exit 1; if cat > "$temporary_file"; then cat -- "$temporary_file" > %s; status=$?; else status=1; fi; rm -f -- "$temporary_file"; exit $status'):format(
        quoted_remote_path(target.path)
    )
    local result, problem = run(ssh_command(target, remote_command), { stdin = buffer_bytes(buffer) })
    if not result then
        helpers.warn('Save failed: ' .. problem)
        return false
    end
    if result.code ~= 0 then
        local reason = first_line_of(result.stderr)
        helpers.warn('Save failed: ' .. (reason ~= '' and reason or ('ssh exit ' .. result.code)))
        return false
    end
    vim.bo[buffer].modified = false
    vim.b[buffer].notebashpp_remote_new = nil
    helpers.notify('Saved ' .. name)
    return true
end

------------------------------------------------------------------- web

-- a local file name for "save as": the last part of the address, or the host
-- name, with the extension of what it turned into. the internet never gives
-- anything a sensible name. neither did my parents.
local function suggested_file_name(url, extension)
    local without_query = url:gsub('[?#].*$', ''):gsub('/+$', '')
    local last_part = without_query:match('^%a+://[^/]+/.*/([^/]+)$') or without_query:match('^%a+://[^/]+/([^/]+)$')
    local base_name = last_part or without_query:match('^%a+://([^/:]+)') or 'page'
    base_name = base_name:gsub('[^%w._-]', '_')
    if extension and not base_name:lower():match('%.' .. extension .. '$') then
        base_name = base_name:gsub('%.html?$', '') .. '.' .. extension
    end
    return base_name
end

-- pandoc 2.15 and later can be told not to touch any file or address
-- (--sandbox); older ones don't know the flag, and converting html to text
-- without media options reads nothing else anyway.
local pandoc_has_sandbox = nil
local function pandoc_to_markdown(html_path)
    if pandoc_has_sandbox == nil then
        local help = run({ 'pandoc', '--help' }, { text = true })
        pandoc_has_sandbox = help ~= nil and (help.stdout or ''):find('--sandbox', 1, true) ~= nil
    end
    local command = { 'pandoc' }
    if pandoc_has_sandbox then
        table.insert(command, '--sandbox')
    end
    vim.list_extend(command, { '--from', 'html', '--to', 'gfm-raw_html', '--wrap', 'none', '--', html_path })
    return run(command)
end

local function read_from_web(buffer, url)
    local download_path = scratch_file()
    local result, problem = run({
        'curl',
        '--fail',
        '--silent',
        '--show-error',
        '--location',
        '--proto',
        '=http,https',
        '--proto-redir',
        '=http,https',
        '--max-redirs',
        '5',
        '--max-filesize',
        tostring(MAXIMUM_BYTES),
        '--max-time',
        tostring(TIME_LIMIT_MILLISECONDS / 1000),
        '--user-agent',
        'Notebash++',
        '--output',
        download_path,
        '--write-out',
        '%{content_type}',
        '--',
        url,
    }, { text = true })
    local function give_up(message)
        os.remove(download_path)
        helpers.warn(('Could not open %s: %s'):format(url, message))
    end
    if not result then
        return give_up(problem)
    end
    if result.code ~= 0 then
        return give_up(first_line_of(result.stderr) ~= '' and first_line_of(result.stderr) or ('curl exit ' .. result.code))
    end
    local size = (vim.uv.fs_stat(download_path) or { size = 0 }).size
    if size > MAXIMUM_BYTES then
        return give_up(('over %d MB'):format(MAXIMUM_BYTES / 1024 / 1024))
    end
    local content_type = (result.stdout or ''):lower()
    local is_html = content_type:find('text/html', 1, true) or content_type:find('application/xhtml', 1, true)
    if not is_html then
        local ok, fill_error = pcall(fill_buffer, buffer, read_bytes(download_path))
        os.remove(download_path)
        vim.b[buffer].notebashpp_save_as_name = suggested_file_name(url)
        if not ok then
            helpers.warn(tostring(fill_error))
        end
        return
    end
    local choice = vim.fn.confirm('Edit this page as HTML or as Markdown?\n\n' .. url, '&HTML\n&Markdown\n&Cancel', 1, 'Question')
    if choice == 2 and vim.fn.executable('pandoc') == 0 then
        helpers.warn('Markdown needs pandoc (https://pandoc.org); opening the page as HTML.')
        choice = 1
    end
    if choice == 1 then
        local ok, fill_error = pcall(fill_buffer, buffer, read_bytes(download_path), 'html')
        vim.b[buffer].notebashpp_save_as_name = suggested_file_name(url, 'html')
        if not ok then
            helpers.warn(tostring(fill_error))
        end
    elseif choice == 2 then
        local converted, convert_problem = pandoc_to_markdown(download_path)
        if not converted or converted.code ~= 0 then
            os.remove(download_path)
            return helpers.warn('pandoc could not convert the page: ' .. (convert_problem or first_line_of(converted and converted.stderr)))
        end
        local ok, fill_error = pcall(fill_buffer, buffer, converted.stdout, 'markdown')
        vim.b[buffer].notebashpp_save_as_name = suggested_file_name(url, 'md')
        if not ok then
            helpers.warn(tostring(fill_error))
        end
    else
        -- cancelled: close the empty document once neovim is done opening
        -- it. leaving was always my strongest skill.
        vim.schedule(function()
            if api.nvim_buf_is_valid(buffer) then
                pcall(api.nvim_buf_delete, buffer, { force = true })
            end
        end)
    end
    os.remove(download_path)
end

------------------------------------------------------------------ hooks

-- a local default for save as: the name the page suggested, in the folder
-- you started in. ssh files suggest their own base name.
---@param buffer integer
---@return string?
function remote_documents.save_as_default(buffer)
    local name = api.nvim_buf_get_name(buffer)
    local kind = remote_documents.kind(name)
    if not kind then
        return nil
    end
    local file_name = vim.b[buffer].notebashpp_save_as_name or vim.fs.basename(name:gsub('[?#].*$', ''))
    return vim.fs.joinpath(vim.fn.getcwd(), file_name ~= '' and file_name or 'page.txt')
end

-- ctrl+s on a remote document: ssh writes back, web asks for a local file.
---@param buffer integer
---@return boolean saved
function remote_documents.save(buffer)
    local name = api.nvim_buf_get_name(buffer)
    local kind = remote_documents.kind(name)
    if kind == 'ssh' then
        return write_over_ssh(buffer, name)
    end
    return require('notebashpp.file_commands').save_as(buffer)
end

-- a session keeps unsaved remote documents through their backup, but opening
-- them again must not reach the network at startup: the session restore
-- creates the buffer with this flag set, and the read skips the fetch. the
-- past can come back without phoning anyone first.
function remote_documents.mark_restored(buffer)
    vim.b[buffer].notebashpp_remote_restored = true
    vim.b[buffer].notebashpp_remote = true
    vim.bo[buffer].buftype = 'acwrite'
    vim.bo[buffer].swapfile = false
end

function remote_documents.setup()
    local augroup = api.nvim_create_augroup('notebashpp_remote_documents', { clear = true })
    local patterns = { 'http://*', 'https://*', 'ssh://*', 'scp://*' }
    api.nvim_create_autocmd('BufReadCmd', {
        group = augroup,
        pattern = patterns,
        callback = function(event)
            if vim.b[event.buf].notebashpp_remote_restored then
                -- once: a later reload fetches as usual.
                vim.b[event.buf].notebashpp_remote_restored = nil
                return
            end
            local name = api.nvim_buf_get_name(event.buf)
            local read_ok, read_error = pcall(remote_documents.kind(name) == 'ssh' and read_over_ssh or read_from_web, event.buf, name)
            if not read_ok then
                helpers.warn('Could not open ' .. name .. ': ' .. tostring(read_error))
            end
        end,
    })
    api.nvim_create_autocmd('BufWriteCmd', {
        group = augroup,
        pattern = patterns,
        callback = function(event)
            -- a plain :w. ssh saves right here; a web page needs save as,
            -- which renames the buffer, so that waits until this write is
            -- over. even saving has to take a number and wait.
            if remote_documents.kind(api.nvim_buf_get_name(event.buf)) == 'ssh' then
                remote_documents.save(event.buf)
            else
                vim.schedule(function()
                    remote_documents.save(event.buf)
                end)
            end
        end,
    })
end

return remote_documents
