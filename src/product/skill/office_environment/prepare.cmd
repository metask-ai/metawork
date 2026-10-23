@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "NODE_OPTIONS="
set "NODE_PATH="
if /i not "%PROCESSOR_ARCHITECTURE%"=="AMD64" exit /b 2
if "%LOCALAPPDATA%"=="" exit /b 2
call "%~dp0environment.cmd"
if "%~1"=="python" goto python
if "%~1"=="node" goto node
echo Usage: prepare.cmd python ^| node
exit /b 2
:python
set "KIND=python"
set "IDENTITY=%PYTHON_ID%"
set "URL=%PYTHON_URL%"
set "SHA=%PYTHON_SHA%"
goto prepare
:node
set "KIND=node"
set "IDENTITY=%NODE_ID%"
set "URL=%NODE_URL%"
set "SHA=%NODE_SHA%"
:prepare
set "BASE=%LOCALAPPDATA%\MetaWork\OfficeDependencies"
set "FINAL=%BASE%\%KIND%-%IDENTITY%"
if exist "%FINAL%" goto check
if not exist "%BASE%" mkdir "%BASE%"
if not exist "%BASE%" exit /b 1
set "ATTEMPT=0"
:stage
set /a ATTEMPT+=1 >nul
set "STAGE=%BASE%\.%KIND%-%RANDOM%-%RANDOM%-%RANDOM%.tmp"
mkdir "%STAGE%" >nul 2>&1
if not errorlevel 1 goto download
if %ATTEMPT% LSS 8 goto stage
echo Unable to create an independent Office preparation directory. 1>&2
exit /b 1
:download
curl.exe --fail --silent --show-error --location --proto =https --proto-redir =https --connect-timeout 30 --max-time 300 --output "%STAGE%\download.zip" "%URL%"
if errorlevel 1 goto failed
certutil.exe -hashfile "%STAGE%\download.zip" SHA256 | findstr.exe /i /x /c:"%SHA%" >nul
if errorlevel 1 goto failed
tar.exe -xf "%STAGE%\download.zip" -C "%STAGE%"
if errorlevel 1 goto failed
del "%STAGE%\download.zip"
if "%KIND%"=="python" goto install_python
"%STAGE%\%NODE_FOLDER%\node.exe" "%~dp0finish.cjs" "%STAGE%" "%FINAL%" "%~dp0."
if errorlevel 1 goto failed
goto completed
:install_python
"%STAGE%\tools\python.exe" -I -B "%~dp0finish.py" "%STAGE%" "%FINAL%" "%~dp0."
if errorlevel 1 goto failed
:completed
if exist "%STAGE%" rmdir /s /q "%STAGE%"
exit /b 0
:check
if "%KIND%"=="python" (
  "%FINAL%\tools\python.exe" -I -B "%~dp0finish.py" --check "%FINAL%"
) else (
  "%FINAL%\%NODE_FOLDER%\node.exe" "%~dp0finish.cjs" --check "%FINAL%"
)
exit /b %errorlevel%
:failed
echo Office dependency preparation failed. No completed environment was replaced. 1>&2
rem Only this invocation's unpublished directory is owned for cleanup.
if exist "%STAGE%" rmdir /s /q "%STAGE%"
exit /b 1
