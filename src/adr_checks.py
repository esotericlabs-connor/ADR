#!/usr/bin/env python3
"""ADR — Manual Hardware Checks GUI
Cross-platform interactive hardware verification window.
Called by adr.sh / adr.ps1 after automated system checks, or run standalone.
Results are written as JSON so the calling script can embed them in the report.
"""

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import wave

try:
    import tkinter as tk
    from tkinter import ttk
except ImportError:
    print(
        "tkinter is not available.\n"
        "  Linux:   sudo apt install python3-tk   (Debian/Ubuntu)\n"
        "           sudo dnf install python3-tkinter  (Fedora/RHEL)\n"
        "  macOS:   reinstall Python from https://python.org (includes tkinter)\n"
        "  Windows: reinstall Python from https://python.org (check 'tcl/tk' box)",
        file=sys.stderr,
    )
    sys.exit(1)

PLATFORM = sys.platform  # 'win32' | 'darwin' | 'linux'

# ── Colour palette ────────────────────────────────────────────────────────────
BG       = "#f0f2f5"
CARD     = "#ffffff"
PRIMARY  = "#1565C0"
SUCCESS  = "#2E7D32"
DANGER   = "#C62828"
MUTED    = "#757575"
TEXT     = "#212121"
BORDER   = "#dde1e7"
HDR_SUB  = "#BBDEFB"

# ── Audio ─────────────────────────────────────────────────────────────────────

def _make_wav(freq: float, duration: float, volume: float, pan: str) -> str:
    """Generate a stereo sine-wave WAV and return the temp file path."""
    sr  = 44100
    n   = int(sr * duration)
    lv  = volume if pan in ("left",  "both") else 0.0
    rv  = volume if pan in ("right", "both") else 0.0
    buf = bytearray()
    for i in range(n):
        s = math.sin(2 * math.pi * freq * i / sr)
        buf += struct.pack("<hh",
                           max(-32767, min(32767, int(s * lv * 32767))),
                           max(-32767, min(32767, int(s * rv * 32767))))
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    with wave.open(tmp.name, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(bytes(buf))
    return tmp.name


def play_tone(freq: float, duration: float, volume: float, pan: str) -> None:
    """Play a tone asynchronously; cleans up the temp file when done."""
    def _run() -> None:
        path = _make_wav(freq, duration, volume, pan)
        try:
            if PLATFORM == "win32":
                import winsound  # noqa: PLC0415
                winsound.PlaySound(path, winsound.SND_FILENAME)
            elif PLATFORM == "darwin":
                subprocess.run(["afplay", path],
                               check=False, timeout=duration + 2)
            else:
                played = False
                for cmd in (
                    ["paplay", path],
                    ["aplay", path],
                    ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path],
                    ["mpv", "--no-video", "--really-quiet", path],
                ):
                    if shutil.which(cmd[0]):
                        subprocess.run(cmd, check=False, timeout=duration + 2)
                        played = True
                        break
                if not played:
                    print("ADR checks: no audio player found "
                          "(paplay / aplay / ffplay / mpv).", file=sys.stderr)
        except Exception:
            pass
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
    threading.Thread(target=_run, daemon=True).start()


# ── System app launchers ──────────────────────────────────────────────────────

def open_camera() -> None:
    if PLATFORM == "win32":
        subprocess.Popen("explorer microsoft.windows.camera:", shell=True)
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", "-a", "Photo Booth"])
    else:
        for app in ("cheese", "kamoso", "guvcview", "camorama"):
            if shutil.which(app):
                subprocess.Popen([app])
                return
        if shutil.which("ffplay"):
            subprocess.Popen(
                ["ffplay", "-f", "video4linux2", "/dev/video0"],
                stderr=subprocess.DEVNULL,
            )


def open_sound_settings() -> None:
    if PLATFORM == "win32":
        subprocess.Popen("explorer ms-settings:sound", shell=True)
    elif PLATFORM == "darwin":
        subprocess.Popen(
            ["open", "/System/Library/PreferencePanes/Sound.prefPane"]
        )
    else:
        for app, extra in (("pavucontrol", []), ("gnome-control-center", ["sound"])):
            if shutil.which(app):
                subprocess.Popen([app] + extra)
                return


def open_text_editor() -> None:
    if PLATFORM == "win32":
        subprocess.Popen(["notepad.exe"])
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", "-a", "TextEdit"])
    else:
        for app in ("gedit", "mousepad", "kate", "xed", "leafpad", "pluma"):
            if shutil.which(app):
                subprocess.Popen([app])
                return
        if shutil.which("xterm") and shutil.which("nano"):
            subprocess.Popen(["xterm", "-e", "nano"])


def open_display_settings() -> None:
    if PLATFORM == "win32":
        subprocess.Popen("explorer ms-settings:display", shell=True)
    elif PLATFORM == "darwin":
        subprocess.Popen(
            ["open", "/System/Library/PreferencePanes/Displays.prefPane"]
        )
    else:
        for app, extra in (
            ("gnome-control-center", ["display"]),
            ("xfce4-display-settings", []),
            ("arandr", []),
        ):
            if shutil.which(app):
                subprocess.Popen([app] + extra)
                return


# ── CheckRow widget ───────────────────────────────────────────────────────────

class CheckRow:
    """One hardware check: label+hint | optional action button | Yes / No."""

    def __init__(
        self,
        parent: tk.Widget,
        label: str,
        hint: str = "",
        action_label: str = "",
        action_fn=None,
        row: int = 0,
    ) -> None:
        self._var = tk.StringVar(value="")

        # Label column
        lbl_frame = tk.Frame(parent, bg=CARD)
        lbl_frame.grid(row=row, column=0, sticky="w", padx=(16, 8), pady=8)
        tk.Label(
            lbl_frame, text=label, bg=CARD, fg=TEXT,
            font=("Helvetica", 11), anchor="w",
        ).pack(anchor="w")
        if hint:
            tk.Label(
                lbl_frame, text=hint, bg=CARD, fg=MUTED,
                font=("Helvetica", 9), anchor="w",
            ).pack(anchor="w")

        # Action button column
        if action_label and action_fn:
            tk.Button(
                parent, text=action_label, command=action_fn,
                bg=PRIMARY, fg="white", relief="flat",
                activebackground="#1976D2", activeforeground="white",
                font=("Helvetica", 10), padx=10, pady=5,
                cursor="hand2", bd=0,
            ).grid(row=row, column=1, padx=8, pady=6, sticky="e")
        else:
            tk.Label(parent, text="", bg=CARD).grid(row=row, column=1)

        # Yes / No radio column
        radio_frame = tk.Frame(parent, bg=CARD)
        radio_frame.grid(row=row, column=2, padx=(8, 16), pady=6)

        def _rb(text: str, value: str, color: str, sel_bg: str) -> tk.Radiobutton:
            return tk.Radiobutton(
                radio_frame, text=text, variable=self._var, value=value,
                bg=CARD, fg=color, activebackground=CARD,
                selectcolor=sel_bg, font=("Helvetica", 11, "bold"),
                cursor="hand2",
            )

        _rb("Yes", "Pass", SUCCESS, "#E8F5E9").pack(side="left", padx=(0, 12))
        _rb("No",  "Fail", DANGER,  "#FFEBEE").pack(side="left")

    def get(self) -> str:
        return self._var.get() or "Not tested"


# ── Main GUI class ────────────────────────────────────────────────────────────

class AdrChecksGui:
    _DEFAULT_VOL = 50  # percent

    def __init__(self, output_file: str, host: str, timestamp: str) -> None:
        self._output_file = output_file
        self._host        = host or "Unknown"
        self._timestamp   = timestamp or ""
        self._vol_pct     = self._DEFAULT_VOL

        self.root = tk.Tk()
        self.root.title("ADR — Manual Hardware Checks")
        self.root.configure(bg=BG)
        self.root.resizable(True, True)
        self._build()
        self._center()

    # ── Layout helpers ────────────────────────────────────────────────────────

    def _card(self, parent: tk.Widget, title: str) -> tk.Frame:
        """Labelled card container for a section."""
        wrap = tk.Frame(parent, bg=BG)
        wrap.pack(fill="x", padx=20, pady=(10, 0))
        tk.Label(
            wrap, text=title.upper(), bg=BG, fg=MUTED,
            font=("Helvetica", 9, "bold"),
        ).pack(anchor="w", padx=2, pady=(4, 2))
        card = tk.Frame(
            wrap, bg=CARD, bd=0, relief="flat",
            highlightbackground=BORDER, highlightthickness=1,
        )
        card.pack(fill="x")
        card.columnconfigure(0, weight=1, minsize=200)
        card.columnconfigure(1, minsize=140)
        card.columnconfigure(2, minsize=120)
        return card

    def _rule(self, parent: tk.Widget, row: int) -> None:
        tk.Frame(parent, bg=BORDER, height=1).grid(
            row=row, column=0, columnspan=3, sticky="ew", padx=10,
        )

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self) -> None:
        root = self.root

        # ── Header bar ───────────────────────────────────────────────────────
        hdr = tk.Frame(root, bg=PRIMARY)
        hdr.pack(fill="x")
        tk.Label(
            hdr, text="ADR  ·  Manual Hardware Checks",
            bg=PRIMARY, fg="white", font=("Helvetica", 15, "bold"),
            padx=20, pady=14,
        ).pack(side="left")
        sub = self._host
        if self._timestamp:
            sub += f"  ·  {self._timestamp}"
        tk.Label(
            hdr, text=sub, bg=PRIMARY, fg=HDR_SUB,
            font=("Helvetica", 10), padx=20,
        ).pack(side="right", anchor="center", pady=16)

        # ── Scrollable canvas body ────────────────────────────────────────────
        body_wrap = tk.Frame(root, bg=BG)
        body_wrap.pack(fill="both", expand=True)

        canvas = tk.Canvas(body_wrap, bg=BG, highlightthickness=0)
        vbar   = ttk.Scrollbar(body_wrap, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=vbar.set)
        vbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        body   = tk.Frame(canvas, bg=BG)
        win_id = canvas.create_window((0, 0), window=body, anchor="nw")

        canvas.bind("<Configure>",
                    lambda e: canvas.itemconfig(win_id, width=e.width))
        body.bind("<Configure>",
                  lambda e: canvas.configure(scrollregion=canvas.bbox("all")))

        def _wheel(e: tk.Event) -> None:
            delta = -1 if (e.delta < 0 or e.num == 5) else 1
            canvas.yview_scroll(delta, "units")

        root.bind_all("<MouseWheel>", _wheel)
        root.bind_all("<Button-4>",   _wheel)
        root.bind_all("<Button-5>",   _wheel)

        # ── Audio section ─────────────────────────────────────────────────────
        audio = self._card(body, "Audio")

        # Volume slider row
        vol_row = tk.Frame(audio, bg=CARD)
        vol_row.grid(row=0, column=0, columnspan=3, sticky="ew",
                     padx=16, pady=(12, 4))
        tk.Label(
            vol_row, text="Test Volume", bg=CARD, fg=TEXT,
            font=("Helvetica", 11),
        ).pack(side="left")
        self._vol_lbl = tk.Label(
            vol_row, text=f"{self._DEFAULT_VOL}%", bg=CARD, fg=PRIMARY,
            font=("Helvetica", 11, "bold"), width=5,
        )
        self._vol_lbl.pack(side="right")
        self._vol_var = tk.IntVar(value=self._DEFAULT_VOL)
        ttk.Scale(
            vol_row, from_=0, to=100, orient="horizontal",
            variable=self._vol_var, command=self._on_vol,
        ).pack(side="left", fill="x", expand=True, padx=(12, 8))

        self._rule(audio, 1)
        self._lspk = CheckRow(
            audio, "Left Speaker",
            "Plays a tone through the left channel only",
            "▶  Play Left",
            lambda: play_tone(440, 1.5, self._vol_pct / 100, "left"),
            row=2,
        )
        self._rule(audio, 3)
        self._rspk = CheckRow(
            audio, "Right Speaker",
            "Plays a tone through the right channel only",
            "▶  Play Right",
            lambda: play_tone(520, 1.5, self._vol_pct / 100, "right"),
            row=4,
        )
        self._rule(audio, 5)
        self._mic = CheckRow(
            audio, "Microphone",
            "Opens sound settings — check input level while speaking",
            "⚙  Sound Settings",
            open_sound_settings,
            row=6,
        )

        # ── Camera section ────────────────────────────────────────────────────
        cam = self._card(body, "Camera")
        self._cam = CheckRow(
            cam, "Webcam",
            "Opens the system camera app",
            "📷  Open Camera",
            open_camera,
            row=0,
        )

        # ── Display section ───────────────────────────────────────────────────
        disp = self._card(body, "Display")
        tk.Label(
            disp,
            text="Check for cracks, dead pixels, backlight evenness, "
                 "and external monitor output.",
            bg=CARD, fg=MUTED, font=("Helvetica", 9),
            wraplength=440, justify="left",
        ).grid(row=0, column=0, columnspan=3, sticky="w", padx=16, pady=(10, 2))
        self._rule(disp, 1)
        self._disp = CheckRow(
            disp, "Display / Screen",
            "No cracks · backlight even · correct resolution",
            "⚙  Display Settings",
            open_display_settings,
            row=2,
        )
        self._rule(disp, 3)
        self._touch = CheckRow(
            disp, "Touch Screen (if fitted)",
            "Touch and multi-touch responsive",
            row=4,
        )

        # ── Input devices section ─────────────────────────────────────────────
        inp = self._card(body, "Input Devices")
        self._kbd = CheckRow(
            inp, "Keyboard",
            "Opens a text editor — type a sentence to test all keys",
            "⌨  Text Editor",
            open_text_editor,
            row=0,
        )
        self._rule(inp, 1)
        self._pad = CheckRow(
            inp, "Trackpad / Mouse",
            "Move cursor · left-click · right-click · scroll",
            row=2,
        )

        # bottom spacer
        tk.Frame(body, bg=BG, height=16).pack()

        # ── Footer ────────────────────────────────────────────────────────────
        footer = tk.Frame(root, bg=BG, pady=12)
        footer.pack(fill="x", side="bottom")

        tk.Button(
            footer, text="Skip — Fill In Later",
            command=self._on_skip, bg=BG, fg=MUTED,
            relief="flat", font=("Helvetica", 11),
            cursor="hand2", padx=12, pady=6,
        ).pack(side="left", padx=20)

        tk.Button(
            footer, text="  Save Results to Report  ",
            command=self._on_save,
            bg=SUCCESS, fg="white", relief="flat",
            activebackground="#1B5E20", activeforeground="white",
            font=("Helvetica", 12, "bold"),
            cursor="hand2", padx=14, pady=8, bd=0,
        ).pack(side="right", padx=20)

        root.minsize(580, 520)
        root.geometry("700x760")

    def _center(self) -> None:
        self.root.update_idletasks()
        w  = self.root.winfo_width()
        h  = self.root.winfo_height()
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        self.root.geometry(f"{w}x{h}+{(sw - w) // 2}+{(sh - h) // 2}")

    # ── Callbacks ─────────────────────────────────────────────────────────────

    def _on_vol(self, _=None) -> None:
        self._vol_pct = self._vol_var.get()
        self._vol_lbl.config(text=f"{self._vol_pct}%")

    def _collect(self, mode: str) -> dict:
        return {
            "mode":         mode,
            "left_speaker":  self._lspk.get(),
            "right_speaker": self._rspk.get(),
            "microphone":    self._mic.get(),
            "webcam":        self._cam.get(),
            "display":       self._disp.get(),
            "touch_screen":  self._touch.get(),
            "keyboard":      self._kbd.get(),
            "trackpad":      self._pad.get(),
        }

    def _write(self, data: dict) -> None:
        if not self._output_file:
            print(json.dumps(data, indent=2))
            return
        try:
            with open(self._output_file, "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2)
        except OSError as exc:
            print(f"ADR checks: could not write results: {exc}", file=sys.stderr)

    def _on_save(self) -> None:
        self._write(self._collect("interactive_gui"))
        self.root.destroy()

    def _on_skip(self) -> None:
        skipped = "Skipped — fill in manually"
        self._write({
            "mode":          "skipped",
            "left_speaker":  skipped,
            "right_speaker": skipped,
            "microphone":    skipped,
            "webcam":        skipped,
            "display":       skipped,
            "touch_screen":  skipped,
            "keyboard":      skipped,
            "trackpad":      skipped,
        })
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="ADR Manual Hardware Checks GUI")
    ap.add_argument("--output-file", default="",
                    help="JSON file to write results (default: stdout)")
    ap.add_argument("--host",      default="Unknown",
                    help="Hostname shown in the window header")
    ap.add_argument("--timestamp", default="",
                    help="Timestamp shown in the window header")
    args = ap.parse_args()
    AdrChecksGui(args.output_file, args.host, args.timestamp).run()


if __name__ == "__main__":
    main()
