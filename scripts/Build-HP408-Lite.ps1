<#
=====================================================================
 HP Pro Tablet 408 G1 - Custom Lite Windows 10 Home x86 ISO builder
=====================================================================
 Folder layout expected (create it before running):

   C:\HP408Build\
      Windows.iso            <- your Windows 10 x86 ISO (from Drive)
      SoftPaqs\              <- all HP spXXXXX.exe files (from Drive)
      Apps\                  <- installers, renamed EXACTLY like this:
          winrar.exe         (WinRAR 32-bit)
          chrome.msi         (Chrome Enterprise 32-bit MSI)
          libreoffice.msi    (LibreOffice x86 MSI)
          sumatrapdf.exe     (SumatraPDF 32-bit installer)
      Updates\               <- OPTIONAL: x86 .msu/.cab updates from the
                                Microsoft Update Catalog (Servicing Stack
                                Update first, then latest Cumulative Update
                                for "Windows 10 Version 22H2 for x86")

 Needs: Windows ADK "Deployment Tools" (for oscdimg.exe), ~25 GB free.
 Run:   Run-Build.cmd (as Administrator)
=====================================================================
#>

param(
  [string]$SourceIso = '',              # path to your existing Windows 10 ISO (any name/location)
  [string]$Work      = 'C:\HP408Build', # build folder (SoftPaqs, Apps, Updates live here)
  [string]$Edition   = 'Windows 10 Home',
  [string]$Branding  = ''               # folder with AFIF-TECH images (default: ..\branding next to this script)
)

# Continue by default: command-line tools that print warnings must not abort the build.
# The critical steps below use -ErrorAction Stop or explicit exit-code checks.
$ErrorActionPreference = 'Continue'

# ---------------- Settings ----------------

# Use the given ISO; else C:\HP408Build\Windows.iso; else let the user pick one
if (-not $SourceIso) { $SourceIso = Join-Path $Work 'Windows.iso' }
if (-not (Test-Path $SourceIso)) {
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title  = 'Select your existing Windows 10 ISO'
  $dlg.Filter = 'ISO files (*.iso)|*.iso'
  if ($dlg.ShowDialog() -ne 'OK') { throw 'No ISO selected.' }
  $SourceIso = $dlg.FileName
}
$SourceIso = (Resolve-Path $SourceIso).Path
Write-Host "Source ISO: $SourceIso" -ForegroundColor Green
$SoftPaqs  = Join-Path $Work 'SoftPaqs'
$AppsSrc   = Join-Path $Work 'Apps'
$UpdSrc    = Join-Path $Work 'Updates'
$IsoDir    = Join-Path $Work 'ISO'
$DrvDir    = Join-Path $Work 'Drivers'
$Mount     = Join-Path $Work 'Mount'
$PEExtra   = Join-Path $Work 'PEExtra'
$OutIso    = Join-Path $Work 'AFIF-TECH_Win10_HP408_x86.iso'
if ($SourceIso -ieq $OutIso) { $OutIso = Join-Path $Work 'AFIF-TECH_Win10_HP408_x86_v2.iso' }  # never overwrite the source
if (-not $Branding) { $Branding = Join-Path (Split-Path $PSScriptRoot -Parent) 'branding' }
$HasBrand  = Test-Path (Join-Path $Branding 'wallpaper.jpg')
$global:AddedInfs = New-Object System.Collections.Generic.HashSet[string]

# Apps that stay (everything else provisioned is removed)
$KeepApps = @(
  'Microsoft.WindowsStore','Microsoft.StorePurchaseApp','Microsoft.DesktopAppInstaller',
  'Microsoft.WindowsCalculator','Microsoft.Windows.Photos','Microsoft.ScreenSketch',
  'Microsoft.SecHealthUI','Microsoft.WindowsNotepad',
  'Microsoft.VCLibs*','Microsoft.UI.Xaml*','Microsoft.NET.*','*Extension*'
)

# Optional Windows capabilities to strip
$RemoveCaps = @(
  'App.StepsRecorder*','App.Support.QuickAssist*','Browser.InternetExplorer*',
  'Hello.Face*','MathRecognizer*','Media.WindowsMediaPlayer*','OneCoreUAP.OneSync*',
  'Microsoft.Windows.WordPad*','Print.Fax.Scan*'
)

# Add drivers one .inf at a time: skips HP installer metadata (HPSetup.inf etc.)
# and keeps going if a single package is rejected.
function Add-Drivers($ImagePath) {
  $ok = 0; $skip = 0
  Get-ChildItem $DrvDir -Recurse -Filter *.inf | ForEach-Object {
    $head = Get-Content $_.FullName -TotalCount 60 -ErrorAction SilentlyContinue | Out-String
    if ($_.Name -match '^(HPSetup|autorun|setup)\.inf$' -or $head -notmatch '(?i)ClassGuid') { $skip++; return }
    try   { Add-WindowsDriver -Path $ImagePath -Driver $_.FullName -ErrorAction Stop | Out-Null; $ok++; [void]$global:AddedInfs.Add($_.Name.ToLower()) }
    catch { Write-Host "    skipped $($_.Exception.Message.Split([char]10)[0])"; $skip++ }
  }
  Write-Host "  Drivers added: $ok, skipped: $skip"
  if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=Drivers::$ImagePath - added $ok, skipped $skip" }
  if ($ok -eq 0) { throw 'No drivers could be added' }
}

function Note($title, $msg) {
  Write-Host "  $title : $msg"
  if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=$title::$msg" }
}

# Take ownership of a file inside a mounted image so it can be replaced
function Grant-Own($p) {
  if (Test-Path $p) {
    cmd /c "takeown /f `"$p`" /a >nul 2>&1"
    cmd /c "icacls `"$p`" /grant *S-1-5-32-544:F >nul 2>&1"
  }
}

# Save $src scaled to fill $w x $h (centre-cropped) as $dst, in the format of $dst's extension
Add-Type -AssemblyName System.Drawing
function Save-Fill($src, $dst, $w, $h) {
  $img = [System.Drawing.Image]::FromFile($src)
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $sc  = [math]::Max($w / $img.Width, $h / $img.Height)
  $nw  = $img.Width * $sc; $nh = $img.Height * $sc
  $g.DrawImage($img, [single](($w - $nw) / 2), [single](($h - $nh) / 2), [single]$nw, [single]$nh)
  $fmt = switch ([IO.Path]::GetExtension($dst).ToLower()) {
    '.bmp' { [System.Drawing.Imaging.ImageFormat]::Bmp }
    '.png' { [System.Drawing.Imaging.ImageFormat]::Png }
    default { [System.Drawing.Imaging.ImageFormat]::Jpeg }
  }
  $tmp = "$dst.afif"
  $bmp.Save($tmp, $fmt); $g.Dispose(); $bmp.Dispose(); $img.Dispose()
  Grant-Own $dst
  Copy-Item $tmp $dst -Force; Remove-Item $tmp -Force
}

# Replace an existing image file, keeping its original size and format
function Replace-Image($src, $dst) {
  if (-not (Test-Path $dst)) { return $false }
  try {
    $i = [System.Drawing.Image]::FromFile($dst); $w = $i.Width; $h = $i.Height; $i.Dispose()
    Save-Fill $src $dst $w $h; return $true
  } catch { Write-Host "    could not replace $dst - $($_.Exception.Message)"; return $false }
}

function Step($t) {
  Write-Host "`n==== $t ====" -ForegroundColor Cyan
  if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=Build stage::$t" }   # visible progress in GitHub
}

# ---------------- Checks ----------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  throw 'Run as Administrator (use Run-Build.cmd).'
}
if (-not (Test-Path $SourceIso)) { throw "Missing $SourceIso" }
if (-not (Test-Path $SoftPaqs))  { throw "Missing $SoftPaqs" }

$oscdimg = @(
  "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
  (Join-Path $Work 'oscdimg.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $oscdimg) {
  $oscdimg = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\amd64\\' } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $oscdimg) { throw 'oscdimg.exe not found. Install Windows ADK > Deployment Tools, or put oscdimg.exe in C:\HP408Build.' }

foreach ($d in $IsoDir,$DrvDir,$Mount,$PEExtra) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } ; New-Item $d -ItemType Directory | Out-Null }
& dism.exe /Cleanup-Mountpoints | Out-Null

# ---------------- 1. Copy ISO contents ----------------
Step '1/8 Copying ISO contents'
$img = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
$dl  = ($img | Get-Volume -ErrorAction Stop).DriveLetter
if (-not $dl) { throw 'Could not get a drive letter for the mounted ISO' }
robocopy "$($dl):\" $IsoDir /E /NFL /NDL /NJH /NJS | Out-Null
Dismount-DiskImage -ImagePath $SourceIso | Out-Null
attrib -r "$IsoDir\*.*" /s /d

# ---------------- 2. Keep only Windows 10 Home ----------------
Step '2/8 Extracting Windows 10 Home only'
$src = @("$IsoDir\sources\install.wim","$IsoDir\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $src) { throw 'No install.wim / install.esd found in the ISO' }
$allImg  = @(Get-WindowsImage -ImagePath $src -ErrorAction Stop)
$homeImg = $allImg | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
if (-not $homeImg -and $allImg.Count -eq 1) {
  $homeImg = $allImg[0]   # single-edition ISO: just use it
  Write-Host "  Using the only edition in this ISO: $($homeImg.ImageName)" -ForegroundColor Yellow
}
if (-not $homeImg) {
  $allImg | ForEach-Object { Write-Host "  [$($_.ImageIndex)] $($_.ImageName)" }
  throw "Edition '$Edition' not found. Change `$Edition at the top of the script to one of the names above."
}
$wim = Join-Path $Work 'install.wim'
if (Test-Path $wim) { Remove-Item $wim -Force }
& dism.exe /Export-Image /SourceImageFile:$src /SourceIndex:$($homeImg.ImageIndex) /DestinationImageFile:$wim /Compress:max /CheckIntegrity
if ($LASTEXITCODE) { throw 'Export failed' }
Remove-Item "$IsoDir\sources\install.*" -Force

# Force Home edition at setup
@"
[EditionID]
Core
[Channel]
Retail
"@ | Set-Content "$IsoDir\sources\ei.cfg" -Encoding ASCII

# ---------------- 3. Extract HP drivers ----------------
Step '3/8 Extracting HP SoftPaqs'
$7z = @("$env:ProgramFiles\7-Zip\7z.exe","${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
Get-ChildItem $SoftPaqs -Filter 'sp*.exe' | ForEach-Object {
  $dest = Join-Path $DrvDir $_.BaseName
  Write-Host "  $($_.Name)"
  if ($7z) { & $7z x $_.FullName "-o$dest" -y | Out-Null }
  else     { Start-Process $_.FullName -ArgumentList '-e','-s','-f',"`"$dest`"" -Wait }
}
$infCount = (Get-ChildItem $DrvDir -Recurse -Filter *.inf).Count
Write-Host "  Found $infCount driver .inf files"
if ($infCount -eq 0) { throw 'No drivers extracted - install 7-Zip and retry.' }

# ---------------- 4. Customise Windows image ----------------
Step '4/8 Mounting Windows image'
Mount-WindowsImage -ImagePath $wim -Index 1 -Path $Mount -ErrorAction Stop | Out-Null

try {
  Write-Host '  Adding drivers...'
  Add-Drivers $Mount

  # Inbox drivers the touch screen needs (HID over I2C etc.). Full Windows has them;
  # the Setup environment may not, so keep a copy to add to boot.wim later.
  $repo = "$Mount\Windows\System32\DriverStore\FileRepository"
  foreach ($n in 'hidi2c','hidinterrupt','buttonconverter','msgpiowin32','hidspi','kmdfsamples') {
    Get-ChildItem $repo -Directory -Filter "$n.inf_*" -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {
      Copy-Item $_.FullName (Join-Path $PEExtra $_.Name) -Recurse -Force
    }
  }
  Note 'Touch helpers' ("collected from Windows: " + ((Get-ChildItem $PEExtra -Directory | ForEach-Object { $_.Name.Split('_')[0] }) -join ', '))

  if ($HasBrand) {
    Write-Host '  Applying AFIF-TECH branding...'
    $wp = Join-Path $Branding 'wallpaper.jpg'
    $ls = Join-Path $Branding 'lockscreen.jpg'
    # Default desktop wallpaper (all sizes Windows may pick from)
    [void](Replace-Image $wp "$Mount\Windows\Web\Wallpaper\Windows\img0.jpg")
    Get-ChildItem "$Mount\Windows\Web\4K\Wallpaper\Windows" -Filter *.jpg -ErrorAction SilentlyContinue |
      ForEach-Object { [void](Replace-Image $wp $_.FullName) }
    # Default lock screen / sign-in background
    Get-ChildItem "$Mount\Windows\Web\Screen" -Filter 'img10*.jpg' -ErrorAction SilentlyContinue |
      ForEach-Object { [void](Replace-Image $ls $_.FullName) }
    # Default account pictures
    $uap = "$Mount\ProgramData\Microsoft\User Account Pictures"
    foreach ($f in 'user.png','user-192.png','user-48.png','user-40.png','user-32.png','user.bmp') {
      $srcPic = Join-Path $Branding $f
      if ((Test-Path $srcPic) -and (Test-Path "$uap\$f")) { Grant-Own "$uap\$f"; Copy-Item $srcPic "$uap\$f" -Force }
    }
    # OEM logo for Settings > System > About
    New-Item "$Mount\Windows\System32\oobe\info" -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $Branding 'oemlogo.bmp') "$Mount\Windows\System32\oobe\info\afiftech.bmp" -Force
    Note 'Branding' 'wallpaper, lock screen, account pictures and OEM logo applied'
  }

  # Windows updates (PowerShell cmdlet - avoids the dism.exe timeouts)
  if (Test-Path $UpdSrc) {
    $upd = Get-ChildItem $UpdSrc -Include *.msu,*.cab -Recurse |
           Sort-Object @{e={ if ($_.Name -match 'ssu|servicing') {0} else {1} }}, Name
    foreach ($u in $upd) {
      Write-Host "  Installing update: $($u.Name) (can take 20-40 min)..."
      try { Add-WindowsPackage -Path $Mount -PackagePath $u.FullName -NoRestart | Out-Null }
      catch { Write-Host "    WARNING: $($u.Name) failed - $($_.Exception.Message)" -ForegroundColor Yellow }
    }
  }

  Write-Host '  Removing bloat apps...'
  Get-AppxProvisionedPackage -Path $Mount | Where-Object {
    $n = $_.DisplayName; -not ($KeepApps | Where-Object { $n -like $_ })
  } | ForEach-Object {
    Write-Host "    - $($_.DisplayName)"
    Remove-AppxProvisionedPackage -Path $Mount -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
  }

  Write-Host '  Removing optional capabilities...'
  Get-WindowsCapability -Path $Mount | Where-Object {
    $c = $_; $_.State -eq 'Installed' -and ($RemoveCaps | Where-Object { $c.Name -like $_ })
  } | ForEach-Object {
    Write-Host "    - $($_.Name)"
    Remove-WindowsCapability -Path $Mount -Name $_.Name -ErrorAction SilentlyContinue | Out-Null
  }

  Write-Host '  Removing OneDrive installer...'
  foreach ($od in "$Mount\Windows\System32\OneDriveSetup.exe","$Mount\Windows\SysWOW64\OneDriveSetup.exe") {
    if (Test-Path $od) { takeown /f $od | Out-Null; icacls $od /grant Administrators:F | Out-Null; Remove-Item $od -Force }
  }

  Write-Host '  Disabling reserved storage (frees ~7 GB on 32 GB eMMC)...'
  & dism.exe /Image:$Mount /Set-ReservedStorageState /State:Disabled | Out-Null

  Write-Host '  Applying registry tweaks...'
  reg load HKLM\OFF_SW  "$Mount\Windows\System32\config\SOFTWARE" | Out-Null
  reg load HKLM\OFF_DEF "$Mount\Users\Default\NTUSER.DAT"         | Out-Null
  # No auto-installed Store promos / suggested apps
  reg add 'HKLM\OFF_SW\Policies\Microsoft\Windows\CloudContent' /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
  reg add 'HKLM\OFF_SW\Policies\Microsoft\Windows\DataCollection' /v AllowTelemetry /t REG_DWORD /d 0 /f | Out-Null
  reg add 'HKLM\OFF_SW\Policies\Microsoft\Windows\OneDrive' /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f | Out-Null
  foreach ($v in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled','ContentDeliveryAllowed','SystemPaneSuggestionsEnabled','SubscribedContent-338388Enabled') {
    reg add 'HKLM\OFF_DEF\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v $v /t REG_DWORD /d 0 /f | Out-Null
  }
  cmd /c "reg delete HKLM\OFF_DEF\Software\Microsoft\Windows\CurrentVersion\Run /v OneDriveSetup /f >nul 2>&1"
  # AFIF-TECH OEM information (Settings > System > About, and winver)
  $oem = 'HKLM\OFF_SW\Microsoft\Windows\CurrentVersion\OEMInformation'
  reg add $oem /v Manufacturer /t REG_SZ /d 'AFIF-TECH' /f | Out-Null
  reg add $oem /v Model /t REG_SZ /d 'HP Pro Tablet 408 G1 - AFIF-TECH Edition' /f | Out-Null
  if ($HasBrand) { reg add $oem /v Logo /t REG_SZ /d 'C:\Windows\System32\oobe\info\afiftech.bmp' /f | Out-Null }
  reg add 'HKLM\OFF_SW\Microsoft\Windows NT\CurrentVersion' /v RegisteredOrganization /t REG_SZ /d 'AFIF-TECH' /f | Out-Null
  # Show the AFIF-TECH lock screen instead of Windows Spotlight pictures
  foreach ($v in 'RotatingLockScreenEnabled','RotatingLockScreenOverlayEnabled') {
    reg add 'HKLM\OFF_DEF\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v $v /t REG_DWORD /d 0 /f | Out-Null
  }
  # Backup trigger for app installs at first admin logon
  reg add 'HKLM\OFF_SW\Microsoft\Windows\CurrentVersion\RunOnce' /v HP408PostInstall /t REG_SZ /d 'cmd.exe /c %WINDIR%\Setup\Scripts\postinstall.cmd' /f | Out-Null
  [gc]::Collect(); Start-Sleep 2
  reg unload HKLM\OFF_DEF | Out-Null
  reg unload HKLM\OFF_SW  | Out-Null

  Write-Host '  Adding apps and post-install script...'
  $scripts = "$Mount\Windows\Setup\Scripts"
  New-Item "$scripts\Apps" -ItemType Directory -Force | Out-Null
  if (Test-Path $AppsSrc) { Copy-Item "$AppsSrc\*" "$scripts\Apps" -Recurse -Force }

@'
@echo off
if exist "%WINDIR%\Setup\Scripts\done.flag" exit /b 0
set A=%WINDIR%\Setup\Scripts\Apps
set L=%WINDIR%\Setup\Scripts\postinstall.log
echo Started %date% %time% > "%L%"

if exist "%A%\winrar.exe"      "%A%\winrar.exe" /S                                        >> "%L%" 2>&1
if exist "%A%\chrome.msi"      msiexec /i "%A%\chrome.msi" /qn /norestart                 >> "%L%" 2>&1
if exist "%A%\libreoffice.msi" msiexec /i "%A%\libreoffice.msi" /qn /norestart ALLUSERS=1 CREATEDESKTOPLINK=1 RebootYesNo=No >> "%L%" 2>&1
if exist "%A%\sumatrapdf.exe"  "%A%\sumatrapdf.exe" -install -s -all-users                >> "%L%" 2>&1

rem WhatsApp as a Chrome app window on the desktop (no 32-bit desktop app exists)
powershell -NoProfile -Command "$c=@('%ProgramFiles%\Google\Chrome\Application\chrome.exe','%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe')|?{Test-Path $_}|select -f 1; if($c){$s=(New-Object -ComObject WScript.Shell).CreateShortcut('C:\Users\Public\Desktop\WhatsApp.lnk');$s.TargetPath=$c;$s.Arguments='--app=https://web.whatsapp.com';$s.Save()}" >> "%L%" 2>&1

rem Save space on the 32 GB eMMC
powercfg /h off
compact /compactos:always >> "%L%" 2>&1

echo done > "%WINDIR%\Setup\Scripts\done.flag"
rd /s /q "%A%"
echo Finished %date% %time% >> "%L%"
'@ | Set-Content "$scripts\postinstall.cmd" -Encoding ASCII

  "@echo off`r`ncall %WINDIR%\Setup\Scripts\postinstall.cmd" | Set-Content "$scripts\SetupComplete.cmd" -Encoding ASCII

  Step '5/8 Cleaning component store'
  try { Repair-WindowsImage -Path $Mount -StartComponentCleanup -ResetBase | Out-Null }
  catch { Write-Host "  WARNING: cleanup skipped - $($_.Exception.Message)" -ForegroundColor Yellow }

  Dismount-WindowsImage -Path $Mount -Save -ErrorAction Stop | Out-Null
}
catch {
  Write-Host "ERROR: $_" -ForegroundColor Red
  cmd /c "reg unload HKLM\OFF_DEF >nul 2>&1"
  cmd /c "reg unload HKLM\OFF_SW >nul 2>&1"
  Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue | Out-Null
  throw
}

# ---------------- 6. Drivers + branding into Windows Setup ----------------
Step '6/8 Touch drivers and branding for Windows Setup'
$bootWim = "$IsoDir\sources\boot.wim"
foreach ($bi in @(Get-WindowsImage -ImagePath $bootWim -ErrorAction Stop)) {
  Write-Host "  boot.wim [$($bi.ImageIndex)] $($bi.ImageName)"
  Mount-WindowsImage -ImagePath $bootWim -Index $bi.ImageIndex -Path $Mount -ErrorAction Stop | Out-Null
  try {
    Add-Drivers $Mount

    # Inbox touch helpers missing from this environment
    $present = @(); $added = @(); $failed = @()
    Get-ChildItem $PEExtra -Directory | ForEach-Object {
      $inf = Get-ChildItem $_.FullName -Filter *.inf | Select-Object -First 1
      if (-not $inf) { return }
      if (Test-Path "$Mount\Windows\INF\$($inf.Name)") { $present += $inf.BaseName; return }
      try { Add-WindowsDriver -Path $Mount -Driver $inf.FullName -ForceUnsigned -ErrorAction Stop | Out-Null; $added += $inf.BaseName; [void]$global:AddedInfs.Add($inf.Name.ToLower()) }
      catch { $failed += $inf.BaseName }
    }
    Note "Setup touch [$($bi.ImageIndex)]" ("already there: " + ($present -join ',') + " | added: " + ($added -join ',') + " | failed: " + ($failed -join ','))

    $isSetup = Test-Path "$Mount\sources\setup.exe"
    if ($isSetup) {
      # Force-load every injected driver before Setup starts, and leave a log on the USB stick
      New-Item "$Mount\HP408" -ItemType Directory -Force | Out-Null
      $global:AddedInfs | Sort-Object | Set-Content "$Mount\HP408\infs.txt" -Encoding ASCII

      reg load HKLM\PE_SYS "$Mount\Windows\System32\config\SYSTEM" | Out-Null
      $q = (reg query 'HKLM\PE_SYS\Setup' /v CmdLine 2>$null) -join "`n"
      $orig = if ($q -match 'CmdLine\s+REG_\w+\s+(.+)') { $Matches[1].Trim() } else { '' }
      if ($orig -and $orig -notmatch 'pe-start') {
@"
@echo off
set LOG=X:\HP408\setup-log.txt
echo AFIF-TECH setup start %date% %time% > %LOG%
for /f "usebackq delims=" %%i in ("X:\HP408\infs.txt") do (
  for /d %%d in ("X:\Windows\System32\DriverStore\FileRepository\%%i_*") do (
    echo drvload %%d\%%i >> %LOG%
    drvload "%%d\%%i" >> %LOG% 2>&1
  )
)
echo. >> %LOG%
echo ==== Devices with problems ==== >> %LOG%
wmic path Win32_PnPEntity where "ConfigManagerErrorCode<>0" get Name,DeviceID,ConfigManagerErrorCode >> %LOG% 2>&1
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%L:\sources\install.esd copy /y %LOG% %%L:\AFIF-TECH-setup-log.txt >nul 2>&1
$orig
"@ | Set-Content "$Mount\HP408\pe-start.cmd" -Encoding ASCII
        reg add 'HKLM\PE_SYS\Setup' /v CmdLine /t REG_SZ /d 'cmd.exe /c X:\HP408\pe-start.cmd' /f | Out-Null
        Note 'Setup hook' "drvload hook installed (original: $orig)"
      } else { Note 'Setup hook' "skipped - CmdLine was '$orig'" }
      [gc]::Collect(); Start-Sleep 2
      reg unload HKLM\PE_SYS | Out-Null
    }

    if ($HasBrand) {
      $n = 0
      foreach ($f in @(Get-ChildItem "$Mount\sources" -Filter 'background*' -ErrorAction SilentlyContinue) +
                     @(Get-ChildItem "$Mount\Windows\System32" -Filter 'winpe.jpg' -ErrorAction SilentlyContinue) +
                     @(Get-ChildItem "$Mount\Windows\System32" -Filter 'setup.bmp' -ErrorAction SilentlyContinue)) {
        if (Replace-Image (Join-Path $Branding 'setup.png') $f.FullName) { $n++ }
      }
      Note "Setup branding [$($bi.ImageIndex)]" "$n background image(s) replaced"
    }
    Dismount-WindowsImage -Path $Mount -Save -ErrorAction Stop | Out-Null
  } catch {
    cmd /c "reg unload HKLM\PE_SYS >nul 2>&1"
    Dismount-WindowsImage -Path $Mount -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
  }
}
if ($HasBrand) {
  Get-ChildItem "$IsoDir\sources" -Filter 'background*' -ErrorAction SilentlyContinue |
    ForEach-Object { [void](Replace-Image (Join-Path $Branding 'setup.png') $_.FullName) }
}

# ---------------- 7. Maximum compression ----------------
Step '7/8 Compressing to install.esd (slow, smallest size)'
& dism.exe /Export-Image /SourceImageFile:$wim /SourceIndex:1 /DestinationImageFile:"$IsoDir\sources\install.esd" /DestinationName:"$Edition - AFIF-TECH Edition" /Compress:recovery /CheckIntegrity
if ($LASTEXITCODE) { throw 'ESD compression failed' }
Remove-Item $wim -Force

# ---------------- 8. Build ISO (BIOS + 32/64-bit UEFI) ----------------
Step '8/8 Building ISO'
if (Test-Path $OutIso) { Remove-Item $OutIso -Force }
$boot = "2#p0,e,b`"$IsoDir\boot\etfsboot.com`"#pEF,e,b`"$IsoDir\efi\microsoft\boot\efisys.bin`""
& $oscdimg -m -o -u2 -udfver102 -lAFIF-TECH_W10 "-bootdata:$boot" $IsoDir $OutIso
if ($LASTEXITCODE) { throw 'oscdimg failed' }

$size = [math]::Round((Get-Item $OutIso).Length / 1GB, 2)
Write-Host "`nDONE: $OutIso  ($size GB)" -ForegroundColor Green
Write-Host 'Write it to USB with Rufus (GPT, UEFI non-CSM, FAT32).'
