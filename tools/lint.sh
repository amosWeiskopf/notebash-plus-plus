#!/usr/bin/env bash
# every static check in one go. ci runs this too, so clean here means clean
# there (i want my failures reproducible. life has been generous enough).
# needs these on the path: lua-language-server, selene, stylua, the shell
# checker, shfmt, actionlint, typos, codespell, markdownlint-cli2, yamllint,
# ruff, mypy and nvim.
set -u
cd "$(dirname "$0")/.." || exit 1

failed=()
check() {
    local name=$1
    shift
    printf '== %s\n' "${name}"
    if ! "$@"; then
        failed+=("${name}")
    fi
}

shell_files=(bin/notebash++ windows/install.sh tools/gen_keys.sh tools/lint.sh)
lua_paths=(lua tests tools init.lua user.example.lua)

# lua-language-server checks types against neovim's own api definitions. write
# the config fresh each time; it points at this machine's runtime. even this
# crap needs to know where it lives. i'm still working on that.
lua_types() {
    local runtime work
    runtime="$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q 2>&1)"
    work="$(mktemp -d)"
    cat >"${work}/luarc.json" <<JSON
{
  "runtime.version": "LuaJIT",
  "runtime.path": ["lua/?.lua", "lua/?/init.lua"],
  "workspace.library": ["${runtime}/lua", "\${3rd}/luv/library"],
  "workspace.checkThirdParty": false,
  "diagnostics.globals": ["vim"]
}
JSON
    lua-language-server --check . --checklevel=Hint --configpath="${work}/luarc.json" \
        --check_format=json --check_out_path="${work}/report.json" >/dev/null 2>&1
    python3 - "${work}/report.json" <<'PY'
import json, sys
try:
    report = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    report = {}
if isinstance(report, list):
    report = {}
count = 0
for path, diagnostics in sorted(report.items()):
    for diagnostic in diagnostics:
        count += 1
        line = diagnostic['range']['start']['line'] + 1
        print(f"{path.split('/')[-1]}:{line}: {diagnostic.get('code')}: {diagnostic['message'].splitlines()[0]}")
print(f'{count} problems')
sys.exit(1 if count else 0)
PY
}

check 'lua types (lua-language-server)' lua_types
check 'lua lint (selene)' selene --display-style quiet "${lua_paths[@]}"
check 'lua format (stylua)' stylua --check "${lua_paths[@]}"
check 'shell lint (shellcheck)' shellcheck -x "${shell_files[@]}"
check 'shell format (shfmt)' shfmt -i 4 -ci -d "${shell_files[@]}"
check 'workflows (actionlint)' actionlint
check 'yaml (yamllint)' yamllint --strict .github CITATION.cff .yamllint.yml
check 'markdown (markdownlint)' markdownlint-cli2 '*.md'
check 'spelling (typos)' typos
check 'spelling (codespell)' codespell
check 'python lint (ruff)' ruff check tools
check 'python format (ruff)' ruff format --check tools
check 'python types (mypy)' mypy tools/check_comments.py
mapfile -t commented_files < <(git ls-files '*.lua' '*.sh' '*.yml' '*.cmd')
check 'comment style' python3 tools/check_comments.py "${commented_files[@]}" bin/notebash++ tools/lint.sh

if ((${#failed[@]})); then
    printf '\nfailed: %s\n' "${failed[*]}"
    exit 1
fi
printf '\nall checks passed\n'
