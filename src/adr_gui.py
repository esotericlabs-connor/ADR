#!/usr/bin/env python3
"""
ADR Launcher — cross-platform GUI for Automated Diagnostic Report.
Requires only Python 3 + tkinter (stdlib).  No pip installs needed.

CLI users: run adr.sh (macOS/Linux) or adr.ps1 (Windows) directly.
"""

from __future__ import annotations  # defers annotation evaluation → Python 3.7+ compatible

import math
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import wave
from tkinter import BooleanVar, IntVar, StringVar, filedialog, messagebox
import tkinter as tk
from tkinter import ttk

# ── Platform ──────────────────────────────────────────────────────────────────
PLATFORM   = sys.platform                                    # win32 | darwin | linux
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

BACKEND = (
    os.path.join(SCRIPT_DIR, "adr.ps1") if PLATFORM == "win32"
    else os.path.join(SCRIPT_DIR, "adr.sh")
)
ENV_FILE    = os.path.join(SCRIPT_DIR, "adr.env")
ENV_EXAMPLE = os.path.join(SCRIPT_DIR, "adr.env.example")

# ── Fonts ─────────────────────────────────────────────────────────────────────
_UI   = "Segoe UI"    if PLATFORM == "win32" else ("Helvetica" if PLATFORM == "darwin" else "DejaVu Sans")
_MONO = "Consolas"    if PLATFORM == "win32" else ("Menlo"     if PLATFORM == "darwin" else "Monospace")

FONT_BODY  = (_UI,   10)
FONT_SMALL = (_UI,    9)
FONT_MONO  = (_MONO,  9)
FONT_H1    = (_UI,   20, "bold")
FONT_H2    = (_UI,   14, "bold")
FONT_H3    = (_UI,   11, "bold")
FONT_BTN   = (_UI,   10, "bold")
FONT_NAV   = (_UI,    9)

# ── Colour palette ────────────────────────────────────────────────────────────
C = dict(
    sidebar        = "#1a2332",
    sidebar_h      = "#273447",
    sidebar_a      = "#3b82f6",
    sidebar_text   = "#94a3b8",
    sidebar_hi_txt = "#ffffff",
    bg             = "#f1f5f9",
    card           = "#ffffff",
    border         = "#e2e8f0",
    text           = "#0f172a",
    muted          = "#64748b",
    accent         = "#2563eb",
    success        = "#16a34a",
    danger         = "#dc2626",
    warn           = "#d97706",
    run_btn        = "#16a34a",
)


# ═══════════════════════════════════════════════════════════════════════════════
# Env-file helpers
# ═══════════════════════════════════════════════════════════════════════════════

def load_env(path: str = ENV_FILE) -> dict:
    """Parse KEY=VALUE pairs from an env file (ignores blank lines and # comments)."""
    out: dict = {}
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def save_env(data: dict, path: str = ENV_FILE) -> None:
    """Write KEY=VALUE pairs to the env file (full overwrite)."""
    lines = [
        "# ADR configuration — written by ADR Launcher\n",
        "# Do not store passwords, Wi-Fi keys, or product keys here.\n\n",
    ]
    for k, v in data.items():
        lines.append(f"{k}={v}\n")
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


# ═══════════════════════════════════════════════════════════════════════════════
# Audio helpers (zero external dependencies — stdlib only)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_wav(freq: float, duration: float, volume: float, pan: str) -> str:
    """Build a stereo WAV tone file; returns its temp path."""
    rate  = 44100
    n     = int(rate * duration)
    lv    = volume if pan in ("left",  "both") else 0.0
    rv    = volume if pan in ("right", "both") else 0.0
    tmp   = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    with wave.open(tmp.name, "w") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        for i in range(n):
            s     = math.sin(2 * math.pi * freq * i / rate)
            left  = int(s * lv * 32767)
            right = int(s * rv * 32767)
            wf.writeframesraw(struct.pack("<hh", left, right))
    return tmp.name


def play_tone(freq: float, duration: float, volume: float, pan: str) -> None:
    """Play a tone asynchronously in a daemon thread; cleans up the temp WAV."""
    def _run() -> None:
        path = _make_wav(freq, duration, volume, pan)
        try:
            if PLATFORM == "win32":
                import winsound
                winsound.PlaySound(path, winsound.SND_FILENAME)
            elif PLATFORM == "darwin":
                subprocess.run(["afplay", path], check=False, capture_output=True)
            else:
                for player in ("paplay", "aplay", "ffplay", "mpv"):
                    if not shutil.which(player):
                        continue
                    args = {
                        "ffplay": ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path],
                        "mpv":    ["mpv", "--no-video", "--really-quiet", path],
                    }.get(player, [player, path])
                    subprocess.run(args, check=False, capture_output=True)
                    break
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
    threading.Thread(target=_run, daemon=True).start()


# ── System launchers ──────────────────────────────────────────────────────────

def open_camera() -> None:
    if PLATFORM == "win32":
        subprocess.Popen(["explorer", "microsoft.windows.camera:"])
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", "-a", "Photo Booth"])
    else:
        for app in ("cheese", "kamoso", "guvcview"):
            if shutil.which(app):
                subprocess.Popen([app])
                return
        subprocess.Popen(["ffplay", "-f", "v4l2", "/dev/video0"])


def open_sound_settings() -> None:
    if PLATFORM == "win32":
        subprocess.Popen(["control", "mmsys.cpl"])
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.sound"])
    else:
        for app in ("pavucontrol", "gnome-control-center", "xfce4-mixer"):
            if shutil.which(app):
                subprocess.Popen([app])
                return


def open_display_settings() -> None:
    if PLATFORM == "win32":
        subprocess.Popen(["control", "desk.cpl"])
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.displays"])
    else:
        for app in ("gnome-control-center", "xfce4-display-settings", "arandr"):
            if shutil.which(app):
                extra = ["display"] if app == "gnome-control-center" else []
                subprocess.Popen([app] + extra)
                return


def open_file(path: str) -> None:
    if PLATFORM == "win32":
        os.startfile(path)
    elif PLATFORM == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# ═══════════════════════════════════════════════════════════════════════════════
# CheckRow widget
# ═══════════════════════════════════════════════════════════════════════════════

class CheckRow:
    """One hardware-check row: label + optional action button + Pass/Fail/N-A radios."""

    def __init__(
        self,
        parent: tk.Widget,
        label: str,
        action_text: str = "",
        action_cmd=None,
    ) -> None:
        self._var = StringVar(value="")
        row = tk.Frame(parent, bg=C["card"])
        row.pack(fill="x", padx=0, pady=3)

        tk.Label(
            row, text=label, bg=C["card"], fg=C["text"],
            font=FONT_BODY, width=36, anchor="w",
        ).pack(side="left")

        if action_text and action_cmd:
            tk.Button(
                row, text=action_text, command=action_cmd,
                font=FONT_SMALL, bg=C["accent"], fg="white",
                relief="flat", padx=8, pady=2, cursor="hand2",
                activebackground=C["sidebar_h"], activeforeground="white",
            ).pack(side="left", padx=(0, 10))

        for val, colour in (("Pass", C["success"]), ("Fail", C["danger"]), ("N/A", C["muted"])):
            tk.Radiobutton(
                row, text=val, variable=self._var, value=val,
                bg=C["card"], fg=colour, selectcolor=C["card"],
                activebackground=C["card"], font=FONT_SMALL, indicatoron=True,
            ).pack(side="left", padx=5)

    def get(self) -> str:
        return self._var.get() or "Not tested"


# ═══════════════════════════════════════════════════════════════════════════════
# Reusable widget builders
# ═══════════════════════════════════════════════════════════════════════════════

def _section_label(parent: tk.Widget, text: str) -> tk.Frame:
    tk.Label(
        parent, text=text, bg=C["bg"], fg=C["muted"],
        font=(_UI, 8, "bold"),
    ).pack(anchor="w", pady=(14, 3), padx=2)
    card = tk.Frame(
        parent, bg=C["card"], highlightthickness=1,
        highlightbackground=C["border"],
    )
    card.pack(fill="x", pady=(0, 4))
    return card


def _field_row(parent: tk.Widget, label: str, var: StringVar, show: str = "") -> None:
    row = tk.Frame(parent, bg=C["card"])
    row.pack(fill="x", padx=14, pady=4)
    tk.Label(row, text=label, bg=C["card"], fg=C["text"],
             font=FONT_SMALL, width=30, anchor="w").pack(side="left")
    tk.Entry(
        row, textvariable=var, show=show, font=FONT_SMALL,
        bg=C["bg"], fg=C["text"], relief="flat",
        highlightthickness=1, highlightbackground=C["border"],
    ).pack(side="left", fill="x", expand=True)


def _combo_row(
    parent: tk.Widget, label: str, var: StringVar, values: list
) -> ttk.Combobox:
    row = tk.Frame(parent, bg=C["card"])
    row.pack(fill="x", padx=14, pady=4)
    tk.Label(row, text=label, bg=C["card"], fg=C["text"],
             font=FONT_SMALL, width=30, anchor="w").pack(side="left")
    cb = ttk.Combobox(row, textvariable=var, values=values, state="readonly", font=FONT_SMALL)
    cb.pack(side="left", fill="x", expand=True)
    return cb


def _check_row(parent: tk.Widget, label: str, var: BooleanVar) -> None:
    row = tk.Frame(parent, bg=C["card"])
    row.pack(fill="x", padx=14, pady=4)
    tk.Checkbutton(
        row, text=label, variable=var, bg=C["card"], fg=C["text"],
        font=FONT_SMALL, activebackground=C["card"], selectcolor=C["card"],
    ).pack(side="left")


def _make_scrollable(parent: tk.Widget) -> tk.Frame:
    """Wrap parent in a canvas+scrollbar; return the inner content frame."""
    canvas = tk.Canvas(parent, bg=C["bg"], highlightthickness=0)
    vsb = ttk.Scrollbar(parent, orient="vertical", command=canvas.yview)
    canvas.configure(yscrollcommand=vsb.set)
    vsb.pack(side="right", fill="y")
    canvas.pack(fill="both", expand=True)
    inner = tk.Frame(canvas, bg=C["bg"])
    wid = canvas.create_window((0, 0), window=inner, anchor="nw")
    inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
    canvas.bind("<Configure>", lambda e: canvas.itemconfig(wid, width=e.width))

    def _scroll(event):
        delta = -1 * (event.delta // 120) if PLATFORM == "win32" else (-1 if event.num == 4 else 1)
        canvas.yview_scroll(delta, "units")

    for widget in (canvas, inner):
        if PLATFORM == "win32":
            widget.bind("<MouseWheel>", _scroll)
        else:
            widget.bind("<Button-4>", _scroll)
            widget.bind("<Button-5>", _scroll)

    return inner


# ═══════════════════════════════════════════════════════════════════════════════
# Main application
# ═══════════════════════════════════════════════════════════════════════════════

class AdrApp(tk.Tk):

    def __init__(self) -> None:
        super().__init__()
        self.title("ADR — Automated Diagnostic Report")
        self.geometry("1080x700")
        self.minsize(820, 560)
        self.configure(bg=C["sidebar"])

        # Runtime state
        self._proc:         subprocess.Popen | None = None
        self._out_q:        queue.Queue             = queue.Queue()
        self._report_path:  str | None              = None

        self._init_settings_vars()
        self._build_layout()
        self._load_settings_from_env()
        self._show_page("home")

    # ── Layout skeleton ───────────────────────────────────────────────────────

    def _build_layout(self) -> None:
        self._sidebar = tk.Frame(self, bg=C["sidebar"], width=200)
        self._sidebar.pack(side="left", fill="y")
        self._sidebar.pack_propagate(False)
        self._content = tk.Frame(self, bg=C["bg"])
        self._content.pack(side="left", fill="both", expand=True)
        self._build_sidebar()
        self._build_pages()

    def _build_sidebar(self) -> None:
        s = self._sidebar

        # Logo area
        logo = tk.Frame(s, bg=C["sidebar"], pady=22)
        logo.pack(fill="x")
        tk.Label(logo, text="ADR", bg=C["sidebar"], fg="#ffffff",
                 font=(_UI, 26, "bold")).pack()
        tk.Label(logo, text="Automated Diagnostic Report", bg=C["sidebar"],
                 fg=C["sidebar_text"], font=(_UI, 7)).pack()

        tk.Frame(s, bg="#2d3f52", height=1).pack(fill="x", padx=18, pady=2)

        # Nav
        self._nav_btns: dict = {}
        for key, label in (
            ("home",     "⌂   Home"),
            ("run",      "▶   Run Diagnostics"),
            ("manual",   "✓   Manual Checks"),
            ("settings", "⚙   Settings"),
        ):
            btn = tk.Button(
                s, text=label, anchor="w",
                font=FONT_NAV, relief="flat", bd=0, padx=18, pady=11,
                bg=C["sidebar"], fg=C["sidebar_text"],
                activebackground=C["sidebar_h"], activeforeground="#ffffff",
                cursor="hand2",
                command=lambda k=key: self._show_page(k),
            )
            btn.pack(fill="x")
            self._nav_btns[key] = btn

        # Spacer
        tk.Frame(s, bg=C["sidebar"]).pack(fill="both", expand=True)

        # Bottom run button
        tk.Frame(s, bg="#2d3f52", height=1).pack(fill="x", padx=18, pady=4)
        self._sidebar_run = tk.Button(
            s, text="▶  Run Diagnostics", font=FONT_BTN,
            bg=C["run_btn"], fg="white", pady=11, relief="flat",
            cursor="hand2", activebackground="#15803d", activeforeground="white",
            command=self._start_run,
        )
        self._sidebar_run.pack(fill="x", padx=14, pady=14)

    def _build_pages(self) -> None:
        self._pages: dict = {}
        for name, builder in (
            ("home",     self._build_home),
            ("run",      self._build_run),
            ("manual",   self._build_manual),
            ("settings", self._build_settings),
        ):
            frame = tk.Frame(self._content, bg=C["bg"])
            builder(frame)
            self._pages[name] = frame

    # ── Navigation ────────────────────────────────────────────────────────────

    def _show_page(self, name: str) -> None:
        for key, btn in self._nav_btns.items():
            if key == name:
                btn.configure(bg=C["sidebar_a"], fg="#ffffff")
            else:
                btn.configure(bg=C["sidebar"], fg=C["sidebar_text"])
        for key, frame in self._pages.items():
            if key == name:
                frame.pack(fill="both", expand=True)
            else:
                frame.pack_forget()

    # ─────────────────────────────────────────────────────────────────────────
    # HOME PAGE
    # ─────────────────────────────────────────────────────────────────────────

    def _build_home(self, parent: tk.Frame) -> None:
        inner = _make_scrollable(parent)
        pad   = tk.Frame(inner, bg=C["bg"])
        pad.pack(fill="both", expand=True, padx=36, pady=28)

        # Hero banner
        hero = tk.Frame(pad, bg=C["accent"], padx=28, pady=28)
        hero.pack(fill="x", pady=(0, 22))
        tk.Label(hero, text="ADR — Automated Diagnostic Report",
                 bg=C["accent"], fg="white", font=FONT_H1).pack(anchor="w")
        tk.Label(hero,
                 text="Cross-platform hardware + software diagnostics for IT technicians and MSPs.",
                 bg=C["accent"], fg="#bfdbfe", font=FONT_BODY).pack(anchor="w", pady=(6, 0))

        # Quick-action cards
        qa = tk.Frame(pad, bg=C["bg"])
        qa.pack(fill="x", pady=(0, 22))
        for col in range(3):
            qa.columnconfigure(col, weight=1, uniform="qa")

        for col, (title, desc, colour, cmd) in enumerate((
            ("▶  Run Full Diagnostics",
             "Collect hardware, software, security, network, and agent data.",
             C["run_btn"], self._start_run),
            ("✓  Manual Checks",
             "Test speakers, webcam, keyboard, display, touch screen, and more.",
             C["accent"], lambda: self._show_page("manual")),
            ("⚙  Settings",
             "Configure AI enrichment, SES email delivery, and run options.",
             C["muted"], lambda: self._show_page("settings")),
        )):
            card = tk.Frame(
                qa, bg=C["card"],
                highlightthickness=1, highlightbackground=C["border"],
            )
            card.grid(row=0, column=col, padx=(0 if col == 0 else 10, 0), sticky="nsew")
            tk.Button(
                card, text=title, font=FONT_BTN, bg=colour, fg="white",
                relief="flat", pady=10, cursor="hand2",
                activebackground=C["sidebar_h"], activeforeground="white",
                command=cmd,
            ).pack(fill="x", padx=14, pady=(14, 6))
            tk.Label(
                card, text=desc, bg=C["card"], fg=C["muted"],
                font=FONT_SMALL, wraplength=230, justify="left",
            ).pack(padx=14, pady=(0, 14), anchor="w")

        # Backend status
        info = _section_label(pad, "BACKEND SCRIPT")
        row  = tk.Frame(info, bg=C["card"])
        row.pack(fill="x", padx=14, pady=10)
        exists = os.path.isfile(BACKEND)
        tk.Label(row, text=os.path.basename(BACKEND),
                 bg=C["card"], fg=C["text"], font=FONT_BODY).pack(side="left")
        tk.Label(
            row,
            text="  ✓ Found" if exists else "  ✗ Not found",
            bg=C["card"], fg=C["success"] if exists else C["danger"], font=FONT_SMALL,
        ).pack(side="left")
        tk.Label(row, text=f"  {BACKEND}", bg=C["card"],
                 fg=C["muted"], font=FONT_SMALL).pack(side="left")

        # CLI reference
        cli_card = _section_label(pad, "CLI USAGE (WITHOUT GUI)")
        if PLATFORM == "win32":
            cli_text = (
                "PowerShell (run as Administrator):\n"
                "  .\\adr.ps1\n"
                "  .\\adr.ps1 -UseAiEnrichment\n"
                "  .\\adr.ps1 -SkipManualChecks -SkipAgentScan\n"
                "  .\\adr.ps1 -OutputDirectory C:\\Reports"
            )
        else:
            cli_text = (
                "Terminal:\n"
                "  bash adr.sh\n"
                "  bash adr.sh --ai\n"
                "  bash adr.sh --skip-manual --skip-agent-scan\n"
                "  bash adr.sh --output-dir ~/Reports"
            )
        tk.Label(
            cli_card, text=cli_text, bg=C["card"], fg=C["muted"],
            font=FONT_MONO, justify="left", anchor="w",
        ).pack(anchor="w", padx=14, pady=10)

    # ─────────────────────────────────────────────────────────────────────────
    # RUN PAGE
    # ─────────────────────────────────────────────────────────────────────────

    def _build_run(self, parent: tk.Frame) -> None:
        # Header bar
        hdr = tk.Frame(parent, bg=C["bg"])
        hdr.pack(fill="x", padx=26, pady=(20, 0))
        tk.Label(hdr, text="Run Diagnostics",
                 bg=C["bg"], fg=C["text"], font=FONT_H2).pack(side="left")
        self._run_status = tk.Label(hdr, text="", bg=C["bg"],
                                    fg=C["muted"], font=FONT_SMALL)
        self._run_status.pack(side="left", padx=14)

        btns = tk.Frame(hdr, bg=C["bg"])
        btns.pack(side="right")
        self._btn_start = tk.Button(
            btns, text="▶  Start", font=FONT_BTN,
            bg=C["run_btn"], fg="white", relief="flat", padx=14, pady=6,
            cursor="hand2", command=self._start_run,
        )
        self._btn_start.pack(side="left", padx=3)
        self._btn_cancel = tk.Button(
            btns, text="✕  Cancel", font=FONT_BTN,
            bg=C["danger"], fg="white", relief="flat", padx=14, pady=6,
            cursor="hand2", state="disabled", command=self._cancel_run,
        )
        self._btn_cancel.pack(side="left", padx=3)
        self._btn_open = tk.Button(
            btns, text="📄  Open Report", font=FONT_BTN,
            bg=C["accent"], fg="white", relief="flat", padx=14, pady=6,
            cursor="hand2", state="disabled", command=self._open_report,
        )
        self._btn_open.pack(side="left", padx=3)

        # Progress bar
        self._progress = ttk.Progressbar(parent, mode="indeterminate")
        self._progress.pack(fill="x", padx=26, pady=(10, 4))

        # Log
        log_frame = tk.Frame(parent, bg=C["bg"])
        log_frame.pack(fill="both", expand=True, padx=26, pady=(0, 6))
        self._log_text = tk.Text(
            log_frame,
            bg="#0d1117", fg="#c9d1d9", font=FONT_MONO,
            relief="flat", wrap="word", state="disabled",
            highlightthickness=1, highlightbackground=C["border"],
        )
        log_sb = ttk.Scrollbar(log_frame, command=self._log_text.yview)
        self._log_text.configure(yscrollcommand=log_sb.set)
        log_sb.pack(side="right", fill="y")
        self._log_text.pack(side="left", fill="both", expand=True)

        # Post-run action bar (manual checks prompt)
        self._postrun = tk.Frame(parent, bg=C["bg"])
        self._postrun.pack(fill="x", padx=26, pady=(0, 14))

    # ── Log helpers ───────────────────────────────────────────────────────────

    def _log(self, text: str) -> None:
        self._log_text.configure(state="normal")
        self._log_text.insert("end", text)
        self._log_text.see("end")
        self._log_text.configure(state="disabled")

    def _log_clear(self) -> None:
        self._log_text.configure(state="normal")
        self._log_text.delete("1.0", "end")
        self._log_text.configure(state="disabled")

    # ── Subprocess management ─────────────────────────────────────────────────

    def _start_run(self) -> None:
        if self._proc and self._proc.poll() is None:
            messagebox.showwarning("Already running",
                                   "A diagnostic run is already in progress.")
            return

        if not os.path.isfile(BACKEND):
            messagebox.showerror(
                "Backend not found",
                f"Could not find:\n{BACKEND}\n\nEnsure adr_gui.py is in the same folder as the ADR scripts.",
            )
            return

        self._save_settings_to_env()
        self._show_page("run")
        self._log_clear()
        self._btn_start.configure(state="disabled")
        self._btn_cancel.configure(state="normal")
        self._btn_open.configure(state="disabled")
        self._report_path = None

        # Clear post-run bar
        for w in self._postrun.winfo_children():
            w.destroy()

        # Build command
        use_ai     = self._bv["USE_AI"].get()
        skip_agent = self._bv["ADR_SKIP_AGENT_SCAN"].get()
        out_dir    = self._sv["ADR_OUTPUT_DIR"].get().strip()

        if PLATFORM == "win32":
            cmd = [
                "powershell.exe", "-ExecutionPolicy", "Bypass",
                "-NoProfile", "-File", BACKEND,
                "-SkipManualChecks",
            ]
            if use_ai:
                cmd.append("-UseAiEnrichment")
                provider = self._sv["ADR_AI_PROVIDER"].get().strip()
                if provider and provider != "auto":
                    cmd += ["-AiProvider", provider]
            if skip_agent:
                cmd.append("-SkipAgentScan")
            if out_dir:
                cmd += ["-OutputDirectory", out_dir]
        else:
            cmd = ["bash", BACKEND, "--skip-manual"]
            if use_ai:
                cmd.append("--ai")
                provider = self._sv["ADR_AI_PROVIDER"].get().strip()
                if provider and provider != "auto":
                    cmd += ["--ai-provider", provider]
            if skip_agent:
                cmd.append("--skip-agent-scan")
            if out_dir:
                cmd += ["--output-dir", out_dir]

        # Env: merge adr.env into process environment
        proc_env = os.environ.copy()
        proc_env.update(load_env(ENV_FILE))
        proc_env["ADR_SKIP_MANUAL_CHECKS"] = "true"  # GUI handles manual checks

        self._log(f"$ {' '.join(cmd)}\n\n")
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=proc_env,
                cwd=SCRIPT_DIR,
            )
        except (FileNotFoundError, OSError) as exc:
            self._log(f"\n[ERROR] Could not launch: {exc}\n")
            self._btn_start.configure(state="normal")
            self._btn_cancel.configure(state="disabled")
            return

        self._progress.start(10)
        self._run_status.configure(text="Running…", fg=C["warn"])
        threading.Thread(target=self._reader_thread, daemon=True).start()
        self.after(80, self._poll_queue)

    def _reader_thread(self) -> None:
        proc = self._proc
        if not proc or not proc.stdout:
            self._out_q.put(("done", -1))
            return
        try:
            for raw in iter(proc.stdout.readline, b""):
                line = raw.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
                self._out_q.put(("line", line))
        finally:
            rc = proc.wait()
            self._out_q.put(("done", rc))

    def _poll_queue(self) -> None:
        try:
            while True:
                kind, data = self._out_q.get_nowait()
                if kind == "line":
                    self._log(data)
                    if "Diagnostic report written to:" in data:
                        candidate = data.split("Diagnostic report written to:")[-1].strip()
                        if os.path.isfile(candidate):
                            self._report_path = candidate
                elif kind == "done":
                    self._on_done(data)
                    return
        except queue.Empty:
            pass
        self.after(80, self._poll_queue)

    def _on_done(self, rc: int) -> None:
        self._progress.stop()
        self._btn_start.configure(state="normal")
        self._btn_cancel.configure(state="disabled")
        if rc == 0:
            self._run_status.configure(text="Complete ✓", fg=C["success"])
            self._log("\n✓ Diagnostics complete.\n")
            if self._report_path:
                self._log(f"Report: {self._report_path}\n")
                self._btn_open.configure(state="normal")
            self._show_manual_prompt()
        else:
            self._run_status.configure(text=f"Exited ({rc})", fg=C["danger"])
            self._log(f"\n✗ Script exited with code {rc}.\n")

    def _show_manual_prompt(self) -> None:
        if self._bv["ADR_SKIP_MANUAL_CHECKS"].get():
            return
        for w in self._postrun.winfo_children():
            w.destroy()
        tk.Label(self._postrun, text="Ready to run manual hardware checks?",
                 bg=C["bg"], fg=C["text"], font=FONT_BODY).pack(side="left")
        tk.Button(
            self._postrun, text="→  Open Manual Checks",
            font=FONT_BTN, bg=C["accent"], fg="white",
            relief="flat", padx=10, pady=5, cursor="hand2",
            command=lambda: self._show_page("manual"),
        ).pack(side="left", padx=8)
        tk.Button(
            self._postrun, text="Skip",
            font=FONT_SMALL, bg=C["bg"], fg=C["muted"],
            relief="flat", cursor="hand2",
            command=lambda: [w.destroy() for w in self._postrun.winfo_children()],
        ).pack(side="left")

    def _cancel_run(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
        self._progress.stop()
        self._run_status.configure(text="Cancelled", fg=C["warn"])
        self._log("\n[Cancelled by user]\n")
        self._btn_start.configure(state="normal")
        self._btn_cancel.configure(state="disabled")

    def _open_report(self) -> None:
        if not self._report_path or not os.path.isfile(self._report_path):
            messagebox.showwarning("No report", "Report file not found.")
            return
        open_file(self._report_path)

    # ─────────────────────────────────────────────────────────────────────────
    # MANUAL CHECKS PAGE
    # ─────────────────────────────────────────────────────────────────────────

    def _build_manual(self, parent: tk.Frame) -> None:
        inner = _make_scrollable(parent)
        pad   = tk.Frame(inner, bg=C["bg"])
        pad.pack(fill="both", expand=True, padx=36, pady=24)

        tk.Label(pad, text="Manual Hardware Checks",
                 bg=C["bg"], fg=C["text"], font=FONT_H2).pack(anchor="w")
        tk.Label(pad,
                 text="Test each component using the action buttons, then mark Pass / Fail / N/A.",
                 bg=C["bg"], fg=C["muted"], font=FONT_SMALL).pack(anchor="w", pady=(3, 14))

        # Volume slider (shared by speaker tests)
        vol_card = _section_label(pad, "SOUND TEST VOLUME")
        vf = tk.Frame(vol_card, bg=C["card"])
        vf.pack(fill="x", padx=14, pady=10)
        self._vol = IntVar(value=50)
        vol_lbl = tk.Label(vf, text="50%", bg=C["card"],
                           fg=C["text"], font=FONT_SMALL, width=5)
        vol_lbl.pack(side="right")
        ttk.Scale(
            vf, from_=0, to=100, variable=self._vol, orient="horizontal",
            command=lambda v: vol_lbl.configure(text=f"{int(float(v))}%"),
        ).pack(side="left", fill="x", expand=True, padx=(0, 8))

        # Audio
        audio_card = _section_label(pad, "AUDIO")
        self._chk_left  = CheckRow(audio_card, "Left Speaker",
            "▶  Test Left",  lambda: play_tone(440, 1.5, self._vol.get() / 100, "left"))
        self._chk_right = CheckRow(audio_card, "Right Speaker",
            "▶  Test Right", lambda: play_tone(440, 1.5, self._vol.get() / 100, "right"))
        self._chk_mic   = CheckRow(audio_card, "Microphone",
            "⚙  Sound Settings", open_sound_settings)
        tk.Frame(audio_card, bg=C["card"], height=6).pack()

        # Camera
        cam_card = _section_label(pad, "CAMERA")
        self._chk_webcam = CheckRow(cam_card, "Webcam",
            "▶  Open Camera", open_camera)
        tk.Frame(cam_card, bg=C["card"], height=6).pack()

        # Display
        disp_card = _section_label(pad, "DISPLAY")
        self._chk_display = CheckRow(disp_card, "Display (no cracks, backlight even)",
            "⚙  Display Settings", open_display_settings)
        self._chk_touch   = CheckRow(disp_card, "Touch Screen")
        tk.Frame(disp_card, bg=C["card"], height=6).pack()

        # Input
        input_card = _section_label(pad, "INPUT DEVICES")
        self._chk_keyboard = CheckRow(input_card, "Keyboard (all keys respond)")
        self._chk_trackpad = CheckRow(input_card, "Trackpad / Pointing Device")
        tk.Frame(input_card, bg=C["card"], height=6).pack()

        # Notes
        notes_card = _section_label(pad, "TECHNICIAN NOTES")
        self._notes = tk.Text(
            notes_card, height=4, font=FONT_BODY,
            bg=C["bg"], fg=C["text"], relief="flat", wrap="word",
            highlightthickness=1, highlightbackground=C["border"],
        )
        self._notes.pack(fill="x", padx=14, pady=10)

        # Save / skip buttons
        bf = tk.Frame(pad, bg=C["bg"])
        bf.pack(fill="x", pady=14)
        tk.Button(
            bf, text="💾  Save & Apply to Report", font=FONT_BTN,
            bg=C["success"], fg="white", relief="flat", padx=18, pady=8,
            cursor="hand2", command=self._save_manual,
        ).pack(side="left")
        tk.Button(
            bf, text="Skip / Fill In Later", font=FONT_SMALL,
            bg=C["bg"], fg=C["muted"], relief="flat", padx=14, pady=8,
            cursor="hand2", command=lambda: self._show_page("run"),
        ).pack(side="left", padx=10)
        self._manual_status = tk.Label(bf, text="", bg=C["bg"],
                                        fg=C["success"], font=FONT_SMALL)
        self._manual_status.pack(side="left", padx=6)

    def _save_manual(self) -> None:
        results = {
            "left_speaker":  self._chk_left.get(),
            "right_speaker": self._chk_right.get(),
            "microphone":    self._chk_mic.get(),
            "webcam":        self._chk_webcam.get(),
            "display":       self._chk_display.get(),
            "touch_screen":  self._chk_touch.get(),
            "keyboard":      self._chk_keyboard.get(),
            "trackpad":      self._chk_trackpad.get(),
            "notes":         self._notes.get("1.0", "end").strip(),
        }
        if self._report_path and os.path.isfile(self._report_path):
            self._patch_report(self._report_path, results)
            self._manual_status.configure(
                text=f"✓ Saved to {os.path.basename(self._report_path)}",
                fg=C["success"],
            )
            self._btn_open.configure(state="normal")
        else:
            self._manual_status.configure(
                text="✓ Noted — run diagnostics first to attach to a report.",
                fg=C["warn"],
            )

    def _patch_report(self, path: str, results: dict) -> None:
        """Replace 'Not tested' placeholders in the report with actual check results."""
        patches = {
            "Display (no cracks, backlight even): ": results["display"],
            "Touch Screen: ":                        results["touch_screen"],
            "Keyboard (all keys responding): ":      results["keyboard"],
            "Trackpad / Pointing Device: ":          results["trackpad"],
            "Left Speaker: ":                        results["left_speaker"],
            "Right Speaker: ":                       results["right_speaker"],
            "Microphone: ":                          results["microphone"],
            "Webcam (live image visible): ":         results["webcam"],
            "Manual Check Mode: ":                   "GUI (ADR Launcher)",
        }
        notes = results.get("notes", "")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
            new_lines = []
            webcam_idx = None
            for line in lines:
                stripped = line.lstrip()
                indent   = line[: len(line) - len(stripped)]
                replaced = False
                for prefix, value in patches.items():
                    if stripped.startswith(prefix):
                        new_lines.append(f"{indent}{prefix}{value}\n")
                        replaced = True
                        break
                if not replaced:
                    new_lines.append(line)
                if "Webcam (live image visible):" in line:
                    webcam_idx = len(new_lines) - 1

            # Inject technician notes after webcam line if provided
            if notes and webcam_idx is not None:
                new_lines.insert(webcam_idx + 1, f"Technician Notes: {notes}\n")

            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(new_lines)
        except OSError as exc:
            messagebox.showerror("Patch failed", str(exc))

    # ─────────────────────────────────────────────────────────────────────────
    # SETTINGS PAGE
    # ─────────────────────────────────────────────────────────────────────────

    def _init_settings_vars(self) -> None:
        self._sv: dict[str, StringVar] = {
            # General
            "ADR_OUTPUT_DIR":                StringVar(),
            # AI – provider selection
            "ADR_AI_PROVIDER":               StringVar(value="auto"),
            "ADR_AI_API_KEY":                StringVar(),
            "ADR_AI_MODEL":                  StringVar(),
            "ADR_AI_ENDPOINT":               StringVar(),
            # OpenAI
            "OPENAI_API_KEY":                StringVar(),
            "ADR_OPENAI_MODEL":              StringVar(value="gpt-4o"),
            "ADR_OPENAI_ENDPOINT":           StringVar(),
            # Anthropic / Claude
            "ANTHROPIC_API_KEY":             StringVar(),
            "ADR_CLAUDE_MODEL":              StringVar(value="claude-sonnet-4-6"),
            "ADR_CLAUDE_ENDPOINT":           StringVar(),
            # Gemini
            "GEMINI_API_KEY":                StringVar(),
            "ADR_GEMINI_MODEL":              StringVar(value="gemini-2.5-flash"),
            "ADR_GEMINI_ENDPOINT":           StringVar(),
            # Perplexity
            "PERPLEXITY_API_KEY":            StringVar(),
            "ADR_PERPLEXITY_MODEL":          StringVar(value="sonar"),
            "ADR_PERPLEXITY_ENDPOINT":       StringVar(),
            # Mistral
            "MISTRAL_API_KEY":               StringVar(),
            "ADR_MISTRAL_MODEL":             StringVar(value="mistral-large-latest"),
            "ADR_MISTRAL_ENDPOINT":          StringVar(),
            # SES
            "ADR_SES_FROM_EMAIL":            StringVar(),
            "ADR_SES_TO_EMAIL":              StringVar(),
            "ADR_SES_AWS_ACCESS_KEY_ID":     StringVar(),
            "ADR_SES_AWS_SECRET_ACCESS_KEY": StringVar(),
            "ADR_SES_AWS_REGION":            StringVar(value="us-east-1"),
        }
        self._bv: dict[str, BooleanVar] = {
            "USE_AI":                 BooleanVar(value=False),
            "ADR_SKIP_MANUAL_CHECKS": BooleanVar(value=False),
            "ADR_SKIP_AGENT_SCAN":    BooleanVar(value=False),
            "ADR_SES_ENABLED":        BooleanVar(value=False),
        }

    def _load_settings_from_env(self) -> None:
        env = load_env(ENV_FILE)
        for k, var in self._sv.items():
            if k in env:
                var.set(env[k])
        for k, var in self._bv.items():
            if k in env:
                var.set(env[k].lower() in ("true", "1", "yes"))
        # Infer USE_AI from whether any API key is present
        ai_keys = ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
                   "PERPLEXITY_API_KEY", "MISTRAL_API_KEY", "ADR_AI_API_KEY")
        if any(env.get(k) for k in ai_keys):
            self._bv["USE_AI"].set(True)

    def _save_settings_to_env(self) -> None:
        data: dict = {}
        for k, var in self._sv.items():
            v = var.get().strip()
            if v:
                data[k] = v
        for k, var in self._bv.items():
            if k == "USE_AI":
                continue
            data[k] = "true" if var.get() else "false"
        save_env(data, ENV_FILE)

    def _build_settings(self, parent: tk.Frame) -> None:
        # Page header
        hdr = tk.Frame(parent, bg=C["bg"])
        hdr.pack(fill="x", padx=26, pady=(20, 0))
        tk.Label(hdr, text="Settings", bg=C["bg"],
                 fg=C["text"], font=FONT_H2).pack(side="left")
        self._settings_status = tk.Label(hdr, text="", bg=C["bg"],
                                          fg=C["success"], font=FONT_SMALL)
        self._settings_status.pack(side="right", padx=10)
        tk.Button(
            hdr, text="💾  Save Settings", font=FONT_BTN,
            bg=C["accent"], fg="white", relief="flat", padx=14, pady=6,
            cursor="hand2", command=self._on_save_settings,
        ).pack(side="right")

        # Tabbed notebook
        nb = ttk.Notebook(parent)
        nb.pack(fill="both", expand=True, padx=26, pady=14)

        for title, builder in (
            ("  General  ", self._build_settings_general),
            ("  AI       ", self._build_settings_ai),
            ("  Email    ", self._build_settings_email),
        ):
            tab    = tk.Frame(nb, bg=C["bg"])
            nb.add(tab, text=title)
            inner  = _make_scrollable(tab)
            pad    = tk.Frame(inner, bg=C["bg"])
            pad.pack(fill="both", expand=True, padx=26, pady=18)
            builder(pad)

    def _build_settings_general(self, parent: tk.Frame) -> None:
        # Output directory
        out_card = _section_label(parent, "REPORT OUTPUT DIRECTORY")
        row = tk.Frame(out_card, bg=C["card"])
        row.pack(fill="x", padx=14, pady=10)
        tk.Label(row, text="Save reports to:", bg=C["card"],
                 fg=C["text"], font=FONT_SMALL, width=22, anchor="w").pack(side="left")
        tk.Entry(
            row, textvariable=self._sv["ADR_OUTPUT_DIR"], font=FONT_SMALL,
            bg=C["bg"], fg=C["text"], relief="flat",
            highlightthickness=1, highlightbackground=C["border"],
        ).pack(side="left", fill="x", expand=True, padx=(0, 8))
        tk.Button(
            row, text="Browse…", font=FONT_SMALL, bg=C["accent"], fg="white",
            relief="flat", padx=8, cursor="hand2",
            command=self._browse_output_dir,
        ).pack(side="left")
        tk.Label(
            out_card,
            text="Leave blank to write reports beside the ADR script.",
            bg=C["card"], fg=C["muted"], font=FONT_SMALL,
        ).pack(anchor="w", padx=14, pady=(0, 10))

        # Skip options
        skip_card = _section_label(parent, "SKIP OPTIONS")
        _check_row(skip_card, "Skip manual hardware checks GUI (fill in afterward)",
                   self._bv["ADR_SKIP_MANUAL_CHECKS"])
        _check_row(skip_card, "Skip remote access agent scan",
                   self._bv["ADR_SKIP_AGENT_SCAN"])
        tk.Label(
            skip_card,
            text=(
                "When not skipped, the agent scan runs automatically in GUI mode\n"
                "(no interactive prompt is needed — the script detects the GUI environment)."
            ),
            bg=C["card"], fg=C["muted"], font=FONT_SMALL,
        ).pack(anchor="w", padx=14, pady=(2, 10))

    def _browse_output_dir(self) -> None:
        d = filedialog.askdirectory(title="Select report output directory")
        if d:
            self._sv["ADR_OUTPUT_DIR"].set(d)

    def _build_settings_ai(self, parent: tk.Frame) -> None:
        master = _section_label(parent, "AI ENRICHMENT")
        _check_row(master, "Enable AI enrichment (adds research suggestions to the report)",
                   self._bv["USE_AI"])
        _combo_row(master, "Provider", self._sv["ADR_AI_PROVIDER"],
                   ["auto", "openai", "claude", "gemini", "perplexity", "mistral", "openai-compatible"])
        tk.Label(
            master,
            text=(
                "'auto' picks the first provider that has an API key configured.\n"
                "Choose a specific provider to force one backend."
            ),
            bg=C["card"], fg=C["muted"], font=FONT_SMALL, justify="left",
        ).pack(anchor="w", padx=14, pady=(2, 10))

        global_card = _section_label(parent, "GLOBAL OVERRIDES  (leave blank to use provider defaults)")
        _field_row(global_card, "Global API Key override",      self._sv["ADR_AI_API_KEY"],  show="*")
        _field_row(global_card, "Global Model override",        self._sv["ADR_AI_MODEL"])
        _field_row(global_card, "Global Endpoint override",     self._sv["ADR_AI_ENDPOINT"])
        tk.Frame(global_card, bg=C["card"], height=6).pack()

        for title, key_k, model_k, ep_k in (
            ("OPENAI",      "OPENAI_API_KEY",       "ADR_OPENAI_MODEL",     "ADR_OPENAI_ENDPOINT"),
            ("CLAUDE / ANTHROPIC", "ANTHROPIC_API_KEY", "ADR_CLAUDE_MODEL", "ADR_CLAUDE_ENDPOINT"),
            ("GEMINI / GOOGLE AI", "GEMINI_API_KEY",  "ADR_GEMINI_MODEL",   "ADR_GEMINI_ENDPOINT"),
            ("PERPLEXITY",  "PERPLEXITY_API_KEY",    "ADR_PERPLEXITY_MODEL","ADR_PERPLEXITY_ENDPOINT"),
            ("MISTRAL",     "MISTRAL_API_KEY",        "ADR_MISTRAL_MODEL",   "ADR_MISTRAL_ENDPOINT"),
        ):
            card = _section_label(parent, title)
            _field_row(card, "API Key",              self._sv[key_k],   show="*")
            _field_row(card, "Model",                self._sv[model_k])
            _field_row(card, "Endpoint (optional)",  self._sv[ep_k])
            tk.Frame(card, bg=C["card"], height=6).pack()

    def _build_settings_email(self, parent: tk.Frame) -> None:
        ses = _section_label(parent, "AMAZON SES EMAIL DELIVERY")
        _check_row(ses, "Enable — email the finished report via Amazon SES v2",
                   self._bv["ADR_SES_ENABLED"])
        tk.Label(
            ses,
            text=(
                "Create a least-privilege IAM user with the ses:SendEmail permission only.\n"
                "ADR_SES_FROM_EMAIL must be a verified SES sender identity.\n"
                "ADR_SES_TO_EMAIL must also be verified unless your account is out of sandbox."
            ),
            bg=C["card"], fg=C["muted"], font=FONT_SMALL, justify="left",
        ).pack(anchor="w", padx=14, pady=(2, 6))
        _field_row(ses, "From email (verified sender)", self._sv["ADR_SES_FROM_EMAIL"])
        _field_row(ses, "To email (recipient)",         self._sv["ADR_SES_TO_EMAIL"])
        _field_row(ses, "AWS Access Key ID",            self._sv["ADR_SES_AWS_ACCESS_KEY_ID"])
        _field_row(ses, "AWS Secret Access Key",        self._sv["ADR_SES_AWS_SECRET_ACCESS_KEY"], show="*")
        _field_row(ses, "AWS Region",                   self._sv["ADR_SES_AWS_REGION"])
        tk.Frame(ses, bg=C["card"], height=8).pack()

    def _on_save_settings(self) -> None:
        self._save_settings_to_env()
        self._settings_status.configure(text="✓ Saved", fg=C["success"])
        self.after(3000, lambda: self._settings_status.configure(text=""))

    # ── Window close ──────────────────────────────────────────────────────────

    def _on_close(self) -> None:
        if self._proc and self._proc.poll() is None:
            if messagebox.askyesno("Quit", "A diagnostic run is in progress. Cancel it and quit?"):
                self._proc.terminate()
                self.destroy()
        else:
            self.destroy()


# ═══════════════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    app = AdrApp()
    app.protocol("WM_DELETE_WINDOW", app._on_close)
    try:
        app.mainloop()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
