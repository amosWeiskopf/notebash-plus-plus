#!/usr/bin/env python3
"""reports comment lines that break the house style: any uppercase letter,
an en or em dash, an arrow glyph, or a two-character ascii arrow inside a
comment. usage: check_comments.py file... (lua, sh, cmd, yml).
a whole program whose only job is to find capital letters and be
disappointed by them. we all know somebody like that. some of us are that somebody."""

import re
import sys

BANNED = re.compile(r'[A-Z\u2013\u2014\u2190-\u21ff]|->|<-')


def lua_comment(line: str) -> str | None:
    # find '--' outside string literals ('...', "...", [[...]] on one line). a
    # dash pair inside a string can die in peace. the rest of us get linted.
    i, quote = 0, None
    while i < len(line):
        c = line[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if line.startswith(quote, i):
                i += len(quote)
                quote = None
                continue
        else:
            if line.startswith('--', i):
                return line[i + 2 :]
            if line.startswith('[[', i):
                quote = ']]'
                i += 2
                continue
            if c in '\'"':
                quote = c
        i += 1
    return None


def hash_comment(line: str) -> str | None:
    stripped = line.lstrip()
    if stripped.startswith('#!'):
        return None
    m = re.search(r'(^|\s)#(?![{(])(.*)$', line)
    if m and not re.search(r'["\']', line[: m.start()]):
        return m.group(2)
    if stripped.startswith('#'):
        return stripped[1:]
    return None


def cmd_comment(line: str) -> str | None:
    m = re.match(r'\s*(rem|::)(.*)$', line, re.I)
    return m.group(2) if m else None


def comment_text(path: str, line: str) -> str | None:
    if path.endswith('.lua'):
        return lua_comment(line)
    if path.endswith('.cmd'):
        return cmd_comment(line)
    return hash_comment(line)


def main(paths: list[str]) -> int:
    bad = 0
    for path in paths:
        with open(path, encoding='utf-8', errors='replace') as source:
            for number, raw_line in enumerate(source, 1):
                line = raw_line.rstrip('\r\n')
                text = comment_text(path, line)
                if text is not None and BANNED.search(text):
                    bad += 1
                    print(f'{path}:{number}: {line.strip()[:110]}')
    print(f'{bad} comment lines break the style', file=sys.stderr)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
