#!/usr/bin/env bash

# Collects an ADR - Automated Diagnostic Report for macOS and Linux.
# The report avoids passwords, Wi-Fi keys, browser history, product keys, and
# customer file contents. Run with sudo/root for the most complete hardware data.

set -o pipefail 2>/dev/null || true

USE_AI=0
OUTPUT_DIR=""
AI_PROVIDER=""
AI_MODEL=""
AI_ENDPOINT=""
ENV_FILE=""
ENV_FILE_STATUS=""

usage() {
    cat <<'USAGE'
Usage: ./adr.sh [--ai] [--ai-provider PROVIDER] [--ai-model MODEL] [--ai-endpoint URL] [--env-file FILE] [--output-dir DIR]

Options:
  --ai              Add optional AI research suggestions.
                    Supported providers: auto, openai, claude, gemini,
                    perplexity, mistral, and openai-compatible.
  --ai-provider P   AI provider to use. Default: auto.
  --ai-model MODEL  Optional model override.
  --ai-endpoint URL Optional endpoint override.
  --env-file FILE   Optional env file. Defaults to adr.env beside this script
                    when present. Used only for optional AI settings.
  --output-dir DIR  Write the report to DIR instead of the script directory.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ai)
            USE_AI=1
            ;;
        --ai-provider)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Missing value for --ai-provider" >&2
                exit 2
            fi
            AI_PROVIDER=$1
            ;;
        --ai-model)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Missing value for --ai-model" >&2
                exit 2
            fi
            AI_MODEL=$1
            ;;
        --ai-endpoint)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Missing value for --ai-endpoint" >&2
                exit 2
            fi
            AI_ENDPOINT=$1
            ;;
        --env-file)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Missing value for --env-file" >&2
                exit 2
            fi
            ENV_FILE=$1
            ;;
        --output-dir)
            shift
            if [ "$#" -eq 0 ]; then
                echo "Missing value for --output-dir" >&2
                exit 2
            fi
            OUTPUT_DIR=$1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

SCRIPT_SOURCE=${BASH_SOURCE[0]:-$0}
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd -P)
if [ -z "$ENV_FILE" ]; then
    ENV_FILE=$SCRIPT_DIR/adr.env
fi
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$SCRIPT_DIR
fi

mkdir -p "$OUTPUT_DIR" || {
    echo "Unable to create output directory: $OUTPUT_DIR" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

one_line() {
    awk 'NF { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

clean_join() {
    awk 'NF {
        gsub(/^[ \t]+|[ \t]+$/, "")
        if (!seen[$0]++) {
            if (out != "") out = out "; "
            out = out $0
        }
    } END {
        if (out == "") print "Unavailable: no data returned"; else print out
    }'
}

redact_identifiers() {
    sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/\1***@\2/g; s#([A-Za-z0-9_.-]+\\)[^;[:space:]]+#\1***#g'
}

indent_block() {
    sed 's/^/  /'
}

extract_profile_value() {
    data=$1
    key=$2
    printf '%s\n' "$data" | awk -v wanted="$key" '
        index($0, ":") {
            left = $0
            sub(/:.*/, "", left)
            gsub(/^[ \t]+|[ \t]+$/, "", left)
            if (left == wanted) {
                sub(/^[^:]*:[ \t]*/, "", $0)
                print
                exit
            }
        }'
}

read_sys_value() {
    path=$1
    if [ -r "$path" ]; then
        tr -d '\000' < "$path" 2>/dev/null | head -n 1
    else
        printf 'Unavailable: cannot read %s' "$path"
    fi
}

run_limited() {
    limit=$1
    shift
    if have timeout; then
        timeout "$limit" "$@" 2>&1
    elif have gtimeout; then
        gtimeout "$limit" "$@" 2>&1
    else
        "$@" 2>&1
    fi
}

count_existing_paths() {
    count=0
    for item in "$@"; do
        if [ -e "$item" ]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

macos_tcc_summary() {
    service=$1
    label=$2
    db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

    if ! have sqlite3; then
        printf '%s\n' "$label privacy usage: Unavailable: sqlite3 command not present"
        return
    fi

    if [ ! -r "$db" ]; then
        printf '%s\n' "$label privacy usage: Unavailable: TCC database not readable for current user"
        return
    fi

    columns=$(sqlite3 "$db" "pragma table_info(access);" 2>/dev/null | awk -F'|' '{print $2}')
    if printf '%s\n' "$columns" | grep -qx 'auth_value'; then
        result=$(sqlite3 "$db" "select count(*), coalesce(sum(case when auth_value=2 then 1 else 0 end),0), coalesce(sum(case when auth_value=0 then 1 else 0 end),0), coalesce(max(last_modified),0) from access where service='$service';" 2>/dev/null)
    elif printf '%s\n' "$columns" | grep -qx 'allowed'; then
        result=$(sqlite3 "$db" "select count(*), coalesce(sum(case when allowed=1 then 1 else 0 end),0), coalesce(sum(case when allowed=0 then 1 else 0 end),0), coalesce(max(last_modified),0) from access where service='$service';" 2>/dev/null)
    else
        result=$(sqlite3 "$db" "select count(*), 0, 0, coalesce(max(last_modified),0) from access where service='$service';" 2>/dev/null)
    fi
    if [ -z "$result" ]; then
        printf '%s\n' "$label privacy usage: Unavailable: TCC query returned no data"
        return
    fi

    count=$(printf '%s' "$result" | awk -F'|' '{print $1}')
    allowed=$(printf '%s' "$result" | awk -F'|' '{print $2}')
    denied=$(printf '%s' "$result" | awk -F'|' '{print $3}')
    last_modified=$(printf '%s' "$result" | awk -F'|' '{print $4}')
    if [ -n "$last_modified" ] && [ "$last_modified" != "0" ]; then
        last_text=$(date -r "$last_modified" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' "Unavailable")
    else
        last_text="Not recorded"
    fi

    printf '%s privacy usage: Entries=%s; Allow=%s; Deny=%s; LastModified=%s; App identifiers not listed\n' "$label" "$count" "$allowed" "$denied" "$last_text"
}

json_escape() {
    sed -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

trim_text() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

load_env_file() {
    file=$1

    if [ ! -f "$file" ]; then
        ENV_FILE_STATUS="Not loaded (optional env file not found: $file)"
        return
    fi

    loaded=0
    skipped_existing=0
    skipped_blank=0
    invalid=0

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(printf '%s' "$raw_line" | tr -d '\r' | trim_text)
        case "$line" in
            ""|\#*)
                continue
                ;;
        esac

        case "$line" in
            export\ *)
                line=$(printf '%s' "${line#export }" | trim_text)
                ;;
        esac

        case "$line" in
            *=*)
                key=$(printf '%s' "${line%%=*}" | trim_text)
                value=$(printf '%s' "${line#*=}" | trim_text)
                ;;
            *)
                invalid=$((invalid + 1))
                continue
                ;;
        esac

        if ! printf '%s\n' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
            invalid=$((invalid + 1))
            continue
        fi

        case "$value" in
            \"*\")
                value=${value#\"}
                value=${value%\"}
                ;;
            \'*\')
                value=${value#\'}
                value=${value%\'}
                ;;
        esac

        case "$value" in
            ""|your-key|changeme|replace-me)
                skipped_blank=$((skipped_blank + 1))
                continue
                ;;
        esac

        if [ -n "$(printenv "$key" 2>/dev/null)" ]; then
            skipped_existing=$((skipped_existing + 1))
            continue
        fi

        export "$key=$value"
        loaded=$((loaded + 1))
    done < "$file"

    ENV_FILE_STATUS="Loaded $loaded setting(s), skipped $skipped_existing existing setting(s), skipped $skipped_blank blank/placeholders, invalid lines $invalid from $file"
}

first_value() {
    for value in "$@"; do
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return
        fi
    done
}

env_first() {
    for name in "$@"; do
        value=$(printenv "$name" 2>/dev/null || true)
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return
        fi
    done
}

normalize_ai_provider() {
    provider=$(printf '%s' "$(first_value "$1" auto)" | tr '[:upper:]' '[:lower:]')
    case "$provider" in
        anthropic)
            printf '%s\n' "claude"
            ;;
        google)
            printf '%s\n' "gemini"
            ;;
        custom)
            printf '%s\n' "openai-compatible"
            ;;
        *)
            printf '%s\n' "$provider"
            ;;
    esac
}

ai_key_for_provider() {
    case "$1" in
        openai)
            env_first OPENAI_API_KEY
            ;;
        claude)
            env_first ANTHROPIC_API_KEY CLAUDE_API_KEY
            ;;
        gemini)
            env_first GEMINI_API_KEY GOOGLE_API_KEY
            ;;
        perplexity)
            env_first PERPLEXITY_API_KEY
            ;;
        mistral)
            env_first MISTRAL_API_KEY
            ;;
        openai-compatible)
            env_first ADR_AI_API_KEY DIAG_AI_API_KEY OPENAI_API_KEY
            ;;
    esac
}

ai_key_names_for_provider() {
    case "$1" in
        openai) printf '%s\n' "OPENAI_API_KEY" ;;
        claude) printf '%s\n' "ANTHROPIC_API_KEY or CLAUDE_API_KEY" ;;
        gemini) printf '%s\n' "GEMINI_API_KEY or GOOGLE_API_KEY" ;;
        perplexity) printf '%s\n' "PERPLEXITY_API_KEY" ;;
        mistral) printf '%s\n' "MISTRAL_API_KEY" ;;
        openai-compatible) printf '%s\n' "ADR_AI_API_KEY or DIAG_AI_API_KEY" ;;
        *) printf '%s\n' "a supported provider API key" ;;
    esac
}

resolve_ai_provider() {
    provider=$(normalize_ai_provider "$(first_value "$AI_PROVIDER" "$(env_first ADR_AI_PROVIDER DIAG_AI_PROVIDER)" auto)")
    if [ "$provider" = "auto" ]; then
        for candidate in openai claude gemini perplexity mistral; do
            if [ -n "$(ai_key_for_provider "$candidate")" ]; then
                printf '%s\n' "$candidate"
                return
            fi
        done
        printf '%s\n' "auto"
        return
    fi
    printf '%s\n' "$provider"
}

resolve_ai_model() {
    provider=$1
    case "$provider" in
        openai)
            provider_model=$(env_first ADR_OPENAI_MODEL OPENAI_MODEL)
            default_model="gpt-5.2"
            ;;
        claude)
            provider_model=$(env_first ADR_CLAUDE_MODEL ANTHROPIC_MODEL CLAUDE_MODEL)
            default_model="claude-sonnet-4-5"
            ;;
        gemini)
            provider_model=$(env_first ADR_GEMINI_MODEL GEMINI_MODEL GOOGLE_AI_MODEL)
            default_model="gemini-2.5-flash"
            ;;
        perplexity)
            provider_model=$(env_first ADR_PERPLEXITY_MODEL PERPLEXITY_MODEL)
            default_model="sonar"
            ;;
        mistral)
            provider_model=$(env_first ADR_MISTRAL_MODEL MISTRAL_MODEL)
            default_model="mistral-large-latest"
            ;;
        openai-compatible)
            provider_model=""
            default_model=""
            ;;
        *)
            provider_model=""
            default_model=""
            ;;
    esac

    first_value "$AI_MODEL" "$provider_model" "$(env_first ADR_AI_MODEL DIAG_AI_MODEL)" "$default_model"
}

resolve_ai_endpoint() {
    provider=$1
    model=$2
    case "$provider" in
        openai)
            provider_endpoint=$(env_first ADR_OPENAI_ENDPOINT OPENAI_API_ENDPOINT)
            default_endpoint="https://api.openai.com/v1/chat/completions"
            ;;
        claude)
            provider_endpoint=$(env_first ADR_CLAUDE_ENDPOINT ANTHROPIC_API_ENDPOINT CLAUDE_API_ENDPOINT)
            default_endpoint="https://api.anthropic.com/v1/messages"
            ;;
        gemini)
            provider_endpoint=$(env_first ADR_GEMINI_ENDPOINT GEMINI_API_ENDPOINT GOOGLE_AI_ENDPOINT)
            default_endpoint="https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent"
            ;;
        perplexity)
            provider_endpoint=$(env_first ADR_PERPLEXITY_ENDPOINT PERPLEXITY_API_ENDPOINT)
            default_endpoint="https://api.perplexity.ai/v1/sonar"
            ;;
        mistral)
            provider_endpoint=$(env_first ADR_MISTRAL_ENDPOINT MISTRAL_API_ENDPOINT)
            default_endpoint="https://api.mistral.ai/v1/chat/completions"
            ;;
        openai-compatible)
            provider_endpoint=""
            default_endpoint=""
            ;;
        *)
            provider_endpoint=""
            default_endpoint=""
            ;;
    esac

    first_value "$AI_ENDPOINT" "$provider_endpoint" "$(env_first ADR_AI_ENDPOINT DIAG_AI_ENDPOINT)" "$default_endpoint"
}

build_ai_body() {
    provider=$1
    model=$2
    prompt=$3
    system_prompt="You help a computer repair shop enrich a diagnostic intake report. Do not invent measured facts. Keep the response concise and label uncertain suggestions."

    if have python3; then
        ADR_AI_PROVIDER_RESOLVED="$provider" ADR_AI_MODEL_RESOLVED="$model" ADR_AI_SYSTEM_PROMPT="$system_prompt" ADR_AI_USER_PROMPT="$prompt" python3 - <<'PY'
import json
import os

provider = os.environ["ADR_AI_PROVIDER_RESOLVED"]
model = os.environ["ADR_AI_MODEL_RESOLVED"]
system_prompt = os.environ["ADR_AI_SYSTEM_PROMPT"]
user_prompt = os.environ["ADR_AI_USER_PROMPT"]

if provider == "claude":
    body = {
        "model": model,
        "max_tokens": 700,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_prompt}],
    }
elif provider == "gemini":
    body = {
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
        "generationConfig": {"temperature": 0.2, "maxOutputTokens": 700},
    }
elif provider == "openai":
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }
else:
    body = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 700,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

print(json.dumps(body))
PY
        return
    fi

    escaped_system=$(printf '%s' "$system_prompt" | json_escape)
    escaped_prompt=$(printf '%s' "$prompt" | json_escape)
    escaped_model=$(printf '%s' "$model" | json_escape)

    case "$provider" in
        claude)
            printf '{"model":"%s","max_tokens":700,"system":"%s","messages":[{"role":"user","content":"%s"}]}\n' "$escaped_model" "$escaped_system" "$escaped_prompt"
            ;;
        gemini)
            printf '{"systemInstruction":{"parts":[{"text":"%s"}]},"contents":[{"role":"user","parts":[{"text":"%s"}]}],"generationConfig":{"temperature":0.2,"maxOutputTokens":700}}\n' "$escaped_system" "$escaped_prompt"
            ;;
        openai)
            printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}]}\n' "$escaped_model" "$escaped_system" "$escaped_prompt"
            ;;
        *)
            printf '{"model":"%s","temperature":0.2,"max_tokens":700,"messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}]}\n' "$escaped_model" "$escaped_system" "$escaped_prompt"
            ;;
    esac
}

parse_ai_response() {
    provider=$1
    response=$2

    if have python3; then
        ADR_AI_PROVIDER_RESOLVED="$provider" AI_RESPONSE="$response" python3 - <<'PY'
import json
import os

provider = os.environ.get("ADR_AI_PROVIDER_RESOLVED", "")
raw = os.environ.get("AI_RESPONSE", "")

def flatten_content(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content") or ""
                if text:
                    parts.append(str(text))
        return "\n".join(part.strip() for part in parts if str(part).strip())
    return ""

try:
    data = json.loads(raw)
    content = ""
    if provider == "claude":
        content = flatten_content(data.get("content"))
    elif provider == "gemini":
        candidates = data.get("candidates") or []
        if candidates:
            content = flatten_content(((candidates[0].get("content") or {}).get("parts")) or [])
    else:
        choices = data.get("choices") or []
        if choices:
            content = flatten_content(((choices[0].get("message") or {}).get("content")))

    if content:
        print(content)
    else:
        print("AI enrichment returned no content.")
except Exception as exc:
    print(f"AI enrichment response could not be parsed: {exc}")
    print(raw[:2000])
PY
        return
    fi

    case "$provider" in
        claude|gemini)
            content=$(printf '%s\n' "$response" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
            ;;
        *)
            content=$(printf '%s\n' "$response" | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
            ;;
    esac

    content=$(printf '%s' "$content" | sed 's/\\n/\
/g; s/\\"/"/g; s/\\\\/\\/g')
    if [ -n "$content" ]; then
        printf '%s\n' "$content"
    else
        printf '%s\n' "AI enrichment response received, but python3 is unavailable to parse JSON robustly."
        printf '%s\n' "$response" | head -c 2000
        printf '\n'
    fi
}

call_ai_enrichment() {
    provider=$1
    model=$2
    endpoint=$3
    facts=$4

    if [ "$provider" = "auto" ]; then
        printf '%s\n' "Skipped: no supported AI API key found. Set one of OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, PERPLEXITY_API_KEY, or MISTRAL_API_KEY."
        return
    fi

    case "$provider" in
        openai|claude|gemini|perplexity|mistral|openai-compatible)
            ;;
        *)
            printf 'Skipped: unsupported AI provider %s.\n' "$provider"
            return
            ;;
    esac

    api_key=$(ai_key_for_provider "$provider")
    if [ -z "$api_key" ]; then
        printf 'Skipped: set %s to enable %s AI enrichment.\n' "$(ai_key_names_for_provider "$provider")" "$provider"
        return
    fi

    if [ -z "$model" ]; then
        printf '%s\n' "Skipped: set --ai-model, ADR_AI_MODEL, or DIAG_AI_MODEL."
        return
    fi

    if [ -z "$endpoint" ]; then
        printf '%s\n' "Skipped: set --ai-endpoint, ADR_AI_ENDPOINT, or DIAG_AI_ENDPOINT."
        return
    fi

    if ! have curl; then
        printf '%s\n' "Skipped: curl is required for AI enrichment."
        return
    fi

    prompt=$(printf 'Measured local facts follow. Suggest likely model-year research terms, valuation research terms, missing-spec follow-ups, and technician checks. Do not overwrite any measured value.\n\n%s' "$facts")
    body=$(build_ai_body "$provider" "$model" "$prompt")

    curl_args=(-sS -X POST "$endpoint" -H "Content-Type: application/json")
    case "$provider" in
        claude)
            curl_args+=(-H "x-api-key: $api_key" -H "anthropic-version: 2023-06-01")
            ;;
        gemini)
            curl_args+=(-H "x-goog-api-key: $api_key")
            ;;
        *)
            curl_args+=(-H "Authorization: Bearer $api_key")
            ;;
    esac

    response=$(curl "${curl_args[@]}" --data "$body" 2>&1)
    curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
        printf 'AI enrichment failed: curl exited with status %s: %s\n' "$curl_status" "$response"
        return
    fi

    parse_ai_response "$provider" "$response"
}

approx_age_from_bios_date() {
    date_value=$1
    if [ -z "$date_value" ] || printf '%s' "$date_value" | grep -qi '^Unavailable'; then
        printf '%s\n' "Unavailable: no BIOS/firmware date returned"
        return
    fi

    if date -d "$date_value" +%s >/dev/null 2>&1; then
        now=$(date +%s)
        then=$(date -d "$date_value" +%s)
        years=$(( (now - then) / 31557600 ))
        if [ "$years" -lt 0 ]; then years=0; fi
        printf 'Approx. %s years (based on BIOS/firmware date %s)\n' "$years" "$date_value"
    else
        printf '%s\n' "Unavailable: could not parse BIOS/firmware date"
    fi
}

load_env_file "$ENV_FILE"

HOST_NAME=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf '%s\n' UNKNOWN)
HOST_SAFE=$(printf '%s' "$HOST_NAME" | tr -c 'A-Za-z0-9_.-' '_')
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE=$OUTPUT_DIR/ADR-$HOST_SAFE-$TIMESTAMP.txt
GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')
UNAME_S=$(uname -s 2>/dev/null || printf '%s\n' Unknown)
if [ "$(id -u 2>/dev/null || printf '999')" = "0" ]; then
    IS_ROOT="true"
else
    IS_ROOT="false"
fi

MAKE="Unavailable: no data returned"
MODEL="Unavailable: no data returned"
SERIAL="Unavailable: no data returned"
BIOS_DATE="Unavailable: no BIOS/firmware date returned"
DEVICE_AGE="Unavailable: no BIOS/firmware date returned"
OS_VERSION="Unavailable: no data returned"
CPU_SUMMARY="Unavailable: no data returned"
GPU_SUMMARY="Unavailable: no data returned"
RAM_SIZE="Unavailable: no data returned"
RAM_SPEED="Unavailable: no data returned"
RAM_TYPE="Unavailable: no data returned"
MEMORY_DETAIL="Unavailable: no data returned"
DRIVE_TYPE="Unavailable: no data returned"
DRIVE_SIZE="Unavailable: no data returned"
FREE_SPACE="Unavailable: no data returned"
SMART_STATUS="Unavailable: no data returned"
BATTERY_RUNTIME="Unavailable: no data returned"
BATTERY_HEALTH="Unavailable: no data returned"
CHARGING_FUNCTIONAL="Unavailable: no data returned"
IDLE_TEMP="Unavailable: no data returned"
OFFICE_INSTALLED="Unavailable: no data returned"
ANTIVIRUS_SOFTWARE="Unavailable: no data returned"
BACKUP_STATUS="Unavailable: no data returned"
DRIVERS_MISSING="Unavailable: no data returned"
ENCRYPTION_ACTIVE="Unavailable: no data returned"
SECURE_BOOT="Unavailable: no data returned"
PENDING_REBOOT="Unavailable: no data returned"
RECENT_UPDATES="Unavailable: no data returned"
RECENT_ERRORS="Unavailable: no data returned"
NETWORK_SUMMARY="Unavailable: no data returned"
NETWORK_DETAILS="Unavailable: no data returned"
DISPLAY_DETECTION="Unavailable: no data returned"
TOUCH_DETECTION="Unavailable: no data returned"
KEYBOARD_DETECTION="Unavailable: no data returned"
TRACKPAD_DETECTION="Unavailable: no data returned"
WEBCAM_DETECTION="Unavailable: no data returned"
AUDIO_DETECTION="Unavailable: no data returned"
ACCOUNT_SUMMARY="Unavailable: no data returned"
CLOUD_IDENTITY_STATUS="Unavailable: no data returned"
CLOUD_SYNC_STATUS="Unavailable: no data returned"
MIC_USAGE="Unavailable: no data returned"
CAMERA_USAGE="Unavailable: no data returned"
MDM_STATUS="Unavailable: no data returned"

if [ "$UNAME_S" = "Darwin" ]; then
    HW_PROFILE=$(system_profiler SPHardwareDataType 2>/dev/null)
    POWER_PROFILE=$(system_profiler SPPowerDataType 2>/dev/null)
    DISPLAY_PROFILE=$(system_profiler SPDisplaysDataType 2>/dev/null)
    MEMORY_PROFILE=$(system_profiler SPMemoryDataType 2>/dev/null)
    STORAGE_PROFILE=$(system_profiler SPStorageDataType 2>/dev/null)
    CAMERA_PROFILE=$(system_profiler SPCameraDataType 2>/dev/null)
    AUDIO_PROFILE=$(system_profiler SPAudioDataType 2>/dev/null)
    USB_BT_PROFILE=$(system_profiler SPUSBDataType SPBluetoothDataType 2>/dev/null)

    MAKE="Apple"
    MODEL=$(extract_profile_value "$HW_PROFILE" "Model Name")
    model_id=$(extract_profile_value "$HW_PROFILE" "Model Identifier")
    if [ -n "$model_id" ]; then MODEL="$MODEL ($model_id)"; fi
    SERIAL=$(extract_profile_value "$HW_PROFILE" "Serial Number (system)")
    [ -z "$SERIAL" ] && SERIAL=$(extract_profile_value "$HW_PROFILE" "Serial Number")
    BIOS_DATE="Unavailable: macOS does not expose a stable local firmware date"
    DEVICE_AGE="Unavailable: use model identifier or optional AI research for model-year lookup"

    OS_VERSION="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"
    chip=$(extract_profile_value "$HW_PROFILE" "Chip")
    processor=$(extract_profile_value "$HW_PROFILE" "Processor Name")
    speed=$(extract_profile_value "$HW_PROFILE" "Processor Speed")
    cores=$(extract_profile_value "$HW_PROFILE" "Total Number of Cores")
    CPU_SUMMARY=$(printf '%s\n%s\n%s\n' "$chip" "$processor $speed" "$cores cores" | clean_join)
    GPU_SUMMARY=$(printf '%s\n' "$DISPLAY_PROFILE" | awk -F': ' '/Chipset Model:/ {print $2}' | clean_join)
    RAM_SIZE=$(extract_profile_value "$HW_PROFILE" "Memory")
    RAM_SPEED=$(printf '%s\n' "$MEMORY_PROFILE" | awk -F': ' '/Speed:/ {print $2}' | clean_join)
    RAM_TYPE=$(printf '%s\n' "$MEMORY_PROFILE" | awk -F': ' '/Type:/ {print $2}' | clean_join)
    if printf '%s\n' "$HW_PROFILE" | grep -qi 'Apple M'; then
        RAM_TYPE="Unified memory (Apple Silicon)"
        RAM_SPEED="Unavailable: unified memory speed not reported by system_profiler"
    fi
    MEMORY_DETAIL=${MEMORY_PROFILE:-"Unavailable: memory profile not returned"}

    root_device=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    disk_info=""
    if [ -n "$root_device" ] && have diskutil; then
        disk_info=$(diskutil info "$root_device" 2>/dev/null)
    fi
    solid_state=$(extract_profile_value "$disk_info" "Solid State")
    media_name=$(extract_profile_value "$disk_info" "Device / Media Name")
    DRIVE_TYPE=$(printf '%s\n%s\n' "$media_name" "Solid State: $solid_state" | clean_join)
    DRIVE_SIZE=$(printf '%s\n' "$STORAGE_PROFILE" | awk -F': ' '/Capacity:/ {print $2; exit}')
    [ -z "$DRIVE_SIZE" ] && DRIVE_SIZE="Unavailable: storage capacity not returned"
    FREE_SPACE=$(df -h / 2>/dev/null | awk 'NR==2 {print "Root volume free=" $4 " of " $2 " (" $5 " used)"}')
    [ -z "$FREE_SPACE" ] && FREE_SPACE="Unavailable: df did not return root volume"
    SMART_STATUS=$(printf '%s\n%s\n' "$disk_info" "$STORAGE_PROFILE" | awk -F': ' '/SMART Status:/ {print $2}' | clean_join)

    BATTERY_RUNTIME=$(pmset -g batt 2>/dev/null | clean_join)
    max_capacity=$(extract_profile_value "$POWER_PROFILE" "Maximum Capacity")
    condition=$(extract_profile_value "$POWER_PROFILE" "Condition")
    cycle_count=$(extract_profile_value "$POWER_PROFILE" "Cycle Count")
    BATTERY_HEALTH=$(printf '%s\n%s\n%s\n' "Maximum Capacity: $max_capacity" "Condition: $condition" "Cycle Count: $cycle_count" | clean_join)
    if printf '%s\n' "$BATTERY_RUNTIME" | grep -Eqi 'AC Power|charging|charged|finishing charge'; then
        CHARGING_FUNCTIONAL="Yes (OS reports AC/charging/charged state; inspect port physically)"
    elif printf '%s\n' "$BATTERY_RUNTIME" | grep -qi 'Battery Power'; then
        CHARGING_FUNCTIONAL="No or not connected (OS reports battery power; verify adapter and port manually)"
    else
        CHARGING_FUNCTIONAL="Manual Check Required (battery state did not confirm charging)"
    fi
    IDLE_TEMP="Unavailable: macOS does not expose idle temperature through a stable built-in noninteractive command"

    OFFICE_INSTALLED=$(for app in /Applications/*.app /Applications/*/*.app; do [ -e "$app" ] || continue; basename "$app"; done | grep -Ei 'Microsoft Word|Microsoft Excel|Microsoft PowerPoint|Microsoft Outlook|LibreOffice|OpenOffice|ONLYOFFICE|WPS Office' | clean_join)
    ANTIVIRUS_SOFTWARE=$({ ls /Applications 2>/dev/null; ps ax -o comm= 2>/dev/null; systemextensionsctl list 2>/dev/null; } | grep -Ei 'Malwarebytes|Sophos|Sentinel|CrowdStrike|Defender|Bitdefender|ESET|Avast|Avira|Webroot|Carbon Black' | head -n 25 | clean_join)
    tm_status=$(tmutil status 2>/dev/null | clean_join)
    tm_dest=$(tmutil destinationinfo 2>/dev/null | clean_join)
    backup_apps=$(for app in /Applications/*.app /Applications/*/*.app; do [ -e "$app" ] || continue; basename "$app"; done | grep -Ei 'Acronis|Backblaze|Carbonite|Veeam|CrashPlan|Datto|Duplicati|Synology Drive|Dropbox|OneDrive' | clean_join)
    BACKUP_STATUS="Time Machine status: $tm_status | Time Machine destinations: $tm_dest | Apps: $backup_apps"
    DRIVERS_MISSING="Unavailable: macOS does not expose a direct missing-driver inventory like Windows PnP"
    ENCRYPTION_ACTIVE=$(fdesetup status 2>/dev/null || printf '%s\n' "Unavailable: fdesetup status failed")
    SECURE_BOOT="Unavailable: macOS Secure Boot status is not consistently exposed through a built-in CLI across Intel/Apple Silicon"
    PENDING_REBOOT=$(if [ -d /Library/Updates ] && find /Library/Updates -maxdepth 1 -name '*.dist' -print -quit 2>/dev/null | grep -q .; then printf '%s\n' "Possible pending macOS update artifacts in /Library/Updates"; else printf '%s\n' "No simple pending reboot flag detected"; fi)
    RECENT_UPDATES=$(softwareupdate --history 2>/dev/null | tail -n 15)
    [ -z "$RECENT_UPDATES" ] && RECENT_UPDATES="Unavailable: softwareupdate history returned no output"
    if have log; then
        RECENT_ERRORS=$(run_limited 15 log show --last 1h --predicate 'messageType == error OR messageType == fault' --style compact 2>/dev/null | tail -n 20)
        [ -z "$RECENT_ERRORS" ] && RECENT_ERRORS="No recent error/fault log entries returned in the last hour"
    fi

    if ping -c 2 -t 3 1.1.1.1 >/dev/null 2>&1; then ping_status=true; else ping_status=false; fi
    if dscacheutil -q host -a name example.com >/dev/null 2>&1; then dns_status=true; else dns_status=false; fi
    active_services=$(networksetup -listallhardwareports 2>/dev/null | clean_join)
    NETWORK_SUMMARY="Ping 1.1.1.1: $ping_status; DNS example.com: $dns_status; Hardware ports: $active_services"
    NETWORK_DETAILS=$(ifconfig 2>/dev/null)
    DISPLAY_DETECTION=$(printf '%s\n' "$DISPLAY_PROFILE" | awk -F': ' '/Chipset Model:|Resolution:|Main Display:|Mirror:|Online:/ {print}' | clean_join)
    TOUCH_DETECTION=$(printf '%s\n' "$USB_BT_PROFILE" | grep -Ei 'touch|digitizer' | clean_join)
    KEYBOARD_DETECTION=$(printf '%s\n' "$USB_BT_PROFILE" | grep -Ei 'keyboard' | clean_join)
    TRACKPAD_DETECTION=$(printf '%s\n' "$USB_BT_PROFILE" | grep -Ei 'trackpad|multitouch|pointing' | clean_join)
    WEBCAM_DETECTION=${CAMERA_PROFILE:-"Not detected by system_profiler SPCameraDataType"}
    AUDIO_DETECTION=${AUDIO_PROFILE:-"Not detected by system_profiler SPAudioDataType"}
    if dseditgroup -o checkmember -m "$USER" admin 2>/dev/null | grep -qi "yes"; then mac_admin=true; else mac_admin=false; fi
    auth_authority=$(dscl . -read "/Users/$USER" AuthenticationAuthority 2>/dev/null)
    if printf '%s\n' "$auth_authority" | grep -qi 'LocalCachedUser'; then
        mac_account_type="Mobile/network cached account"
    else
        mac_account_type="Local macOS account"
    fi
    secure_token_raw=$(sysadminctl -secureTokenStatus "$USER" 2>&1)
    if printf '%s\n' "$secure_token_raw" | grep -qi 'ENABLED'; then
        secure_token="Enabled"
    elif printf '%s\n' "$secure_token_raw" | grep -qi 'DISABLED'; then
        secure_token="Disabled"
    else
        secure_token="Unknown"
    fi
    ACCOUNT_SUMMARY="Current account identifier redacted; UID=$(id -u 2>/dev/null); Admin=$mac_admin; AccountType=$mac_account_type; SecureToken=$secure_token"
    mobileme_accounts=$(defaults read MobileMeAccounts Accounts 2>/dev/null)
    icloud_count=$(printf '%s\n' "$mobileme_accounts" | grep -c 'AccountID' 2>/dev/null || printf '0')
    if [ "$icloud_count" -gt 0 ] 2>/dev/null; then icloud_configured=true; else icloud_configured=false; fi
    icloud_drive_present=false
    [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] && icloud_drive_present=true
    CLOUD_IDENTITY_STATUS="Apple ID/iCloud configured: $icloud_configured; Account count=$icloud_count; iCloud Drive folder present=$icloud_drive_present; Account identifiers redacted"
    onedrive_app=false
    [ -d /Applications/OneDrive.app ] && onedrive_app=true
    if pgrep -x OneDrive >/dev/null 2>&1; then onedrive_running=true; else onedrive_running=false; fi
    onedrive_folder_count=$(count_existing_paths "$HOME"/Library/CloudStorage/OneDrive*)
    CLOUD_SYNC_STATUS="OneDrive installed=$onedrive_app; OneDrive running=$onedrive_running; OneDrive sync roots detected=$onedrive_folder_count; iCloud Drive folder present=$icloud_drive_present; Exact sync-complete state unavailable through safe built-in commands; no customer file tree scanned"
    MIC_USAGE=$(macos_tcc_summary "kTCCServiceMicrophone" "Microphone")
    CAMERA_USAGE=$(macos_tcc_summary "kTCCServiceCamera" "Camera")
    if have profiles; then
        MDM_STATUS=$(profiles status -type enrollment 2>/dev/null | redact_identifiers | clean_join)
    else
        MDM_STATUS="Unavailable: profiles command not present"
    fi

elif [ "$UNAME_S" = "Linux" ]; then
    MAKE=$(read_sys_value /sys/class/dmi/id/sys_vendor)
    MODEL=$(read_sys_value /sys/class/dmi/id/product_name)
    SERIAL=$(read_sys_value /sys/class/dmi/id/product_serial)
    BIOS_DATE=$(read_sys_value /sys/class/dmi/id/bios_date)
    DEVICE_AGE=$(approx_age_from_bios_date "$BIOS_DATE")
    if [ -r /etc/os-release ]; then
        OS_VERSION="$(. /etc/os-release && printf '%s' "$PRETTY_NAME") kernel $(uname -r)"
    else
        OS_VERSION="$(uname -srmo 2>/dev/null)"
    fi

    cpu_name=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    cpu_count=$(if have nproc; then nproc 2>/dev/null; else grep -c '^processor' /proc/cpuinfo 2>/dev/null; fi)
    CPU_SUMMARY=$(printf '%s\n%s logical CPUs\n' "$cpu_name" "$cpu_count" | clean_join)
    if have lspci; then
        GPU_SUMMARY=$(lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | clean_join)
    else
        GPU_SUMMARY="Unavailable: command not present (lspci)"
    fi
    RAM_SIZE=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    [ -z "$RAM_SIZE" ] && RAM_SIZE="Unavailable: /proc/meminfo not readable"
    if have dmidecode && [ "$IS_ROOT" = "true" ]; then
        mem_decode=$(dmidecode -t memory 2>/dev/null)
        RAM_SPEED=$(printf '%s\n' "$mem_decode" | awk -F': ' '/Configured Memory Speed:|Speed:/ && $2 !~ /Unknown|Configured/ {print $2}' | clean_join)
        RAM_TYPE=$(printf '%s\n' "$mem_decode" | awk -F': ' '/Type:/ && $2 !~ /Unknown|Error/ {print $2}' | clean_join)
        MEMORY_DETAIL=$(printf '%s\n' "$mem_decode" | awk '/Memory Device/,/^$/ {print}' | head -n 200)
    elif have dmidecode; then
        RAM_SPEED="Unavailable: requires root for dmidecode"
        RAM_TYPE="Unavailable: requires root for dmidecode"
        MEMORY_DETAIL="Unavailable: requires root for dmidecode"
    else
        RAM_SPEED="Unavailable: command not present (dmidecode)"
        RAM_TYPE="Unavailable: command not present (dmidecode)"
        MEMORY_DETAIL="Unavailable: command not present (dmidecode)"
    fi

    if have lsblk; then
        lsblk_disks=$(lsblk -d -o NAME,MODEL,SIZE,ROTA,TYPE,TRAN 2>/dev/null)
        DRIVE_TYPE=$(printf '%s\n' "$lsblk_disks" | awk 'NR>1 {rota=($4=="0" ? "SSD/NVMe likely" : ($4=="1" ? "Rotational HDD likely" : "Unknown")); print $1 " " $2 " " $3 " " rota " tran=" $6}' | clean_join)
        DRIVE_SIZE=$(printf '%s\n' "$lsblk_disks" | awk 'NR>1 {print $1 " " $2 " " $3}' | clean_join)
    else
        DRIVE_TYPE="Unavailable: command not present (lsblk)"
        DRIVE_SIZE="Unavailable: command not present (lsblk)"
    fi
    FREE_SPACE=$(df -hT 2>/dev/null | awk 'NR==1 || $7=="/" {print}' | clean_join)
    if have smartctl; then
        smart_scan=$(smartctl --scan 2>/dev/null | awk '{print $1}' | head -n 5)
        if [ -n "$smart_scan" ]; then
            SMART_STATUS=$(for dev in $smart_scan; do smartctl -H "$dev" 2>/dev/null | awk -v dev="$dev" '/SMART overall-health|SMART Health Status|self-assessment/ {print dev ": " $0}'; done | clean_join)
        else
            SMART_STATUS="Unavailable: smartctl found no scannable drives"
        fi
    else
        SMART_STATUS="Unavailable: command not present (smartctl); install smartmontools for deeper SMART health"
    fi

    battery_lines=""
    health_lines=""
    for bat in /sys/class/power_supply/BAT*; do
        [ -d "$bat" ] || continue
        name=$(basename "$bat")
        capacity=$(cat "$bat/capacity" 2>/dev/null)
        status=$(cat "$bat/status" 2>/dev/null)
        battery_lines="$battery_lines
$name: charge=${capacity:-unknown}%, status=${status:-unknown}"
        full=$(cat "$bat/energy_full" "$bat/charge_full" 2>/dev/null | head -n 1)
        design=$(cat "$bat/energy_full_design" "$bat/charge_full_design" 2>/dev/null | head -n 1)
        if [ -n "$full" ] && [ -n "$design" ] && [ "$design" != "0" ]; then
            health=$(awk -v full="$full" -v design="$design" 'BEGIN {printf "%.1f%% (%s/%s)", (full/design)*100, full, design}')
            health_lines="$health_lines
$name: $health"
        fi
    done
    BATTERY_RUNTIME=$(printf '%s\n' "$battery_lines" | clean_join)
    BATTERY_HEALTH=$(printf '%s\n' "$health_lines" | clean_join)
    if printf '%s\n' "$BATTERY_RUNTIME" | grep -Eqi 'Charging|Full'; then
        CHARGING_FUNCTIONAL="Yes (OS reports charging/full state; inspect port physically)"
    elif printf '%s\n' "$BATTERY_RUNTIME" | grep -qi 'Discharging'; then
        CHARGING_FUNCTIONAL="No or not connected (OS reports discharging; verify adapter and port manually)"
    else
        CHARGING_FUNCTIONAL="Manual Check Required (battery state did not confirm charging)"
    fi

    if have sensors; then
        IDLE_TEMP=$(sensors 2>/dev/null | grep -E 'Package id|Tctl|temp[0-9]|Composite' | head -n 20 | clean_join)
    else
        thermal_lines=$(for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            type=$(cat "$zone/type" 2>/dev/null)
            temp=$(cat "$zone/temp" 2>/dev/null)
            awk -v type="${type:-thermal_zone}" -v temp="$temp" 'BEGIN {printf "%s: %.1f C\n", type, temp/1000}'
        done)
        IDLE_TEMP=$(printf '%s\n' "$thermal_lines" | clean_join)
    fi

    package_lines=$({ dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null; rpm -qa 2>/dev/null; flatpak list --app 2>/dev/null; snap list 2>/dev/null; } | grep -Ei 'libreoffice|openoffice|wps-office|onlyoffice|microsoft-office' | head -n 25)
    OFFICE_INSTALLED=$(printf '%s\n' "$package_lines" | clean_join)
    av_lines=$({ dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null; rpm -qa 2>/dev/null; flatpak list --app 2>/dev/null; snap list 2>/dev/null; systemctl list-units --type=service --all --no-pager 2>/dev/null; ps ax -o comm= 2>/dev/null; } | grep -Ei 'clamav|sophos|sentinel|crowdstrike|defender|mdatp|bitdefender|eset|avast|carbon.?black|falcon' | head -n 30)
    ANTIVIRUS_SOFTWARE=$(printf '%s\n' "$av_lines" | clean_join)
    backup_lines=$({ dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null; rpm -qa 2>/dev/null; flatpak list --app 2>/dev/null; snap list 2>/dev/null; systemctl list-units --type=service --all --no-pager 2>/dev/null; } | grep -Ei 'timeshift|deja-dup|restic|borgbackup|duplicati|backintime|veeam|rsnapshot|urbackup|syncthing|rclone' | head -n 30)
    BACKUP_STATUS=$(printf '%s\n' "$backup_lines" | clean_join)
    if have lsblk; then
        ENCRYPTION_ACTIVE=$(lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null | grep -Ei 'crypto_LUKS|crypt' | clean_join)
    else
        ENCRYPTION_ACTIVE="Unavailable: command not present (lsblk)"
    fi
    if [ -d /sys/firmware/efi ]; then
        if have mokutil; then
            SECURE_BOOT=$(mokutil --sb-state 2>/dev/null | clean_join)
        else
            SECURE_BOOT="UEFI detected; Secure Boot state unavailable because mokutil is not installed"
        fi
    else
        SECURE_BOOT="Legacy BIOS boot or EFI directory not exposed"
    fi
    if [ -f /var/run/reboot-required ]; then
        PENDING_REBOOT="Pending reboot flag present (/var/run/reboot-required)"
    else
        PENDING_REBOOT="No /var/run/reboot-required flag detected"
    fi
    if have journalctl; then
        RECENT_ERRORS=$(journalctl -p err -b -n 20 --no-pager 2>/dev/null)
        [ -z "$RECENT_ERRORS" ] && RECENT_ERRORS="No journalctl error entries returned for current boot"
    else
        RECENT_ERRORS=$(dmesg 2>/dev/null | tail -n 30)
        [ -z "$RECENT_ERRORS" ] && RECENT_ERRORS="Unavailable: journalctl not present and dmesg returned no output"
    fi
    RECENT_UPDATES=$({ tail -n 20 /var/log/apt/history.log 2>/dev/null; tail -n 20 /var/log/dnf.log 2>/dev/null; tail -n 20 /var/log/yum.log 2>/dev/null; tail -n 20 /var/log/pacman.log 2>/dev/null; } | clean_join)
    if have lspci; then
        DRIVERS_MISSING=$(lspci -k 2>/dev/null | awk '/^[0-9a-fA-F].*:/{dev=$0; driver=0} /Kernel driver in use:/{driver=1} /^$/ {if (dev && !driver) print dev " (no kernel driver in use shown)"; dev=""; driver=0}' | head -n 25 | clean_join)
    else
        DRIVERS_MISSING="Unavailable: command not present (lspci)"
    fi

    if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then ping_status=true; else ping_status=false; fi
    if getent hosts example.com >/dev/null 2>&1; then dns_status=true; else dns_status=false; fi
    adapters=$(if have ip; then ip -brief addr 2>/dev/null; else ifconfig 2>/dev/null; fi)
    NETWORK_SUMMARY="Ping 1.1.1.1: $ping_status; DNS example.com: $dns_status; Active adapters: $(printf '%s\n' "$adapters" | awk '$2=="UP" || /UP/ {print}' | clean_join)"
    NETWORK_DETAILS=${adapters:-"Unavailable: no adapter detail returned"}
    DISPLAY_DETECTION=$(if have xrandr; then xrandr --query 2>/dev/null | grep -E ' connected|disconnected' | clean_join; elif have lspci; then lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | clean_join; else printf '%s\n' "Unavailable: xrandr/lspci not present"; fi)
    TOUCH_DETECTION=$(grep -Ei 'touch|digitizer' /proc/bus/input/devices 2>/dev/null | clean_join)
    KEYBOARD_DETECTION=$(grep -Ei 'keyboard' /proc/bus/input/devices 2>/dev/null | clean_join)
    TRACKPAD_DETECTION=$(grep -Ei 'touchpad|trackpad|pointing' /proc/bus/input/devices 2>/dev/null | clean_join)
    WEBCAM_DETECTION=$(ls /dev/video* 2>/dev/null | clean_join)
    AUDIO_DETECTION=$({ cat /proc/asound/cards 2>/dev/null; if have pactl; then pactl list short sinks 2>/dev/null; pactl list short sources 2>/dev/null; fi; } | clean_join)
    if id -nG 2>/dev/null | grep -Eq '(^| )(sudo|wheel|admin)($| )'; then linux_admin_group=true; else linux_admin_group=false; fi
    ACCOUNT_SUMMARY="Current account identifier redacted; UID=$(id -u 2>/dev/null); Root=$IS_ROOT; sudo/wheel/admin group membership=$linux_admin_group"
    if have goa-cli; then
        goa_providers=$(goa-cli list 2>/dev/null | grep -Ei 'Provider|provider' | redact_identifiers | clean_join)
        CLOUD_IDENTITY_STATUS="GNOME Online Accounts providers: $goa_providers"
    else
        CLOUD_IDENTITY_STATUS="Unavailable: no built-in Apple ID/Microsoft Account equivalent; goa-cli not present"
    fi
    if have onedrive; then onedrive_cli=true; else onedrive_cli=false; fi
    if have systemctl; then
        onedrive_service=$(systemctl --user is-active onedrive 2>/dev/null || true)
        [ -z "$onedrive_service" ] && onedrive_service="not detected"
    else
        onedrive_service="Unavailable: systemctl not present"
    fi
    onedrive_config=false
    [ -d "$HOME/.config/onedrive" ] && onedrive_config=true
    CLOUD_SYNC_STATUS="OneDrive CLI installed=$onedrive_cli; OneDrive user service=$onedrive_service; OneDrive config present=$onedrive_config; Exact sync-complete state depends on client logs and is not inferred by scanning customer files"
    if have pactl; then
        source_count=$(pactl list short sources 2>/dev/null | awk 'NF {count++} END {print count+0}')
        active_capture_count=$(pactl list short source-outputs 2>/dev/null | awk 'NF {count++} END {print count+0}')
        MIC_USAGE="Microphone/audio input sources=$source_count; Active capture streams=$active_capture_count; App identifiers not listed"
    else
        MIC_USAGE="Unavailable: pactl command not present"
    fi
    video_count=$(ls /dev/video* 2>/dev/null | wc -l | tr -d ' ')
    if have fuser; then
        active_video_count=$(fuser /dev/video* 2>/dev/null | wc -w | tr -d ' ')
        CAMERA_USAGE="Video devices=$video_count; Active video device handles=$active_video_count; Process names not listed"
    else
        CAMERA_USAGE="Video devices=$video_count; Active camera use unavailable: fuser command not present"
    fi
    MDM_STATUS="Unavailable: no common built-in Linux MDM enrollment command checked"

else
    OS_VERSION="$(uname -a 2>/dev/null)"
    DEVICE_AGE="Unavailable: unsupported OS for this script"
    MAKE="Unavailable: unsupported OS for this script"
    MODEL="Unavailable: unsupported OS for this script"
    SERIAL="Unavailable: unsupported OS for this script"
fi

FACT_TEXT=$(cat <<EOF
GeneratedAt: $GENERATED_AT
Host: $HOST_NAME
OS: $OS_VERSION
Make: $MAKE
Model: $MODEL
Serial: $SERIAL
BIOSDate: $BIOS_DATE
DeviceAge: $DEVICE_AGE
CPU: $CPU_SUMMARY
GPU: $GPU_SUMMARY
RAMSize: $RAM_SIZE
RAMSpeed: $RAM_SPEED
RAMType: $RAM_TYPE
DriveType: $DRIVE_TYPE
DriveSize: $DRIVE_SIZE
FreeSpace: $FREE_SPACE
SMART: $SMART_STATUS
BatteryHealth: $BATTERY_HEALTH
Charging: $CHARGING_FUNCTIONAL
Temperature: $IDLE_TEMP
Office: $OFFICE_INSTALLED
Antivirus: $ANTIVIRUS_SOFTWARE
Backup: $BACKUP_STATUS
Encryption: $ENCRYPTION_ACTIVE
Drivers: $DRIVERS_MISSING
Network: $NETWORK_SUMMARY
Account: $ACCOUNT_SUMMARY
CloudIdentity: $CLOUD_IDENTITY_STATUS
CloudSync: $CLOUD_SYNC_STATUS
MicrophoneUsage: $MIC_USAGE
CameraUsage: $CAMERA_USAGE
MDM: $MDM_STATUS
EOF
)

AI_RESULT=""
AI_PROVIDER_RESOLVED=""
AI_MODEL_RESOLVED=""
AI_ENDPOINT_RESOLVED=""
if [ "$USE_AI" = "1" ]; then
    AI_PROVIDER_RESOLVED=$(resolve_ai_provider)
    AI_MODEL_RESOLVED=$(resolve_ai_model "$AI_PROVIDER_RESOLVED")
    AI_ENDPOINT_RESOLVED=$(resolve_ai_endpoint "$AI_PROVIDER_RESOLVED" "$AI_MODEL_RESOLVED")
    AI_RESULT=$(call_ai_enrichment "$AI_PROVIDER_RESOLVED" "$AI_MODEL_RESOLVED" "$AI_ENDPOINT_RESOLVED" "$FACT_TEXT")
fi

emit_section() {
    title=$1
    printf '\n## %s\n' "$title"
    printf '%*s\n' "$(( ${#title} + 3 ))" '' | tr ' ' '-'
}

{
    printf '%s\n' "ADR - Automated Diagnostic Report"
    printf '%s\n' "================================="

    emit_section "Report Metadata"
    printf 'Generated: %s\n' "$GENERATED_AT"
    printf 'Host Name: %s\n' "$HOST_NAME"
    printf 'Run As Root: %s\n' "$IS_ROOT"
    printf 'Script Path: %s\n' "$SCRIPT_SOURCE"
    printf 'Output File: %s\n' "$OUTPUT_FILE"
    printf 'Environment File: %s\n' "$ENV_FILE_STATUS"
    printf '%s\n' "Privacy Guardrail: Does not collect passwords, Wi-Fi keys, browser history, product keys, or customer file contents."

    emit_section "Original Intake Checklist"
    printf 'Device Age: %s\n' "$DEVICE_AGE"
    printf 'Serial: %s\n' "$SERIAL"
    printf 'Make: %s\n' "$MAKE"
    printf 'Model: %s\n' "$MODEL"
    printf '%s\n' "Estimated Device Value: Manual Check Required (optional AI section can provide research terms)"
    printf 'CPU: %s\n' "$CPU_SUMMARY"
    printf 'GPU: %s\n' "$GPU_SUMMARY"
    printf 'RAM Size: %s\n' "$RAM_SIZE"
    printf 'RAM Speed: %s\n' "$RAM_SPEED"
    printf 'RAM Type: %s\n' "$RAM_TYPE"
    printf '%s\n' "Cooling Type: Manual Check Required (OS does not reliably report cooling design)"
    printf 'OS Version: %s\n' "$OS_VERSION"
    printf 'Office Installed: %s\n' "$OFFICE_INSTALLED"
    printf 'Antivirus Software: %s\n' "$ANTIVIRUS_SOFTWARE"
    printf 'Backup Software Active: %s\n' "$BACKUP_STATUS"
    printf '%s\n' "Admin / BIOS Password Provided: Manual Check Required (do not collect or store passwords)"
    printf '\n%s\n\n' "Display & Visuals"
    printf '%s\n' "Display Intact/No Cracks: Manual Check Required"
    printf '%s\n' "Backlight Functional/Even: Manual Check Required"
    printf 'Touch Screen Responsive: Manual Check Required (detected: %s)\n' "$TOUCH_DETECTION"
    printf 'External Video Output OK: Manual Check Required (detected display/video: %s)\n' "$DISPLAY_DETECTION"
    printf '\n%s\n\n' "Input & Peripheral Health"
    printf 'Keyboard Working: Manual Check Required (detected: %s)\n' "$KEYBOARD_DETECTION"
    printf 'Trackpad Working: Manual Check Required (detected: %s)\n' "$TRACKPAD_DETECTION"
    printf 'Webcam Working: Manual Check Required (detected: %s)\n' "$WEBCAM_DETECTION"
    printf 'Internet/WiFi Working: %s\n' "$NETWORK_SUMMARY"
    printf 'Speakers/Mic Working: Manual Check Required (detected: %s; usage: %s)\n' "$AUDIO_DETECTION" "$MIC_USAGE"
    printf '\n%s\n\n' "Power & Thermal Stats"
    printf '%s\n' "DC Jack/Type-C Port Condition: Manual Check Required"
    printf 'Charging Functional: (Yes/No) %s\n' "$CHARGING_FUNCTIONAL"
    printf 'Battery Health %%: %s\n' "$BATTERY_HEALTH"
    printf 'Idle Temp: (deg C) %s\n' "$IDLE_TEMP"
    printf '\n%s\n\n' "Storage & Logic"
    printf 'Drive Type: %s\n' "$DRIVE_TYPE"
    printf 'Drive Size: %s\n' "$DRIVE_SIZE"
    printf 'Free Space: %s\n' "$FREE_SPACE"
    printf 'SMART Drive Status: %s\n' "$SMART_STATUS"
    printf 'Drivers Missing/Errors: %s\n' "$DRIVERS_MISSING"
    printf 'BitLocker/Encryption Active: %s\n' "$ENCRYPTION_ACTIVE"
    printf '\n%s\n\n' "Technician's Assessment"
    printf '%s\n' "Physical Condition: (Dust, dents, missing screws) Manual Check Required"
    printf '%s\n' "Previous Repair Evidence: Manual Check Required"
    printf '%s\n' "Initial Issue: Manual Check Required"
    printf '%s\n' "Secondary Risks/Issues Found: Manual Check Required"
    printf '%s\n' "Required Parts/Labor: Manual Check Required"

    emit_section "Expanded Automated Diagnostics"
    printf 'BIOS/Firmware Date: %s\n' "$BIOS_DATE"
    printf 'Secure Boot: %s\n' "$SECURE_BOOT"
    printf 'Pending Reboot: %s\n' "$PENDING_REBOOT"
    printf 'CPU Detail: %s\n' "$CPU_SUMMARY"
    printf 'GPU Detail: %s\n' "$GPU_SUMMARY"
    printf '%s\n' "Memory Detail:"
    printf '%s\n' "$MEMORY_DETAIL" | indent_block
    printf '%s\n' "Recent Updates:"
    printf '%s\n' "$RECENT_UPDATES" | indent_block
    printf '%s\n' "Recent Critical/Error Events:"
    printf '%s\n' "$RECENT_ERRORS" | indent_block

    emit_section "Security / Backup / Encryption"
    printf 'Secure Boot: %s\n' "$SECURE_BOOT"
    printf 'Encryption: %s\n' "$ENCRYPTION_ACTIVE"
    printf 'Antivirus: %s\n' "$ANTIVIRUS_SOFTWARE"
    printf 'Backup Software/Services: %s\n' "$BACKUP_STATUS"
    printf 'MDM/Enrollment: %s\n' "$MDM_STATUS"

    emit_section "Cloud / Account Status"
    printf 'Current Account: %s\n' "$ACCOUNT_SUMMARY"
    printf 'Cloud Identity: %s\n' "$CLOUD_IDENTITY_STATUS"
    printf 'Cloud Sync: %s\n' "$CLOUD_SYNC_STATUS"

    emit_section "Storage / Battery / Thermal"
    printf 'Drive Type: %s\n' "$DRIVE_TYPE"
    printf 'Drive Size: %s\n' "$DRIVE_SIZE"
    printf 'Free Space: %s\n' "$FREE_SPACE"
    printf 'SMART/Health: %s\n' "$SMART_STATUS"
    printf 'Battery Runtime State: %s\n' "$BATTERY_RUNTIME"
    printf 'Battery Health: %s\n' "$BATTERY_HEALTH"
    printf 'Charging State: %s\n' "$CHARGING_FUNCTIONAL"
    printf 'Thermal Sensors: %s\n' "$IDLE_TEMP"

    emit_section "Network / Peripheral Detection"
    printf 'Network Summary: %s\n' "$NETWORK_SUMMARY"
    printf '%s\n' "Network Details:"
    printf '%s\n' "$NETWORK_DETAILS" | indent_block
    printf 'Display/Monitor Detection: %s\n' "$DISPLAY_DETECTION"
    printf 'Touch Detection: %s\n' "$TOUCH_DETECTION"
    printf 'Keyboard Detection: %s\n' "$KEYBOARD_DETECTION"
    printf 'Trackpad/Pointing Detection: %s\n' "$TRACKPAD_DETECTION"
    printf 'Webcam Detection: %s\n' "$WEBCAM_DETECTION"
    printf 'Camera Privacy/Usage: %s\n' "$CAMERA_USAGE"
    printf '%s\n' "Audio Detection:"
    printf '%s\n' "$AUDIO_DETECTION" | indent_block
    printf 'Microphone Privacy/Usage: %s\n' "$MIC_USAGE"

    emit_section "Manual Checks Required"
    printf '%s\n' "Estimated device value and device age confirmation"
    printf '%s\n' "Display glass, panel damage, backlight evenness, and external display output"
    printf '%s\n' "Keyboard, trackpad, touchscreen, webcam, speakers, and microphone functional testing"
    printf '%s\n' "DC jack/USB-C port tightness, charger compatibility, liquid damage, dust, dents, and missing screws"
    printf '%s\n' "Admin/BIOS password availability without recording the password"
    printf '%s\n' "Previous repair evidence, initial issue, secondary risks, and parts/labor quote"

    if [ "$USE_AI" = "1" ]; then
        emit_section "AI Research Suggestions"
        printf 'Provider: %s\n' "$AI_PROVIDER_RESOLVED"
        printf 'Endpoint: %s\n' "$AI_ENDPOINT_RESOLVED"
        printf 'Model: %s\n' "$AI_MODEL_RESOLVED"
        printf '%s\n' "$AI_RESULT"
    fi
} > "$OUTPUT_FILE"

printf 'Diagnostic report written to: %s\n' "$OUTPUT_FILE"
