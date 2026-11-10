-- editor settings come from your notepad++ config.xml where available, read
-- by notebashpp.notepadpp_settings_import; otherwise from notepad++
-- defaults. basically somebody else's decisions from years ago. i want
-- control of my life. apparently i'm starting with tab widths.

local option_objects = vim.opt
local imported_view = require('notebashpp.notepadpp_settings_import').view_options()
local imported_new_document = require('notebashpp.notepadpp_settings_import').new_document_options()

-- skip options neovim lacks (newer than the oldest supported release, or
-- renamed later), so startup survives. set what exists and leave the rest.
-- i've lowered my expectations to 'opens without dying'. still ambitious.
local editor_option = setmetatable({}, {
    __index = function(_, name)
        return vim.o[name]
    end,
    __newindex = function(_, name, value)
        if vim.fn.exists('+' .. name) == 1 then
            vim.o[name] = value
        end
    end,
})

-- margins follow notepad++: line numbers, then bookmarks, then folds.
-- statuscolumn draws that order with the number right-aligned. like a bill.
-- even my line numbers look like money i don't have.
editor_option.number = true
editor_option.numberwidth = 4
editor_option.signcolumn = 'yes:1'
editor_option.foldcolumn = '0'
editor_option.statuscolumn = '%=%l %s%C'

-- windows-style selection: shift+arrows select, typing replaces it. the caret
-- sits between characters (selection=exclusive, virtualedit=onemore). i want
-- that exact behaviour. apparently i'll rebuild an editor before i'll admit
-- i'm afraid of change.
editor_option.mouse = 'a'
editor_option.mousemodel = 'popup_setpos'
editor_option.selectmode = 'mouse,key'
editor_option.keymodel = 'startsel,stopsel'
editor_option.selection = 'exclusive'
editor_option.virtualedit = 'block,onemore'
editor_option.whichwrap = 'b,s,<,>,[,],h,l'
editor_option.backspace = 'indent,eol,start'
editor_option.startofline = false

-- scintillaprimaryview wrap: off unless notepad++'s config.xml enables it.
-- long lines disappear past the right edge until you scroll. i paid for the
-- whole screen and still have to dig my own text out. absolutely shit. a view
-- menu choice saved in preferences.json wins over the imported setting. i
-- want at least one of my decisions to count for something.
editor_option.wrap = require('notebashpp.preferences').get('word_wrap', imported_view.Wrap == 'yes')
-- compare keeps word wrap, like compareplus. neovim's diff mode would turn it
-- off for every compared window. apparently my failures need a wider grave.
vim.opt.diffopt:append('followwrap')
editor_option.linebreak = true
editor_option.breakindent = true

-- tabsetting: replacebyspace="no" size="4"; maitainindent yes. that's the
-- spelling in config.xml. ship a typo and it gets a future. i should have
-- tried being a typo.
editor_option.expandtab = false
editor_option.tabstop = 4
editor_option.shiftwidth = 0
editor_option.softtabstop = 0
editor_option.autoindent = true
editor_option.smartindent = false
editor_option.cindent = false
vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('notebashpp_ft', { clear = true }),
    callback = function()
        -- filetype plugins change these; notepad++ doesn't. restore them
        -- after every filetype plugin has had its say. unpaid work undoing
        -- unpaid work. what a phenomenal use of the time i have left.
        vim.bo.expandtab = false
        vim.bo.tabstop = 4
        vim.bo.shiftwidth = 0
        vim.bo.softtabstop = 0
        vim.bo.textwidth = 0
        vim.bo.indentexpr = ''
        vim.bo.cindent = false
        vim.bo.smartindent = false
        option_objects.formatoptions:remove({ 'c', 'r', 'o', 't', 'a' })
    end,
})
editor_option.textwidth = 0

-- currentlineindicator="1": highlight the caret line so i can find where i
-- am. the rest of my life can stay absolutely fucking lost.
editor_option.cursorline = true
editor_option.scrolloff = 0
editor_option.sidescroll = 1
editor_option.sidescrolloff = 0

-- files: no swap prompts; reload changed files. new documents use cr lf
-- (newdocdefaultsettings format="0"), utf-8 (encoding="4"). config.xml's
-- format leads fileformats ('0' dos, '1' mac, '2' unix). without one, windows
-- & wsl get dos first; everyone else gets unix. even a line ending needs this
-- much paperwork. death will probably want a config file.
editor_option.swapfile = false
editor_option.autoread = true
editor_option.hidden = true
editor_option.confirm = false
local is_windows_like = vim.fn.has('win32') == 1 or vim.fn.has('wsl') == 1
local new_document_format = ({ ['0'] = 'dos', ['1'] = 'mac', ['2'] = 'unix' })[imported_new_document.format or '']
local first_format = new_document_format or (is_windows_like and 'dos' or 'unix')
editor_option.fileformats = table.concat(
    vim.list_extend(
        { first_format },
        vim.tbl_filter(function(format)
            return format ~= first_format
        end, { 'dos', 'unix', 'mac' })
    ),
    ','
)
editor_option.fileencodings = 'ucs-bom,utf-8,default,latin1'
editor_option.fixendofline = false
editor_option.endofline = false
-- no modelines. notepad++ never let a file set its own options, and a
-- modeline can set fileencoding, iskeyword and friends to text that later
-- lands in the status bar or a menu. i don't let strangers rearrange my
-- furniture either. not that anyone offers.
editor_option.modeline = false
-- while saving, neovim copies the old file aside, then deletes that copy once
-- the save works. a full disk or dead wsl mid-save costs the new version, not
-- both. i'd love this much protection for my life choices. the copy goes in
-- neovim's own state folder, never beside your file. backupcopy=yes
-- overwrites the original in place, so windows keeps its permissions and
-- links. even this bastard gets to keep its connections.
editor_option.writebackup = true
editor_option.backupcopy = 'yes'
vim.fn.mkdir(vim.fn.stdpath('state') .. '/backup', 'p')
vim.uv.fs_chmod(vim.fn.stdpath('state') .. '/backup', tonumber('700', 8))
editor_option.backupdir = vim.fn.stdpath('state') .. '/backup//'
editor_option.undolevels = 1000

-- search goes through the find dialog, not /. these options only affect the
-- odd vim search that gets through anyway. i removed the door and the bastard
-- is still coming through the wall.
editor_option.ignorecase = false
editor_option.smartcase = false
editor_option.hlsearch = false
editor_option.incsearch = true
editor_option.wrapscan = true

-- auto-completion uses notebashpp.word_completion, with words from the
-- current file. neovim's own 'autocomplete' opens the list on every caret
-- move. i want a word suggestion, please, not supervision of my failure.
editor_option.autocomplete = false
editor_option.complete = '.'
editor_option.completeopt = 'menuone,noinsert'
editor_option.pumheight = 10
editor_option.shortmess = 'filnxtToOFIcCsWS'

-- quiet screen: no corner mode display, bells or ruler. window title: a star
-- if modified, then the file name, then notebash++. i want the taskbar to
-- show exactly which unsaved shit i'll regret losing.
editor_option.showmode = false
editor_option.ruler = false
editor_option.showcmd = false
editor_option.laststatus = 3
editor_option.showtabline = 2
editor_option.cmdheight = 1
editor_option.report = 9999
editor_option.belloff = 'all'
editor_option.errorbells = false
editor_option.visualbell = false
editor_option.timeoutlen = 400
editor_option.ttimeoutlen = 10
editor_option.updatetime = 300
editor_option.list = false
editor_option.splitright = true
editor_option.splitbelow = true
editor_option.termguicolors = true
editor_option.title = true
editor_option.titlestring = '%{&modified ? "*" : ""}%{v:lua.require("notebashpp.document_tabs").title()} - Notebash++'
editor_option.conceallevel = 2
-- conceallevel is on for the hidden-lines folding, but syntax files use it
-- too: json hid every quote and markdown hid its asterisks. notepad++ shows
-- every character you typed. so does this. i hide enough already.
vim.g.vim_json_conceal = 0
vim.g.markdown_syntax_conceal = 0
vim.g.tex_conceal = ''
-- neovim's markdown tree-sitter queries hide *, `, link addresses and code
-- fences through the same conceallevel. load them without their conceal
-- directives. a text editor that deletes text from view is a magician, and
-- i've been fooled enough.
for _, language in ipairs({ 'markdown', 'markdown_inline' }) do
    pcall(function()
        local query_texts = {}
        for _, query_file in ipairs(vim.treesitter.query.get_files(language, 'highlights')) do
            query_texts[#query_texts + 1] = table.concat(vim.fn.readfile(query_file), '\n')
        end
        if #query_texts > 0 then
            local query_text = table.concat(query_texts, '\n'):gsub('%(#set!%s+conceal[_%a]*%s+".-"%)', '')
            vim.treesitter.query.set(language, 'highlights', query_text)
        end
    end)
end
editor_option.concealcursor = 'nvic'
editor_option.jumpoptions = 'stack'
editor_option.wildmode = 'longest:full,full'
editor_option.wildoptions = 'pum'
editor_option.shada = "!,'100,<50,s10,h"

-- fold by syntax tree if neovim has a parser, otherwise by indent. all folds
-- start open. i want you to see the whole mess before you decide this is how
-- to spend your finite life (my mistake already).
editor_option.foldenable = true
editor_option.foldlevel = 99
editor_option.foldlevelstart = 99
editor_option.foldmethod = 'indent'
editor_option.fillchars = 'fold: ,foldopen:-,foldclose:+,foldsep: ,eob: '

-- hebrew: 'rightleft' stays off until shift+f10 asks. enough chaos already.
editor_option.rightleft = false
editor_option.delcombine = false

-- no leader key or netrw file browser; let the stock matchit plugin load.
-- basically i'm gutting vim and calling it a project. cheaper than dealing
-- with whatever the hell i'm actually unhappy about.
vim.g.mapleader = nil
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1
-- neovim 0.12's own http opener (plugin/net.lua) would fetch every web
-- address a second time, without the html or markdown question.
-- remote_documents.lua does that job. one of us fetching is plenty.
vim.g.loaded_nvim_net_plugin = true
vim.g.loaded_matchit = nil

-- apply user.lua's vim_options last so they win. you get the final word. i
-- wrote all this and can still be overruled in one file. feels like home.
for name, value in pairs(require('notebashpp.user_settings').get('vim_options') or {}) do
    editor_option[name] = value
end
