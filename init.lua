-- notebash++: neovim that types and edits like notepad++ 8.5.3. i gave a
-- powerful editor the job of pretending to be a simpler one. basically my
-- career, except this bastard still gets maintained.
--
-- the keyboard uses notepad++ 8.5.3's default shortcuts (parameters.cpp),
-- changed by one user's own %appdata%\notepad++\shortcuts.xml, plus the
-- compareplus 1.1.0 defaults. keys.md lists every key. i wrote evidence.
--
-- start through bin/notebash++, which sets nvim_appname=notebashpp and
-- leaves the plain `nvim` config in ~/.config/nvim alone. i want at least one
-- failed relationship where we don't destroy each other's belongings.

-- neovim before 0.11 lacks apis this config needs, so complain & stop here
-- before it half-works. i'm already doing that with my life. absolutely no
-- need for a second implementation.
if vim.fn.has('nvim-0.11') == 0 then
    vim.api.nvim_echo({ { 'Notebash++ needs Neovim 0.11 or newer.', 'ErrorMsg' } }, true, {})
    return
end
-- luajit looks for modules in the current folder first (./?.lua, ./?.so).
-- a pcall(require) of a module this neovim lacks would then run whatever a
-- downloaded folder ships under that name. drop those entries. i've let
-- enough strangers run my life without adding their lua.
local function without_current_folder(search_path)
    local kept_entries = {}
    for entry in search_path:gmatch('[^;]+') do
        if not entry:match('^%./') and not entry:match('^%.\\') then
            kept_entries[#kept_entries + 1] = entry
        end
    end
    return table.concat(kept_entries, ';')
end
package.path = without_current_folder(package.path)
package.cpath = without_current_folder(package.cpath)
vim.loader.enable()
require('notebashpp').setup()
