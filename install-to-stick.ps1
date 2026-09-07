<#
.SYNOPSIS
    Installs the license-free hardware audit tool onto a Blancco Drive Eraser USB stick.

.DESCRIPTION
    Copies the collector, the diagnostics app and the carried packages onto a
    stick that already holds Blancco Drive Eraser, generates \autorun from
    collect.sh with Unix line endings, and splices the "Hardware audit" menu
    into the stick's own grub.cfg without touching Blancco's entries.

    Safe to re-run: it replaces its own menu block rather than appending a
    second copy, and keeps the untouched original as grub.cfg.bak-before-hwaudit.

.PARAMETER Target
    Root of the stick, e.g. F:\ . Omit it and the only connected BLANCCO stick
    is used.

.PARAMETER IsoPath
    Path to systemrescue-13.02-amd64.iso. Omit it and the script looks in
    .\images\, then on the target, then on any other connected BLANCCO stick.

.PARAMETER DryRun
    Report what would happen and write nothing.

.EXAMPLE
    .\install-to-stick.ps1
.EXAMPLE
    .\install-to-stick.ps1 -Target F:\ -IsoPath D:\images\systemrescue-13.02-amd64.iso
#>
param(
    [string]$Target,
    [string]$IsoPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$ISO_NAME = 'systemrescue-13.02-amd64.iso'
$ISO_SHA  = 'AD4D670B72859D887C7960142A9A9D36A3E50446694A035E254442F65D6E7572'
$ISO_URL  = 'https://www.system-rescue.org/Download/'
$MARKER   = '### Hardware audit - SystemRescue 13.02'

$src       = $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$problems  = @()

function Say  { param($m) Write-Host $m }
function Ok   { param($m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function Info { param($m) Write-Host "  [ .. ]  $m" -ForegroundColor Gray }
function Warn { param($m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host ""; Write-Host "  FAILED: $m" -ForegroundColor Red; Write-Host ""; exit 1 }
function Get-Sha { param($p) (Get-FileHash -Path $p -Algorithm SHA256).Hash }

Say ""
Say "=============================================================="
Say " Hardware audit - install to a Blancco USB stick"
if ($DryRun) { Say " DRY RUN - nothing will be written" }
Say "=============================================================="
Say ""

# ---------------------------------------------------------------- source check
Say "Source: $src"
foreach ($f in @('hwaudit\collect.sh', 'hwaudit\app\index.html', 'hwaudit\app\server.py',
                 'hwaudit\firmware\sof-firmware.pkg.tar.zst', 'boot\grub\hwaudit-menu.cfg')) {
    if (-not (Test-Path (Join-Path $src $f))) {
        Die "source file missing: $f`n  Is this script sitting in the repository folder?"
    }
}
$camCount = @(Get-ChildItem (Join-Path $src 'hwaudit\camera') -Filter '*.pkg.tar.zst' -ErrorAction SilentlyContinue).Count
if ($camCount -lt 6) { Die "expected 6 camera packages in hwaudit\camera, found $camCount" }
Ok "source tree complete ($camCount camera packages)"

# ---------------------------------------------------------------- pick the stick
try { $srcLetter = (Split-Path -Qualifier $src).TrimEnd(':') } catch { $srcLetter = '' }

if (-not $Target) {
    $cands = @(Get-Volume -ErrorAction SilentlyContinue |
               Where-Object { $_.FileSystemLabel -eq 'BLANCCO' -and $_.DriveLetter })
    if ($cands.Count -eq 0) {
        Die "no volume labelled BLANCCO is connected.`n  Plug the stick in, or pass -Target F:\"
    }
    if ($cands.Count -gt 1) {
        Say "  More than one BLANCCO stick is connected:"
        foreach ($c in $cands) { Say ("    {0}:  {1:N1} GB free" -f $c.DriveLetter, ($c.SizeRemaining / 1GB)) }
        Die "pass the one you mean, e.g. -Target $($cands[0].DriveLetter):\"
    }
    $Target = "$($cands[0].DriveLetter):\"
    Info "auto-detected the only BLANCCO stick"
}

$T = $Target.TrimEnd('\') + '\'
if (-not (Test-Path $T)) { Die "target not found: $T" }

try { $tgtLetter = (Split-Path -Qualifier $T).TrimEnd(':') } catch { $tgtLetter = '' }

# Prove it really is a Blancco stick before writing to it.
if (-not (Test-Path (Join-Path $T 'boot\grub\grub.cfg'))) {
    Die "$T has no \boot\grub\grub.cfg - that is not a Blancco stick."
}
if (-not @(Get-ChildItem (Join-Path $T 'images') -Filter 'bde_volume*.iso' -ErrorAction SilentlyContinue)) {
    Die "$(Join-Path $T 'images') has no bde_volume*.iso - that is not a Blancco stick.`n  This installer adds to a Blancco stick, it does not create one."
}
if ($tgtLetter -and $srcLetter -and ($tgtLetter -eq $srcLetter)) {
    Die "target and repository are on the same drive ($T). Keep the repository off the stick."
}
Say "Target: $T"
Ok "confirmed Blancco stick"

# ---------------------------------------------------------------- locate the ISO
$tgtIso   = Join-Path $T "images\$ISO_NAME"
$needCopy = $true
$isoSrc   = $null

if (Test-Path $tgtIso) {
    Info "target already has $ISO_NAME - verifying (takes a moment)"
    if ((Get-Sha $tgtIso) -eq $ISO_SHA) {
        Ok "ISO already present and correct"
        $needCopy = $false
    } else {
        Warn "ISO on the stick has the wrong hash - it will be replaced"
    }
}

if ($needCopy) {
    $tries = @()
    if ($IsoPath) { $tries += $IsoPath }
    $tries += (Join-Path $src "images\$ISO_NAME")
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue |
                     Where-Object { $_.FileSystemLabel -eq 'BLANCCO' -and $_.DriveLetter -and $_.DriveLetter -ne $tgtLetter })) {
        $tries += "$($v.DriveLetter):\images\$ISO_NAME"
    }
    foreach ($p in $tries) { if ($p -and (Test-Path $p)) { $isoSrc = $p; break } }

    if (-not $isoSrc) {
        Die ("cannot find $ISO_NAME.`n" +
             "  Looked in: " + ($tries -join ', ') + "`n`n" +
             "  It is deliberately not in the repository (1.4 GB, and not ours to`n" +
             "  redistribute). Copy it from another BLANCCO stick, or download it from`n" +
             "  $ISO_URL and drop it in:  " + (Join-Path $src 'images') + "`n" +
             "  Expected SHA256: $ISO_SHA")
    }
    Info "ISO source: $isoSrc"
    Info "verifying source ISO"
    if ((Get-Sha $isoSrc) -ne $ISO_SHA) {
        Die "source ISO hash does not match - do not use it.`n  Expected $ISO_SHA"
    }
    Ok "source ISO hash matches"

    $need = (Get-Item $isoSrc).Length + 20MB
    $free = (Get-Volume -DriveLetter $tgtLetter).SizeRemaining
    if ($free -lt $need) {
        Die ("not enough room on {0}: need {1:N1} GB, {2:N1} GB free" -f $T, ($need / 1GB), ($free / 1GB))
    }
}

# ---------------------------------------------------------------- write
Say ""
Say "Installing..."

if ($DryRun) {
    Info "would copy  hwaudit\  ->  ${T}hwaudit\"
    if ($needCopy) { Info "would copy  $ISO_NAME  ->  ${T}images\" }
    Info "would write ${T}autorun from hwaudit\collect.sh (LF, no BOM)"
    Info "would splice the audit menu into ${T}boot\grub\grub.cfg"
    Info "would create ${T}specs\"
    Say ""
    Say "Dry run complete - nothing was written."
    exit 0
}

# app, camera packages, firmware, and the readable master copy of the collector
$null = New-Item -ItemType Directory -Path (Join-Path $T 'hwaudit') -Force
Copy-Item (Join-Path $src 'hwaudit\*') (Join-Path $T 'hwaudit') -Recurse -Force
Ok "copied hwaudit\"

if ($needCopy) {
    $null = New-Item -ItemType Directory -Path (Join-Path $T 'images') -Force
    Info "copying the ISO (1.4 GB - this is the slow part)"
    Copy-Item $isoSrc $tgtIso -Force
    Ok "copied $ISO_NAME"
}

# \autorun is the copy SystemRescue actually runs. Generate it from collect.sh
# so there is one source of truth, and force LF - a CRLF here breaks the
# shebang and the stick boots to nothing.
$sh = [IO.File]::ReadAllText((Join-Path $src 'hwaudit\collect.sh'))
$sh = $sh.Replace("`r`n", "`n").Replace("`r", "`n")
[IO.File]::WriteAllText((Join-Path $T 'autorun'), $sh, $utf8NoBom)
Ok "wrote \autorun from collect.sh"

# Splice our menu block into the stick's own grub.cfg. Blancco's entries and
# its "set default" are never touched.
$g    = Join-Path $T 'boot\grub\grub.cfg'
$bak  = Join-Path $T 'boot\grub\grub.cfg.bak-before-hwaudit'
$orig = [IO.File]::ReadAllText($g)
if (-not (Test-Path $bak)) {
    Copy-Item $g $bak
    Info "kept the untouched original as grub.cfg.bak-before-hwaudit"
}
Copy-Item $g (Join-Path $T ("boot\grub\grub.cfg.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')))

$idx = $orig.IndexOf($MARKER)
if ($idx -ge 0) {
    $base = $orig.Substring(0, $idx)
    Info "replacing the existing audit menu"
} else {
    $base = $orig
}
$block  = [IO.File]::ReadAllText((Join-Path $src 'boot\grub\hwaudit-menu.cfg')).Replace("`r`n", "`n").Replace("`r", "`n")
$newCfg = $base.TrimEnd("`r", "`n") + "`n`n" + $block
[IO.File]::WriteAllText($g, $newCfg, $utf8NoBom)
Ok "spliced the audit menu into grub.cfg"

$null = New-Item -ItemType Directory -Path (Join-Path $T 'specs') -Force
Ok "ensured \specs\ exists"

# FAT32 caches writes; push them out before anyone pulls the stick.
try {
    Write-VolumeCache -DriveLetter $tgtLetter -ErrorAction Stop
    Ok "flushed write cache"
} catch {
    Warn "could not flush the write cache - use Safely Remove Hardware before unplugging"
}

# ---------------------------------------------------------------- verify
Say ""
Say "Verifying what is actually on the stick..."

$auto = Join-Path $T 'autorun'
if (-not (Test-Path $auto)) {
    $problems += "\autorun is missing"
} else {
    $bytes = [IO.File]::ReadAllBytes($auto)
    if ($bytes -contains 13) { $problems += "\autorun contains CR - the shebang will not run" }
    else { Ok "\autorun has Unix line endings" }
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 35 -or $bytes[1] -ne 33) { $problems += "\autorun does not start with a shebang" }
    else { Ok "\autorun starts with #!" }
}

foreach ($f in @('hwaudit\collect.sh', 'hwaudit\app\index.html', 'hwaudit\app\server.py',
                 'hwaudit\firmware\sof-firmware.pkg.tar.zst')) {
    if (-not (Test-Path (Join-Path $T $f))) { $problems += "missing on stick: $f" }
}
$n = @(Get-ChildItem (Join-Path $T 'hwaudit\camera') -Filter '*.pkg.tar.zst' -ErrorAction SilentlyContinue).Count
if ($n -ne 6) { $problems += "expected 6 camera packages on the stick, found $n" } else { Ok "6 camera packages present" }

if (-not (Test-Path $tgtIso)) {
    $problems += "$ISO_NAME missing from \images"
} else {
    if ((Get-Sha $tgtIso) -ne $ISO_SHA) { $problems += "$ISO_NAME on the stick fails its hash check" }
    else { Ok "ISO verified on the stick" }
}

$after = [IO.File]::ReadAllText($g)
if ($after -notmatch [regex]::Escape($MARKER)) { $problems += "grub.cfg has no audit menu" } else { Ok "grub.cfg carries the audit menu" }
if ($after -notmatch '--id=hwaudit') { $problems += "grub.cfg is missing the hwaudit entry" }
if ($after -notmatch 'bde_volume') { $problems += "grub.cfg no longer mentions Blancco - restore grub.cfg.bak-before-hwaudit" }
else { Ok "Blancco's own entries are intact" }

Say ""
if ($problems.Count -gt 0) {
    Say "  Finished with problems:"
    foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Red }
    Say ""
    exit 1
}

Say "=============================================================="
Say " Done. $T is ready."
Say "=============================================================="
Say ""
Say " Use Safely Remove Hardware, then boot the target machine from"
Say " the stick and pick:"
Say ""
Say "   Hardware audit - specs + SMART, no license used"
Say "     -> Collect hardware report to USB [auto]"
Say ""
Say " Results are appended to \specs\reports.txt on the stick."
Say " Secure Boot must be OFF on the machine being audited."
Say ""
