<#
.SYNOPSIS
Downloads SteamCMD (if not already present) and fetches the archived
pre-25th-anniversary Half-Life build into HalfLifeAssets\, optionally with
Opposing Force (app 50) and Blue Shift (app 130), and optionally zips each
game for importing on the headset (AirDrop, Files).

.DESCRIPTION
Valve's 25th Anniversary Update (Nov 2023) broke shader/asset compat with
Xash3D-FWGS; the mod ecosystem targets the build Valve archived on the
`steam_legacy` beta branch of app 70. See README.md for background.

Opposing Force and Blue Shift have no steam_legacy branch (their public
build is from 2020, before the anniversary update), but both pull
Half-Life's depots from app 70's current, post-anniversary build. So they
install into a staging folder (build\steam-mods\) and only their own
gamedirs (gearbox*, bshift*) are copied into HalfLifeAssets\, never valve*.

-Zip writes build\asset-zips\<gamedir>.zip per game, its _hd/_addon overlays
included: send one to the headset and open it in LambdaVision. Without -Zip,
copy HalfLifeAssets to the Mac doing the build and push it from there
(./scripts/push-assets.sh, macOS only).

Needs a Steam account that owns the games. steamcmd prompts for the
password and any Steam Guard code interactively — this script never takes
either as a parameter or stores them.

.PARAMETER SteamUsername
Steam account name to log in as (must own the games). Optional with -Zip,
which then only zips what HalfLifeAssets\ already holds.

.PARAMETER ExtraApps
Extra apps to fetch: 50 (Opposing Force), 130 (Blue Shift).

.PARAMETER Zip
Zip each game in HalfLifeAssets\ into build\asset-zips\.

.EXAMPLE
.\scripts\fetch-assets.ps1 -SteamUsername YOUR_STEAM_USERNAME

.EXAMPLE
.\scripts\fetch-assets.ps1 -SteamUsername YOUR_STEAM_USERNAME -ExtraApps 50,130 -Zip
#>
param(
    [string]$SteamUsername,
    [ValidateSet(50, 130)][int[]]$ExtraApps = @(),
    [switch]$Zip,
    [string]$SteamCmdDir = "$HOME\bin\steamcmd"
)
$ErrorActionPreference = "Stop"

if (-not $SteamUsername -and -not $Zip) {
    Write-Error "Give -SteamUsername to download, or -Zip to zip what HalfLifeAssets already holds."
    exit 1
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
$Assets = Join-Path $ProjectRoot "HalfLifeAssets"

# Each game's own gamedir, the only one (with its overlays) taken from its
# staging install.
$AppGamedir = @{ 50 = "gearbox"; 130 = "bshift" }

if ($SteamUsername) {
    $SteamCmdBin = Join-Path $SteamCmdDir "steamcmd.exe"

    if (-not (Test-Path $SteamCmdBin)) {
        Write-Host "==> SteamCMD not found at $SteamCmdBin - downloading..."
        New-Item -ItemType Directory -Force -Path $SteamCmdDir | Out-Null
        $zipFile = Join-Path $env:TEMP "steamcmd.zip"
        Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $zipFile
        Expand-Archive -Path $zipFile -DestinationPath $SteamCmdDir -Force
        Remove-Item $zipFile
    }

    Write-Host "==> Fetching Half-Life (app 70, steam_legacy beta) into $Assets ..."
    Write-Host "    steamcmd will prompt for your Steam password / Steam Guard code."
    & $SteamCmdBin `
        +force_install_dir "$Assets" `
        +login $SteamUsername `
        +app_update 70 -beta steam_legacy validate `
        +quit

    if (-not (Test-Path (Join-Path $Assets "valve\liblist.gam"))) {
        Write-Error "Download finished but HalfLifeAssets\valve\liblist.gam is missing - check the steamcmd output above."
        exit 1
    }

    foreach ($app in $ExtraApps) {
        $gamedir = $AppGamedir[$app]
        $stage = Join-Path $ProjectRoot "build\steam-mods\app$app"
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Write-Host "==> Fetching app $app (public branch) into the staging folder $stage ..."
        & $SteamCmdBin `
            +force_install_dir "$stage" `
            +login $SteamUsername `
            +app_update $app validate `
            +quit
        if (-not (Test-Path (Join-Path $stage "$gamedir\liblist.gam"))) {
            Write-Error "App $app finished but $stage\$gamedir\liblist.gam is missing - check the steamcmd output above."
            exit 1
        }
        Get-ChildItem -Path $stage -Directory | Where-Object { $_.Name -eq $gamedir -or $_.Name -like "${gamedir}_*" } | ForEach-Object {
            Write-Host "    copying $($_.Name)\ into HalfLifeAssets\"
            $target = Join-Path $Assets $_.Name
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Copy-Item -Path (Join-Path $_.FullName "*") -Destination $target -Recurse -Force
        }
    }

    # Depot 96 (the official Gearbox "Half-Life High Definition" pack) ships as
    # HalfLifeAssets\valve_hd\ alongside valve\ (the expansions' HD packs come
    # the same way as gearbox_hd\ and bshift_hd\). Its depot ships
    # models\Hgrunt03.mdl with a capital H; NTFS is case-insensitive so this is
    # invisible here, but the engine requests the lowercase name and this
    # folder is headed for a case-sensitive volume (visionOS APFS) - normalize
    # it now so it isn't a missing-model crash later.
    Get-ChildItem -Path $Assets -Directory -Filter "*_hd" | ForEach-Object {
        $hd = Join-Path $_.FullName "models\Hgrunt03.mdl"
        $item = Get-Item -LiteralPath $hd -ErrorAction SilentlyContinue
        if ($item -and $item.Name -ceq "Hgrunt03.mdl") {
            # A same-name-different-case rename can fail on NTFS ("already
            # exists") depending on .NET version, since the case-insensitive
            # lookup treats source and target as the same path — hop through a
            # temp name.
            $tempName = "Hgrunt03.mdl.casefix"
            Rename-Item -LiteralPath $hd -NewName $tempName
            Rename-Item -LiteralPath (Join-Path $_.FullName "models\$tempName") -NewName "hgrunt03.mdl"
            Write-Host "==> Renamed $($_.Name)\models\Hgrunt03.mdl -> hgrunt03.mdl (case-sensitive filesystem fix)"
        }
    }
}

if ($Zip) {
    # ZipArchive with forward-slash entry names: Windows PowerShell 5.1's
    # Compress-Archive writes backslashes, which unpack as flat file names
    # with "\" in them anywhere but Windows.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $out = Join-Path $ProjectRoot "build\asset-zips"
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $isGame = { param($d) (Test-Path (Join-Path $d "liblist.gam")) -or (Test-Path (Join-Path $d "gameinfo.txt")) }
    $zipped = 0
    foreach ($base in Get-ChildItem -Path $Assets -Directory) {
        if (-not (& $isGame $base.FullName)) { continue }
        # A game's overlays are the <gamedir>_* folders without a liblist.
        $dirs = @($base) + @(Get-ChildItem -Path $Assets -Directory | Where-Object {
            $_.Name -like "$($base.Name)_*" -and -not (& $isGame $_.FullName) })
        $zipPath = Join-Path $out "$($base.Name).zip"
        Write-Host "==> Zipping $(($dirs | ForEach-Object Name) -join ' ') -> build\asset-zips\$($base.Name).zip"
        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath }
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($dir in $dirs) {
                Get-ChildItem -LiteralPath $dir.FullName -Recurse -File | Where-Object { $_.Name -ne ".DS_Store" } | ForEach-Object {
                    $entry = $dir.Name + "/" + $_.FullName.Substring($dir.FullName.Length + 1).Replace("\", "/")
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry)
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        $zipped++
    }
    if ($zipped -eq 0) {
        Write-Error "No games in HalfLifeAssets\ to zip."
        exit 1
    }
    Write-Host ""
    Write-Host "Done. Send a zip from build\asset-zips\ to the headset (AirDrop, or the Files app) and open it in LambdaVision."
}
else {
    Write-Host ""
    Write-Host "Done. Copy the HalfLifeAssets folder to your Mac, then run ./scripts/push-assets.sh there to send it to the headset,"
    Write-Host "or rerun with -Zip to import the games on the headset instead."
}
