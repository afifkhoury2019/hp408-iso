# HP Pro Tablet 408 G1 — Lite Windows 10 ISO builder

Builds a light, driver-ready Windows 10 x86 ISO for the HP Pro Tablet 408 G1
on a GitHub-hosted Windows virtual machine. No software needed on your PC.

## What the ISO contains
- **One edition only:** Windows 10 Home (or Pro, selectable)
- **All HP drivers built in** (touch, Wi-Fi, Bluetooth, audio, camera, sensors),
  also inside Windows Setup, so touch works from the first screen
- **Removed:** Xbox, games, Mail/Calendar, Maps, Weather, Cortana, OneDrive,
  Windows Media Player, Internet Explorer, Steps Recorder, ads and suggested apps,
  reserved storage (~7 GB back on the 32 GB eMMC)
- **Kept:** Store, Calculator, Photos, Snipping, Notepad, Windows Security
- **Installed automatically on first boot:** WinRAR, Google Chrome,
  LibreOffice (last 32-bit release, 25.2.x), SumatraPDF, and a WhatsApp
  desktop shortcut (WhatsApp Web in its own window — there is no 32-bit
  WhatsApp desktop app)
- **Space savers:** hibernation off, CompactOS, component store reset,
  maximum ESD compression

## How to build
1. Share the Google Drive folder with the Windows ISO and HP SoftPaqs as
   **Anyone with the link → Viewer**.
2. Open **Actions → Build HP408 Lite ISO → Run workflow**.
3. Choose the edition (Pro activates with the tablet's built-in license; Home does not).
   Optionally paste a direct `.msu` link for the latest
   *Cumulative Update for Windows 10 Version 22H2 for x86* from the Microsoft Update Catalog.
4. Wait about 1.5–3 hours. Download **HP408G1-Win10-Lite-ISO** from the run's
   *Artifacts* section (kept for 5 days), then unzip it.

## Write to USB and install
- **Rufus:** GPT, UEFI (non CSM), FAT32.
- On the tablet: hold **Volume Down** + **Power** → Boot Device Options → USB
  (use an OTG hub for the USB stick and a keyboard).
- Delete all partitions on the internal drive and install.
- After first sign-in, give the apps 10–20 minutes to install in the background.

## Files
| File | Purpose |
|---|---|
| `.github/workflows/build-iso.yml` | The cloud build |
| `drive-files.txt` | Google Drive file IDs to download |
| `scripts/Get-Apps.ps1` | Downloads the 32-bit app installers |
| `scripts/Build-HP408-Lite.ps1` | Customises the image and builds the ISO (also runs on your own PC) |
| `scripts/hp408_inject_drivers.bat` | Simple driver injection into an existing Rufus USB |

> Windows 10 stopped receiving free security updates in October 2025.
> Keep Chrome up to date.
