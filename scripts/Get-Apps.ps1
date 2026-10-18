<#
  Downloads the 32-bit app installers for the HP Pro Tablet 408 build and
  saves them with the names Build-HP408-Lite.ps1 expects:
    winrar.exe, chrome.msi, libreoffice.msi, sumatrapdf.exe
  Each app is optional: a failed download prints a warning and the build
  continues without that app.
#>
param([Parameter(Mandatory)][string]$OutDir)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # much faster Invoke-WebRequest
New-Item $OutDir -ItemType Directory -Force | Out-Null
$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }

function Test-Url($u) {
  try { (Invoke-WebRequest $u -Method Head -Headers $UA -UseBasicParsing -MaximumRedirection 5).StatusCode -eq 200 }
  catch { $false }
}
function Save($name, $url) {
  Write-Host "  $name  <=  $url"
  Invoke-WebRequest $url -OutFile (Join-Path $OutDir $name) -Headers $UA -UseBasicParsing
  $mb = [math]::Round((Get-Item (Join-Path $OutDir $name)).Length / 1MB, 1)
  Write-Host "    OK ($mb MB)" -ForegroundColor Green
}
function Try-App($label, [scriptblock]$block) {
  Write-Host "`n[$label]" -ForegroundColor Cyan
  try { & $block } catch { Write-Host "  WARNING: $label skipped - $($_.Exception.Message)" -ForegroundColor Yellow }
}

# ---- Google Chrome (32-bit enterprise MSI) ---------------------------
Try-App 'Chrome' {
  Save 'chrome.msi' 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise.msi'
}

# ---- WinRAR 32-bit: newest version that still has a 32-bit build -------
Try-App 'WinRAR' {
  $page = (Invoke-WebRequest 'https://www.rarlab.com/download.htm' -Headers $UA -UseBasicParsing).Content
  $cands = @()
  if ($page -match 'winrar-x64-(\d{3,4})\.exe') { $cands += "https://www.rarlab.com/rar/wrar$($Matches[1]).exe" }
  $cands += 'https://www.rarlab.com/rar/wrar712.exe','https://www.rarlab.com/rar/wrar711.exe',
            'https://www.rarlab.com/rar/wrar701.exe','https://www.rarlab.com/rar/wrar700.exe',
            'https://www.rarlab.com/rar/wrar624.exe'
  $url = $cands | Where-Object { Test-Url $_ } | Select-Object -First 1
  if (-not $url) { throw 'no 32-bit WinRAR build found' }
  Save 'winrar.exe' $url
}

# ---- LibreOffice x86 MSI (32-bit ended at 25.2.x) ----------------------
Try-App 'LibreOffice' {
  $base = 'https://downloadarchive.documentfoundation.org/libreoffice/old/'
  $list = (Invoke-WebRequest $base -Headers $UA -UseBasicParsing).Content
  $vers = [regex]::Matches($list, 'href="(\d+\.\d+\.\d+\.\d+)/"') | ForEach-Object { $_.Groups[1].Value } |
          Sort-Object { [version]$_ } -Descending
  $url = $null
  foreach ($v in $vers) {
    if ([version]$v -ge [version]'25.8') { continue }        # no x86 builds from 25.8 on
    $u = "$base$v/win/x86/LibreOffice_${v}_Win_x86.msi"
    if (Test-Url $u) { $url = $u; break }
  }
  if (-not $url) { throw 'no x86 MSI found in the archive' }
  Save 'libreoffice.msi' $url
}

# ---- SumatraPDF 32-bit installer ---------------------------------------
Try-App 'SumatraPDF' {
  $page = (Invoke-WebRequest 'https://www.sumatrapdfreader.org/download-free-pdf-viewer' -Headers $UA -UseBasicParsing).Content
  $m = [regex]::Matches($page, '(/dl/rel/[\d\.]+/SumatraPDF-[\d\.]+-install\.exe)') | Select-Object -First 1
  if (-not $m) { throw 'installer link not found on the download page' }
  Save 'sumatrapdf.exe' ("https://www.sumatrapdfreader.org" + $m.Groups[1].Value)
}

Write-Host "`nApps folder:" -ForegroundColor Cyan
Get-ChildItem $OutDir | Format-Table Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} -AutoSize
