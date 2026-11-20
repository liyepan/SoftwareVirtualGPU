@echo off
setlocal
set "ROOT=%~dp0.."
set "CFG=%~1"
if "%CFG%"=="" set "CFG=Debug"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo [build] vswhere not found. Install Visual Studio 2026 with Desktop C++.
  exit /b 1
)

set "VSPATH="
for /f "delims=" %%i in ('"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath') do set "VSPATH=%%i"
if not defined VSPATH (
  echo [build] Visual Studio with C++ toolset not found.
  exit /b 1
)

call "%VSPATH%\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 >nul
if errorlevel 1 (
  echo [build] VsDevCmd failed.
  exit /b 1
)

if not exist "%ROOT%\driver\svgpu.sln" (
  echo [build] driver\svgpu.sln not found - driver project not created yet.
  exit /b 2
)

msbuild "%ROOT%\driver\svgpu.sln" /m /p:Configuration=%CFG% /p:Platform=x64 /v:m
if errorlevel 1 exit /b 1
echo [build] ok: %CFG%
exit /b 0
