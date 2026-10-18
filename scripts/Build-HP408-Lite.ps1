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
  [string]$Edition   = 'Windows 10 Home'
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
$OutIso    = Join-Path $Work 'HP408G1_Win10Home_x86_Lite_Final.iso'
if ($SourceIso -ieq $OutIso) { $OutIso = Join-Path $Work 'HP408G1_Win10Home_x86_Lite_Final_v2.iso' }  # never overwrite the source

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
    try   { Add-WindowsDriver -Path $ImagePath -Driver $_.FullName -ErrorAction Stop | Out-Null; $ok++ }
    catch { Write-Host "    skipped $($_.Exception.Message.Split([char]10)[0])"; $skip++ }
  }
  Write-Host "  Drivers added: $ok, skipped: $skip"
  if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=Drivers::$ImagePath - added $ok, skipped $skip" }
  if ($ok -eq 0) { throw 'No drivers could be added' }
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

foreach ($d in $IsoDir,$DrvDir,$Mount) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } ; New-Item $d -ItemType Directory | Out-Null }
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

# ---------------- 6. Drivers into Windows Setup ----------------
Step '6/8 Adding drivers to Windows Setup (touch during install)'
Mount-WindowsImage -ImagePath "$IsoDir\sources\boot.wim" -Index 2 -Path $Mount -ErrorAction Stop | Out-Null
Add-Drivers $Mount
Dismount-WindowsImage -Path $Mount -Save -ErrorAction Stop | Out-Null

# ---------------- 7. Maximum compression ----------------
Step '7/8 Compressing to install.esd (slow, smallest size)'
& dism.exe /Export-Image /SourceImageFile:$wim /SourceIndex:1 /DestinationImageFile:"$IsoDir\sources\install.esd" /Compress:recovery /CheckIntegrity
if ($LASTEXITCODE) { throw 'ESD compression failed' }
Remove-Item $wim -Force

# ---------------- 8. Build ISO (BIOS + 32/64-bit UEFI) ----------------
Step '8/8 Building ISO'
if (Test-Path $OutIso) { Remove-Item $OutIso -Force }
$boot = "2#p0,e,b`"$IsoDir\boot\etfsboot.com`"#pEF,e,b`"$IsoDir\efi\microsoft\boot\efisys.bin`""
& $oscdimg -m -o -u2 -udfver102 -lHP408_W10HOME "-bootdata:$boot" $IsoDir $OutIso
if ($LASTEXITCODE) { throw 'oscdimg failed' }

$size = [math]::Round((Get-Item $OutIso).Length / 1GB, 2)
Write-Host "`nDONE: $OutIso  ($size GB)" -ForegroundColor Green
Write-Host 'Write it to USB with Rufus (GPT, UEFI non-CSM, FAT32).'
