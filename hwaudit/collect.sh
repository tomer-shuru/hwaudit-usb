#!/bin/bash
# Hardware audit + graphical diagnostics. Consumes no Blancco licenses.
#
# Boots -> asks for Item / Asset tag on the console -> reads the hardware ->
# launches a graphical diagnostics app (X + Firefox) for screen, keyboard,
# mouse, speakers and webcam -> appends one * separated line per machine to
# \specs\reports.txt.
#
# KEEP_RAW=1 also dumps the full raw hardware files.
# FORCE_CONSOLE=1 skips the GUI and uses the text-mode tests.
KEEP_RAW=0
DEBUG=0
FORCE_CONSOLE=0
PORT=8731

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DATE_LOCAL="$(date '+%Y-%m-%d %H:%M')"
WORK=/tmp/hwaudit
RUN=/tmp/hwaudit-run          # logs + staged files, in RAM. NOT under $WORK,
RES="$WORK/results.json"       # which gets rm -rf'd before the app starts.

TTY=/dev/tty
[ -r "$TTY" ] && [ -w "$TTY" ] || TTY=""
ask() { local __v="$1"; shift; local __r=""
    if [ -n "$TTY" ]; then read -r -p "$*" __r <"$TTY" >"$TTY" 2>&1; else read -r -p "$*" __r; fi
    printf -v "$__v" '%s' "$__r"; }
anykey() { if [ -n "$TTY" ]; then read -rsn1 -p "${1:-Press any key...}" <"$TTY" >"$TTY" 2>&1
    else read -rsn1 -p "${1:-Press any key...}"; fi; echo; }
banner() { echo; echo "================================================================"; echo " $*"
    echo "================================================================"; }

# Silence: no terminal bell, no PC speaker. Between them they beep at the
# operator during boot for no useful reason - the only sound this tool should
# make is the one the Speakers tab plays deliberately.
[ -n "$TTY" ] && setterm --blength 0 >"$TTY" 2>/dev/null
modprobe -r pcspkr 2>/dev/null

# ======================================================================
# 1. USB
# ======================================================================
banner "Hardware audit  -  $DATE_LOCAL"

DEV="$(readlink -f /dev/disk/by-label/BLANCCO 2>/dev/null)"
if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    mkdir -p /mnt/_scan
    for p in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
        if mount -o ro "$p" /mnt/_scan 2>/dev/null; then
            if [ -d /mnt/_scan/images ] && ls /mnt/_scan/images/bde_volume* >/dev/null 2>&1; then
                umount /mnt/_scan; DEV="$p"; break
            fi
            umount /mnt/_scan
        fi
    done
fi
[ -b "$DEV" ] || { echo "ERROR: BLANCCO USB not found."; anykey; exit 1; }

# Do NOT adopt whatever mountpoint happens to exist already. SystemRescue's
# autorun framework mounts the stick at /var/autorun/mnt for its own use and
# takes that mountpoint away again while this script is still running. Every
# write then failed with "No such file or directory", the app directory went
# MISSING, the SOF firmware could not be read (so no sound card), and the run
# ended in text mode having saved nothing. Mount the stick ourselves, on a
# mountpoint only this script owns, and re-mount it whenever it disappears.
MNT=/mnt/usbaudit

# True only if the stick is really there AND writable - the read-only case
# looks identical until the first write fails.
usb_rw() {
    [ -d "$MNT/hwaudit/app" ] || return 1
    mkdir -p "$MNT/specs" 2>/dev/null || return 1
    : >"$MNT/specs/.wtest" 2>/dev/null || return 1
    rm -f "$MNT/specs/.wtest" 2>/dev/null
    return 0
}

mount_usb() {
    usb_rw && return 0
    # The device node can change between boots, so resolve it again.
    local d; d="$(readlink -f /dev/disk/by-label/BLANCCO 2>/dev/null)"
    [ -b "$d" ] && DEV="$d"
    mkdir -p "$MNT" 2>/dev/null
    umount "$MNT" 2>/dev/null                    # clear a dead mount
    mount -o rw,sync "$DEV" "$MNT" 2>/dev/null || mount -o rw "$DEV" "$MNT" 2>/dev/null
    if ! usb_rw; then
        # Someone else still holds the device read-only, so a second rw mount
        # is refused: bind their mountpoint instead and remount that rw. A
        # bind survives the original being (lazily) unmounted underneath it.
        local other
        other="$(findmnt -rn -o TARGET -S "$DEV" 2>/dev/null | grep -v "^${MNT}$" | head -n1)"
        [ -n "$other" ] && mount --bind "$other" "$MNT" 2>/dev/null
        mount -o remount,rw,sync "$MNT" 2>/dev/null || mount -o remount,rw "$MNT" 2>/dev/null
    fi
    usb_rw
}

# Call this before touching the stick. Fails only if it is really gone.
ensure_usb() {
    usb_rw && return 0
    local t
    for t in 1 2 3; do
        mount_usb && return 0
        sleep 2
    done
    return 1
}

mount_usb || { echo "ERROR: cannot mount the BLANCCO stick ($DEV) read-write."
    findmnt -rn -o SOURCE,TARGET,OPTIONS 2>/dev/null | head -n 10
    anykey; exit 1; }

# Logs are written in RAM and copied to the stick at the end. A stick that
# vanishes mid-run can then never break the run itself.
mkdir -p "$RUN"
LOG="$RUN/last-run.log"
GUILOG="$RUN/gui.log"
: >"$LOG"; : >"$GUILOG"
echo "[$STAMP] started dev=$DEV mnt=$MNT" >>"$LOG"

# Copy everything we need off the stick right now, while we know it is there:
# the app and the SOF firmware package. After this the run does not depend on
# the stick again until the report is saved.
STAGE="$RUN/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "$MNT/hwaudit/app" "$STAGE/app" 2>>"$LOG"
cp -a "$MNT/hwaudit/firmware/sof-firmware.pkg.tar.zst" "$STAGE/" 2>>"$LOG"
cp -a "$MNT/hwaudit/camera" "$STAGE/camera" 2>/dev/null   # optional, MIPI machines only
sync
echo "USB ready: $DEV on $MNT"
echo "  staged: app=$( [ -f "$STAGE/app/index.html" ] && echo ok || echo MISSING )" \
     "firmware=$( [ -f "$STAGE/sof-firmware.pkg.tar.zst" ] && echo ok || echo MISSING )" \
     "camera=$( ls "$STAGE"/camera/*.pkg.tar.zst >/dev/null 2>&1 && echo ok || echo none )"

# Append the in-RAM logs to the stick. Safe to call at any point.
flush_logs() {
    ensure_usb || return 1
    [ -s "$GUILOG" ] && cat "$GUILOG" >>"$MNT"/specs/gui.log 2>/dev/null && : >"$GUILOG"
    [ -s "$LOG" ]    && cat "$LOG"    >>"$MNT"/specs/last-run.log 2>/dev/null && : >"$LOG"
    [ -f "$RUN/Xorg.0.log" ] && cp "$RUN/Xorg.0.log" "$MNT/specs/Xorg.0.log" 2>/dev/null
    [ -f "$RUN/trace.log" ] && cp "$RUN/trace.log" "$MNT/specs/trace.log" 2>/dev/null
    sync
    return 0
}

if [ "$DEBUG" = "1" ]; then exec 19>>"$RUN/trace.log"; export BASH_XTRACEFD=19
    export PS4='+ ${LINENO}: '; set -x; fi
trap 'rc=$?; set +x; echo "[$STAMP] exited status=$rc" >>"$LOG"; flush_logs; sync' EXIT

# Item and asset tag are entered in the app. Only the text-mode fallback
# asks for them on the console.
ITEM=""; ASSET_TAG=""

# ======================================================================
# 2. Specs
# ======================================================================
echo; echo "Reading hardware..."
MAKE="$(dmidecode -s system-manufacturer 2>/dev/null | head -n1)"
MODEL="$(dmidecode -s system-product-name 2>/dev/null | head -n1)"
SERIAL="$(dmidecode -s system-serial-number 2>/dev/null | head -n1)"
TYPE="$(dmidecode -s chassis-type 2>/dev/null | head -n1)"
BIOSV="$(dmidecode -s bios-version 2>/dev/null | head -n1)"

# A desktop or tower has no built-in webcam, so "webcam: FAILED: NotFoundError"
# is the expected result on one, not a fault. It must not reach the Diagnostics
# column, where it reads like a defect on the spreadsheet. All-in-ones and every
# portable chassis do have a camera, so those keep reporting failures normally.
case "$TYPE" in
    Desktop|"Low Profile Desktop"|"Mini Tower"|Tower|"Space-saving"|"Pizza Box"|\
    "Lunch Box"|"Sealed-case PC"|"Mini PC"|"Stick PC"|"Rack Mount Chassis"|\
    "Main Server Chassis"|Blade) SUPPRESS_CAM=1 ;;
    *)                           SUPPRESS_CAM=0 ;;
esac
CPU="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n1)"
THREADS="$(nproc --all 2>/dev/null)"
[ -n "$SERIAL" ] || SERIAL="unknown"

# Lenovo puts the marketing name ("ThinkStation P520", "ThinkPad T480s") in the
# DMI *Version* field and leaves Product Name as the MTM machine code
# ("30BFS44D0P"). The MTM means nothing on an audit sheet and does not match the
# sticker, so prefer the real name. Family and the tail of the SKU number are
# second and third sources - some boards leave Version empty. Every other vendor
# already puts the name in Product Name, so only Lenovo is remapped.
dmi_sane() {   # reject the placeholder junk DMI is full of
    case "$1" in
        ""|[Nn]one|"Not Available"|"Not Specified"|"Default string"|"INVALID"|\
        "To be filled by O.E.M."|"To Be Filled By O.E.M."|"System Product Name"|\
        "Lenovo Product") return 1 ;;
    esac
    return 0
}
is_mtm() {     # a second machine code is no better than the first
    printf '%s' "$1" | grep -qE '^[0-9]{2}[A-Za-z0-9]{2,}$'
}

MODEL_MTM=""
case "$MAKE" in
    [Ll][Ee][Nn][Oo][Vv][Oo]*)
        # SKU reads LENOVO_MT_30BF_BU_Think_FM_ThinkStation P520 - the friendly
        # name is whatever follows the last _FM_ marker.
        for cand in "$(dmidecode -s system-version    2>/dev/null | head -n1)" \
                    "$(dmidecode -s system-family     2>/dev/null | head -n1)" \
                    "$(dmidecode -s system-sku-number 2>/dev/null | head -n1 | sed 's/.*_FM_//')"
        do
            dmi_sane "$cand" || continue
            is_mtm "$cand" && continue
            MODEL_MTM="$MODEL"; MODEL="$cand"; break
        done
        ;;
esac

# Log the raw identity fields on every machine, whatever the vendor. When a
# model comes out wrong the answer is in here, not in a theory.
{
    echo "[$STAMP] dmi identity"
    echo "  manufacturer : $MAKE"
    echo "  product-name : $(dmidecode -s system-product-name 2>/dev/null | head -n1)"
    echo "  version      : $(dmidecode -s system-version      2>/dev/null | head -n1)"
    echo "  family       : $(dmidecode -s system-family       2>/dev/null | head -n1)"
    echo "  sku-number   : $(dmidecode -s system-sku-number   2>/dev/null | head -n1)"
    echo "  -> MODEL     : $MODEL${MODEL_MTM:+   (MTM $MODEL_MTM)}"
} >>"$GUILOG" 2>&1
# Flushed straight away: the identity is the one thing worth having even if the
# operator powers off right after the specs appear.
flush_logs

# Read each populated memory slot as "<megabytes>|<DDR generation>", so the
# report can say "16 GB DDR4" for one stick and "16 GB x2 DDR4" for two.
TMPR="/tmp/ram.$$"
dmidecode -t memory 2>/dev/null | awk '
/^Memory Device/           { inblk=1; sz=""; un=""; ty=""; next }
inblk && /^[ \t]*Size:[ \t]+[0-9]+/      { sz=$2; un=$3 }
inblk && /^[ \t]*Type:[ \t]/             { ty=$2 }
inblk && /^[ \t]*$/        { if (sz!="") { print ((un ~ /^G/) ? sz*1024 : sz) "|" ty } inblk=0 }
END                        { if (inblk && sz!="") { print ((un ~ /^G/) ? sz*1024 : sz) "|" ty } }
' >"$TMPR"

RAM_MB=0; RAM_SIZES=""; RAM_TYPE=""; RAM_COUNT=0
while IFS='|' read -r mb ty; do
    [ -z "$mb" ] && continue
    RAM_MB=$((RAM_MB + mb))
    RAM_COUNT=$((RAM_COUNT + 1))
    RAM_SIZES="$RAM_SIZES $((mb / 1024))"
    if [ -z "$RAM_TYPE" ] && [ -n "$ty" ] && [ "$ty" != "Unknown" ]; then RAM_TYPE="$ty"; fi
done <"$TMPR"; rm -f "$TMPR"

if [ "$RAM_COUNT" -eq 0 ]; then
    RAM="unknown"
else
    RAM_FIRST=""; RAM_SAME=1
    for s in $RAM_SIZES; do
        [ -z "$RAM_FIRST" ] && RAM_FIRST="$s"
        [ "$s" != "$RAM_FIRST" ] && RAM_SAME=0
    done
    if [ "$RAM_SAME" -eq 1 ]; then
        RAM="${RAM_FIRST} GB"
        [ "$RAM_COUNT" -gt 1 ] && RAM="${RAM_FIRST} GB x${RAM_COUNT}"
    else
        # Mixed sizes: list them, e.g. "8 GB + 16 GB DDR4"
        RAM="$(echo $RAM_SIZES | sed 's/ / GB + /g') GB"
    fi
    [ -n "$RAM_TYPE" ] && RAM="$RAM $RAM_TYPE"
fi
RAM_DETAIL="$(dmidecode -t memory 2>/dev/null | awk '/Memory Device/,0' \
    | grep -E '^[ \t]+(Size|Type|Speed|Manufacturer|Part Number):' \
    | grep -v 'No Module Installed' | sed 's/^[ \t]*/    /')"

BOOTDISK="$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -n1)"
[ -n "$BOOTDISK" ] || BOOTDISK="$(basename "$DEV" | sed 's/[0-9]*$//')"
TMPD="/tmp/disks.$$"; lsblk -dbno NAME,SIZE,MODEL 2>/dev/null >"$TMPD"
DISK_CAP=""; DISK_DETAIL=""; DISK_COUNT=0
while read -r n sz rest; do
    [ "$n" = "$BOOTDISK" ] && continue
    case "$n" in loop*|sr*|ram*) continue;; esac
    [ -z "$sz" ] && continue
    DISK_COUNT=$((DISK_COUNT+1))
    gb=$(( (sz + 500000000) / 1000000000 ))
    DISK_CAP="${DISK_CAP}${DISK_CAP:+ + }${gb} GB"
    hl="$(smartctl -H "/dev/$n" 2>/dev/null | grep -iE 'overall-health|SMART Health' | head -n1 | sed 's/.*: *//')"
    DISK_DETAIL="${DISK_DETAIL}    /dev/$n  ${gb} GB  ${rest:-unknown}  SMART: ${hl:-n/a}
"
done <"$TMPD"; rm -f "$TMPD"
if [ "$DISK_COUNT" -eq 0 ]; then
    DISK_CAP="NONE"
    if lspci -nn 2>/dev/null | grep -qi 'Volume Management Device'; then
        DISK_DETAIL="    No drive detected. Intel RST/VMD is on in BIOS - the drive was
    removed, or set the storage controller to AHCI and re-run.
"
    else DISK_DETAIL="    No internal drive detected.
"; fi
fi

# Battery health = last full charge capacity / design capacity.
#
# Read it from sysfs rather than upower: the kernel publishes the capacity
# pair as charge_* (uAh) on some machines and energy_* (uWh) on others, and
# upower only ever shows the energy form.
bat_scan() {
    BATT="N/A"; BATT_DETAIL=""; BATT_SRC="none"; BATT_CYCLES=""; BATT_RATIO=""
    local b u f d
    for b in /sys/class/power_supply/*; do
        [ -r "$b/type" ] || continue
        [ "$(cat "$b/type" 2>/dev/null)" = "Battery" ] || continue
        for u in charge energy; do
            f="$(cat "$b/${u}_full" 2>/dev/null)"
            d="$(cat "$b/${u}_full_design" 2>/dev/null)"
            case "$f" in ''|*[!0-9]*) continue;; esac
            case "$d" in ''|*[!0-9]*) continue;; esac
            [ "$d" -gt 0 ] || continue
            BATT_RATIO="$(awk -v a="$f" -v b="$d" 'BEGIN{printf "%.1f",(a/b)*100}')"
            BATT="${BATT_RATIO}%"
            BATT_SRC="$(basename "$b")/${u}_full"
            BATT_CYCLES="$(cat "$b/cycle_count" 2>/dev/null)"
            BATT_DETAIL="    ${u}_full $f of $d design ($BATT_SRC), cycles ${BATT_CYCLES:-unknown}"
            return 0
        done
    done
    return 1
}
bat_suspect() { [ -n "$BATT_RATIO" ] && awk -v r="$BATT_RATIO" 'BEGIN{exit !(r>=99.5)}'; }

bat_scan
BATT_NOTE=""

# A pack that reports its full charge as exactly its design capacity is not
# tracking wear at all - the EliteBook 840 G5 does this, and also claims zero
# charge cycles on a battery built in 2019. Its ACPI design figure is simply
# its current full charge, so every Linux tool reads 100%.
#
# SMBIOS type 22 carries the factory design capacity from a different source,
# and on that machine it is right: 50010 mWh (an HP SS03XL is a 50 Wh pack)
# against the 36.7 Wh the battery calls its design. 36.7 / 50.0 = 73%, which
# is what Blancco reports. So keep the measured full charge and take the
# design figure from SMBIOS instead.
#
# Loading the sbs/sbshc smart-battery drivers and re-reading was tried first
# and changed nothing on this machine, so it is not worth the boot time.
if bat_suspect; then
    BATT_WAS="$BATT ($BATT_SRC)"

    # Full charge in mWh, from whichever pair the kernel publishes.
    FULL_MWH=""
    for b in /sys/class/power_supply/*; do
        [ "$(cat "$b/type" 2>/dev/null)" = "Battery" ] || continue
        ef="$(cat "$b/energy_full" 2>/dev/null)"          # uWh
        cf="$(cat "$b/charge_full" 2>/dev/null)"          # uAh
        vd="$(cat "$b/voltage_min_design" 2>/dev/null)"   # uV
        case "$ef" in ''|*[!0-9]*) ;; *) FULL_MWH=$(( ef / 1000 ));; esac
        if [ -z "$FULL_MWH" ]; then
            case "$cf" in ''|*[!0-9]*) continue;; esac
            case "$vd" in ''|*[!0-9]*) continue;; esac
            FULL_MWH=$(( cf / 1000 * vd / 1000000 ))
        fi
        [ -n "$FULL_MWH" ] && break
    done

    # Design capacity from SMBIOS. dmidecode prints mWh on most machines and
    # mAh on a few, in which case the design voltage converts it.
    DMI_CAP="$(dmidecode -t 22 2>/dev/null | sed -n 's/^[ \t]*Design Capacity: *//p' | head -n1)"
    DMI_V="$(dmidecode -t 22 2>/dev/null | sed -n 's/^[ \t]*Design Voltage: *//p' | head -n1)"
    DES_MWH=""
    case "$DMI_CAP" in
        *' mWh') DES_MWH="${DMI_CAP% mWh}";;
        *' mAh') _mah="${DMI_CAP% mAh}"; _mv="${DMI_V% mV}"
                 case "$_mah" in ''|*[!0-9]*) ;; *)
                     case "$_mv" in ''|*[!0-9]*) ;; *) DES_MWH=$(( _mah * _mv / 1000 ));; esac;;
                 esac;;
    esac
    case "$DES_MWH" in ''|*[!0-9]*) DES_MWH="";; esac

    # Only accept it if it is bigger than the measured full charge (otherwise
    # it is not a wear figure at all) and the result is not absurd.
    if [ -n "$DES_MWH" ] && [ -n "$FULL_MWH" ] && [ "$DES_MWH" -gt "$FULL_MWH" ] \
       && [ "$FULL_MWH" -gt 0 ] \
       && awk -v a="$FULL_MWH" -v b="$DES_MWH" 'BEGIN{exit !((a/b)*100>=10)}'; then
        BATT_RATIO="$(awk -v a="$FULL_MWH" -v b="$DES_MWH" 'BEGIN{printf "%.1f",(a/b)*100}')"
        BATT="${BATT_RATIO}%"
        BATT_SRC="ACPI full charge / SMBIOS design"
        BATT_DETAIL="    $FULL_MWH mWh full of $DES_MWH mWh design (SMBIOS type 22)"
    fi
    echo "  battery: was $BATT_WAS - the pack reports full == design." >>"$GUILOG"
    echo "    full=${FULL_MWH:-?} mWh  smbios design=${DES_MWH:-unavailable} mWh" >>"$GUILOG"
    echo "    result: $BATT ($BATT_SRC)" >>"$GUILOG"

    bat_suspect && BATT_NOTE="SUSPECT - pack reports full charge as its design capacity${BATT_CYCLES:+, $BATT_CYCLES cycles}"
fi

# upower as a last resort if sysfs published no usable pair at all.
if [ "$BATT" = "N/A" ]; then
    BPATH="$(upower -e 2>/dev/null | grep -i 'BAT' | head -n1)"
    if [ -n "$BPATH" ]; then
        EF="$(upower -i "$BPATH" 2>/dev/null | awk '/energy-full:/{print $2; exit}')"
        ED="$(upower -i "$BPATH" 2>/dev/null | awk '/energy-full-design:/{print $2; exit}')"
        if [ -n "$EF" ] && [ -n "$ED" ]; then
            BATT="$(awk -v a="$EF" -v b="$ED" 'BEGIN{ if(b>0) printf "%.1f%%",(a/b)*100; else print "N/A" }')"
            BATT_SRC="upower"; BATT_DETAIL="    $EF Wh of $ED Wh design (upower)"
        fi
    fi
fi

# Log every raw source, so a number that looks wrong can be traced instead of
# guessed at.
{ echo "[$STAMP] battery health=$BATT src=$BATT_SRC cycles=${BATT_CYCLES:-unknown} ${BATT_NOTE}"
  for b in /sys/class/power_supply/*; do
      echo "  --- $b"; sed 's/^/    /' "$b/uevent" 2>/dev/null
  done
  upower -d 2>&1 | head -40
  dmidecode -t 22 2>&1 | head -30
} >>"$GUILOG" 2>&1

WIFI_CHIP="$(lspci -nn 2>/dev/null | grep -i 'network controller' | sed 's/^[^ ]* //' | head -n1)"
[ -n "$WIFI_CHIP" ] || WIFI_CHIP="$(lsusb 2>/dev/null | grep -iE 'wlan|wireless|802\.11' | head -n1)"
[ -n "$WIFI_CHIP" ] || WIFI_CHIP="none detected"

echo "  $MAKE $MODEL${MODEL_MTM:+ [$MODEL_MTM]} / $SERIAL"
echo "  $CPU"
echo "  RAM $RAM   Disk $DISK_CAP   Battery $BATT"
[ -n "$BATT_NOTE" ] && {
    echo "  ! battery health is not trustworthy on this machine: $BATT_NOTE"
    echo "    the pack reports design capacity as its full charge. Unplug the"
    echo "    charger and re-run if you need a real figure."; }

# --- audio ------------------------------------------------------------
# A sound server needs XDG_RUNTIME_DIR; root has none by default, which is
# why PipeWire silently failed to start and the browser found no output.
echo "Preparing audio..."
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

# Make sure the sound modules are actually loaded before looking for cards.
# Platform modules are per-generation, so name them all - the missing ones
# just fail quietly. mtl covers Meteor Lake (Core Ultra), which the older
# tgl-only list did not.
modprobe -a snd_hda_intel snd_soc_avs snd_usb_audio \
    snd_sof_pci_intel_tgl snd_sof_pci_intel_cnl snd_sof_pci_intel_icl \
    snd_sof_pci_intel_mtl snd_sof_pci_intel_lnl snd_sof_pci_intel_ptl 2>/dev/null
udevadm settle --timeout=5 2>/dev/null
alsactl init 2>/dev/null

# SystemRescue ships no sof-firmware, so on Intel SOF machines (Tiger Lake and
# newer) the SOF driver cannot bind and no card appears at all. We carry the
# Arch sof-firmware package on the stick and install it into /lib/firmware,
# then reload the drivers so they can find it this time.
SOFPKG="$STAGE/sof-firmware.pkg.tar.zst"
if ! aplay -l 2>/dev/null | grep -q '^card'; then
    echo "  no sound card - attempting SOF firmware install" >>"$GUILOG"

    if [ -f "$SOFPKG" ] && [ ! -d /lib/firmware/intel/sof ]; then
        mkdir -p /tmp/sof
        if tar -xf "$SOFPKG" -C /tmp/sof usr/lib/firmware 2>>"$GUILOG"; then
            cp -a /tmp/sof/usr/lib/firmware/. /lib/firmware/ 2>>"$GUILOG"
            # Belt and braces: also point the kernel's firmware loader at it.
            echo /lib/firmware >/sys/module/firmware_class/parameters/path 2>/dev/null
            echo "  installed SOF firmware: $(find /lib/firmware/intel/sof* -type f 2>/dev/null | wc -l) files" >>"$GUILOG"
        else
            echo "  SOF firmware extraction FAILED" >>"$GUILOG"
        fi
        rm -rf /tmp/sof
    fi

    # Retry the probe now that the firmware is on disk. Do NOT name the driver
    # module: the old hardcoded tgl list silently did nothing on an EliteBook
    # 840 G11, whose module is snd_sof_pci_intel_mtl - the failed probe was
    # never retried, and because that module stayed bound to the PCI device
    # the legacy-HDA fallback could not claim it either, so both paths
    # reported "no card". Unbinding and rebinding the audio device re-runs
    # probe whatever the platform and whatever the module is called.
    AUDIO_PCI="$(lspci -Dn 2>/dev/null | awk '$2 ~ /^0403:/ {print $1}')"
    for d in $AUDIO_PCI; do
        drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)"
        if [ -n "$drv" ] && [ -d "/sys/bus/pci/drivers/$drv" ]; then
            echo "  rebinding $d from driver $drv" >>"$GUILOG"
            echo "$d" >"/sys/bus/pci/drivers/$drv/unbind" 2>>"$GUILOG"
            sleep 1
            echo "$d" >"/sys/bus/pci/drivers/$drv/bind" 2>>"$GUILOG"
        else
            echo "  $d has no driver bound - asking the bus to probe it" >>"$GUILOG"
            echo "$d" >/sys/bus/pci/drivers_probe 2>>"$GUILOG"
        fi
    done
    udevadm settle --timeout=10 2>/dev/null
    sleep 4

    # Still nothing? Reload every SOF module actually present, discovered from
    # lsmod rather than guessed, then fall back to legacy HDA which needs no
    # firmware at all.
    if ! aplay -l 2>/dev/null | grep -q '^card'; then
        SOFMODS="$(lsmod 2>/dev/null | awk '/^snd_sof/{print $1}')"
        echo "  no card yet - reloading: ${SOFMODS:-none} + snd_hda_intel" >>"$GUILOG"
        # shellcheck disable=SC2086
        [ -n "$SOFMODS" ] && modprobe -r $SOFMODS 2>>"$GUILOG"
        modprobe -r snd_hda_intel 2>/dev/null
        sleep 1
        # shellcheck disable=SC2086
        [ -n "$SOFMODS" ] && modprobe -a $SOFMODS 2>>"$GUILOG"
        modprobe snd_hda_intel 2>/dev/null
        udevadm settle --timeout=10 2>/dev/null
        sleep 4
    fi

    if ! aplay -l 2>/dev/null | grep -q '^card'; then
        echo "  SOF still no card - falling back to legacy HDA" >>"$GUILOG"
        SOFMODS="$(lsmod 2>/dev/null | awk '/^snd_sof/{print $1}')"
        # shellcheck disable=SC2086
        [ -n "$SOFMODS" ] && modprobe -r $SOFMODS 2>/dev/null
        modprobe -r snd_hda_intel snd_intel_dspcfg 2>/dev/null
        sleep 1
        modprobe snd_intel_dspcfg dsp_driver=1 2>/dev/null
        modprobe snd_hda_intel 2>/dev/null
        udevadm settle --timeout=10 2>/dev/null
        sleep 3
    fi
    dmesg 2>/dev/null | grep -iE 'sof|snd_hda|firmware' | tail -25 >>"$GUILOG"
fi

for card in $(aplay -l 2>/dev/null | sed -n 's/^card \([0-9]*\).*/\1/p' | sort -u); do
    amixer -c "$card" scontrols 2>/dev/null | sed -n "s/.*'\(.*\)',.*/\1/p" | while read -r ctl; do
        amixer -c "$card" -q sset "$ctl" unmute  2>/dev/null
        amixer -c "$card" -q sset "$ctl" 100%    2>/dev/null
        amixer -c "$card" -q sset "$ctl" on      2>/dev/null
    done
done
AUDIO_CARDS="$(aplay -l 2>/dev/null | grep -i '^card' | sed 's/,.*//' | sort -u | tr '\n' ';')"
[ -n "$AUDIO_CARDS" ] || AUDIO_CARDS="none"

# Mozilla's official Firefox builds are compiled WITHOUT the cubeb ALSA
# backend - PulseAudio is the only one available, so media.cubeb.backend=alsa
# was silently doing nothing. That is why the console beeps but the app is
# mute. PipeWire is useless here (no wireplumber, no pipewire-pulse in the
# ISO), so run PulseAudio itself.
#
# PulseAudio refuses to start as root unless --system is given, and system
# mode wants a dedicated account, so create one. Authentication is bypassed
# with auth-anonymous on a private socket, which avoids the pulse-access
# group dance (group changes would not apply to this already-running shell).
PULSE_SOCK=/tmp/pulse-socket
if [ "$AUDIO_CARDS" != "none" ] && command -v pulseaudio >/dev/null 2>&1; then
    getent group pulse        >/dev/null 2>&1 || groupadd -r pulse 2>/dev/null
    getent group pulse-access >/dev/null 2>&1 || groupadd -r pulse-access 2>/dev/null
    id pulse >/dev/null 2>&1 || useradd -r -g pulse -G audio,pulse-access \
        -d /var/run/pulse -s /usr/bin/nologin pulse 2>/dev/null
    mkdir -p /var/run/pulse /var/lib/pulse
    chown -R pulse:pulse /var/run/pulse /var/lib/pulse 2>/dev/null

    cat >/tmp/pa-system.pa <<'PA'
.fail
load-module module-udev-detect
.nofail
load-module module-alsa-sink
load-module module-native-protocol-unix auth-anonymous=1 socket=/tmp/pulse-socket
load-module module-always-sink
PA

    pulseaudio --system --daemonize=yes --exit-idle-time=-1 --disallow-exit=yes \
        -n --file=/tmp/pa-system.pa >>"$GUILOG" 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [ -S "$PULSE_SOCK" ] && break
        sleep 1
    done
fi

if [ -S "$PULSE_SOCK" ]; then
    export PULSE_SERVER="unix:$PULSE_SOCK"
    pactl set-sink-mute   @DEFAULT_SINK@ 0   2>/dev/null
    pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null
    AUDIO_BACKEND="pulseaudio ($PULSE_SOCK)"
else
    AUDIO_BACKEND="NONE - browser will be silent"
fi

{
  echo "[$STAMP] audio"
  echo "  cards: $AUDIO_CARDS"
  echo "  backend: $AUDIO_BACKEND"
  aplay -l 2>&1 | head -20
  pactl info 2>&1 | head -12
  # Open the output device and write one second of silence. This proves the
  # PCM opens without making the operator listen to a tone on every boot -
  # the audible check belongs in the app's Speakers tab, not in the log.
  echo "  --- silent open test on the default ALSA device ---"
  timeout 2 aplay -q -f cd -d 1 /dev/zero >/dev/null 2>&1
  echo "  aplay open rc=$?"
} >>"$GUILOG" 2>&1
echo "  audio cards: $AUDIO_CARDS"
echo "  audio server: $AUDIO_BACKEND"

# --- wifi scan --------------------------------------------------------
echo "Scanning WiFi..."
modprobe -a iwlwifi ath10k_pci ath11k_pci rtw88_pci mt7921e 2>/dev/null
udevadm settle --timeout=5 2>/dev/null
WIF="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')"
WIFI_COUNT=0; WIFI_LIST=""
if [ -n "$WIF" ]; then
    rfkill unblock all 2>/dev/null
    ip link set "$WIF" up 2>/dev/null
    sleep 3
    # The first scan after bringing the radio up almost always comes back
    # empty - the card is still calibrating. Retry and keep the best result.
    for try in 1 2 3 4 5; do
        OUT="$(timeout 20 iw dev "$WIF" scan 2>>"$GUILOG")"
        N="$(printf '%s' "$OUT" | grep -c 'SSID:')"
        if [ "${N:-0}" -gt "${WIFI_COUNT:-0}" ]; then
            WIFI_COUNT="$N"
            WIFI_LIST="$(printf '%s' "$OUT" | sed -n 's/^[ \t]*SSID: //p' \
                | grep -v '^$' | sort -u | head -8 | tr '\n' ' ')"
        fi
        [ "${WIFI_COUNT:-0}" -gt 0 ] && break
        echo "  wifi scan attempt $try found nothing, retrying..." >>"$GUILOG"
        sleep 4
    done
fi
[ -n "$WIF" ] || WIF="none"
{ echo "[$STAMP] wifi if=$WIF count=$WIFI_COUNT"; iw dev 2>&1 | head -10
  rfkill list 2>&1 | head -10; } >>"$GUILOG" 2>&1
echo "  wifi: $WIF, $WIFI_COUNT networks"

# ======================================================================
# 4. Graphical diagnostics app
# ======================================================================
# The staged copy in RAM, not the stick: the app must still start even if the
# stick is pulled or unmounted underneath us mid-run.
APPSRC="$STAGE/app"
rm -rf "$WORK"; mkdir -p "$WORK/app"
GUI_OK=0

# Firefox is packaged under different names depending on the build
# (SystemRescue 13 ships firefox-esr-bin, so the binary is firefox-esr).
FF=""
for c in firefox firefox-esr firefox-bin /usr/lib/firefox-esr/firefox \
         /usr/lib/firefox/firefox /opt/firefox-esr/firefox /opt/firefox/firefox; do
    if command -v "$c" >/dev/null 2>&1; then FF="$(command -v "$c")"; break; fi
    if [ -x "$c" ]; then FF="$c"; break; fi
done
PY3=""; command -v python3 >/dev/null 2>&1 && PY3=python3
[ -n "$PY3" ] || { command -v python >/dev/null 2>&1 && PY3=python; }
XI=""; command -v xinit >/dev/null 2>&1 && XI=xinit

{
  echo "[$STAMP] GUI prerequisites"
  echo "  app dir : $APPSRC $( [ -d "$APPSRC" ] && echo OK || echo MISSING )"
  echo "  python  : ${PY3:-MISSING}"
  echo "  xinit   : ${XI:-MISSING}"
  echo "  firefox : ${FF:-MISSING}"
} >>"$GUILOG" 2>&1
echo "GUI check: app=$( [ -d "$APPSRC" ] && echo ok || echo MISSING ) python=${PY3:-MISSING} xinit=${XI:-MISSING} firefox=${FF:-MISSING}"

if [ "$FORCE_CONSOLE" != "1" ] && [ -d "$APPSRC" ] \
   && [ -n "$PY3" ] && [ -n "$XI" ] && [ -n "$FF" ]; then

    cp "$APPSRC/index.html" "$APPSRC/server.py" "$WORK/app/" 2>/dev/null

    "$PY3" - "$WORK/app/specs.json" "$SERIAL" "$TYPE" "$MAKE" "$MODEL" \
        "$CPU" "$RAM" "$DISK_CAP" "$BATT" "$BIOSV" "$WIFI_CHIP" "$WIF" "$WIFI_COUNT" \
        "$WIFI_LIST" "$AUDIO_CARDS" <<'PY'
import json, sys
p = sys.argv[1]
k = ["serial","type","make","model","cpu","ram","disk","battery",
     "bios","wifi_chip","wifi_if","wifi_count","wifi_list","audio_cards"]
json.dump(dict(zip(k, sys.argv[2:])), open(p, "w"))
PY

    # Firefox profile: kiosk, camera auto-allowed, no first-run noise.
    PROF="$WORK/ffprof"; mkdir -p "$PROF"
    cat >"$PROF/user.js" <<'JS'
user_pref("media.navigator.permission.disabled", true);
user_pref("permissions.default.camera", 1);
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("dom.disable_beforeunload", true);
user_pref("full-screen-api.warning.timeout", 0);
user_pref("browser.startup.firstrunSkipsHomepage", true);
JS
    # There is no sound server, so pin Firefox to ALSA. Left on auto it probes
    # for PulseAudio, fails, and silently ends up with no output at all.
    #
    # The content sandbox blocks direct /dev/snd access, which is why the tone
    # is silent in the browser even though speaker-test works on the console.
    # Firefox normally reaches audio through the PulseAudio socket, which the
    # sandbox permits; talking to ALSA directly needs the sandbox relaxed.
    # Do NOT pin media.cubeb.backend: this build only has the PulseAudio
    # backend, so forcing "alsa" selects a backend that does not exist and
    # yields silence. Left unset it finds the Pulse server we started.
    cat >>"$PROF/user.js" <<'JS'
user_pref("security.sandbox.content.level", 0);
user_pref("media.cubeb.sandbox", false);
user_pref("media.utility-process.enabled", false);
user_pref("dom.ipc.processCount", 1);
JS
    # The mouse test needs a clean wheel press: autoscroll would drop a scroll
    # cursor on the page, and middle-click paste would dump text into inputs.
    cat >>"$PROF/user.js" <<'JS'
user_pref("general.autoScroll", false);
user_pref("middlemouse.paste", false);
user_pref("middlemouse.contentLoadURL", false);
JS
    [ -S "$PULSE_SOCK" ] || echo 'user_pref("media.cubeb.backend", "alsa");' >>"$PROF/user.js"

    # xfwm4 needs a session bus. Firefox's own dbus-launch --autolaunch fails
    # here ("X11 autolaunch was disabled at compile time"), so start one
    # explicitly and let every X child inherit it.
    if command -v dbus-launch >/dev/null 2>&1 && [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        eval "$(dbus-launch --sh-syntax 2>>"$GUILOG")"
        export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
        echo "  dbus session: ${DBUS_SESSION_BUS_ADDRESS:-FAILED}" >>"$GUILOG"
    fi
    # Turn off X's GPU acceleration. This ISO's Mesa cannot load a DRI driver
    # at all ("MESA-LOADER: failed to open dri: .../dri_gbm.so" in Xorg.0.log),
    # so on a machine new enough that X binds the real GPU - an EliteBook 840
    # G11, Meteor Lake - glamor has nothing to render through and the panel
    # stays black while X itself runs happily. Software rendering is plenty for
    # colour floods and a kiosk browser, and it is what the older machines were
    # already effectively using.
    mkdir -p /etc/X11/xorg.conf.d 2>/dev/null
    cat >/etc/X11/xorg.conf.d/20-noaccel.conf <<'XC'
Section "Device"
    Identifier "modesetting-noaccel"
    Driver     "modesetting"
    Option     "AccelMethod" "none"
EndSection
XC
    echo "  wrote /etc/X11/xorg.conf.d/20-noaccel.conf (AccelMethod none)" >>"$GUILOG"

    # xfwm4 grabs some key combinations at the X level, so they never reach
    # Firefox and the app cannot block them however hard it tries: Alt+Space
    # opened the window menu right on top of the tests, looking like a stray
    # right-click. The bindings live in xfconf, which this ISO does ship
    # (xfconf 4.20.0). Write the config before xfconfd can start, so it is
    # read at first launch, and blank the other window grabs too - any key the
    # WM swallows is a key the keyboard test would wrongly show as dead.
    mkdir -p "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml" 2>/dev/null
    cat >"$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml" <<'XK'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="xfwm4" type="empty">
    <property name="custom" type="empty">
      <property name="&lt;Alt&gt;space" type="string" value="empty"/>
      <property name="&lt;Alt&gt;Tab" type="string" value="empty"/>
      <property name="&lt;Alt&gt;&lt;Shift&gt;Tab" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F4" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F5" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F6" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F7" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F8" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F9" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F10" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F11" type="string" value="empty"/>
      <property name="&lt;Alt&gt;F12" type="string" value="empty"/>
      <property name="&lt;Alt&gt;Insert" type="string" value="empty"/>
      <property name="&lt;Alt&gt;Delete" type="string" value="empty"/>
      <property name="&lt;Super&gt;p" type="string" value="empty"/>
      <property name="Print" type="string" value="empty"/>
    </property>
  </property>
</channel>
XK
    export GUILOG FF PROF PORT RES PULSE_SERVER WORK
    cat >"$WORK/xstart" <<'XS'
#!/bin/bash
exec >>"$GUILOG" 2>&1
echo "  xstart: DISPLAY=$DISPLAY"
# The app server was started before X, so it has no DISPLAY of its own. Hand it
# the real values - it needs a connection to clear Caps Lock after the keyboard
# test, which the browser cannot do by itself.
printf 'DISPLAY=%s\nXAUTHORITY=%s\n' "$DISPLAY" "${XAUTHORITY:-}" >"$WORK/app/xenv" 2>/dev/null
echo "  xenv: DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-none}"
xset s off -dpms 2>/dev/null
xset r off 2>/dev/null          # no key auto-repeat - it skipped the screen test
xsetroot -solid black 2>/dev/null

# Force each connected output to its preferred (first listed) mode. Without
# this X can settle on a fallback resolution and everything is letterboxed.
for o in $(xrandr 2>/dev/null | awk '/ connected/{print $1}'); do
    m="$(xrandr 2>/dev/null | awk -v o="$o" \
        '$0 ~ "^"o" connected"{f=1;next} f&&/^ +[0-9]+x[0-9]+/{print $1;exit}')"
    if [ -n "$m" ]; then xrandr --output "$o" --mode "$m" 2>/dev/null; echo "  $o -> $m"; fi
done
xrandr 2>/dev/null | grep -E ' connected|\*' | head -10

# A window manager is required, otherwise the browser window is never sized to
# the screen and --kiosk cannot go fullscreen (kiosk asks the WM for fullscreen
# via _NET_WM_STATE_FULLSCREEN - with no WM there is nobody to honour it).
# xfwm4 has no --daemon option; passing one made it exit and print usage.
# If xfconfd is already running it will not re-read the file written above, so
# set the same keys through it as well. Harmless when the file already won.
if command -v xfconf-query >/dev/null 2>&1; then
    for k in '<Alt>space' '<Alt>Tab' '<Alt><Shift>Tab' '<Alt>F4' '<Alt>F7' '<Alt>F8' 'Print'; do
        xfconf-query -c xfce4-keyboard-shortcuts -p "/xfwm4/custom/$k" -n -t string -s empty 2>/dev/null \
          || xfconf-query -c xfce4-keyboard-shortcuts -p "/xfwm4/custom/$k" -s empty 2>/dev/null
    done
    echo "  xfwm4 key grabs cleared (Alt+Space and friends)"
fi

if command -v xfwm4 >/dev/null 2>&1; then
    xfwm4 --compositor=off &
elif command -v openbox >/dev/null 2>&1; then
    openbox &
fi
for i in 1 2 3 4 5 6 7 8; do
    pgrep -x xfwm4 >/dev/null 2>&1 || pgrep -x openbox >/dev/null 2>&1 && break
    sleep 1
done
if pgrep -x xfwm4 >/dev/null 2>&1 || pgrep -x openbox >/dev/null 2>&1; then
    echo "  WM running: yes"
else
    echo "  WM running: NO - window will not be fullscreen"
fi

# Fallback for the no-WM case: pre-seed the window geometry Firefox restores
# on startup, so the window at least covers the screen.
SW="$(xrandr 2>/dev/null | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\1/p' | head -1)"
SH="$(xrandr 2>/dev/null | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\2/p' | head -1)"
if [ -n "$SW" ] && [ -n "$SH" ]; then
    echo "  screen ${SW}x${SH}"
    printf '{"chrome://browser/content/browser.xhtml":{"main-window":{"screenX":"0","screenY":"0","width":"%s","height":"%s","sizemode":"fullscreen"}}}\n' \
        "$SW" "$SH" >"$PROF/xulstore.json"
fi

( while [ ! -f "$RES" ]; do sleep 1; done; sleep 2; pkill -f firefox ) &
echo "  launching $FF"
"$FF" --profile "$PROF" --kiosk "http://127.0.0.1:$PORT/index.html"
echo "  browser exited rc=$?"
XS
    chmod +x "$WORK/xstart"

    "$PY3" "$WORK/app/server.py" "$WORK/app" "$PORT" "$RES" >>"$GUILOG" 2>&1 &
    SRVPID=$!
    sleep 1

    banner "Launching the diagnostics app"
    echo "Work through the tests, write your diagnosis on the last page,"
    echo "then press 'Save & finish'."
    echo
    sleep 2
    echo "  starting X..." >>"$GUILOG"

    # Everything so far goes to the stick BEFORE X takes the screen. If the
    # display ends up black the operator can only power-cycle, and the exit
    # trap never runs - without this flush the whole run leaves no trace.
    { echo "[$STAMP] about to start X"
      echo "  outputs seen by the kernel:"
      for card in /sys/class/drm/card*-*; do
          [ -r "$card/status" ] || continue
          echo "    $(basename "$card"): $(cat "$card/status" 2>/dev/null)" \
               "enabled=$(cat "$card/enabled" 2>/dev/null)"
      done
      echo "  graphics:"; lspci -nn 2>/dev/null | grep -iE 'vga|display|3d'
      echo "  loaded drm modules:"; lsmod 2>/dev/null | awk '/^(i915|xe|amdgpu|nouveau|nvidia|radeon)/{print "    "$1}'
      echo "  backlight:"
      for bl in /sys/class/backlight/*; do
          [ -r "$bl/brightness" ] || continue
          echo "    $(basename "$bl"): $(cat "$bl/brightness" 2>/dev/null)/$(cat "$bl/max_brightness" 2>/dev/null)"
      done
      # Webcam. The app tests the camera with getUserMedia, so a failure only
      # ever showed up in the browser and died with the X session. Meteor Lake
      # era Dells (Latitude 7440/7450 and friends) hang the camera off the
      # Intel IPU6 over MIPI rather than USB: the kernel binds it, but the
      # stack exposes media/subdev nodes only, with no /dev/video* a browser
      # can open. Recording all of this here is what tells "no capture node,
      # MIPI hardware" apart from "genuinely dead webcam" without a re-run.
      echo "  camera:"
      CAM_VNODES="$(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
      CAM_MNODES="$(ls /dev/media* 2>/dev/null | tr '\n' ' ')"
      CAM_UVCMOD="$(lsmod 2>/dev/null | awk '$1=="uvcvideo"{print $1}')"
      CAM_IPU="$(lspci -nn 2>/dev/null | grep -iE 'multimedia|imaging' | grep -i intel)"
      CAM_SENSORMOD="$(lsmod 2>/dev/null | awk '/^(ov|hi5|imx|gc[0-9])/{print $1; exit}')"
      CAM_SENSORNAME="$(dmesg 2>/dev/null | sed -n 's/.*Found supported sensor \([A-Za-z0-9]*\).*/\1/p' | tail -n1)"
      # uvcvideo only loads when a real USB camera is attached, so it is a
      # firmer signal than matching lsusb strings. The dmesg sensor line can
      # scroll out of the ring buffer on a noisy boot, hence the module check
      # alongside it - either one is enough to call the sensor bound.
      CAM_KIND=none
      if [ -n "$CAM_IPU" ] && { [ -n "$CAM_SENSORMOD" ] || [ -n "$CAM_SENSORNAME" ]; }; then
          CAM_KIND=mipi
      elif [ -n "$CAM_IPU" ]; then
          CAM_KIND=ipu-nosensor
      fi
      [ -n "$CAM_UVCMOD" ] && CAM_KIND=uvc
      echo "    v4l nodes  : ${CAM_VNODES:-NONE}"
      echo "    media nodes: ${CAM_MNODES:-NONE}"
      echo "    verdict    : $CAM_KIND (sensor=${CAM_SENSORNAME:-${CAM_SENSORMOD:-none}})"
      echo "    imaging pci:"
      lspci -nn 2>/dev/null | grep -iE 'imaging|multimedia|camera' | sed 's/^/    /'
      echo "    usb video:"
      lsusb 2>/dev/null | grep -iE 'cam|webcam|video|imaging' | sed 's/^/    /'
      echo "    camera modules:"
      lsmod 2>/dev/null | awk '/^(uvcvideo|intel_ipu6|ipu6|videodev|ov[0-9]|intel_vsc|ivsc|int3472)/{print "    "$1}'
      command -v v4l2-ctl >/dev/null 2>&1 && v4l2-ctl --list-devices 2>&1 | sed 's/^/    /'
      echo "    camera dmesg:"
      dmesg 2>/dev/null | grep -iE 'ipu6|int3472|uvcvideo|ivsc|ov[0-9]{4}' | tail -15 | sed 's/^/    /'
    } >>"$GUILOG" 2>&1
    flush_logs

    # ---- MIPI/IPU6 camera: libcamera + PipeWire so the browser can see it ----
    # Runs ONLY when the camera is not a plain USB webcam. On a UVC machine
    # nothing below executes: no packages extracted, no daemons started, no
    # extra Firefox prefs. The path that already works is left untouched.
    #
    # PulseAudio is deliberately preserved. pipewire-pulse would replace it and
    # take the speaker test down with it, so the pulse shim is refused even if
    # it is sitting on the stick, wireplumber's ALSA monitor is disabled, and
    # the whole thing is rolled back if audio breaks anyway.
    # ---- MIPI/IPU6 camera: install libcamera so the app can grab frames ----
    # Runs ONLY when the camera is not a plain USB webcam. On a UVC machine
    # nothing below executes and the browser's own getUserMedia path is left
    # exactly as it was.
    #
    # No PipeWire, no wireplumber, no Firefox prefs. Firefox reaches a PipeWire
    # camera only through xdg-desktop-portal, which needs a full GNOME or KDE
    # portal backend plus an interactive permission dialog - unworkable in a
    # kiosk. libcamera on its own opens this sensor fine, so the app falls back
    # to asking server.py for frames instead. PulseAudio is never touched.
    CAM_LC=skipped
    if [ "$CAM_KIND" = "mipi" ]; then
        echo "[$STAMP] MIPI camera - installing libcamera" >>"$GUILOG"
        for p in "$STAGE"/camera/*.pkg.tar.zst; do
            [ -f "$p" ] || continue
            case "$(basename "$p")" in
                pipewire*|pulseaudio*|wireplumber*|libwireplumber*)
                    echo "  REFUSED $(basename "$p") - not needed, risks the audio test" >>"$GUILOG"
                    continue ;;
            esac
            if tar -xf "$p" -C / usr 2>>"$GUILOG"; then
                echo "  installed $(basename "$p")" >>"$GUILOG"
            else
                echo "  FAILED to extract $(basename "$p")" >>"$GUILOG"
            fi
        done
        ldconfig 2>/dev/null

        if command -v cam >/dev/null 2>&1; then
            # Run it for real and keep the output. Piping straight into sed
            # would report sed's exit status, which is always 0 - that is how a
            # missing libSDL2 once got logged as "ok".
            CAM_OUT="$(cam --list 2>&1)"; CAM_RC=$?
            printf '%s\n' "$CAM_OUT" | sed 's/^/    /' >>"$GUILOG"
            if [ "$CAM_RC" -ne 0 ]; then
                CAM_LC="cam-rc=$CAM_RC"
            elif printf '%s' "$CAM_OUT" | grep -qi 'Available cameras'; then
                CAM_LC=ok
            else
                CAM_LC=no-cameras-listed
            fi
        else
            CAM_LC=no-cam-binary
            echo "  cam binary missing - is libcamera-tools on the stick?" >>"$GUILOG"
        fi
        echo "  libcamera: $CAM_LC" >>"$GUILOG"
        flush_logs
    fi

    xinit "$WORK/xstart" -- :0 vt7 -nolisten tcp >>"$GUILOG" 2>&1
    echo "  xinit rc=$?" >>"$GUILOG"
    if [ ! -f "$RES" ]; then                    # X refused :0 / vt7 - try startx
        echo "  retrying with startx..." >>"$GUILOG"
        startx "$WORK/xstart" >>"$GUILOG" 2>&1
        echo "  startx rc=$?" >>"$GUILOG"
    fi
    kill "$SRVPID" 2>/dev/null
    if [ -f "$RES" ]; then
        GUI_OK=1
    fi
    # Keep the X server log either way - a black screen with a "successful"
    # X server is exactly the case where it is needed.
    for l in /var/log/Xorg.0.log "$HOME/.local/share/xorg/Xorg.0.log"; do
        [ -f "$l" ] && cp "$l" "$RUN/Xorg.0.log" 2>/dev/null && break
    done
    flush_logs
    sync
fi

NOTES=""; OBS=""
if [ "$GUI_OK" = "1" ]; then
    NOTES="$("$PY3" -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('notes','').replace(chr(10),' ; '))" "$RES" 2>/dev/null)"
    OBS="$("$PY3" -c "import json,sys;d=json.load(open(sys.argv[1]));o=d.get('observations',{});print('; '.join('%s: %s'%(k,v) for k,v in o.items()))" "$RES" 2>/dev/null)"
    ITEM="$("$PY3" -c "import json,sys;print(json.load(open(sys.argv[1])).get('item',''))" "$RES" 2>/dev/null)"
    ASSET_TAG="$("$PY3" -c "import json,sys;print(json.load(open(sys.argv[1])).get('asset_tag',''))" "$RES" 2>/dev/null)"
    echo "Diagnostics app finished."
else
    # ---------------- console fallback ----------------
    banner "Diagnostics (text mode)"
    echo "The graphical app could not start - using text-mode tests."
    echo
    ask ITEM      "Item number        : "
    ask ASSET_TAG "Asset tag          : "
    echo
    echo "SCREEN: black, then white. Press a key at each."
    anykey "Press any key for BLACK..."
    setterm --background black --foreground black --cursor off --clear all 2>/dev/null
    anykey ""; setterm --default --cursor on --clear all 2>/dev/null
    anykey "Press any key for WHITE..."
    setterm --background white --foreground white --cursor off --clear all 2>/dev/null
    anykey ""; setterm --default --cursor on --clear all 2>/dev/null

    echo; echo "KEYBOARD: press keys for 20 seconds (ESC to end early)."
    KEYS=0; END=$(( $(date +%s) + 20 ))
    while [ "$(date +%s)" -lt "$END" ]; do
        k=""; if [ -n "$TTY" ]; then read -rsn1 -t 1 k <"$TTY"; else read -rsn1 -t 1 k; fi
        [ $? -ne 0 ] && continue
        [ "$k" = $'\e' ] && break
        printf '%s ' "${k:-[ENTER]}"; KEYS=$((KEYS+1))
    done
    echo; echo "  $KEYS keys"

    echo; echo "MOUSE: move and click for 10 seconds..."
    BYTES="$(timeout 10 cat /dev/input/mice 2>/dev/null | wc -c)"
    echo "  $BYTES bytes of pointer data"

    echo; echo "SPEAKERS: playing a tone..."
    command -v speaker-test >/dev/null 2>&1 && timeout 0.6 speaker-test -t sine -f 1000 -c 2 >/dev/null 2>&1

    echo; echo "WEBCAM: $(ls /dev/video* 2>/dev/null | tr '\n' ' ')"

    OBS="text mode: keys=$KEYS, pointer_bytes=$BYTES, wifi_networks=$WIFI_COUNT"
    banner "Your diagnosis"
    echo "Type your notes. Empty line to finish."
    while true; do
        line=""; if [ -n "$TTY" ]; then read -r -p "> " line <"$TTY" >"$TTY" 2>&1; else read -r -p "> " line; fi
        [ -z "$line" ] && break
        NOTES="${NOTES}${NOTES:+ ; }${line}"
    done
fi

# ======================================================================
# 5. Summary
# ======================================================================
# Strip tabs, newlines and the * separator out of every field so one machine
# is always exactly one line with exactly ten separators.
clean() { printf '%s' "$1" | tr '\t\n\r*' '    ' | sed 's/  */ /g; s/^ //; s/ $//'; }
# The app hands back its own observations (screen, keyboard, mouse, audio,
# webcam) and until now they were assembled into $OBS and then dropped on the
# floor - a "Camera failed: NotFoundError" lived on screen and nowhere else.
# Log the lot, and fold any failure into the Diagnostics column too: a dead
# webcam has to be visible in the spreadsheet, not buried in gui.log.
DIAG="$NOTES"
[ -n "$OBS" ] && { echo "[$STAMP] observations: $OBS" >>"$GUILOG"; flush_logs; }
FAILS="$(printf '%s\n' "$OBS" | awk -v nocam="$SUPPRESS_CAM" 'BEGIN{RS=";"}
    /FAILED/ { if (nocam == "1" && tolower($0) ~ /webcam|camera/) next
               gsub(/^[ \n]+|[ \n]+$/, "")
               printf "%s%s", (n++ ? " ; " : ""), $0 }')"
[ "$SUPPRESS_CAM" = "1" ] && printf '%s\n' "$OBS" | grep -qiE 'webcam|camera' \
    && { echo "[$STAMP] chassis=$TYPE has no built-in webcam; camera result kept out of Diagnostics" >>"$GUILOG"; flush_logs; }
[ -n "$FAILS" ] && DIAG="${DIAG:+$DIAG ; }$FAILS"

LINE="$(printf '%s*%s*%s*%s*%s*%s*%s*%s*%s*%s*%s' \
    "$(clean "$ITEM")" "$(clean "$SERIAL")" "$(clean "$ASSET_TAG")" "$(clean "$TYPE")" \
    "$(clean "$MAKE")" "$(clean "$MODEL")" "$(clean "$CPU")" "$(clean "$RAM")" \
    "$(clean "$DISK_CAP")" "$(clean "$BATT")" "$(clean "$DIAG")")"

# Keep a copy in RAM first, so the line is never lost while the stick is being
# recovered.
printf '%s\n' "$LINE" >>"$RUN/report-pending.txt"

# The stick must be back before this write - it is the whole point of the run.
if ! ensure_usb; then
    echo
    echo "The USB stick is not reachable. Re-seat it and press a key to retry."
    echo "(Nothing is lost - the result is held in memory until it is saved.)"
    while ! ensure_usb; do anykey "Press a key to retry..."; done
fi

# One append-only file for every machine, * separated for Excel.
REPORT="$MNT/specs/reports.txt"
[ -f "$REPORT" ] || printf 'Item*S.N*Asset Tag*Type*Make*Model*CPU*RAM*Disk Capacity*Battery Health*Diagnostics\n' >"$REPORT"
printf '%s\n' "$LINE" >>"$REPORT"
sync
echo "report line appended (gui=$GUI_OK)" >>"$LOG"
rm -f "$RUN/report-pending.txt"
flush_logs

# The app's first served camera frame, raw and untouched, plus cam's own
# account of the format it negotiated. Colour and exposure faults cannot be
# judged from a log line, so the pixels themselves come off the machine - but
# only when raw dumps were asked for, since it is ~900 KB of stick per run.
# server.py writes it to RAM regardless; this is just the copy out.
if [ "$KEEP_RAW" = "1" ] && [ -d /tmp/hwaudit-run/camdebug ]; then
    cp -a /tmp/hwaudit-run/camdebug "$MNT/specs/${STAMP}_camdebug" 2>/dev/null
    sync
    echo "camera debug dumped to specs/${STAMP}_camdebug" >>"$GUILOG"
fi

if [ "$KEEP_RAW" = "1" ]; then
    RAW="$MNT/specs/${STAMP}_${SERIAL}_raw"; mkdir -p "$RAW/smart"
    dmidecode >"$RAW/system.txt" 2>&1
    dmidecode -t baseboard -t chassis -t processor >"$RAW/baseboard.txt" 2>&1
    dmidecode -t memory >"$RAW/memory.txt" 2>&1
    lshw >"$RAW/hardware.txt" 2>&1; lshw -json >"$RAW/hardware.json" 2>&1
    inxi -FxxxzZ --width 160 >"$RAW/inxi.txt" 2>&1
    lspci -vnn >"$RAW/pci.txt" 2>&1; lsusb -v >"$RAW/usb.txt" 2>&1
    lsblk -O >"$RAW/block.txt" 2>&1; upower -d >"$RAW/battery.txt" 2>&1
    dmesg >"$RAW/dmesg.txt" 2>&1
    for n in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        [ "$n" = "$BOOTDISK" ] && continue
        smartctl -x "/dev/$n" >"$RAW/smart/$n.txt" 2>&1
    done
    sync
fi

# ======================================================================
# 6. Flush
# ======================================================================
banner "RESULT"
echo "$LINE"
echo; echo "Flushing to USB, do not remove it yet..."
flush_logs
sync; sync
# Count while the stick is still mounted - after the umount the path is gone.
NLINES="$(grep -c '' "$MNT/specs/reports.txt" 2>/dev/null)"
trap - EXIT                                  # nothing left to flush
if umount "$MNT" 2>/dev/null; then STATE="UNMOUNTED - safe to remove"
else mount -o remount,ro "$MNT" 2>/dev/null; sync; STATE="flushed (read-only) - safe to remove"; fi
banner "DONE - $STATE"
echo "Appended to : specs/reports.txt  ($NLINES lines incl. header)"
echo; echo "Pull the USB out, or type  poweroff  to shut down."; echo
anykey
