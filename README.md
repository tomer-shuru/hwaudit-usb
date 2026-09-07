# Hardware audit for the Blancco USB stick

A license-free hardware audit and diagnostics tool that rides along on a Blancco
Drive Eraser boot USB.

## Why it exists

Blancco Drive Eraser consumes a paid license for **any** report it saves or sends.
An erasure report costs an erasure license; a hardware-only report is treated as an
"asset report" and costs an asset license. There is no license-free export — the
only free artifact is the Issue Report (F3), which is encrypted and readable only
by Blancco staff.

So this tool collects specs and diagnostics **without booting Blancco at all**. It
adds a second boot entry to the same stick that boots SystemRescue 13.02 and runs
its own collector and diagnostics app. Blancco's own menu entries are untouched,
and `set default=bde_flr` still boots Blancco unattended.

## Installing onto a stick

The stick must already be a working Blancco Drive Eraser USB. This adds to one; it
does not create one.

1. Plug the stick in.
2. Double-click **`install.cmd`**.

That's it. It finds the connected `BLANCCO` volume, copies everything, generates
`\autorun`, and splices the audit menu into that stick's own `grub.cfg`.

Options, if you need them:

```powershell
.\install-to-stick.ps1 -DryRun                 # show what would happen, write nothing
.\install-to-stick.ps1 -Target F:\             # more than one stick plugged in
.\install-to-stick.ps1 -IsoPath D:\images\systemrescue-13.02-amd64.iso
```

It is safe to re-run. It replaces its own menu block rather than appending a second
copy, keeps the untouched original as `grub.cfg.bak-before-hwaudit`, and takes a
timestamped backup on every run. It refuses to touch a volume that is not a Blancco
stick, and verifies everything it wrote before reporting success.

### You need the SystemRescue ISO

`systemrescue-13.02-amd64.iso` is **not in this repository** — 1.4 GB, and not ours
to redistribute. The installer looks for it in this order:

1. `-IsoPath` if you passed one
2. `images\` next to the installer
3. the target stick (if it already has it, it is verified and left alone)
4. any other connected `BLANCCO` stick

The easiest route for a coworker: plug in a stick that already has the tool
alongside the new one, and the installer copies it across.

Otherwise download it from <https://www.system-rescue.org/Download/> and drop it in
`images\`. It must be this exact build:

```
SHA256  ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572
```

The installer checks that hash before and after copying and refuses to proceed on a
mismatch.

## Using it

Boot the target machine from the stick. **Secure Boot must be off** — Blancco's
signed shim only trusts Blancco-signed kernels, so SystemRescue otherwise fails with
"bad shim signature".

Pick **Hardware audit - specs + SMART, no license used**, then:

| Entry | When |
|---|---|
| Collect hardware report to USB **[auto]** | normal |
| **[low RAM, no copytoram]** | machine has little RAM |
| **[basic display]** | black or broken screen on the auto entry |
| SystemRescue shell only | troubleshooting |

The script reads the hardware, launches a graphical app for the screen, keyboard,
mouse, speaker, webcam and WiFi tests, you type a diagnosis, and it appends one line
to `\specs\reports.txt` on the stick.

**Machines are audited with their drives already pulled.** `Disk Capacity = NONE` is
the normal, expected result, not a detection bug.

## Output

`\specs\reports.txt`, append-only, `*` separated so it pastes straight into Excel:

```
Item*S.N*Asset Tag*Type*Make*Model*CPU*RAM*Disk Capacity*Battery Health*Diagnostics
```

Notes on individual fields:

- **RAM** is formatted `16 GB DDR4`, `16 GB x2 DDR4`, `8 GB + 16 GB DDR4`.
- **Battery Health** is last-full-charge ÷ design capacity. A reading of exactly
  100% means the pack reports its full charge *as* its design capacity — it is not
  tracking wear. Where ACPI does that, design capacity is taken from SMBIOS type 22
  instead, which matches what Blancco reports.
- **Model** on Lenovo comes from DMI `system-version`, not `system-product-name`.
  Lenovo puts the MTM machine code (`30BFS44D0P`) in Product Name and the name on
  the sticker (`ThinkStation P520`) in Version. Other vendors are read normally.
- **Diagnostics** is the free-text diagnosis you type, plus any test that failed.
  Webcam failures are suppressed on desktop and tower chassis, which have no
  built-in camera — all-in-ones and laptops still report them.

## Making changes

**Always edit `hwaudit/collect.sh`.** `\autorun` on the stick is a generated copy —
it is the file SystemRescue actually runs, and editing it directly means your change
is lost on the next install. The installer regenerates it and forces LF endings; a
CRLF in that file breaks the shebang and the stick boots to nothing.

After editing, re-run `install.cmd` against each stick.

Every test costs a full reboot on real hardware. Before deploying:

- Check the ISO's own `\sysresccd\PKGLIST_X86_64.TXT` to confirm a binary exists
  rather than assuming it does.
- `bash -n` the script.
- **Debug from the logs on the stick, not from theories.** `\specs\gui.log` and
  `\specs\last-run.log` are written on every boot and usually contain the exact
  error already.

## What is in here

```
hwaudit/collect.sh              the collector - the master copy, edit this
hwaudit/app/index.html          the diagnostics GUI (vanilla JS, no external assets)
hwaudit/app/server.py           localhost HTTP server; getUserMedia needs a secure
                                context, and file:// is not one
hwaudit/firmware/               Arch sof-firmware, extracted at runtime on Intel SOF
                                machines that otherwise report no sound card
hwaudit/camera/                 libcamera + SDL packages for MIPI/IPU6 laptops
                                (Dell Latitude 7440/7450, Meteor Lake). Only used
                                when the camera probe returns CAM_KIND=mipi.
boot/grub/hwaudit-menu.cfg      the menu block spliced into each stick's grub.cfg
install-to-stick.ps1            the installer
install.cmd                     double-click wrapper for it
```

Deliberately **not** in here:

- `images/` — the ISOs. Too big for git, and not ours to redistribute.
- `specs/` — audit output. Contains customer serial numbers and asset tags and must
  never reach a repository.
- `autorun` — generated from `collect.sh` at install time.

## Chromebooks

Chromebooks cannot boot this stick and it is not worth forcing. They run coreboot +
depthcharge, which only boots ChromeOS-signed kernel partitions, and ARM models are
out regardless since SystemRescue 13.02 is amd64 only. They are audited by a separate
Developer Mode shell script (`cbaudit.sh`), which is not part of this repository.
