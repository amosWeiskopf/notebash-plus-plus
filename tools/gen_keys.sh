#!/usr/bin/env bash
# rebuilds keys.md from lua/notebashpp/keybindings.lua in a throwaway config
# directory, so nobody's real settings leak into the documentation. i boot a
# whole editor to write one list. basically i'd rather automate this shit than
# type a table by hand. apparently my remaining life is worth less.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
temporary_config_directory="$(mktemp -d)"
ln -s "$PROJECT_ROOT" "$temporary_config_directory/notebashpp-gen"
cd "$PROJECT_ROOT"
NVIM_APPNAME=notebashpp-gen XDG_CONFIG_HOME="$temporary_config_directory" XDG_DATA_HOME="$temporary_config_directory/data" NOTEBASHPP_TEST=1 NOTEBASHPP_NO_SESSION=1 \
    nvim --headless -c "luafile $PROJECT_ROOT/tools/gen_keys.lua" -c 'qa!' 2>&1
rm -rf "$temporary_config_directory"
