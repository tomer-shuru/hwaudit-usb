#!/usr/bin/env python3
"""Tiny local server for the diagnostics app.

Serves the app over http://127.0.0.1 (a secure context, so the browser will
allow camera access) and accepts POST /save carrying the results JSON, plus
POST /capsoff to clear a Caps Lock left latched by the keyboard test.
Exits as soon as the results file has been written.

    server.py <app_dir> <port> <results_file>
"""
import ctypes
import glob
import http.server
import os
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading

APP_DIR, PORT, OUT = sys.argv[1], int(sys.argv[2]), sys.argv[3]

LOCK_MASK = 1 << 1          # X11 LockMask - Caps Lock
XKB_USE_CORE_KBD = 0x0100


def _x_targets():
    """DISPLAY/XAUTHORITY pairs worth trying.

    The server is started before X, so its own environment has no DISPLAY.
    xstart writes the real values to <app_dir>/xenv once X is up; the rest are
    fallbacks for the case where that file never appeared (plain `xinit` sets
    up no authority at all, `startx` puts a cookie in /tmp/serverauth.*).
    """
    env = {}
    try:
        with open(os.path.join(APP_DIR, "xenv")) as fh:
            for line in fh:
                k, _, v = line.strip().partition("=")
                if k and v:
                    env[k] = v
    except OSError:
        pass
    disp = env.get("DISPLAY") or os.environ.get("DISPLAY") or ":0"
    auths = [env.get("XAUTHORITY"), os.environ.get("XAUTHORITY"), None,
             os.path.expanduser("~/.Xauthority")]
    auths += sorted(glob.glob("/tmp/serverauth.*"), key=os.path.getmtime,
                    reverse=True)
    out = []
    for a in auths:
        if a is not None and not os.path.exists(a):
            continue
        if (disp, a) not in out:
            out.append((disp, a))
    return out


def _open_display(x11):
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    for disp, auth in _x_targets():
        if auth:
            os.environ["XAUTHORITY"] = auth
        else:
            os.environ.pop("XAUTHORITY", None)
        d = x11.XOpenDisplay(disp.encode())
        if d:
            print("caps: connected to %s (auth=%s)" % (disp, auth or "none"),
                  flush=True)
            return d
    return None


def caps_off():
    """Clear Caps Lock if it is on. Returns a short status for the log.

    A web page cannot touch a modifier, so the browser asks the server and the
    server asks X. Reading the state first keeps this a no-op when the
    operator never pressed the key.
    """
    try:
        x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
    except OSError as exc:
        return "libX11 not loadable: %s" % exc
    d = _open_display(x11)
    if not d:
        return "no X display"
    dpy = ctypes.c_void_p(d)
    try:
        x11.XDefaultRootWindow.restype = ctypes.c_ulong
        x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        root_win = x11.XDefaultRootWindow(dpy)

        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        rx, ry, wx, wy = (ctypes.c_int() for _ in range(4))
        mask = ctypes.c_uint()
        x11.XQueryPointer.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint)]
        x11.XQueryPointer(dpy, root_win, ctypes.byref(root), ctypes.byref(child),
                          ctypes.byref(rx), ctypes.byref(ry),
                          ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(mask))
        if not mask.value & LOCK_MASK:
            return "already off (mods=0x%x)" % mask.value

        # XkbLockModifiers needs the extension initialised on this connection.
        op, ev, err = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
        maj, minr = ctypes.c_int(1), ctypes.c_int(0)
        x11.XkbQueryExtension.argtypes = [ctypes.c_void_p] + \
            [ctypes.POINTER(ctypes.c_int)] * 5
        x11.XkbQueryExtension(dpy, ctypes.byref(op), ctypes.byref(ev),
                              ctypes.byref(err), ctypes.byref(maj),
                              ctypes.byref(minr))
        x11.XkbLockModifiers.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                         ctypes.c_uint, ctypes.c_uint]
        ok = x11.XkbLockModifiers(dpy, XKB_USE_CORE_KBD, LOCK_MASK, 0)
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XFlush(dpy)
        return "cleared" if ok else "XkbLockModifiers refused"
    except Exception as exc:                       # never let this kill the run
        return "error: %r" % exc
    finally:
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay(dpy)


# ---------------------------------------------------------------- camera ----
# MIPI/IPU6 laptops expose only raw ISYS nodes, which no browser can open, and
# reaching them through PipeWire would need xdg-desktop-portal plus a
# permission dialog. libcamera opens them fine, so the page falls back to
# asking us for frames. USB webcams never reach this code - getUserMedia
# handles those in the browser.
CAM_LOCK = threading.Lock()
CAM_W, CAM_H = 640, 480     # stride 1920 is 64 byte aligned, so no row padding
# Auto-exposure and gain start from scratch every time the camera is opened, so
# frame 1 is nearly unexposed - it came back as a dark, noise-speckled mess that
# looked like raw sensor data. Grab a short burst and keep the last one, by
# which point the soft ISP AGC has settled.
CAM_FRAMES = 20


def _bmp(raw, w, h):
    """Wrap packed 24bpp pixel data as a BMP.

    libcamera's RGB888 follows DRM fourcc naming, so the bytes land in memory
    as B,G,R - already the order BMP wants, no channel swap. BMP rows run
    bottom-up and each is padded to a 4 byte boundary.
    """
    stride = w * 3
    pad = (-stride) % 4
    rows = bytearray()
    for y in range(h - 1, -1, -1):
        rows += raw[y * stride:(y + 1) * stride] + b"\0" * pad
    hdr = b"BM" + struct.pack("<IHHI", 14 + 40 + len(rows), 0, 0, 54)
    dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(rows),
                      2835, 2835, 0, 0)
    return bytes(hdr + dib + rows)


# Set once the first frame has been dumped for offline inspection.
CAM_DUMPED = []
CAM_DEBUG = "/tmp/hwaudit-run/camdebug"


def capture():
    """Grab one frame with libcamera. Returns (bmp_bytes, error_string).

    cam(1) opens and closes the sensor per call. Slower than holding the
    stream open, but it needs no background process and cannot leave the
    camera powered if the operator walks away mid-test.

    The frame served first in a run is also written to CAM_DEBUG untouched,
    together with cam's own account of the format it negotiated. Colour and
    exposure faults are impossible to judge from a description, and this way
    one boot produces something that can actually be examined.
    """
    want = CAM_W * CAM_H * 3
    d = tempfile.mkdtemp(prefix="camframe-")
    try:
        env = dict(os.environ, LIBCAMERA_LOG_LEVELS="*:INFO")
        proc = subprocess.run(
            ["cam", "--camera=1", "--capture=%d" % CAM_FRAMES,
             "--stream=width=%d,height=%d,pixelformat=RGB888" % (CAM_W, CAM_H),
             "--file=" + os.path.join(d, "f#.bin")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, env=env)
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        # Newest wins: whether cam numbers the frames or overwrites one file,
        # the most recently written is the last of the burst.
        files = sorted(glob.glob(os.path.join(d, "*")),
                       key=os.path.getmtime, reverse=True)
        if not files:
            return None, out[-400:] or "cam wrote no frame"
        got = os.path.getsize(files[0])
        with open(files[0], "rb") as fh:
            raw = fh.read()

        if not CAM_DUMPED:
            CAM_DUMPED.append(True)
            # A row stride wider than the pixels shears the picture, which is
            # exactly what a "looks like raw sensor data" image looks like.
            stride = (got // CAM_H) if CAM_H else 0
            print("camera: got %d bytes, expected %d for %dx%d "
                  "(implied stride %d, %.2f bytes/px)"
                  % (got, want, CAM_W, CAM_H, stride, stride / float(CAM_W or 1)),
                  flush=True)
            try:
                os.makedirs(CAM_DEBUG, exist_ok=True)
                with open(os.path.join(CAM_DEBUG, "frame0.raw"), "wb") as fh:
                    fh.write(raw)
                with open(os.path.join(CAM_DEBUG, "cam.txt"), "w") as fh:
                    fh.write("argv: %s\n\n%s\n" % (proc.args, out))
                print("camera: dumped first frame to %s" % CAM_DEBUG, flush=True)
            except Exception as exc:
                print("camera: dump failed: %r" % exc, flush=True)

        if got < want:
            return None, ("frame was %d bytes, expected %d for %dx%d. %s"
                          % (got, want, CAM_W, CAM_H, out[-300:]))
        return _bmp(raw[:want], CAM_W, CAM_H), ""
    except FileNotFoundError:
        return None, "cam binary not installed"
    except subprocess.TimeoutExpired:
        return None, "cam timed out after 60s"
    except Exception as exc:                   # never let this kill the run
        return None, repr(exc)
    finally:
        shutil.rmtree(d, ignore_errors=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=APP_DIR, **kw)

    def _reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0].rstrip("/").endswith("camframe.bmp"):
            with CAM_LOCK:                     # one cam(1) at a time
                img, err = capture()
            if img:
                self.send_response(200)
                self.send_header("Content-Type", "image/bmp")
                self.send_header("Content-Length", str(len(img)))
                self.end_headers()
                self.wfile.write(img)
            else:
                body = err.encode("utf-8", "replace")[:500]
                self.send_response(503)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            return
        super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path.rstrip("/").endswith("capsoff"):
            status = caps_off()
            print("caps lock after keyboard test: %s" % status, flush=True)
            self._reply(status.encode())
            return
        tmp = OUT + ".part"
        with open(tmp, "wb") as fh:
            fh.write(body)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, OUT)
        self._reply(b"ok")

    def end_headers(self):
        # No caching, so a re-run never serves a stale page.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as srv:
    srv.timeout = 1
    while not os.path.exists(OUT):
        srv.handle_request()
