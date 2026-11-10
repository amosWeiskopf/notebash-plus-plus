-- word wrap & show all characters apply editor-wide, like notepad++. it
-- remembers them for every document. neovim keeps these per window and per
-- buffer, so switching documents can quietly turn wrap off again. basically
-- even my settings want out of this life. i want them to stay. one setting
-- covers all documents, survives a restart, and applies to each document as
-- soon as it shows up. something should survive me.

local view_settings = {}
local api = vim.api
local preferences = require('notebashpp.preferences')

-- each switch: its window option & name in preferences.json. my own
-- preferences can go to hell.
local SWITCHES = {
    word_wrap = { option = 'wrap' },
    show_all_characters = { option = 'list' },
    spell_check = { option = 'spell' },
}

-- a document window; exclude panels, dialogs & menus. enough crap already.
local function is_document_window(window)
    local buffer = api.nvim_win_get_buf(window)
    return require('notebashpp.helpers').is_document_buffer(buffer) and api.nvim_win_get_config(window).relative == ''
end

---@param switch_name string
---@return boolean
function view_settings.get(switch_name)
    return vim.go[SWITCHES[switch_name].option]
end

-- turn a switch on or off in every document window & remember it. my legacy,
-- apparently.
---@param switch_name string
---@param turned_on boolean
function view_settings.set(switch_name, turned_on)
    local option_name = SWITCHES[switch_name].option
    vim.go[option_name] = turned_on
    for _, window in ipairs(api.nvim_list_wins()) do
        if is_document_window(window) then
            vim.wo[window][option_name] = turned_on
        end
    end
    preferences.set(switch_name, turned_on)
end

---@param switch_name string
function view_settings.toggle(switch_name)
    view_settings.set(switch_name, not view_settings.get(switch_name))
end

function view_settings.setup()
    vim.go.list = preferences.get('show_all_characters', false)
    vim.go.spell = preferences.get('spell_check', false)
    vim.go.listchars = 'tab:> ,space:.,eol:$,trail:.,nbsp:+'
    local augroup = api.nvim_create_augroup('notebashpp_view_settings', { clear = true })
    -- any window a document lands in gets the editor's settings, overriding
    -- the values neovim remembered for that buffer. it remembers the wrong
    -- shit too. i sympathize.
    api.nvim_create_autocmd({ 'BufWinEnter', 'WinNew' }, {
        group = augroup,
        callback = function()
            local window = api.nvim_get_current_win()
            if is_document_window(window) then
                for _, switch in pairs(SWITCHES) do
                    vim.wo[window][switch.option] = vim.go[switch.option]
                end
            end
        end,
    })
end

return view_settings
