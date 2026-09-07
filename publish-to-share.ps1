<#
.SYNOPSIS
    Publishes the audit tool to a network share so coworkers can install it
    onto their own Blancco sticks without git.

.DESCRIPTION
    Copies the installable tree plus the SystemRescue ISO to a shared folder and
    stamps it with the commit it came from. A coworker then plugs in their stick,
    opens the share, and double-clicks install.cmd.

    The share gets a plain folder - no .git, no repository. History stays here.

.PARAMETER Share
    Destination, e.g. \\fileserver\it\hwaudit or S:\tools\hwaudit. Remembered in
    .publish-target, so later runs need no argument.

.PARAMETER IsoPath
    Path to systemrescue-13.02-amd64.iso. Omit it and any connected BLANCCO stick
    is used as the source.

.PARAMETER DryRun
    Report what would happen and write nothing.

.EXAMPLE
    .\publish-to-share.ps1 -Share \\fileserver\it\hwaudit
.EXAMPLE
    .\publish-to-share.ps1
#>
param(
    [string]$Share,
    [string]$IsoPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$ISO_NAME = 'systemrescue-13.02-amd64.iso'
$ISO_SHA  = 'AD4D670B72859D887C7960142A9A9D36A3E50446694A035E254442F65D6E7572'

$src       = $PSScriptRoot
$memo      = Join-Path $src '.publish-target'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Say  { param($m) Write-Host $m }
function Ok   { param($m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function Info { param($m) Write-Host "  [ .. ]  $m" -ForegroundColor Gray }
function Warn { param($m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host ""; Write-Host "  FAILED: $m" -ForegroundColor Red; Write-Host ""; exit 1 }
function Get-Sha { param($p) (Get-FileHash -Path $p -Algorithm SHA256).Hash }

# What a coworker needs. Everything else - .git, .gitignore, the publish
# scripts, images\ - stays here.
$PAYLOAD = @('hwaudit', 'boot', 'install-to-stick.ps1', 'install.cmd', 'README.md')

Say ""
Say "=============================================================="
Say " Hardware audit - publish to the share"
if ($DryRun) { Say " DRY RUN - nothing will be written" }
Say "=============================================================="
Say ""

# ---------------------------------------------------------------- destination
if (-not $Share) {
    if (Test-Path $memo) {
        $Share = (Get-Content $memo -Raw).Trim()
        Info "using the remembered target from .publish-target"
    }
}
if (-not $Share) {
    Die ("no share given and none remembered.`n" +
         "  Run it once with the destination, e.g.:`n" +
         "    .\publish-to-share.ps1 -Share \\fileserver\it\hwaudit`n" +
         "  It is remembered after that.")
}
$Share = $Share.TrimEnd('\')
Say "Source: $src"
Say "Share:  $Share"

# ---------------------------------------------------------------- sanity
foreach ($p in $PAYLOAD) {
    if (-not (Test-Path (Join-Path $src $p))) { Die "missing from the repository: $p" }
}

# Publish a known commit, not a half-finished edit.
$commit = 'unknown'
$dirty  = $false
try {
    Push-Location $src
    $commit = (& git rev-parse --short HEAD 2>$null)
    $status = (& git status --porcelain 2>$null)
    if ($status) { $dirty = $true }
    Pop-Location
} catch { Warn "could not read git state" }

if ($dirty) {
    Warn "the repository has uncommitted changes - the share will not match any commit"
    Warn "commit first if you want to be able to tell later what was published"
} else {
    Ok "repository is clean at commit $commit"
}

# ---------------------------------------------------------------- iso
$shareIso = Join-Path $Share "images\$ISO_NAME"
$needIso  = $true
$isoSrc   = $null

if (Test-Path $shareIso) {
    Info "share already has $ISO_NAME - verifying (takes a moment)"
    if ((Get-Sha $shareIso) -eq $ISO_SHA) { Ok "ISO on the share is correct"; $needIso = $false }
    else { Warn "ISO on the share has the wrong hash - it will be replaced" }
}

if ($needIso) {
    $tries = @()
    if ($IsoPath) { $tries += $IsoPath }
    $tries += (Join-Path $src "images\$ISO_NAME")
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue |
                     Where-Object { $_.FileSystemLabel -eq 'BLANCCO' -and $_.DriveLetter })) {
        $tries += "$($v.DriveLetter):\images\$ISO_NAME"
    }
    foreach ($p in $tries) { if ($p -and (Test-Path $p)) { $isoSrc = $p; break } }
    if (-not $isoSrc) {
        Die ("cannot find $ISO_NAME to publish.`n" +
             "  Looked in: " + ($tries -join ', ') + "`n" +
             "  Plug in a stick that has it, or pass -IsoPath.")
    }
    Info "ISO source: $isoSrc"
    if ((Get-Sha $isoSrc) -ne $ISO_SHA) { Die "source ISO hash does not match - do not publish it." }
    Ok "source ISO hash matches"
}

# ---------------------------------------------------------------- write
Say ""
if ($DryRun) {
    foreach ($p in $PAYLOAD) { Info "would copy  $p  ->  $Share\" }
    if ($needIso) { Info "would copy  $ISO_NAME  ->  $Share\images\" }
    Info "would stamp $Share\VERSION.txt with commit $commit"
    Say ""
    Say "Dry run complete - nothing was written."
    exit 0
}

Say "Publishing..."
$null = New-Item -ItemType Directory -Path $Share -Force
foreach ($p in $PAYLOAD) {
    $s = Join-Path $src $p
    if (Test-Path $s -PathType Container) {
        $d = Join-Path $Share $p
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        Copy-Item $s $d -Recurse -Force
    } else {
        Copy-Item $s (Join-Path $Share $p) -Force
    }
    Ok "copied $p"
}

if ($needIso) {
    $null = New-Item -ItemType Directory -Path (Join-Path $Share 'images') -Force
    Info "copying the ISO (1.4 GB - this is the slow part)"
    Copy-Item $isoSrc $shareIso -Force
    Ok "copied $ISO_NAME"
}

$stamp = @(
    "Hardware audit tool for the Blancco USB stick"
    ""
    "Published : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    "By        : $env:USERNAME on $env:COMPUTERNAME"
    "Commit    : $commit$(if ($dirty) { '  (WITH UNCOMMITTED CHANGES)' } else { '' })"
    ""
    "To install onto your own Blancco stick:"
    "  1. Plug the stick in."
    "  2. Double-click install.cmd in this folder."
    ""
    "It will not touch anything that is not a Blancco stick, and it leaves"
    "Blancco's own boot entries alone. See README.md."
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $Share 'VERSION.txt'), $stamp + "`r`n", $utf8NoBom)
Ok "stamped VERSION.txt"

# ---------------------------------------------------------------- verify
Say ""
Say "Verifying the share..."
$problems = @()
foreach ($f in @('install.cmd', 'install-to-stick.ps1', 'README.md', 'VERSION.txt',
                 'hwaudit\collect.sh', 'hwaudit\app\index.html', 'hwaudit\app\server.py',
                 'hwaudit\firmware\sof-firmware.pkg.tar.zst', 'boot\grub\hwaudit-menu.cfg')) {
    if (-not (Test-Path (Join-Path $Share $f))) { $problems += "missing on the share: $f" }
}
$n = @(Get-ChildItem (Join-Path $Share 'hwaudit\camera') -Filter '*.pkg.tar.zst' -ErrorAction SilentlyContinue).Count
if ($n -ne 6) { $problems += "expected 6 camera packages, found $n" } else { Ok "6 camera packages present" }

# The collector must reach the share with Unix line endings intact.
$b = [IO.File]::ReadAllBytes((Join-Path $Share 'hwaudit\collect.sh'))
if ($b -contains 13) { $problems += "collect.sh on the share has CRLF - installs from here would break" }
else { Ok "collect.sh still has Unix line endings" }

if (-not (Test-Path $shareIso)) { $problems += "$ISO_NAME missing from the share" }
else {
    if ((Get-Sha $shareIso) -ne $ISO_SHA) { $problems += "$ISO_NAME on the share fails its hash check" }
    else { Ok "ISO verified on the share" }
}

if (-not $DryRun) { [IO.File]::WriteAllText($memo, $Share, $utf8NoBom) }

Say ""
if ($problems.Count -gt 0) {
    Say "  Finished with problems:"
    foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Red }
    Say ""
    exit 1
}

Say "=============================================================="
Say " Published to $Share"
Say "=============================================================="
Say ""
Say " Tell your coworkers:"
Say ""
Say "   1. Plug your Blancco stick in."
Say "   2. Open $Share"
Say "   3. Double-click install.cmd"
Say ""
Say " Re-run this script after any change to publish the new version."
Say ""
