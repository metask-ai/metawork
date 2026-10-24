@echo off
setlocal EnableExtensions DisableDelayedExpansion
if "%LOCALAPPDATA%"=="" exit /b 2
call "%~dp0environment.cmd"
if errorlevel 1 exit /b 2
set "BASE=%LOCALAPPDATA%\%OFFICE_NAMESPACE:/=\%"
set "NODE_OPTIONS="
set "NODE_PATH="
if "%~1"=="python" goto python
if "%~1"=="node" goto node
echo Usage: run.cmd python ^| node script [arguments]
exit /b 2
:python
set "METAWORK_OFFICE_ENV=%BASE%\python-%PYTHON_ID%"
if not exist "%METAWORK_OFFICE_ENV%\tools\python.exe" goto missing
"%METAWORK_OFFICE_ENV%\tools\python.exe" -I -B "%~dp0run.py" %*
exit /b %errorlevel%
:node
set "METAWORK_OFFICE_ENV=%BASE%\node-%NODE_ID%"
if not exist "%METAWORK_OFFICE_ENV%\%NODE_FOLDER%\node.exe" goto missing
"%METAWORK_OFFICE_ENV%\%NODE_FOLDER%\node.exe" "%~dp0run.cjs" %*
exit /b %errorlevel%
:missing
echo Office environment missing. Ask the user before running prepare.cmd %~1. 1>&2
exit /b 3
