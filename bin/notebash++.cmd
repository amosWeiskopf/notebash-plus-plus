@echo off
rem the notebash++ launcher for windows. native neovim, no wsl. clone the
rem repository into %localappdata%\notebashpp; neovim reads its config there.
rem i want one place to keep this crap (the rest of my life has absolutely no
rem such arrangement). starts neovide if installed, otherwise neovim in this
rem console window. basically i spent part of my finite life making one editor
rem impersonate another. death will have to wait until i finish configuring
rem it. please enjoy whatever this is. setlocal keeps nvim_appname out of the
rem console you started from. i'd love to leave something behind, preferably
rem not environment variables. nodefaultcurrentdirectoryinexepath stops
rem windows from looking for neovide.exe or nvim.exe in the current folder
rem first, where a cloned repo could have left its own. the program search
rem uses %path% only. no parentheses around %*: inside them cmd reads your
rem file names a second time as commands, and a name with ^& in it becomes two
rem commands. apparently opening a file is too small a disaster.
setlocal
set NVIM_APPNAME=notebashpp
set NoDefaultCurrentDirectoryInExePath=1
rem notebash++ needs neovim 0.11 or newer. read the first line of nvim
rem --version from the nvim.exe on %path%. when nvim is missing or older,
rem offer to install it with winget (default no), else print the download
rem link. after winget, a new console window sees the updated %path%. quotes
rem are removed from the answer so it cannot end the comparison early.
set NVIM_VERSION_LINE=
set NVIM_MAJOR=0
set NVIM_MINOR=0
for /f "delims=" %%v in ('nvim.exe --version 2^>nul') do if not defined NVIM_VERSION_LINE set "NVIM_VERSION_LINE=%%v"
if not defined NVIM_VERSION_LINE goto neovim_missing
set "NVIM_VERSION_NUMBER=%NVIM_VERSION_LINE:NVIM v=%"
for /f "tokens=1,2 delims=.-" %%a in ("%NVIM_VERSION_NUMBER%") do set "NVIM_MAJOR=%%a" & set "NVIM_MINOR=%%b"
if %NVIM_MAJOR% GEQ 1 goto neovim_ready
if %NVIM_MINOR% GEQ 11 goto neovim_ready
echo Notebash++ needs Neovim 0.11 or newer; this nvim is %NVIM_VERSION_LINE%.
goto neovim_offer
:neovim_missing
echo Notebash++ needs Neovim 0.11 or newer, and there is no nvim.exe on PATH.
:neovim_offer
where $PATH:winget.exe >nul 2>nul
if errorlevel 1 goto neovim_download_link
set "INSTALL_ANSWER=n"
set /p "INSTALL_ANSWER=Install Neovim with winget (winget install --id Neovim.Neovim -e)? [y/N] "
set "INSTALL_ANSWER=%INSTALL_ANSWER:"=%"
if /i "%INSTALL_ANSWER%"=="y" goto neovim_winget
if /i "%INSTALL_ANSWER%"=="yes" goto neovim_winget
:neovim_download_link
echo Download Neovim 0.11 or newer: https://github.com/neovim/neovim/releases/latest
exit /b 1
:neovim_winget
winget install --id Neovim.Neovim -e
if errorlevel 1 exit /b 1
echo Neovim is installed. Open a new console window and start Notebash++ again.
exit /b 0
:neovim_ready
set NEOVIDE_PROGRAM=
for /f "delims=" %%p in ('where $PATH:neovide.exe 2^>nul') do if not defined NEOVIDE_PROGRAM set "NEOVIDE_PROGRAM=%%p"
if not defined NEOVIDE_PROGRAM goto console
start "" "%NEOVIDE_PROGRAM%" -- -- %*
goto :eof
:console
nvim -- %*
