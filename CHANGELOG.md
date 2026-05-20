# ADR — Automated Diagnostic Report
## Code Changelog

---

### 2026-05-19 — v1.0 Initial Release Build

**Files changed:** `src/adr.sh`, `src/adr.ps1`, `src/adr_gui.py`, `src/adr_checks.py`, `src/adr.env.example`, `.github/workflows/build.yml`

- Added cross-platform GUI launcher (`adr_gui.py`) with sidebar navigation, live diagnostic log, integrated manual hardware checks, and a settings page for AI and email configuration
- Added manual hardware checks GUI (`adr_checks.py`) with stereo speaker tone tests, webcam/microphone launchers, Pass/Fail/N-A radio buttons for each component, volume slider, and technician notes field
- Added `--gui` flag to `adr.sh` and `-Gui` switch to `adr.ps1` to launch the GUI directly from the CLI
- Added ASCII title banner and version number (`v1.0`) displayed at script startup in both bash and PowerShell
- Added step-by-step status indicators (`→ Collecting hardware data...`, `→ Scanning root drive...`, etc.) printed to the terminal during each major scan phase
- Added root drive anomaly detection that flags unexpected files and folders at the OS root (`/` on macOS/Linux, `C:\` on Windows)
- Added comprehensive remote access agent detection covering 40+ agents (ScreenConnect, Atera, TeamViewer, AnyDesk, RustDesk, NinjaRMM, and more) with SHA-256 hashes of found executables
- Added optional Y/N prompt before the agent scan; skippable via `--skip-agent-scan` flag or `ADR_SKIP_AGENT_SCAN=true` in `adr.env`
- Added Amazon SES v2 email delivery of the finished report (AWS SigV4 signed, no AWS CLI required)
- Added PyInstaller compatibility fix so the GUI executable correctly locates `adr.ps1`/`adr.sh` when running as a frozen binary
- Added GitHub Actions workflow (`.github/workflows/build.yml`) that automatically builds `ADR.exe` (Windows) and `ADR-x86_64.AppImage` (Linux) on every tag push and publishes a GitHub Release with download zips
- Added `adr.env.example` with documented configuration for all providers, SES, manual check skip, and agent scan skip options
- macOS distribution remains as `bash adr.sh`; packaged binary planned for a future release
