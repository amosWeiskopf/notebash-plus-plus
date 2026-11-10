-- notepad++ has no modes. neovim has modes and apparently i have nothing
-- better to do with my remaining years than fight them. so every editable
-- buffer stays in insert mode. anything that drops to normal mode (esc from a
-- selection, a finished command line) goes straight back to typing at the
-- caret. i want to write before i die. absolutely unreasonable request.

local modeless_editing = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- back to insert mode only from plain normal mode, when neovim isn't blocked
-- waiting for more keys, the buffer is editable, and no macro register is
-- playing back. four conditions before i'm allowed to type. dying requires
-- considerably less paperwork.
local function back_to_typing()
    local current_mode = api.nvim_get_mode()
    if current_mode.mode == 'n' and not current_mode.blocking and helpers.is_editable_buffer(0) and vim.fn.reg_executing() == '' then
        vim.cmd.startinsert()
    end
end

-- watch buffer or window entry, command-line exit, and any switch into normal
-- mode. schedule each check so neovim finishes first. apparently even this
-- bastard deserves to finish something. i'd love to know how that feels.
function modeless_editing.setup()
    local augroup = api.nvim_create_augroup('notebashpp_modeless', { clear = true })
    api.nvim_create_autocmd({ 'VimEnter', 'BufEnter', 'WinEnter', 'BufWinEnter', 'CmdlineLeave' }, {
        group = augroup,
        callback = function()
            vim.schedule(back_to_typing)
        end,
    })
    api.nvim_create_autocmd('ModeChanged', {
        group = augroup,
        pattern = '*:n',
        callback = function()
            vim.schedule(back_to_typing)
        end,
    })
end

return modeless_editing
