<#
.SYNOPSIS
    Builds one self-contained .zip - tool, installer and the SystemRescue ISO -
    to attach to a GitHub Release.

.DESCRIPTION
    The ISO cannot live in the repository: git refuses files over 100 MB. A
    GitHub Release attachment can be up to 2 GB, which is where it goes instead.

    A coworker downloads the zip from the Releases page, extracts it, plugs in
    their Blancco stick and double-clicks install.cmd. Nothing else is needed.

.PARAMETER IsoPath
    Path to systemrescue-13.02-amd64.iso. Omit it and any connected BLANCCO stick
    is used as the source.

.PARAMETER Tag
    Version tag for the file name, e.g. v1.0. Defaults to the date.

.EXAMPLE
    .\build-release-zip.ps1 -Tag v1.0
#>
param(
    [string]$IsoPath,
    [string]$Tag
)

$ErrorActionPreference = 'Stop'

$ISO_NAME = 'systemrescue-13.02-amd64.iso'
$ISO_SHA  = 'AD4D670B72859D887C7960142A9A9D36A3E50446694A035E254442F65D6E7572'
$GH_LIMIT = 2GB

$src       = $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Say  { param($m) Write-Host $m }
function Ok   { param($m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function Info { param($m) Write-Host "  [ .. ]  $m" -ForegroundColor Gray }
function Warn { param($m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host ""; Write-Host "  FAILED: $m" -ForegroundColor Red; Write-Host ""; exit 1 }
function Get-Sha { param($p) (Get-FileHash -Path $p -Algorithm SHA256).Hash }

# What a coworker needs, and nothing else. The build and publish scripts stay
# behind - they are not their job.
$PAYLOAD = @('hwaudit', 'boot', 'install-to-stick.ps1', 'install.cmd', 'README.md')

if (-not $Tag) { $Tag = 'v' + (Get-Date -Format 'yyyy.MM.dd') }

Say ""
Say "=============================================================="
Say " Hardware audit - build the release zip"
Say "=============================================================="
Say ""
Say "Source: $src"
Say "Tag:    $Tag"

foreach ($p in $PAYLOAD) {
    if (-not (Test-Path (Join-Path $src $p))) { Die "missing from the repository: $p" }
}

# Stamp the zip with the commit it came from, so a coworker's copy can always be
# traced back to a known version.
$commit = 'unknown'
$dirty  = $false
try {
    Push-Location $src
    $commit = (& git rev-parse --short HEAD 2>$null)
    if (& git status --porcelain 2>$null) { $dirty = $true }
    Pop-Location
} catch { Warn "could not read git state" }

if ($dirty) {
    Warn "the repository has uncommitted changes"
    Warn "commit and push first, or the zip will not match anything on GitHub"
} else {
    Ok "repository is clean at commit $commit"
}

# ---------------------------------------------------------------- iso
$tries = @()
if ($IsoPath) { $tries += $IsoPath }
$tries += (Join-Path $src "images\$ISO_NAME")
foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue |
                 Where-Object { $_.FileSystemLabel -eq 'BLANCCO' -and $_.DriveLetter })) {
    $tries += "$($v.DriveLetter):\images\$ISO_NAME"
}
$isoSrc = $null
foreach ($p in $tries) { if ($p -and (Test-Path $p)) { $isoSrc = $p; break } }
if (-not $isoSrc) {
    Die ("cannot find $ISO_NAME.`n" +
         "  Looked in: " + ($tries -join ', ') + "`n" +
         "  Plug in a Blancco stick that has it, or pass -IsoPath.")
}
Info "ISO source: $isoSrc"
Info "verifying it (takes a moment)"
if ((Get-Sha $isoSrc) -ne $ISO_SHA) { Die "ISO hash does not match - do not ship it." }
Ok "ISO hash matches"

# ---------------------------------------------------------------- stage
$dist  = Join-Path $src 'dist'
$stage = Join-Path $dist 'hwaudit-usb'
$zip   = Join-Path $dist "hwaudit-usb-$Tag.zip"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$null = New-Item -ItemType Directory -Path $stage -Force

Say ""
Say "Staging..."
foreach ($p in $PAYLOAD) {
    $s = Join-Path $src $p
    if (Test-Path $s -PathType Container) { Copy-Item $s (Join-Path $stage $p) -Recurse -Force }
    else { Copy-Item $s (Join-Path $stage $p) -Force }
    Ok "staged $p"
}

$null = New-Item -ItemType Directory -Path (Join-Path $stage 'images') -Force
Info "copying the ISO into the staging folder (1.4 GB)"
Copy-Item $isoSrc (Join-Path $stage "images\$ISO_NAME") -Force
Ok "staged $ISO_NAME"

$readme = @(
    "Hardware audit tool for the Blancco USB stick"
    "============================================="
    ""
    "Version   : $Tag"
    "Commit    : $commit$(if ($dirty) { '  (BUILT WITH UNCOMMITTED CHANGES)' } else { '' })"
    "Built     : $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $env:USERNAME"
    ""
    "TO INSTALL ONTO YOUR BLANCCO STICK"
    ""
    "  1. Plug your Blancco stick into this PC."
    "  2. Double-click  install.cmd  in this folder."
    "  3. Wait for it to say Done. Copying the 1.4 GB ISO is the slow part."
    "  4. Use Safely Remove Hardware before unplugging."
    ""
    "IF WINDOWS BLOCKS IT"
    ""
    "  You downloaded this from the internet, so Windows may refuse to run it."
    "  Right-click the ZIP you downloaded, choose Properties, tick Unblock at"
    "  the bottom, click OK - then extract it again."
    ""
    "WHAT IT DOES"
    ""
    "  It adds a hardware audit option to your stick's boot menu. It does not"
    "  format anything, and it leaves Blancco's own boot entries alone. It will"
    "  refuse to touch a drive that is not a Blancco stick."
    ""
    "  When you boot from the stick afterwards, pick:"
    "    Hardware audit - specs + SMART, no license used"
    "      -> Collect hardware report to USB [auto]"
    ""
    "  Secure Boot must be OFF on the machine you are auditing."
    ""
    "  Results are appended to \specs\reports.txt on the stick."
    ""
    "Full detail is in README.md."
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $stage 'READ ME FIRST.txt'), $readme + "`r`n", $utf8NoBom)
Ok "wrote 'READ ME FIRST.txt'"

# ---------------------------------------------------------------- zip
Say ""
Info "compressing - this takes a few minutes"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Fastest, not Optimal: the ISO is already compressed, so squeezing it harder
# costs minutes and saves almost nothing.
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stage, $zip, [System.IO.Compression.CompressionLevel]::Fastest, $true)
Ok "built $(Split-Path $zip -Leaf)"

Remove-Item $stage -Recurse -Force

$size = (Get-Item $zip).Length
Say ""
Say "Verifying the zip..."
Add-Type -AssemblyName System.IO.Compression
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
$names   = $archive.Entries | ForEach-Object { $_.FullName }
$archive.Dispose()
$problems = @()
foreach ($want in @('hwaudit-usb/install.cmd', 'hwaudit-usb/install-to-stick.ps1',
                    'hwaudit-usb/READ ME FIRST.txt', 'hwaudit-usb/hwaudit/collect.sh',
                    "hwaudit-usb/images/$ISO_NAME")) {
    if ($names -notcontains $want) { $problems += "missing from the zip: $want" }
}
$camInZip = @($names | Where-Object { $_ -like 'hwaudit-usb/hwaudit/camera/*.pkg.tar.zst' }).Count
if ($camInZip -ne 6) { $problems += "expected 6 camera packages in the zip, found $camInZip" }
else { Ok "6 camera packages in the zip" }

if ($problems.Count -eq 0) { Ok "zip contents check out ($($names.Count) entries)" }

if ($size -gt $GH_LIMIT) {
    $problems += ("zip is {0:N2} GB - over GitHub's 2 GB per-file release limit" -f ($size / 1GB))
}

Say ""
if ($problems.Count -gt 0) {
    Say "  Finished with problems:"
    foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Red }
    Say ""
    exit 1
}

Say "=============================================================="
Say (" Built: {0}" -f $zip)
Say (" Size:  {0:N2} GB   (GitHub allows 2 GB per release file)" -f ($size / 1GB))
Say "=============================================================="
Say ""
Say " Upload it:"
Say ""
Say "   1. Go to your repo on github.com"
Say "   2. Releases  ->  Draft a new release"
Say "   3. Choose a tag: type  $Tag  and pick 'Create new tag'"
Say "   4. Drag the zip above into the attachment box"
Say "   5. Publish release"
Say ""
Say " Coworkers then download it from the Releases page, extract, and"
Say " double-click install.cmd."
Say ""
Say " The repo is private, so they must be collaborators on it to"
Say " download - add them under Settings -> Collaborators."
Say ""
