Camera packages for MIPI/IPU6 laptops (Dell Latitude 7440/7450, Meteor Lake etc).

Extracted into the live system by collect.sh ONLY when the camera probe returns
CAM_KIND=mipi. On a USB/UVC laptop none of this is touched and the browser's
own getUserMedia path is used exactly as before.

SystemRescue 13.02 already ships glib2, gnutls, libyaml, libunwind, libelf,
libglvnd, lua and systemd-libs, so only these are needed:

  libcamera        0.7.2-3   Simple pipeline handler + SoftISP
  libcamera-ipa    0.7.2-3   IPA modules, required by libcamera
  libcamera-tools  0.7.2-3   the `cam` binary, used to grab frames
  sdl3             3.4.14-1  cam links against SDL2; not in the ISO
  sdl2-compat      2.32.70-1 provides libSDL2-2.0.so.0 on top of sdl3
  libyuv           r2921     libcamera dependency, not in the ISO

WHY NOT PIPEWIRE: Firefox reaches a PipeWire camera only through
xdg-desktop-portal, which needs a full GNOME or KDE portal backend plus an
interactive permission dialog - unworkable in a kiosk. That route was tried and
abandoned; libcamera alone opens the sensor, so server.py shells out to `cam`
and serves frames to the page instead.

Do NOT add pipewire*, wireplumber* or pulseaudio* here. They are not needed and
pipewire-pulse would displace the PulseAudio the speaker test relies on.
collect.sh refuses them by filename, but just leave them out.

Source: https://geo.mirror.pkgbuild.com/extra/os/x86_64/
Fetched 2026-08-19.
