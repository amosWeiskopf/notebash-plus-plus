-- keep menu settings (word wrap, dark mode, spell check) for next time.
-- notepad++ uses config.xml; we use a small json file in neovim's data
-- folder, private, written whole or not at all. basically my preferences get
-- a future. i just get older.

local preferences = {}

local preferences_file = vim.fn.stdpath('data') .. '/preferences.json'

---@type table<string, any>?
local loaded_values = nil

local function read_values()
    if loaded_values then
        return loaded_values
    end
    loaded_values = {}
    local read_ok, file_lines = pcall(vim.fn.readfile, preferences_file)
    if read_ok then
        local decode_ok, decoded = pcall(vim.json.decode, table.concat(file_lines, '\n'))
        if decode_ok and type(decoded) == 'table' then
            loaded_values = decoded
        end
    end
    return loaded_values
end

-- the saved value, or `default` if nothing was saved or the saved value has
-- another type than the default ("yes" where true belongs would stop the
-- whole startup). even failure gets a plan.
---@param name string
---@param default any
---@return any
function preferences.get(name, default)
    local value = read_values()[name]
    if value == nil or (default ~= nil and type(value) ~= type(default)) then
        return default
    end
    return value
end

-- remember a value & write the file immediately. trust cost me enough.
---@param name string
---@param value any
function preferences.set(name, value)
    local values = read_values()
    values[name] = value
    pcall(require('notebashpp.helpers').write_private_file, { vim.json.encode(values) }, preferences_file)
end

return preferences
