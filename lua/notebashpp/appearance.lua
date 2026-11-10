-- notepad++'s default light colours & font. white paper, black ink, a little
-- blue. basically i rebuilt the office that ate my life (my mistake).
-- stylers.xml: default style is consolas 10; config.xml: zoom="-2", which is
-- where the starting zoom is read from.

local appearance = {}

appearance.font = 'Consolas'
appearance.size = 10
appearance.zoom = tonumber(require('notebashpp.notepadpp_settings_import').view_options().zoom) or 0

-- dark mode: each light colour below has a dark partner. one paint list.
-- notepad++ added it in 8.0 (issue 7692, 55 votes). these are close to vs
-- code's dark+, which most eyes already know. basically we voted for darkness
-- and got a familiar shade of shit.
local DARK_PARTNER = {
    ['#000000'] = '#D4D4D4',
    ['#FFFFFF'] = '#1E1E1E',
    ['#808080'] = '#858585',
    ['#E4E4E4'] = '#252526',
    ['#F0F0F0'] = '#2D2D30',
    ['#F2F2F2'] = '#2D2D30',
    ['#F3F3F3'] = '#252526',
    ['#E8E8FF'] = '#2A2D3E',
    ['#C0C0C0'] = '#3E3E42',
    ['#FF0000'] = '#F44747',
    ['#B0B0B0'] = '#5A5A5A',
    ['#FFFF80'] = '#6B5B00',
    ['#00FFFF'] = '#0E6A73',
    ['#0078D7'] = '#0E639C',
    ['#A0A0A0'] = '#6E6E6E',
    ['#404040'] = '#BBBBBB',
    ['#606060'] = '#A0A0A0',
    ['#DADADA'] = '#2D2D2D',
    ['#000080'] = '#9CDCFE',
    ['#C00000'] = '#F48771',
    ['#B05000'] = '#CE9178',
    ['#006000'] = '#6A9955',
    ['#C0E0FF'] = '#094771',
    ['#008000'] = '#6A9955',
    ['#C6FFC6'] = '#373D29',
    ['#FF8080'] = '#6F2C2C',
    ['#FFD0D0'] = '#4B1818',
    ['#FFFFC0'] = '#3E3D1F',
    ['#FFE080'] = '#6B5B00',
    ['#FF8000'] = '#FFA657',
    ['#0000FF'] = '#569CD6',
    ['#804000'] = '#C586C0',
    ['#8000FF'] = '#4EC9B0',
    ['#3070D0'] = '#75BEFF',
    ['#80FF80'] = '#2E5E2E',
    ['#FFFF00'] = '#6B6B00',
    ['#8080FF'] = '#3C3C8C',
    ['#CCE8FF'] = '#094771',
    ['#91C9F7'] = '#094771',
    ['#505050'] = '#A0A0A0',
    ['#C8C8C8'] = '#454545',
    ['#0050A0'] = '#75BEFF',
}

-- one light colour does two jobs; dark mode needs two colours. even the paint
-- is burned out.
local DARK_EXCEPTIONS = {
    Visual = { bg = '#264F78' },
    String = { fg = '#CE9178' },
    Character = { fg = '#CE9178' },
    PmenuSel = { fg = '#FFFFFF' },
    DiffDelete = { fg = '#F48771' },
    NotebashColumn = { bg = '#3A3D41' },
    NotebashSheetCurrent = { fg = '#FFFFFF', bg = '#0E639C' },
    NotebashSheetEditor = { bg = '#252526' },
    NotebashSheetInvalid = { fg = '#F48771', bold = true },
}

function appearance.dark_mode()
    return require('notebashpp.preferences').get('dark_mode', false) == true
end

-- one line per highlight group, so this reads like a paint chart. i want my
-- wasted life colour-coded, please.
local function set_highlight(group_name, highlight_spec)
    if appearance.dark_mode() and not highlight_spec.link then
        local dark_spec = {}
        for field_name, field_value in pairs(highlight_spec) do
            if (field_name == 'fg' or field_name == 'bg' or field_name == 'sp') and type(field_value) == 'string' then
                dark_spec[field_name] = DARK_PARTNER[field_value:upper()] or field_value
            else
                dark_spec[field_name] = field_value
            end
        end
        highlight_spec = vim.tbl_extend('force', dark_spec, DARK_EXCEPTIONS[group_name] or {})
    end
    vim.api.nvim_set_hl(0, group_name, highlight_spec)
end

-- toggle dark mode, repaint & save the choice. at least this regret persists.
---@param dark_on boolean
function appearance.set_dark_mode(dark_on)
    require('notebashpp.preferences').set('dark_mode', dark_on)
    appearance.colors()
end

function appearance.colors()
    vim.o.background = appearance.dark_mode() and 'dark' or 'light'
    vim.cmd('highlight clear')
    if vim.fn.exists('syntax_on') == 1 then
        vim.cmd('syntax reset')
    end
    vim.g.colors_name = 'notebashpp'
    set_highlight('Normal', { fg = '#000000', bg = '#FFFFFF' })
    set_highlight('NormalNC', { link = 'Normal' })
    set_highlight('LineNr', { fg = '#808080', bg = '#E4E4E4' })
    set_highlight('CursorLineNr', { fg = '#808080', bg = '#E4E4E4' })
    set_highlight('SignColumn', { bg = '#F0F0F0' })
    set_highlight('FoldColumn', { fg = '#808080', bg = '#F3F3F3' })
    set_highlight('CursorLine', { bg = '#E8E8FF' })
    set_highlight('CursorColumn', { bg = '#E8E8FF' })
    set_highlight('Visual', { bg = '#C0C0C0' })
    set_highlight('MatchParen', { fg = '#FF0000', bold = true })
    set_highlight('Folded', { fg = '#808080', bg = '#F3F3F3' })
    set_highlight('NonText', { fg = '#B0B0B0' })
    set_highlight('EndOfBuffer', { fg = '#FFFFFF' })
    set_highlight('Whitespace', { fg = '#B0B0B0' })
    set_highlight('SpecialKey', { fg = '#B0B0B0' })
    set_highlight('Search', { bg = '#FFFF80' })
    set_highlight('IncSearch', { bg = '#00FFFF' })
    set_highlight('CurSearch', { bg = '#00FFFF' })
    set_highlight('Pmenu', { fg = '#000000', bg = '#FFFFFF' })
    set_highlight('PmenuSel', { fg = '#FFFFFF', bg = '#0078D7' })
    set_highlight('PmenuSbar', { bg = '#F0F0F0' })
    set_highlight('PmenuThumb', { bg = '#C0C0C0' })
    set_highlight('NormalFloat', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('FloatBorder', { fg = '#A0A0A0', bg = '#F0F0F0' })
    set_highlight('FloatTitle', { fg = '#000000', bg = '#F0F0F0', bold = true })
    set_highlight('FloatFooter', { fg = '#404040', bg = '#F0F0F0' })
    set_highlight('StatusLine', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('StatusLineNC', { fg = '#606060', bg = '#F0F0F0' })
    set_highlight('WinSeparator', { fg = '#C0C0C0', bg = '#FFFFFF' })
    set_highlight('TabLine', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('TabLineFill', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('TabLineSel', { fg = '#000000', bg = '#FFFFFF' })
    set_highlight('WinBar', { fg = '#000000', bg = '#DADADA' })
    set_highlight('WinBarNC', { fg = '#000000', bg = '#DADADA' })
    set_highlight('Title', { fg = '#000080', bold = true })
    set_highlight('Directory', { fg = '#000080' })
    set_highlight('ErrorMsg', { fg = '#C00000' })
    set_highlight('WarningMsg', { fg = '#B05000' })
    set_highlight('MoreMsg', { fg = '#006000' })
    set_highlight('Question', { fg = '#006000' })
    set_highlight('ModeMsg', { fg = '#000000' })
    set_highlight('MsgArea', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('QuickFixLine', { bg = '#C0E0FF' })
    set_highlight('qfFileName', { fg = '#008000', bold = true })
    set_highlight('qfLineNr', { fg = '#808080' })
    set_highlight('DiffAdd', { bg = '#C6FFC6' })
    set_highlight('DiffDelete', { fg = '#FF8080', bg = '#FFD0D0' })
    set_highlight('DiffChange', { bg = '#FFFFC0' })
    set_highlight('DiffText', { bg = '#FFE080' })
    set_highlight('Conceal', { fg = '#808080' })
    -- only real misspellings get a red underline, like dspellcheck. neovim's
    -- capitals, rare & regional words stay quiet. i want spelling help,
    -- please, my failures already have supervision.
    set_highlight('SpellBad', { sp = '#FF0000', undercurl = true })
    set_highlight('SpellCap', {})
    set_highlight('SpellRare', {})
    set_highlight('SpellLocal', {})

    -- syntax, close to notepad++'s default lexer colours: comments green,
    -- keywords bold blue, numbers orange, strings grey. i gave the strings
    -- the colour of my future. absolutely accurate, for once.
    set_highlight('Comment', { fg = '#008000' })
    set_highlight('Constant', { fg = '#FF8000' })
    set_highlight('String', { fg = '#808080' })
    set_highlight('Character', { fg = '#808080' })
    set_highlight('Number', { fg = '#FF8000' })
    set_highlight('Boolean', { fg = '#0000FF', bold = true })
    set_highlight('Float', { fg = '#FF8000' })
    set_highlight('Identifier', { fg = '#000000' })
    set_highlight('Function', { fg = '#000000' })
    set_highlight('Statement', { fg = '#0000FF', bold = true })
    set_highlight('Keyword', { fg = '#0000FF', bold = true })
    set_highlight('Operator', { fg = '#000080', bold = true })
    set_highlight('PreProc', { fg = '#804000' })
    set_highlight('Type', { fg = '#8000FF' })
    set_highlight('Special', { fg = '#000080' })
    set_highlight('Delimiter', { fg = '#000080' })
    set_highlight('Underlined', { fg = '#0000FF', underline = true })
    set_highlight('Error', { fg = '#FFFFFF', bg = '#FF0000' })
    set_highlight('Todo', { fg = '#FF0000', bold = true })
    set_highlight('@variable', { fg = '#000000' })
    set_highlight('@punctuation', { fg = '#000080' })
    set_highlight('@markup.heading', { fg = '#000080', bold = true })

    -- notebash++'s own groups: bookmarks, find marks, the five mark styles,
    -- the tab bar, the menus and the dialogs. other modules look them up by
    -- name, so keep the names exactly as they are. even my mistakes have
    -- dependents now.
    set_highlight('NotebashBookmark', { fg = '#3070D0' })
    set_highlight('NotebashSheetHeader', { fg = '#000000', bg = '#E4E4E4', bold = true })
    set_highlight('NotebashSheetRowNumber', { fg = '#808080', bg = '#F0F0F0' })
    set_highlight('NotebashSheetGrid', { fg = '#C8C8C8' })
    set_highlight('NotebashSheetCurrent', { fg = '#000000', bg = '#91C9F7', bold = true })
    set_highlight('NotebashSheetSelection', { bg = '#CCE8FF' })
    set_highlight('NotebashSheetEdited', { fg = '#B05000', italic = true })
    set_highlight('NotebashSheetEditor', { fg = '#000000', bg = '#FFFFFF' })
    set_highlight('NotebashSheetInvalid', { fg = '#C00000', bold = true })
    set_highlight('NotebashFound', { bg = '#00FFFF' })
    set_highlight('NotebashMark', { bg = '#FF8080' })
    set_highlight('NotebashSmart', { bg = '#80FF80' })
    set_highlight('NotebashStyle1', { bg = '#00FFFF' })
    set_highlight('NotebashStyle2', { bg = '#FF8000' })
    set_highlight('NotebashStyle3', { bg = '#FFFF00' })
    set_highlight('NotebashStyle4', { bg = '#8080FF' })
    set_highlight('NotebashStyle5', { bg = '#008000', fg = '#FFFFFF' })
    set_highlight('NotebashColumn', { bg = '#C0C0C0' })
    set_highlight('NotebashCaret', { bg = '#000000', fg = '#FFFFFF' })
    set_highlight('NotebashMultiCaret', { link = 'NotebashCaret' })
    set_highlight('NotebashMultiSelection', { link = 'Visual' })
    set_highlight('NotebashHidden', { fg = '#3070D0', bold = true })
    set_highlight('NotebashTab', { fg = '#000000', bg = '#DADADA' })
    set_highlight('NotebashTabSel', { fg = '#000000', bg = '#FFFFFF', bold = true })
    set_highlight('NotebashTabMod', { fg = '#C00000', bg = '#DADADA' })
    set_highlight('NotebashTabSelMod', { fg = '#C00000', bg = '#FFFFFF', bold = true })
    set_highlight('NotebashTabClose', { fg = '#808080', bg = '#DADADA' })
    set_highlight('NotebashTabSelClose', { fg = '#808080', bg = '#FFFFFF' })
    set_highlight('NotebashMenuBar', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('NotebashMenuBarOpen', { fg = '#000000', bg = '#CCE8FF' })
    set_highlight('NotebashMenu', { fg = '#000000', bg = '#F2F2F2' })
    set_highlight('NotebashMenuSel', { fg = '#000000', bg = '#91C9F7' })
    set_highlight('NotebashMenuKey', { fg = '#000000', bg = '#F2F2F2', underline = true })
    set_highlight('NotebashMenuHint', { fg = '#505050', bg = '#F2F2F2' })
    set_highlight('NotebashMenuOff', { fg = '#A0A0A0', bg = '#F2F2F2' })
    set_highlight('NotebashMenuSep', { fg = '#C8C8C8', bg = '#F2F2F2' })
    set_highlight('NotebashDlgLabel', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('NotebashDlgField', { fg = '#000000', bg = '#FFFFFF' })
    set_highlight('NotebashDlgOn', { fg = '#000000', bg = '#F0F0F0', bold = true })
    set_highlight('NotebashDlgOff', { fg = '#606060', bg = '#F0F0F0' })
    set_highlight('NotebashDlgKey', { fg = '#0050A0', bg = '#F0F0F0' })
    set_highlight('NotebashDlgMsg', { fg = '#000080', bg = '#F0F0F0', bold = true })
    set_highlight('NotebashDlgErr', { fg = '#C00000', bg = '#F0F0F0', bold = true })
    -- notification floats (messages.lua): body, border & title per level.
    -- even this shit gets a title.
    set_highlight('NotebashNote', { fg = '#000000', bg = '#F0F0F0' })
    set_highlight('NotebashNoteBorder', { fg = '#A0A0A0', bg = '#F0F0F0' })
    set_highlight('NotebashNoteTitle', { fg = '#000080', bg = '#F0F0F0', bold = true })
    set_highlight('NotebashNoteWarn', { fg = '#B05000', bg = '#F0F0F0', bold = true })
    set_highlight('NotebashNoteError', { fg = '#C00000', bg = '#F0F0F0', bold = true })
    -- the json tree panel (json_tree.lua): a grey sidebar like the plugin's
    -- docked window, keys navy, strings brown, numbers orange, the selected
    -- node in selection blue. a stale tree goes grey, like my hair did.
    set_highlight('NotebashJsonTree', { fg = '#000000', bg = '#F3F3F3' })
    set_highlight('NotebashJsonTreeHeader', { fg = '#000000', bg = '#DADADA' })
    set_highlight('NotebashJsonTreeCurrent', { bg = '#C0E0FF' })
    set_highlight('NotebashJsonTreeExpander', { fg = '#808080', bold = true })
    set_highlight('NotebashJsonTreeKey', { fg = '#000080' })
    set_highlight('NotebashJsonTreeString', { fg = '#B05000' })
    set_highlight('NotebashJsonTreeNumber', { fg = '#FF8000' })
    set_highlight('NotebashJsonTreeLiteral', { fg = '#0000FF', bold = true })
    set_highlight('NotebashJsonTreeSize', { fg = '#808080' })
    set_highlight('NotebashJsonTreeStale', { fg = '#A0A0A0' })
    set_highlight('NotebashJsonTreeError', { fg = '#C00000', bold = true })
end

-- zoom changes the font by 1 point per step, scintilla's smallest step, from
-- 4 to 72 points. notepad++ stops at +20 (30 points at its default size). we
-- go up to projector size. i'd love my mistakes to reach the back of the room
-- as well.
appearance.SMALLEST_FONT_SIZE = 4
appearance.LARGEST_FONT_SIZE = 72

function appearance.font_size()
    return math.max(appearance.SMALLEST_FONT_SIZE, math.min(appearance.LARGEST_FONT_SIZE, appearance.size + appearance.zoom))
end

function appearance.apply_font()
    vim.o.guifont = ('%s:h%d'):format(appearance.font, appearance.font_size())
end

-- ctrl+numpad plus and minus (or ctrl+wheel) move zoom one step, clamped to
-- -10 and +20; ctrl+numpad slash (step 0) resets it to 0. only neovide can
-- change the font. in a terminal, the terminal owns the font; we just
-- announce the number. basically management, without the fucking salary.
function appearance.zoom_by(zoom_step)
    local helpers = require('notebashpp.helpers')
    if zoom_step == 0 then
        appearance.zoom = 0
    else
        local smallest_zoom = appearance.SMALLEST_FONT_SIZE - appearance.size
        local largest_zoom = appearance.LARGEST_FONT_SIZE - appearance.size
        appearance.zoom = math.max(smallest_zoom, math.min(largest_zoom, appearance.zoom + zoom_step))
    end
    if not vim.g.neovide then
        -- the terminal draws the text; only it can change the text size.
        -- windows terminal, gnome terminal, konsole & kitty have their own
        -- ctrl+= and ctrl+- zoom. ask them. i'm absolutely powerless here
        -- (good preparation for the rest of life).
        return helpers.notify("In a terminal, use the terminal's own zoom (Ctrl+= and Ctrl+- in most terminals).")
    end
    appearance.apply_font()
    -- a new font size changes screen width. word wrap stays on because it
    -- belongs to each window, not the font. lines simply rewrap. i change one
    -- thing and everything rearranges itself. like my life, but it works.
    if appearance.font_size() == appearance.SMALLEST_FONT_SIZE and zoom_step < 0 then
        helpers.notify(('Zoom: smallest size (%d pt)'):format(appearance.SMALLEST_FONT_SIZE))
    elseif appearance.font_size() == appearance.LARGEST_FONT_SIZE and zoom_step > 0 then
        helpers.notify(('Zoom: largest size (%d pt)'):format(appearance.LARGEST_FONT_SIZE))
    end
end

-- neovide animates the caret & scrolling. i want to edit text, please, my
-- remaining years are quite capable of disappearing without choreography. set
-- the font, turn every animation off & remove padding once per run.
-- neovide_done remembers this, including across a code reload.
local function configure_neovide_once()
    if not vim.g.neovide or appearance.neovide_done then
        return
    end
    appearance.neovide_done = true
    appearance.apply_font()
    vim.g.neovide_cursor_animation_length = 0
    vim.g.neovide_cursor_trail_size = 0
    vim.g.neovide_cursor_animate_in_insert_mode = false
    vim.g.neovide_scroll_animation_length = 0
    vim.g.neovide_position_animation_length = 0
    vim.g.neovide_cursor_vfx_mode = ''
    vim.g.neovide_hide_mouse_when_typing = false
    vim.g.neovide_remember_window_size = true
    vim.g.neovide_padding_top = 0
    vim.g.neovide_padding_left = 0
    -- closing keeps unsaved work in the session snapshot for next time, so no
    -- question is asked. without a session, ask first. i want to lose my work
    -- through my own shit decisions, please.
    vim.g.neovide_confirm_quit = not require('notebashpp.session').enabled()
end

function appearance.setup()
    appearance.colors()
    -- neovide may only announce itself after its window attaches, so try now
    -- & again on uienter. i check for signs of life twice. mine can wait.
    configure_neovide_once()
    vim.api.nvim_create_autocmd('UIEnter', {
        group = vim.api.nvim_create_augroup('notebashpp_look', { clear = true }),
        callback = configure_neovide_once,
    })
    -- a thin caret while typing, like a windows editor. the block takes up
    -- more space, which apparently qualifies as a purpose. i should try that.
    vim.o.guicursor = 'n-v-ve-i-ci-sm-c:ver25,r-cr-o:hor20,a:blinkwait600-blinkon600-blinkoff600'
end

return appearance
