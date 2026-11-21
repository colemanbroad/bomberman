@echo off
rem Builds dist\bomberman.exe on Windows. See README.md for the one-time setup.
setlocal
cd /d "%~dp0.."
where goose >nul 2>nul || (echo goose.exe is not on PATH. Unpack goose-v2026.3-windows-x64.zip and add its folder to PATH. & exit /b 1)
where cmake >nul 2>nul || (echo cmake is not on PATH. Run this from "x64 Native Tools Command Prompt for VS", or install CMake. & exit /b 1)
if "%OPENSSL_ROOT_DIR%"=="" if not "%VCPKG_ROOT%"=="" set "OPENSSL_ROOT_DIR=%VCPKG_ROOT%\installed\x64-windows"
if "%OPENSSL_ROOT_DIR%"=="" (echo Set OPENSSL_ROOT_DIR to your OpenSSL folder, for example %%VCPKG_ROOT%%\installed\x64-windows. & exit /b 1)
if not exist dist mkdir dist
goose build bomberman.goose -o dist\bomberman.exe || exit /b 1
copy /y "%OPENSSL_ROOT_DIR%\bin\*.dll" dist >nul
echo Built dist\bomberman.exe
