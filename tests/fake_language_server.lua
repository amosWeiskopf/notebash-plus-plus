-- a tiny test language server, run with nvim -l, speaking lsp over stdin and
-- stdout. definition finds the first occurrence of the word under the caret;
-- references find every occurrence. a line containing "problem" gets a
-- warning, hover says "about <word>", and completion offers one word.
-- basically it knows absolutely nothing and still has a job. shit, i'm
-- jealous.

local documents = {}

local function read_message()
    local content_length
    while true do
        local header_line = io.read('*l')
        if header_line == nil then
            return nil
        end
        header_line = header_line:gsub('\r$', '')
        if header_line == '' then
            break
        end
        local length_text = header_line:match('^Content%-Length: (%d+)')
        if length_text then
            content_length = tonumber(length_text)
        end
    end
    return vim.json.decode(io.read(content_length))
end

local function send(message)
    message.jsonrpc = '2.0'
    local body = vim.json.encode(message)
    io.write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
    io.flush()
end

local function document_lines(uri)
    return vim.split(documents[uri] or '', '\n', { plain = true })
end

local function word_at(uri, position)
    local line_text = document_lines(uri)[position.line + 1] or ''
    local word_start, word_end = position.character + 1, position.character
    while word_start > 1 and line_text:sub(word_start - 1, word_start - 1):match('[%w_]') do
        word_start = word_start - 1
    end
    while word_end < #line_text and line_text:sub(word_end + 1, word_end + 1):match('[%w_]') do
        word_end = word_end + 1
    end
    return line_text:sub(word_start, word_end)
end

-- every whole-word occurrence of `word`. no escape from this shit.
local function locations_of(uri, word)
    local locations = {}
    if word == '' then
        return locations
    end
    for line_index, line_text in ipairs(document_lines(uri)) do
        local search_from = 1
        while true do
            local found_start, found_end = line_text:find(word, search_from, true)
            if not found_start then
                break
            end
            local before = line_text:sub(found_start - 1, found_start - 1)
            local after = line_text:sub(found_end + 1, found_end + 1)
            if not before:match('[%w_]') and not after:match('[%w_]') then
                locations[#locations + 1] = {
                    uri = uri,
                    range = { start = { line = line_index - 1, character = found_start - 1 }, ['end'] = { line = line_index - 1, character = found_end } },
                }
            end
            search_from = found_end + 1
        end
    end
    return locations
end

local function publish_problems(uri)
    local diagnostics = {}
    for line_index, line_text in ipairs(document_lines(uri)) do
        local found_start, found_end = line_text:find('problem', 1, true)
        if found_start then
            diagnostics[#diagnostics + 1] = {
                range = { start = { line = line_index - 1, character = found_start - 1 }, ['end'] = { line = line_index - 1, character = found_end } },
                severity = 2,
                message = 'fake problem here',
                source = 'fake',
            }
        end
    end
    send({ method = 'textDocument/publishDiagnostics', params = { uri = uri, diagnostics = diagnostics } })
end

while true do
    local message = read_message()
    if not message then
        break
    end
    local method, params = message.method, message.params
    if method == 'initialize' then
        send({
            id = message.id,
            result = {
                capabilities = {
                    textDocumentSync = 1,
                    definitionProvider = true,
                    completionProvider = vim.empty_dict(),
                    referencesProvider = true,
                    hoverProvider = true,
                },
                serverInfo = { name = 'fake' },
            },
        })
    elseif method == 'textDocument/didOpen' then
        documents[params.textDocument.uri] = params.textDocument.text
        publish_problems(params.textDocument.uri)
    elseif method == 'textDocument/didChange' then
        documents[params.textDocument.uri] = params.contentChanges[#params.contentChanges].text
        publish_problems(params.textDocument.uri)
    elseif method == 'textDocument/definition' then
        local locations = locations_of(params.textDocument.uri, word_at(params.textDocument.uri, params.position))
        send({ id = message.id, result = locations[1] or vim.NIL })
    elseif method == 'textDocument/references' then
        send({ id = message.id, result = locations_of(params.textDocument.uri, word_at(params.textDocument.uri, params.position)) })
    elseif method == 'textDocument/hover' then
        local word = word_at(params.textDocument.uri, params.position)
        send({ id = message.id, result = { contents = { kind = 'plaintext', value = 'about ' .. word } } })
    elseif method == 'textDocument/completion' then
        send({ id = message.id, result = { { label = 'fake_completion' } } })
    elseif method == 'exit' then
        break
    elseif message.id ~= nil then
        send({ id = message.id, result = vim.NIL })
    end
end
