-- a test user.lua with every setting changed from its default. i built the
-- most demanding user imaginable, so the real ones seem easygoing. basically
-- i made an asshole from scratch. i could have just looked in the mirror.
return {
    duplicate_whole_lines = true,
    line_delete_acts_on_selected_lines = true,
    keys = {
        rtl = { '<S-F10>' },
        line_delete = { '<C-l>', '<C-S-l>' },
        line_cut = {},
    },
    commands = {
        {
            id = 'shout_line',
            label = 'Shout the Current Line',
            keys = { '<C-M-k1>' },
            run = function()
                local line_number = vim.api.nvim_win_get_cursor(0)[1]
                local text = vim.api.nvim_buf_get_lines(0, line_number - 1, line_number, false)[1]
                vim.api.nvim_buf_set_lines(0, line_number - 1, line_number, false, { text:upper() })
            end,
        },
    },
}
