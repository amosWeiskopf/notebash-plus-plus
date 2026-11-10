#!/usr/bin/env bash
# puts notebash++ on the windows side. notebash++ stays in wsl with neovim;
# windows gets neovide (the window), copied to
# %localappdata%\programs\notebash++, plus start menu & desktop shortcuts.
# each shortcut starts neovide, which runs wsl.exe, which runs bin/notebash++
# --embed in this distro. three programs across two operating systems to edit
# a text file. i want my remaining years back, please. basically we built a
# machine to waste a life, then gave it shortcuts. at least you can write
# something worth keeping. (no pressure.) run it from wsl: notebash++
# -install

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WINDOWS_USER_NAME="${NOTEBASHPP_WINUSER:-$(cd /mnt/c && cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')}"
INSTALL_DIRECTORY="/mnt/c/Users/$WINDOWS_USER_NAME/AppData/Local/Programs/Notebash++"
WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}"
NEOVIDE_VERSION="0.17.2"
# github's sha-256 for neovide-windows-x86_64.zip 0.17.2. discard any download
# that doesn't match. i want a little more evidence before putting a
# stranger's exe on your desktop. a server's word is worth about as much as my
# retirement plan.
NEOVIDE_ZIP_SHA256="53fbc5bbcd41adb73badab7ae42103846a1358ef1cfa98dce8b98fae63aa4c68"

# download neovide once. if it is already there, leave it alone. i wish i'd
# applied this much restraint to the rest of my damn life.
mkdir -p "$INSTALL_DIRECTORY"
if [ ! -f "$INSTALL_DIRECTORY/neovide.exe" ]; then
    download_directory="$(mktemp -d)"
    echo "Downloading Neovide $NEOVIDE_VERSION..."
    curl -fsSL -o "$download_directory/neovide.zip" "https://github.com/neovide/neovide/releases/download/$NEOVIDE_VERSION/neovide-windows-x86_64.zip"
    if ! echo "$NEOVIDE_ZIP_SHA256  $download_directory/neovide.zip" | sha256sum -c --status; then
        rm -rf "$download_directory"
        echo "The Neovide download does not match its published checksum; nothing was installed." >&2
        exit 1
    fi
    unzip -q -o "$download_directory/neovide.zip" -d "$download_directory"
    cp "$download_directory/neovide.exe" "$INSTALL_DIRECTORY/neovide.exe"
    rm -rf "$download_directory"
fi

install_directory_windows_path="$(wslpath -w "$INSTALL_DIRECTORY")"
# --exec, not --: after a bare -- wsl.exe runs the rest through bash -c, and a
# windows file name dropped on the shortcut could be $(anything).
shortcut_arguments="--neovim-bin wsl.exe -- -d \"$WSL_DISTRO\" --exec \"$PROJECT_ROOT/bin/notebash++\""

# values reach powershell as environment variables via wslenv to windows,
# never as script text. powershell treats ' and curly ’ ‘ as quotes, so a
# folder named o’brien'; calc # could otherwise write its own script.
# basically a folder gets to execute its ambitions. mine can go to hell.
export NOTEBASHPP_SHORTCUT_TARGET="$install_directory_windows_path\neovide.exe"
export NOTEBASHPP_SHORTCUT_ARGUMENTS="$shortcut_arguments"
export NOTEBASHPP_SHORTCUT_FOLDER="$install_directory_windows_path"
export WSLENV="${WSLENV:+$WSLENV:}NOTEBASHPP_SHORTCUT_TARGET:NOTEBASHPP_SHORTCUT_ARGUMENTS:NOTEBASHPP_SHORTCUT_FOLDER"

# powershell writes the .lnk files; only windows knows its shortcut crap. run
# it from /mnt/c. windows programs get upset when started in a linux folder
# they cannot see. absolutely relatable. i too need everything wrong with my
# life kept outside my field of vision.
cd /mnt/c
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
\$windows_shell = New-Object -ComObject WScript.Shell
\$shortcut_folders = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))
foreach (\$shortcut_folder in \$shortcut_folders) {
    \$shortcut = \$windows_shell.CreateShortcut((Join-Path \$shortcut_folder 'Notebash++.lnk'))
    \$shortcut.TargetPath = \$env:NOTEBASHPP_SHORTCUT_TARGET
    \$shortcut.Arguments = \$env:NOTEBASHPP_SHORTCUT_ARGUMENTS
    \$shortcut.WorkingDirectory = \$env:NOTEBASHPP_SHORTCUT_FOLDER
    \$shortcut.IconLocation = \$env:NOTEBASHPP_SHORTCUT_TARGET + ',0'
    \$shortcut.Description = 'Notebash++: Neovim with the Notepad++ keyboard'
    \$shortcut.Save()
    Write-Output (Join-Path \$shortcut_folder 'Notebash++.lnk')
}
"
echo "Done. Start Notebash++ from the Start menu or the desktop, or run: notebash++ -gui"
