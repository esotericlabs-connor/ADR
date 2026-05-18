# ADR - Automated Diagnostic Report

ADR is a pair of standalone diagnostic scripts for repair shops and MSPs:

- `src/adr.ps1` for Windows.
- `src/adr.sh` for macOS and Linux.

Each script collects as much of the intake checklist as the operating system can report, then writes one timestamped text file in the same folder as the script by default:

```text
ADR-<HOSTNAME>-<YYYYMMDD-HHMMSS>.txt
```

The output is designed to be copied into a ticket.

## What It Collects

ADR uses built-in OS commands first and does not install anything automatically. Run it as Administrator/root for the best results.

AI is completely optional. The scripts do not require any LLM/API key unless a technician explicitly enables AI enrichment with `-UseAiEnrichment` or `--ai`.

Collected where available:

- Make, model, serial, BIOS/firmware date, approximate device age.
- OS version, boot/update/reboot indicators, recent critical errors.
- CPU, GPU, RAM size/speed/type, storage size/free space.
- SMART or drive health when the OS exposes it.
- Battery charge, battery health, charging state, and thermal sensors when available.
- Office-like apps, antivirus/security tools, backup tools/services.
- Encryption status, Secure Boot where exposed, missing driver/device errors.
- Network/DNS/ping checks and peripheral detection.
- Current account type and admin status without printing account names or emails.
- Microsoft account, Entra ID/Azure AD, domain/workplace join indicators on Windows.
- Apple ID/iCloud sign-in presence on macOS with account identifiers redacted.
- OneDrive/iCloud/cloud-sync presence, running state, and sync-root detection without scanning customer files.
- Microphone/camera detection plus OS privacy/usage indicators where exposed.

Manual fields stay in the report as `Manual Check Required`, including display cracks, port tightness, keyboard feel, liquid damage, required parts/labor, and password availability. ADR does not collect passwords.

## Privacy Guardrails

ADR does not collect:

- Passwords, BIOS passwords, Wi-Fi keys, browser history, product keys, or customer file contents.
- File listings from customer profile folders.
- Customer Microsoft account, Apple ID, Google account, or email addresses in plain text.
- Ticket/customer-identifying notes unless a technician manually adds them after the report is generated.

ADR does not recursively scan OneDrive, iCloud Drive, Desktop, Documents, or customer folders to infer sync state. When exact sync-complete state is not available from safe built-in commands, the report says so and asks the technician to inspect the sync client UI.

## Quick Start

Windows PowerShell:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\src\adr.ps1
```

Windows PowerShell with AI enrichment:

```powershell
# Either set a key in your shell or use src/adr.env.
$env:OPENAI_API_KEY = "your-key"
powershell.exe -ExecutionPolicy Bypass -File .\src\adr.ps1 -UseAiEnrichment -AiProvider openai
```

macOS/Linux:

```bash
chmod +x ./src/adr.sh
sudo ./src/adr.sh
```

macOS/Linux with AI enrichment:

```bash
# Either export a key in your shell or use src/adr.env.
export ANTHROPIC_API_KEY="your-key"
sudo -E ./src/adr.sh --ai --ai-provider claude
```

Use `sudo -E` when AI enrichment needs environment variables preserved through sudo.

## Output Location

By default, reports are saved in the same folder as the script:

- Running `src/adr.ps1` writes beside `src/adr.ps1`.
- Running `src/adr.sh` writes beside `src/adr.sh`.

Optional override:

```powershell
.\src\adr.ps1 -OutputDirectory "C:\Temp\ADR"
```

```bash
./src/adr.sh --output-dir /tmp/adr
```

## AI Enrichment

AI enrichment is opt-in and optional. Normal diagnostic reporting does not need an AI provider, an API key, or internet access. AI only runs when the technician passes `-UseAiEnrichment` on Windows or `--ai` on macOS/Linux.

AI never replaces measured system facts. It appends an `AI Research Suggestions` section that can suggest likely model-year research terms, valuation research terms, missing-spec follow-ups, and technician checks.

## Env File Setup

ADR includes a safe template at `src/adr.env.example`.

To use it:

1. Copy `src/adr.env.example` to `src/adr.env`.
2. Fill in only the provider/key/model values you want.
3. Run ADR normally. The scripts auto-load `src/adr.env` if it exists.

The env file is optional. If `src/adr.env` does not exist, ADR ignores it and continues. Shell environment variables and command-line flags take precedence over values loaded from `adr.env`.

PowerShell env file override:

```powershell
.\src\adr.ps1 -UseAiEnrichment -EnvFile .\src\adr.env
```

Bash env file override:

```bash
./src/adr.sh --ai --env-file ./src/adr.env
```

Provider selection can be explicit or automatic. `auto` uses the first available key in this order:

1. OpenAI
2. Claude/Anthropic
3. Gemini
4. Perplexity
5. Mistral

PowerShell:

```powershell
.\src\adr.ps1 -UseAiEnrichment -AiProvider auto
.\src\adr.ps1 -UseAiEnrichment -AiProvider gemini -AiModel gemini-2.5-flash
```

Bash:

```bash
./src/adr.sh --ai --ai-provider auto
./src/adr.sh --ai --ai-provider perplexity --ai-model sonar-pro
```

### Supported Providers

| Provider | API key env var | Model override env var | Default model | Default endpoint |
| --- | --- | --- | --- | --- |
| `openai` | `OPENAI_API_KEY` | `ADR_OPENAI_MODEL` or `OPENAI_MODEL` | `gpt-5.2` | `https://api.openai.com/v1/chat/completions` |
| `claude` | `ANTHROPIC_API_KEY` or `CLAUDE_API_KEY` | `ADR_CLAUDE_MODEL`, `ANTHROPIC_MODEL`, or `CLAUDE_MODEL` | `claude-sonnet-4-5` | `https://api.anthropic.com/v1/messages` |
| `gemini` | `GEMINI_API_KEY` or `GOOGLE_API_KEY` | `ADR_GEMINI_MODEL`, `GEMINI_MODEL`, or `GOOGLE_AI_MODEL` | `gemini-2.5-flash` | `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent` |
| `perplexity` | `PERPLEXITY_API_KEY` | `ADR_PERPLEXITY_MODEL` or `PERPLEXITY_MODEL` | `sonar` | `https://api.perplexity.ai/v1/sonar` |
| `mistral` | `MISTRAL_API_KEY` | `ADR_MISTRAL_MODEL` or `MISTRAL_MODEL` | `mistral-large-latest` | `https://api.mistral.ai/v1/chat/completions` |
| `openai-compatible` | `ADR_AI_API_KEY` or `DIAG_AI_API_KEY` | `ADR_AI_MODEL` or `DIAG_AI_MODEL` | none | `ADR_AI_ENDPOINT` or `DIAG_AI_ENDPOINT` |

Global overrides also work:

- PowerShell flags: `-AiProvider`, `-AiModel`, `-AiEndpoint`.
- Bash flags: `--ai-provider`, `--ai-model`, `--ai-endpoint`.
- Environment variables: `ADR_AI_PROVIDER`, `ADR_AI_MODEL`, `ADR_AI_ENDPOINT`.
- Older compatibility variables: `DIAG_AI_PROVIDER`, `DIAG_AI_MODEL`, `DIAG_AI_ENDPOINT`.

Provider aliases:

- `anthropic` maps to `claude`.
- `google` maps to `gemini`.
- `custom` maps to `openai-compatible`.

## Examples

OpenAI:

```powershell
$env:OPENAI_API_KEY = "your-key"
.\src\adr.ps1 -UseAiEnrichment -AiProvider openai
```

Claude:

```bash
export ANTHROPIC_API_KEY="your-key"
sudo -E ./src/adr.sh --ai --ai-provider claude
```

Gemini:

```powershell
$env:GEMINI_API_KEY = "your-key"
.\src\adr.ps1 -UseAiEnrichment -AiProvider gemini
```

Perplexity:

```bash
export PERPLEXITY_API_KEY="your-key"
./src/adr.sh --ai --ai-provider perplexity --ai-model sonar-pro
```

Mistral:

```powershell
$env:MISTRAL_API_KEY = "your-key"
.\src\adr.ps1 -UseAiEnrichment -AiProvider mistral
```

OpenAI-compatible local or hosted gateway:

```bash
export ADR_AI_API_KEY="your-key"
export ADR_AI_MODEL="your-model"
export ADR_AI_ENDPOINT="https://your-provider.example/v1/chat/completions"
./src/adr.sh --ai --ai-provider openai-compatible
```

## Technician Workflow

1. Copy the `src` folder to the workbench machine, a USB drive, or a shared tools folder.
2. Run the matching script as Administrator/root.
3. Open the generated `ADR-...txt` report beside the script.
4. Complete the manual-check fields.
5. Copy the finished report into the ticket.

## Troubleshooting

- If hardware fields say `Unavailable: requires admin/root`, rerun elevated.
- If SMART is unavailable on Linux, install `smartmontools` outside ADR and rerun. ADR will detect `smartctl` if present.
- If Bash AI variables disappear under sudo, use `sudo -E`.
- If AI enrichment says the model or endpoint is unavailable, set the provider-specific model or endpoint override.
- If a provider changes model names, keep the provider and key the same, then override only the model.

## API References

The AI adapters use provider-documented HTTP APIs:

- OpenAI Chat Completions: `https://api.openai.com/v1/chat/completions`
- Anthropic Messages: `https://api.anthropic.com/v1/messages`
- Gemini `generateContent`: `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`
- Perplexity Sonar: `https://api.perplexity.ai/v1/sonar`
- Mistral Chat Completions: `https://api.mistral.ai/v1/chat/completions`
