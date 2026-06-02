@echo off
setlocal

REM Get the folder this .bat file is in
set "SOURCE_DIR=%~dp0"
set "SOURCE_DIR=%SOURCE_DIR:~0,-1%"

REM Get the folder name
for %%A in ("%SOURCE_DIR%") do set "FOLDER_NAME=%%~nxA"

REM Output zip path
set "ZIP_FILE=%SOURCE_DIR%\%FOLDER_NAME%.zip"

REM Find 7-Zip
set "SEVENZIP=%ProgramFiles%\7-Zip\7z.exe"

if not exist "%SEVENZIP%" (
    set "SEVENZIP=%ProgramFiles(x86)%\7-Zip\7z.exe"
)

if not exist "%SEVENZIP%" (
    echo 7-Zip was not found.
    echo Please install 7-Zip or update the path in this script.
    exit /b 1
)

REM Delete existing zip if it exists
if exist "%ZIP_FILE%" del "%ZIP_FILE%"

REM Zip everything in this folder except:
REM - this .bat file
REM - files/folders starting with .
REM - the output zip itself
pushd "%SOURCE_DIR%"

"%SEVENZIP%" a -tzip "%ZIP_FILE%" "*" ^
    -xr!".*" ^
    -xr!"%~nx0" ^
    -xr!"%FOLDER_NAME%.zip"

popd
exit /b 0