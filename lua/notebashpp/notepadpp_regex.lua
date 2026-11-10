-- notepad++ search text becomes a vim pattern. the find dialog has three
-- search modes. apparently one way to waste my life wasn't enough.
--
-- normal mode is literal text. extended mode adds character escapes: \n \r \t
-- \0, \x with two hex digits, \u with four, \o with three octal digits, \d
-- with three decimal digits and \b with eight binary digits. regular
-- expression mode translates boost (pcre style) syntax into vim's very-magic
-- syntax. basically i taught two editors to misunderstand each other, and
-- called this progress. notepad++ line ends can be \r\n, \n or \r; all three
-- match a vim line end. neovim treats a line end as a line end. i'd love this
-- much clarity about what i'm doing with my remaining years (but here we
-- are).

local notepadpp_regex = {}

-- expand extended-mode escapes into their actual characters. an unrecognised
-- backslash sequence stays exactly as typed. i forgive this text more easily
-- than my own damn decisions.
function notepadpp_regex.expand_extended(text)
    local pieces, position = {}, 1
    while position <= #text do
        local character = text:sub(position, position)
        if character == '\\' and position < #text then
            local escape_letter = text:sub(position + 1, position + 1)
            local single_character_escapes = { n = '\n', r = '\r', t = '\t', ['0'] = '\0', ['\\'] = '\\' }
            if single_character_escapes[escape_letter] then
                pieces[#pieces + 1] = single_character_escapes[escape_letter]
                position = position + 2
            elseif escape_letter == 'x' and text:sub(position + 2, position + 3):match('^%x%x$') then
                pieces[#pieces + 1] = string.char(tonumber(text:sub(position + 2, position + 3), 16))
                position = position + 4
            elseif escape_letter == 'u' and text:sub(position + 2, position + 5):match('^%x%x%x%x$') then
                pieces[#pieces + 1] = vim.fn.nr2char(tonumber(text:sub(position + 2, position + 5), 16))
                position = position + 6
            -- \o and \d stop at 255, the biggest byte. \o777 or \d999 stay as
            -- typed, like any meaningless escape. even this crap has limits.
            -- i should try having some.
            elseif escape_letter == 'o' and text:sub(position + 2, position + 4):match('^[0-3][0-7][0-7]$') then
                pieces[#pieces + 1] = string.char(tonumber(text:sub(position + 2, position + 4), 8))
                position = position + 5
            elseif escape_letter == 'd' and (tonumber(text:sub(position + 2, position + 4):match('^%d%d%d$')) or 256) <= 255 then
                local decimal_byte = tonumber(text:sub(position + 2, position + 4)) or 0
                pieces[#pieces + 1] = string.char(decimal_byte)
                position = position + 5
            elseif escape_letter == 'b' and text:sub(position + 2, position + 9):match('^[01]+$') and #text:sub(position + 2, position + 9) == 8 then
                pieces[#pieces + 1] = string.char(tonumber(text:sub(position + 2, position + 9), 2))
                position = position + 10
            else
                pieces[#pieces + 1] = character
                position = position + 1
            end
        else
            pieces[#pieces + 1] = character
            position = position + 1
        end
    end
    return table.concat(pieces)
end

-- literal text becomes very-nomagic (backslash followed by capital v). escape
-- backslashes and slashes; any line break matches a line end, whatever its
-- operating system. even this crap gets a fresh start.
function notepadpp_regex.literal(text)
    text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
    local pieces = {}
    -- one utf-8 character at a time. i can ruin this without butchering
    -- accents.
    for character in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if character == '\\' then
            pieces[#pieces + 1] = '\\\\'
        elseif character == '\n' then
            pieces[#pieces + 1] = '\\n'
        elseif character == '/' then
            pieces[#pieces + 1] = '\\/'
        else
            pieces[#pieces + 1] = character
        end
    end
    return '\\V' .. table.concat(pieces)
end

-- boost word characters: digits, ascii letters, underscore & every code point
-- from u+00aa to u+ffff (ª to ￿). absolutely generous admission criteria. my
-- failed ideas would qualify if they had code points.
local WORD_CHARACTER_RANGES = '0-9A-Za-z_\\u00aa-\\uffff'

-- translate the inside of [...]. vim collections don't understand shorthand
-- classes like \d and \s, so spell them out as ranges. return the translated
-- body & position after the closing ], or nil if it never closes. i also
-- start shit i can't finish (this file, basically).
local function translate_class_body(pattern_text, position)
    local pieces = {}
    -- keep the leading ^; a ] immediately after [ or [^ is literal. even a
    -- bracket gets special treatment. i should have asked.
    if pattern_text:sub(position, position) == '^' then
        pieces[#pieces + 1] = '^'
        position = position + 1
    end
    if pattern_text:sub(position, position) == ']' then
        pieces[#pieces + 1] = '\\]'
        position = position + 1
    end
    while position <= #pattern_text do
        local character = pattern_text:sub(position, position)
        if character == ']' then
            return table.concat(pieces), position + 1
        elseif character == '\\' then
            local escaped_character = pattern_text:sub(position + 1, position + 1)
            local class_escapes = {
                d = '0-9',
                s = ' \\t\\n\\r\\f\\v',
                w = WORD_CHARACTER_RANGES,
                t = '\\t',
                n = '\\n',
                r = '\\r',
                ['\\'] = '\\\\',
                [']'] = '\\]',
                ['['] = '[',
                ['-'] = '\\-',
                ['^'] = '\\^',
            }
            if class_escapes[escaped_character] then
                pieces[#pieces + 1] = class_escapes[escaped_character]
                position = position + 2
            elseif escaped_character == 'x' then
                -- \x{...}: any hex digit count becomes \u; plain \x takes
                -- two. damn paperwork.
                local hex_digits = pattern_text:match('^{(%x+)}', position + 2)
                if hex_digits then
                    pieces[#pieces + 1] = '\\u' .. hex_digits
                    position = position + 4 + #hex_digits
                else
                    pieces[#pieces + 1] = '\\x' .. pattern_text:sub(position + 2, position + 3)
                    position = position + 4
                end
            else
                -- other escapes lose the backslash. even punctuation gets to
                -- shed baggage.
                pieces[#pieces + 1] = escaped_character
                position = position + 2
            end
        elseif character == '[' and pattern_text:sub(position, position + 1) == '[:' then
            -- posix classes like [:alpha:] mean the same in vim, so pass them
            -- through. i've spent whole evenings achieving less agreement
            -- than this.
            local class_name_end = pattern_text:find(':]', position + 2, true)
            if class_name_end then
                pieces[#pieces + 1] = pattern_text:sub(position, class_name_end + 1)
                position = class_name_end + 2
            else
                pieces[#pieces + 1] = '['
                position = position + 1
            end
        else
            pieces[#pieces + 1] = character
            position = position + 1
        end
    end
    return nil, position
end

-- boost & vim spell these escapes the same. shared custody of shit.
local ESCAPES_VIM_SPELLS_THE_SAME = { t = true, e = true, f = true, d = true, D = true, s = true, S = true }

-- translate pcre (boost) into vim very magic. dot_matches_newline is the find
-- dialog's ". matches newline" checkbox. inline (?i) or (?-i) becomes vim's
-- \c or its capital counterpart, prepended to the whole pattern. local
-- decisions with global consequences. basically my financial planning.
function notepadpp_regex.pcre(pattern_text, dot_matches_newline)
    -- notepad++'s find box holds 2,046 characters. past 4096 bytes, pasted
    -- text is searched literally instead of translated. translation reads
    -- ahead at every [ and (?, so huge broken patterns get slow. nobody
    -- writes a 4,000 character regex on purpose (i want to believe we still
    -- fear death).
    if #pattern_text > 4096 then
        return notepadpp_regex.literal(pattern_text)
    end
    local pieces, position = {}, 1
    -- one closer per open paren, so ) knows which group ends. i envy the
    -- bastard.
    local group_closers = {}
    local case_flag = ''
    while position <= #pattern_text do
        local character = pattern_text:sub(position, position)
        if character == '\\' then
            local escaped_character = pattern_text:sub(position + 1, position + 1)
            position = position + 2
            if escaped_character == '' then
                -- a final lone backslash matches itself. at least something
                -- here has company.
                pieces[#pieces + 1] = '\\\\'
            elseif escaped_character == 'r' then
                -- \r alone or followed by \n matches one line end. windows
                -- needs two characters for that ending. i need a whole
                -- evening to achieve nothing.
                if pattern_text:sub(position, position + 1) == '\\n' then
                    position = position + 2
                end
                pieces[#pieces + 1] = '\\n'
            elseif escaped_character == 'n' or escaped_character == 'R' then
                -- boost's backslash capital r matches any line break; vim
                -- gets one line end. even endings require this much damn
                -- administration.
                pieces[#pieces + 1] = '\\n'
            elseif escaped_character == 'v' then
                -- vertical tab needs an explicit byte: \v means something
                -- else in very magic. same spelling, different damage.
                -- basically every promise i've made myself.
                pieces[#pieces + 1] = '%x0b'
            elseif escaped_character == 'a' then
                -- the bell character. i spent actual remaining lifetime
                -- supporting this.
                pieces[#pieces + 1] = '%x07'
            elseif escaped_character == 'h' then
                pieces[#pieces + 1] = '[ \\t]'
            elseif escaped_character == 'w' then
                pieces[#pieces + 1] = '[' .. WORD_CHARACTER_RANGES .. ']'
            elseif escaped_character == 'W' then
                pieces[#pieces + 1] = '[^' .. WORD_CHARACTER_RANGES .. ']'
            elseif escaped_character == 'b' then
                pieces[#pieces + 1] = '%(<|>)'
            elseif escaped_character == 'B' or escaped_character == 'G' then
                -- "not a word boundary" and "where the last match ended" have
                -- no vim equivalent. drop them, broadening matches. basically
                -- i lowered the standards until it worked. i'd call this
                -- growth if it hadn't already fucked up the rest of my life.
                pieces[#pieces + 1] = ''
            elseif escaped_character == '<' then
                pieces[#pieces + 1] = '<'
            elseif escaped_character == '>' then
                pieces[#pieces + 1] = '>'
            elseif escaped_character == 'A' or escaped_character == '`' then
                -- start of the whole buffer.
                pieces[#pieces + 1] = '%^'
            elseif escaped_character == 'z' or escaped_character == 'Z' or escaped_character == "'" then
                -- end of the whole buffer. i want my unfinished crap this
                -- neatly contained.
                pieces[#pieces + 1] = '%$'
            elseif escaped_character == 'K' then
                -- boost keep-out forgets the match so far; vim uses \zs. i'd
                -- pay for that.
                pieces[#pieces + 1] = '\\zs'
            elseif escaped_character == 'x' then
                local hex_digits = pattern_text:match('^{(%x+)}', position)
                if hex_digits then
                    pieces[#pieces + 1] = '%u' .. hex_digits
                    position = position + 2 + #hex_digits
                else
                    pieces[#pieces + 1] = '%x' .. pattern_text:sub(position, position + 1)
                    position = position + 2
                end
            elseif escaped_character == 'Q' then
                -- backslash capital q quotes literal text until backslash
                -- capital e or the end. use a very-nomagic group, switching
                -- back to very magic before closing. even this little escape
                -- from the bullshit has an expiry condition.
                local quote_end = pattern_text:find('\\E', position, true)
                local quoted_text = pattern_text:sub(position, (quote_end or #pattern_text + 1) - 1)
                pieces[#pieces + 1] = '%(' .. notepadpp_regex.literal(quoted_text) .. '\\v)'
                position = quote_end and quote_end + 2 or #pattern_text + 1
            elseif ESCAPES_VIM_SPELLS_THE_SAME[escaped_character] or escaped_character:match('%d') or not escaped_character:match('%w') then
                -- vim spells these the same, so keep the escape as typed:
                -- tab, escape & form feed, digit & whitespace classes and
                -- their capital negations, backreferences, and escaped
                -- punctuation. absolutely no translation needed. i want my
                -- remaining years back, but apparently preserving backslashes
                -- is what i do now.
                pieces[#pieces + 1] = '\\' .. escaped_character
            else
                -- an unknown letter escape becomes the letter. wasted effort,
                -- familiar.
                pieces[#pieces + 1] = escaped_character
            end
        elseif character == '[' then
            -- no ] anywhere after this [ means no class. avoid reading the
            -- rest of the pattern once per [. a pasted line of 10000 [ used
            -- to take seconds. basically i built a machine to waste what
            -- little life i have left.
            local class_contents, position_after_class
            if pattern_text:find(']', position + 1, true) then
                class_contents, position_after_class = translate_class_body(pattern_text, position + 1)
            end
            if class_contents then
                pieces[#pieces + 1] = '[' .. class_contents .. ']'
                position = position_after_class
            else
                -- an unclosed [ is literal. i too have abandoned structural
                -- ambitions.
                pieces[#pieces + 1] = '\\['
                position = position + 1
            end
        elseif character == '(' then
            -- (?: is non-capturing; (?= and (?! look ahead; (?<= and (?<!
            -- look behind. vim uses %( and closes with @= @! @<= @<!
            -- respectively for lookarounds. named groups, (?<name>, (?p<name>
            -- with capital p, or (?'name'), become plain numbered groups. the
            -- name goes. apparently being remembered costs extra even in this
            -- crap. inline flags change case for the whole pattern; any other
            -- (? becomes a non-capturing group. i want fewer surprises, which
            -- is a ridiculous thing to want from two regex engines.
            if pattern_text:sub(position + 1, position + 1) == '?' then
                local after_question_mark = pattern_text:sub(position + 2)
                if after_question_mark:sub(1, 1) == ':' then
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')'
                    position = position + 3
                elseif after_question_mark:sub(1, 1) == '=' then
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')@='
                    position = position + 3
                elseif after_question_mark:sub(1, 1) == '!' then
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')@!'
                    position = position + 3
                elseif after_question_mark:sub(1, 2) == '<=' then
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')@<='
                    position = position + 4
                elseif after_question_mark:sub(1, 2) == '<!' then
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')@<!'
                    position = position + 4
                elseif after_question_mark:match('^<%a') or after_question_mark:match('^P<') or after_question_mark:match("^'") then
                    local group_name_end = pattern_text:find("[>']", position + 3)
                    pieces[#pieces + 1] = '('
                    group_closers[#group_closers + 1] = ')'
                    position = (group_name_end or position + 2) + 1
                elseif after_question_mark:match('^[imsx-]+%)') then
                    local inline_flags = after_question_mark:match('^([imsx-]+)%)')
                    if inline_flags:match('^[^-]*i') then
                        case_flag = '\\c'
                    elseif inline_flags:match('%-.*i') then
                        case_flag = '\\C'
                    end
                    position = position + 3 + #inline_flags
                else
                    pieces[#pieces + 1] = '%('
                    group_closers[#group_closers + 1] = ')'
                    position = position + 2
                end
            else
                pieces[#pieces + 1] = '('
                group_closers[#group_closers + 1] = ')'
                position = position + 1
            end
        elseif character == ')' then
            -- a ) without an open group is literal. no opening, still a damn
            -- ending.
            pieces[#pieces + 1] = table.remove(group_closers) or '\\)'
            position = position + 1
        elseif character == '.' then
            pieces[#pieces + 1] = dot_matches_newline and '\\_.' or '.'
            position = position + 1
        elseif character == '{' then
            -- {n,m} counts mean the same in vim; lazy {n,m}? becomes {-n,m}.
            -- empty {} and {,}, or a brace that's no count, stay literal. i
            -- check these numbers more carefully than my pension.
            local quantifier = pattern_text:match('^{%d*,?%d*}', position)
            if quantifier and quantifier ~= '{}' and quantifier ~= '{,}' then
                local is_lazy = pattern_text:sub(position + #quantifier, position + #quantifier) == '?'
                if is_lazy then
                    pieces[#pieces + 1] = '{-' .. quantifier:sub(2)
                    position = position + #quantifier + 1
                else
                    pieces[#pieces + 1] = quantifier
                    position = position + #quantifier
                end
            else
                pieces[#pieces + 1] = '\\{'
                position = position + 1
            end
        elseif character == '*' or character == '+' or character == '?' then
            -- lazy *? +? ?? become vim's {-} {-1,} {-0,1}, taking the
            -- minimum. i want this policy applied to the years this shit
            -- takes off my life.
            local next_character = pattern_text:sub(position + 1, position + 1)
            if next_character == '?' then
                pieces[#pieces + 1] = ({ ['*'] = '{-}', ['+'] = '{-1,}', ['?'] = '{-0,1}' })[character]
                position = position + 2
            elseif next_character == '+' then
                -- possessive becomes greedy, vim's closest option. even the
                -- compromise takes.
                pieces[#pieces + 1] = character
                position = position + 2
            else
                pieces[#pieces + 1] = character
                position = position + 1
            end
        elseif
            character == '='
            or character == '@'
            or character == '%'
            or character == '<'
            or character == '>'
            or character == '~'
            or character == '&'
            or character == '/'
        then
            -- these are plain in boost, special in vim very magic; / ends a
            -- search command. escape them with a backslash. unpaid emotional
            -- support for syntax.
            pieces[#pieces + 1] = '\\' .. character
            position = position + 1
        else
            pieces[#pieces + 1] = character
            position = position + 1
        end
    end
    return case_flag .. '\\v' .. table.concat(pieces)
end

-- build one full vim search pattern. search_options comes from the find
-- dialog: mode ('normal', 'extended' or 'regex'), match_case, whole_word &
-- dot_nl. whole_word adds word boundaries and switches back to magic before
-- the group closes. match_case prepends \c or its capital counterpart.
-- basically a committee meeting to decide whether 'a' deserves contempt for
-- looking different. i could have gone outside.
function notepadpp_regex.build(text, search_options)
    local vim_pattern
    if search_options.mode == 'regex' then
        vim_pattern = notepadpp_regex.pcre(text, search_options.dot_nl)
    elseif search_options.mode == 'extended' then
        vim_pattern = notepadpp_regex.literal(notepadpp_regex.expand_extended(text))
    else
        vim_pattern = notepadpp_regex.literal(text)
    end
    if search_options.whole_word then
        vim_pattern = '\\<\\%(' .. vim_pattern .. '\\m\\)\\>'
    end
    return (search_options.match_case and '\\C' or '\\c') .. vim_pattern
end

-- replacement text for one match. get_submatch(number) returns that submatch.
-- regex mode supports $0 $& $1 ${12} \1 \n \r \t \\ $$ and boost's case
-- operators: \u and \l change the next character; their capital versions
-- change everything afterwards. backslash capital e stops the case mode.
-- extended mode only expands character escapes. normal returns text
-- untouched. i want to be returned untouched too, but i've spent my evening
-- teaching punctuation how to replace things. absolutely no refunds on that
-- time.
function notepadpp_regex.replacement(text, search_options, get_submatch)
    if search_options.mode == 'normal' then
        return text
    end
    if search_options.mode == 'extended' then
        return (notepadpp_regex.expand_extended(text):gsub('\r\n', '\n'):gsub('\r', '\n'))
    end
    local pieces = {}
    local case_mode, next_character_case = nil, nil
    -- emit one output piece after case conversion: pending \u or \l affects
    -- only its first character; running upper/lower case mode affects the
    -- rest. even letters get a chance to change. i keep writing this crap.
    local function emit(piece)
        if next_character_case and piece ~= '' then
            local first_character = vim.fn.strcharpart(piece, 0, 1)
            local remaining_characters = vim.fn.strcharpart(piece, 1)
            first_character = next_character_case == 'u' and vim.fn.toupper(first_character) or vim.fn.tolower(first_character)
            if case_mode == 'U' then
                remaining_characters = vim.fn.toupper(remaining_characters)
            elseif case_mode == 'L' then
                remaining_characters = vim.fn.tolower(remaining_characters)
            end
            piece = first_character .. remaining_characters
            next_character_case = nil
        elseif case_mode == 'U' then
            piece = vim.fn.toupper(piece)
        elseif case_mode == 'L' then
            piece = vim.fn.tolower(piece)
        end
        pieces[#pieces + 1] = piece
    end
    local position = 1
    while position <= #text do
        local character = text:sub(position, position)
        local next_character = text:sub(position + 1, position + 1)
        if character == '$' and next_character == '$' then
            emit('$')
            position = position + 2
        elseif character == '$' and (next_character == '&' or next_character == '0') then
            emit(get_submatch(0))
            position = position + 2
        elseif character == '$' and next_character:match('%d') then
            local group_number_digits = text:match('^%d+', position + 1)
            emit(get_submatch(tonumber(group_number_digits)))
            position = position + 1 + #group_number_digits
        elseif character == '$' and next_character == '{' then
            local group_number_digits = text:match('^{(%d+)}', position + 1)
            if group_number_digits then
                emit(get_submatch(tonumber(group_number_digits)))
                position = position + 3 + #group_number_digits
            else
                -- ${ without a group number emits just $ first. money without
                -- prospects.
                emit('$')
                position = position + 1
            end
        elseif character == '\\' and next_character:match('%d') then
            emit(get_submatch(tonumber(next_character)))
            position = position + 2
        elseif character == '\\' and next_character ~= '' then
            if next_character == 'n' then
                emit('\n')
            elseif next_character == 'r' then
                -- windows \r\n emits one line end, as does \r alone. two
                -- bytes, same grave.
                if text:sub(position + 2, position + 3) == '\\n' then
                    position = position + 2
                end
                emit('\n')
            elseif next_character == 't' then
                emit('\t')
            elseif next_character == 'u' or next_character == 'l' then
                next_character_case = next_character
            elseif next_character == 'U' or next_character == 'L' then
                case_mode = next_character
            elseif next_character == 'E' then
                case_mode = nil
            else
                emit(next_character)
            end
            position = position + 2
        else
            emit(character)
            position = position + 1
        end
    end
    return table.concat(pieces)
end

return notepadpp_regex
