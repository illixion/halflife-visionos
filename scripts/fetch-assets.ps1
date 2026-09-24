<#
.SYNOPSIS
Downloads SteamCMD (if not already present) and fetches the archived
pre-25th-anniversary Half-Life build into HalfLifeAssets\.

.DESCRIPTION
Valve's 25th Anniversary Update (Nov 2023) broke shader/asset compat with
Xash3D-FWGS; the mod ecosystem targets the build Valve archived on the
`steam_legacy` beta branch of app 70. See README.md for background.

This only prepares HalfLifeAssets\ on this machine. Pushing it to the
headset (./scripts/push-assets.sh, devicectl) is macOS-only and needs the
folder copied over to the Mac doing the build.

Needs a Steam account that owns Half-Life. steamcmd prompts for the
password and any Steam Guard code interactively — this script never takes
either as a parameter or stores them.

.PARAMETER SteamUsername
Steam account name to log in as (must own Half-Life).

.EXAMPLE
.\scripts\fetch-assets.ps1 -SteamUsername YOUR_STEAM_USERNAME
#>
param(
    [Parameter(Mandatory = $true)][string]$SteamUsername,
    [string]$SteamCmdDir = "$HOME\bin\steamcmd"
)
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$SteamCmdBin = Join-Path $SteamCmdDir "steamcmd.exe"

if (-not (Test-Path $SteamCmdBin)) {
    Write-Host "==> SteamCMD not found at $SteamCmdBin - downloading..."
    New-Item -ItemType Directory -Force -Path $SteamCmdDir | Out-Null
    $zip = Join-Path $env:TEMP "steamcmd.zip"
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $SteamCmdDir -Force
    Remove-Item $zip
}

Write-Host "==> Fetching Half-Life (app 70, steam_legacy beta) into $ProjectRoot\HalfLifeAssets ..."
Write-Host "    steamcmd will prompt for your Steam password / Steam Guard code."
& $SteamCmdBin `
    +force_install_dir "$ProjectRoot\HalfLifeAssets" `
    +login $SteamUsername `
    +app_update 70 -beta steam_legacy validate `
    +quit

if (-not (Test-Path "$ProjectRoot\HalfLifeAssets\valve\liblist.gam")) {
    Write-Error "Download finished but HalfLifeAssets\valve\liblist.gam is missing - check the steamcmd output above."
    exit 1
}

# Depot 96 (the official Gearbox "Half-Life High Definition" pack) ships as
# HalfLifeAssets\valve_hd\ alongside valve\ - app_update 70 already pulled it,
# no separate fetch step needed. Its depot ships models\Hgrunt03.mdl with a
# capital H; NTFS is case-insensitive so this is invisible here, but the
# engine requests the lowercase name and this folder is headed for a
# case-sensitive Mac volume (visionOS APFS) via push-assets.sh - normalize it
# now so it isn't a missing-model crash later.
$HdHgrunt = "$ProjectRoot\HalfLifeAssets\valve_hd\models\Hgrunt03.mdl"
if (Test-Path $HdHgrunt) {
    # A same-name-different-case rename can fail on NTFS ("already exists")
    # depending on .NET version, since the case-insensitive lookup treats
    # source and target as the same path — hop through a temp name.
    $TempName = "$HdHgrunt.casefix"
    Rename-Item -Path $HdHgrunt -NewName (Split-Path -Leaf $TempName)
    Rename-Item -Path $TempName -NewName "hgrunt03.mdl"
    Write-Host "==> Renamed valve_hd\models\Hgrunt03.mdl -> hgrunt03.mdl (case-sensitive filesystem fix)"
}

Write-Host ""
Write-Host "Done. Copy the HalfLifeAssets folder to your Mac, then run ./scripts/push-assets.sh there to send it to the headset."
