@echo off
setlocal EnableDelayedExpansion
title HP Pro Tablet 408 G1 - Windows 10 32-bit driver injection

:: =====================================================================
::  Injects HP Pro Tablet 408 G1 drivers into a Windows 10 USB made
::  with Rufus, so touch / Wi-Fi / audio work right after installation.
::
::  BEFORE RUNNING:
::   1. Extract every HP SoftPaq (sp73491.exe, Wi-Fi, Bluetooth, audio,
::      sensors...) with 7-Zip into its own subfolder of C:\HP408Drivers
::      e.g. C:\HP408Drivers\sp73491\...
::   2. Plug in the Rufus Windows 10 USB.
::   3. Right-click this file > Run as administrator.
:: =====================================================================

net session >nul 2>&1
if errorlevel 1 (
    echo Please right-click this file and choose "Run as administrator".
    pause
    exit /b 1
)

set "DRV=C:\HP408Drivers"
set "MNT=C:\WimMount"

if not exist "%DRV%\" (
    echo Driver folder %DRV% not found. Extract the HP drivers there first.
    pause
    exit /b 1
)

echo.
set /p "USB=Enter the drive letter of the Rufus USB (example: E): "
set "USB=%USB::=%:"
set "SRCDIR=%USB%\sources"

if exist "%SRCDIR%\install.swm" (
    echo This USB has a split install image ^(install.swm^) - not supported by this script.
    pause
    exit /b 1
)

if exist "%SRCDIR%\install.wim" (
    set "IMG=%SRCDIR%\install.wim"
    set "TYPE=wim"
) else if exist "%SRCDIR%\install.esd" (
    set "IMG=%SRCDIR%\install.esd"
    set "TYPE=esd"
) else (
    echo No install.wim or install.esd found in %SRCDIR%
    pause
    exit /b 1
)

echo.
echo ===== Windows editions in this image =====
dism /Get-WimInfo /WimFile:"%IMG%"
echo.
set /p "IDX=Type the Index number of the edition you will install (e.g. Windows 10 Pro): "

:: ---- ESD is read-only: convert the chosen edition to WIM -------------
if "%TYPE%"=="esd" (
    echo.
    echo Converting install.esd to install.wim ^(this takes a while^)...
    dism /Export-Image /SourceImageFile:"%IMG%" /SourceIndex:%IDX% /DestinationImageFile:"%SRCDIR%\install.wim" /Compress:max /CheckIntegrity
    if errorlevel 1 goto :fail
    del /f /q "%IMG%"
    set "IMG=%SRCDIR%\install.wim"
    set "IDX=1"
)

dism /Cleanup-Mountpoints >nul 2>&1
if exist "%MNT%" rd /s /q "%MNT%"
mkdir "%MNT%"

:: ---- 1) Windows itself (drivers present after installation) --------
echo.
echo [1/2] Adding drivers to the Windows image...
dism /Mount-Image /ImageFile:"%IMG%" /Index:%IDX% /MountDir:"%MNT%"
if errorlevel 1 goto :fail
dism /Image:"%MNT%" /Add-Driver /Driver:"%DRV%" /Recurse
if errorlevel 1 echo WARNING: some drivers were skipped - continuing.
dism /Unmount-Image /MountDir:"%MNT%" /Commit
if errorlevel 1 goto :fail

:: ---- 2) Windows Setup environment (touch works during setup) -------
echo.
echo [2/2] Adding drivers to Windows Setup ^(boot.wim^)...
dism /Mount-Image /ImageFile:"%SRCDIR%\boot.wim" /Index:2 /MountDir:"%MNT%"
if errorlevel 1 goto :fail
dism /Image:"%MNT%" /Add-Driver /Driver:"%DRV%" /Recurse
if errorlevel 1 echo WARNING: some drivers were skipped - continuing.
dism /Unmount-Image /MountDir:"%MNT%" /Commit
if errorlevel 1 goto :fail

rd /s /q "%MNT%" 2>nul
echo.
echo =====================================================
echo  DONE. Boot the tablet from this USB and install.
echo  Touch, Wi-Fi and audio drivers are now built in.
echo =====================================================
pause
exit /b 0

:fail
echo.
echo *** Something failed. Cleaning up without saving changes... ***
dism /Unmount-Image /MountDir:"%MNT%" /Discard >nul 2>&1
dism /Cleanup-Mountpoints >nul 2>&1
pause
exit /b 1
