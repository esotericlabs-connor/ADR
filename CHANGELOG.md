# ADR — Automated Diagnostic Report
## Code Changelog

How to use this file:
- Copy the **Commit message** block for the version you just built and paste it directly into your `git commit -m "..."` or GitHub commit dialog.
- Each entry documents what changed and why, without referencing AI tooling or model names.

---

### v1.2 — 2026-05-19

**Commit message (copy/paste):**
```
feat(gui): on-demand UAC elevation for Run Diagnostics (Windows)
fix(gui): correct encoding for elevated log capture (UTF-8 via StreamWriter)
fix(gui): hide elevated PowerShell window; suppress agent-scan prompt in GUI mode
fix(ps1): skip ASCII banner and auto-answer agent scan when ADR_GUI_MODE=true
feat(gui): copyable CLI command rows on Home page
fix(gui): smart auto-scroll in log (stops when user scrolls up)
```

**Changes:**
- Added `_is_admin()` module-level function using `ctypes.windll.shell32.IsUserAnAdmin()` (Windows) or `os.geteuid()` (Unix)
- Added `import base64`, `import re`, `import time` to stdlib imports
- Added four elevated-run state variables to `AdrApp.__init__`: `_elevated_mode`, `_elevated_log_path`, `_elevated_log_pos`, `_elevated_start`
- `_start_run()` shows a Yes/No/Cancel dialog when on Windows and not already running as Administrator; Yes path calls `_start_run_elevated()` and returns early; sets `ADR_GUI_MODE=true` in subprocess env for all GUI runs
- `_start_run_elevated()`: creates temp log via `tempfile.mkstemp`; builds `-EncodedCommand` PS script using `StreamWriter` (UTF-8 no-BOM) + `*>&1 | ForEach-Object` pipeline (captures all streams, strips ANSI naturally); sets `ADR_GUI_MODE=true` and `ADR_SKIP_MANUAL_CHECKS=true` in elevated env; uses `SW_HIDE=0` (no visible console window) and `-NonInteractive` so interactive prompts throw → catch defaults to "y"
- `_poll_elevated_log()`: reads new bytes as UTF-8, strips residual ANSI via `_strip_ansi()`, detects `ADR_EXIT:` sentinel for completion or 10-minute timeout
- `_reader_thread()`: applies `_strip_ansi()` to all subprocess output lines
- `_on_elevated_done()`, `_cancel_run()`, `_on_close()`: elevated-run aware
- `Write-AdrBanner` in `adr.ps1`: skipped when `$env:ADR_GUI_MODE = "true"` (avoids Unicode box-drawing encoding issues over the log pipe)
- Agent scan in `adr.ps1`: auto-answers "y" when `$env:ADR_GUI_MODE = "true"` instead of blocking on `[Console]::ReadLine()`
- Home page CLI section replaced: each command now has its own row with a `⧉ Copy` button that puts the command in the clipboard
- Log auto-scroll: only scrolls to bottom when already near the bottom — allows scrolling up to review past output without being yanked back

---

### v1.1 — 2026-05-19

**Commit message (copy/paste):**
```
fix(ps1): replace PS7-only ?? operator with PS5.1-compatible if/else

feat(gui): add GitHub release update checker with in-app notification bar
feat(gui): add ADR_VERSION constant and GITHUB_REPO constant to launcher
feat(version): restructure CHANGELOG with copy-paste commit messages
```

**Changes:**
- Fixed `??` null-coalescing operator in `adr.ps1` GUI launch block — that operator requires PowerShell 7+ and caused a parse error on the required PowerShell 5.1 minimum
- Added `ADR_VERSION = "1.0"` and `GITHUB_REPO = "esotericlabs-connor/ADR"` constants to `adr_gui.py`
- Added background update checker that queries the GitHub Releases API 800 ms after launch and shows a dismissable amber notification bar on the Home page when a newer version is available
- Update notification includes the remote version tag, current version, and a "View Release →" button that opens the GitHub release page in the browser
- Update check is non-blocking (daemon thread), silent on network failure, and uses semantic version comparison supporting any `vX.Y.Z` tag format
- Restructured `CHANGELOG.md` to include ready-to-copy commit messages alongside each version entry

---

### v1.0 — 2026-05-19

**Commit message (copy/paste):**
```
feat: initial v1.0 release — GUI launcher, terminal banner, CI pipeline

- Add cross-platform GUI launcher (adr_gui.py) with sidebar nav, live log,
  manual hardware checks, and settings for AI/SES configuration
- Add --gui / -Gui flags to adr.sh and adr.ps1 to open the launcher from CLI
- Add ASCII title banner (v1.0, Written by Connor Remsen) to both scripts
- Add step-by-step status indicators printed during each scan phase
- Add root drive anomaly detection (flags unexpected files at OS root)
- Add remote access agent scan covering 40+ agents with SHA-256 hashes
- Add optional Y/N prompt before agent scan; skippable via flag or env var
- Add Amazon SES v2 email delivery of finished reports (no AWS CLI needed)
- Add GitHub Actions workflow building Windows EXE and Linux AppImage on tag push
- Fix PyInstaller SCRIPT_DIR resolution for frozen executables
```

**Changes:**
- Added cross-platform GUI launcher (`adr_gui.py`) with four pages: Home, Run Diagnostics, Manual Checks, Settings
- Added manual hardware checks GUI (`adr_checks.py`) with stereo speaker tone tests, webcam/microphone launchers, Pass/Fail/N-A radio buttons, volume slider, and technician notes
- Added `--gui` flag to `adr.sh` and `-Gui` switch to `adr.ps1` — both locate and exec `adr_gui.py` with Python 3
- Added ASCII title banner displayed at script startup in terminal (bash and PowerShell), with color support when running interactively
- Added step-by-step status indicators printed during each major scan phase (`→ Collecting hardware data...`, `→ Scanning root drive...`, etc.)
- Added root drive anomaly detection — flags files and folders that should not be at the OS root
- Added remote access agent detection covering 40+ agents (ScreenConnect, Atera, TeamViewer, AnyDesk, RustDesk, NinjaRMM, and more) with SHA-256 hashes of found executables on macOS, Linux, and Windows
- Added optional Y/N interactive prompt before agent scan; skippable via `--skip-agent-scan` / `-SkipAgentScan` flag or `ADR_SKIP_AGENT_SCAN=true` in `adr.env`
- Added Amazon SES v2 report email delivery with AWS SigV4 request signing (no AWS CLI required; bash uses openssl, PowerShell uses .NET crypto)
- Added GitHub Actions workflow (`.github/workflows/build.yml`) — push a `v*` tag to automatically build `ADR.exe` (Windows) and `ADR-x86_64.AppImage` (Linux) and publish a GitHub Release with download zips
- Added PyInstaller compatibility: `SCRIPT_DIR` resolves to the executable's directory when frozen, so companion scripts are found correctly
- Added `adr.env.example` documenting all configuration options

---

## Version bump checklist

When incrementing the version, update these three locations:

| File | Variable | Example |
|------|----------|---------|
| `src/adr.sh` | `ADR_VERSION="1.1"` | line ~9 |
| `src/adr.ps1` | `$script:AdrVersion = "1.1"` | line ~62 |
| `src/adr_gui.py` | `ADR_VERSION = "1.1"` | line ~44 |

Then tag and push:
```bash
git tag v1.1
git push origin main --tags
```
GitHub Actions builds and publishes the release automatically.
