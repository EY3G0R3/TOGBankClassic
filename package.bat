@echo off
setlocal enabledelayedexpansion

:: Extract version from .toc file
for /f "tokens=3" %%v in ('findstr /C:"## Version:" TOGBankClassic.toc') do set VERSION=%%v

set DISTDIR=dist
set ZIPNAME=%DISTDIR%\TOGBankClassic.%VERSION%.zip
set BUILDDIR=%TEMP%\TOGBankClassic-build

:: Ensure dist folder exists
if not exist "%DISTDIR%" mkdir "%DISTDIR%"
set ADDONDIR=%BUILDDIR%\TOGBankClassic

:: Clean up any previous build
if exist "%ZIPNAME%" del "%ZIPNAME%"
if exist "%BUILDDIR%" rmdir /s /q "%BUILDDIR%"

:: Create temp structure
mkdir "%ADDONDIR%"
mkdir "%ADDONDIR%\Modules\UI"
mkdir "%ADDONDIR%\Libs"

:: Copy addon files (exclude temp files and build artifacts)
copy TOGBankClassic.toc "%ADDONDIR%\" >nul
copy Core.lua "%ADDONDIR%\" >nul
copy embeds.xml "%ADDONDIR%\" >nul
copy LICENSE "%ADDONDIR%\" >nul
copy CHANGELOG.md "%ADDONDIR%\" >nul
robocopy Modules "%ADDONDIR%\Modules" /E /XF tmpclaude-* /NFL /NDL /NJH /NJS /NC /NS /NP >nul
robocopy Libs "%ADDONDIR%\Libs" /E /XF tmpclaude-* /NFL /NDL /NJH /NJS /NC /NS /NP >nul

:: Create zip using PowerShell
powershell -Command "Compress-Archive -Path '%ADDONDIR%' -DestinationPath '%ZIPNAME%'"

:: Cleanup
rmdir /s /q "%BUILDDIR%"

echo Created: %ZIPNAME%
