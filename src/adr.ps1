#requires -Version 5.1
<#
.SYNOPSIS
Collects an ADR - Automated Diagnostic Report for Windows computers.

.DESCRIPTION
Creates a timestamped ADR text report beside this script by default. The report is
designed for MSP/shop ticket notes and avoids collecting secrets, passwords,
browser history, product keys, or customer file contents.

.PARAMETER UseAiEnrichment
Adds an optional AI research section. Provider can be selected with
-AiProvider or ADR_AI_PROVIDER. Supported providers: auto, openai, claude,
gemini, perplexity, mistral, and openai-compatible.

.PARAMETER AiProvider
AI provider to use when -UseAiEnrichment is set. Defaults to auto, which uses
the first available API key in this order: OpenAI, Claude, Gemini, Perplexity,
then Mistral.

.PARAMETER AiModel
Optional model override. Provider-specific model env vars are also supported.

.PARAMETER AiEndpoint
Optional endpoint override. ADR_AI_ENDPOINT and DIAG_AI_ENDPOINT are also
supported.

.PARAMETER EnvFile
Optional ADR env file path. Defaults to adr.env beside this script when that
file exists. The env file is only used for optional AI settings.

.PARAMETER OutputDirectory
Optional output folder. Defaults to the folder containing this script.

.PARAMETER SkipManualChecks
Skip the interactive hardware check GUI. Manual check fields in the report
are left blank for the technician to complete afterward.
Also controlled by ADR_SKIP_MANUAL_CHECKS=true in adr.env.

.PARAMETER SkipAgentScan
Skip the interactive remote access agent scan prompt. When omitted the script
asks Y/N before scanning. Also controlled by ADR_SKIP_AGENT_SCAN=true in adr.env.
#>

[CmdletBinding()]
param(
    [switch]$UseAiEnrichment,
    [ValidateSet("auto", "openai", "claude", "anthropic", "gemini", "google", "perplexity", "mistral", "openai-compatible", "custom")]
    [string]$AiProvider,
    [string]$AiModel,
    [string]$AiEndpoint,
    [string]$EnvFile,
    [string]$OutputDirectory,
    [switch]$SkipManualChecks,
    [switch]$SkipAgentScan,
    [switch]$Gui
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$script:AdrVersion = "1.2"

# ── GUI launch (-Gui flag) ─────────────────────────────────────────────────────
if ($Gui.IsPresent) {
    $guiScript = Join-Path $PSScriptRoot "adr_gui.py"
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) {
        Write-Host "Error: Python 3 is required to launch the ADR GUI." -ForegroundColor Red
        Write-Host "Install Python 3 from python.org and try again." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $guiScript)) {
        Write-Host "Error: adr_gui.py not found at $guiScript" -ForegroundColor Red
        exit 1
    }
    & $python.Source $guiScript
    exit 0
}

function Write-AdrBanner {
    if ($env:ADR_GUI_MODE -eq "true") { return }   # GUI provides its own chrome
    $w = 60
    $border = '║'
    $h      = '═'
    $tl     = '╔'; $tr = '╗'; $bl = '╚'; $br = '╝'
    $line   = $h * ($w - 2)
    Write-Host ""
    Write-Host "$tl$line$tr" -ForegroundColor Cyan
    Write-Host "$border$(' ' * ($w - 2))$border" -ForegroundColor Cyan
    Write-Host "$border  " -ForegroundColor Cyan -NoNewline
    Write-Host "   ___    ____   ____  " -ForegroundColor White -NoNewline
    Write-Host (' ' * ($w - 27)) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border  " -ForegroundColor Cyan -NoNewline
    Write-Host "  / _ \  |  _ \ |  _ \ " -ForegroundColor White -NoNewline
    Write-Host (' ' * ($w - 28)) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border  " -ForegroundColor Cyan -NoNewline
    Write-Host " | |_| | | | | || |_) |" -ForegroundColor White -NoNewline
    Write-Host (' ' * ($w - 28)) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border  " -ForegroundColor Cyan -NoNewline
    Write-Host " |  _  | | |_| ||  _ < " -ForegroundColor White -NoNewline
    Write-Host (' ' * ($w - 28)) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border  " -ForegroundColor Cyan -NoNewline
    Write-Host " |_| |_| |____/ |_| \_\" -ForegroundColor White -NoNewline
    Write-Host (' ' * ($w - 28)) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border$(' ' * ($w - 2))$border" -ForegroundColor Cyan
    $title = "  Automated Diagnostic Report"
    $ver   = "v$($script:AdrVersion)"
    $pad   = $w - 2 - $title.Length - $ver.Length - 2
    Write-Host "$border" -ForegroundColor Cyan -NoNewline
    Write-Host $title -ForegroundColor White -NoNewline
    Write-Host (' ' * $pad) -NoNewline
    Write-Host $ver -ForegroundColor Cyan -NoNewline
    Write-Host "  $border" -ForegroundColor Cyan
    $author = "  Written by Connor Remsen"
    $apad   = $w - 2 - $author.Length
    Write-Host "$border" -ForegroundColor Cyan -NoNewline
    Write-Host $author -ForegroundColor DarkGray -NoNewline
    Write-Host (' ' * $apad) -NoNewline
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host "$border$(' ' * ($w - 2))$border" -ForegroundColor Cyan
    Write-Host "$bl$line$br" -ForegroundColor Cyan
    Write-Host ""
}

function Write-AdrStatus {
    param([string]$Message)
    Write-Host "  " -NoNewline
    Write-Host "→" -ForegroundColor Cyan -NoNewline
    Write-Host "  $Message"
}

function Resolve-AdrOutputDirectory {
    param([string]$RequestedDirectory)

    if (-not [string]::IsNullOrWhiteSpace($RequestedDirectory)) {
        $resolved = $RequestedDirectory
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $resolved = $PSScriptRoot
    }
    else {
        $resolved = (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $resolved).Path
}

function Import-AdrEnvFile {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $path = $RequestedPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $path = Join-Path $PSScriptRoot "adr.env"
    }
    else {
        $path = Join-Path (Get-Location).Path "adr.env"
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return "Not loaded (optional env file not found: $path)"
    }

    $loaded = 0
    $skippedExisting = 0
    $skippedBlank = 0
    $invalid = 0

    try {
        foreach ($rawLine in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $line = ([string]$rawLine).Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }

            if ($line.StartsWith("export ")) {
                $line = $line.Substring(7).Trim()
            }

            $equalsIndex = $line.IndexOf("=")
            if ($equalsIndex -le 0) {
                $invalid++
                continue
            }

            $key = $line.Substring(0, $equalsIndex).Trim()
            $value = $line.Substring($equalsIndex + 1).Trim()

            if ($key -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
                $invalid++
                continue
            }

            if ((($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) -and $value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            if ([string]::IsNullOrWhiteSpace($value) -or $value -match "^(your-key|changeme|replace-me)$") {
                $skippedBlank++
                continue
            }

            $existing = [Environment]::GetEnvironmentVariable($key, "Process")
            if (-not [string]::IsNullOrWhiteSpace($existing)) {
                $skippedExisting++
                continue
            }

            [Environment]::SetEnvironmentVariable($key, $value, "Process")
            $loaded++
        }

        return "Loaded $loaded setting(s), skipped $skippedExisting existing setting(s), skipped $skippedBlank blank/placeholders, invalid lines $invalid from $path"
    }
    catch {
        return "Not loaded (error reading env file: $($_.Exception.Message))"
    }
}

function Test-AdrAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Format-AdrBytes {
    param([object]$Bytes)

    if ($null -eq $Bytes -or [string]::IsNullOrWhiteSpace([string]$Bytes)) {
        return "Unavailable: no data returned"
    }

    try {
        $value = [double]$Bytes
    }
    catch {
        return "Unavailable: invalid byte value"
    }

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }

    return ("{0:N1} {1}" -f $value, $units[$unitIndex])
}

function Join-AdrText {
    param(
        [object[]]$Items,
        [string]$EmptyText = "Unavailable: no data returned",
        [string]$Separator = "; "
    )

    $clean = @()
    foreach ($item in $Items) {
        if ($null -eq $item) {
            continue
        }

        $text = ([string]$item).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $clean += $text
        }
    }

    $clean = @($clean | Select-Object -Unique)
    if ($clean.Count -eq 0) {
        return $EmptyText
    }

    return ($clean -join $Separator)
}

function ConvertTo-AdrText {
    param(
        [object]$Value,
        [string]$EmptyText = "Unavailable: no data returned"
    )

    if ($null -eq $Value) {
        return $EmptyText
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $EmptyText
        }
        return $Value.Trim()
    }

    $text = ($Value | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $EmptyText
    }

    return $text
}

function Get-AdrCim {
    param(
        [string]$ClassName,
        [string]$Namespace = "root/cimv2",
        [string]$Filter
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Filter)) {
            return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        }

        return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop)
    }
    catch {
        return @()
    }
}

function Get-AdrExternalOutput {
    param(
        [string]$FileName,
        [string[]]$Arguments = @()
    )

    if (-not (Get-Command $FileName -ErrorAction SilentlyContinue)) {
        return "Unavailable: command not present ($FileName)"
    }

    try {
        $output = & $FileName @Arguments 2>&1
        $text = ConvertTo-AdrText $output "Unavailable: command returned no output"
        return $text
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function First-AdrNonBlank {
    param(
        [object[]]$Values,
        [string]$EmptyText = "Unavailable: no data returned"
    )

    foreach ($value in $Values) {
        if ($null -eq $value) {
            continue
        }

        $text = ([string]$value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }

    return $EmptyText
}

function Format-AdrDate {
    param([object]$DateValue)

    if ($null -eq $DateValue -or [string]::IsNullOrWhiteSpace([string]$DateValue)) {
        return "Unavailable: no date returned"
    }

    try {
        return (Get-Date $DateValue).ToString("yyyy-MM-dd")
    }
    catch {
        return "Unavailable: invalid date"
    }
}

function Get-AdrApproxAge {
    param([object]$DateValue)

    if ($null -eq $DateValue -or [string]::IsNullOrWhiteSpace([string]$DateValue)) {
        return "Unavailable: no BIOS/firmware date returned"
    }

    try {
        $date = Get-Date $DateValue
        $years = [math]::Max(0, [math]::Floor(((Get-Date) - $date).TotalDays / 365.25))
        return "Approx. $years years (based on BIOS/firmware date $($date.ToString("yyyy-MM-dd")))"
    }
    catch {
        return "Unavailable: could not parse BIOS/firmware date"
    }
}

function Get-AdrMemoryTypeName {
    param([object]$Code)

    if ($null -eq $Code) {
        return "Unknown"
    }

    $map = @{
        0 = "Unknown"; 1 = "Other"; 2 = "DRAM"; 3 = "Synchronous DRAM"; 4 = "Cache DRAM"
        5 = "EDO"; 6 = "EDRAM"; 7 = "VRAM"; 8 = "SRAM"; 9 = "RAM"; 10 = "ROM"
        11 = "Flash"; 12 = "EEPROM"; 13 = "FEPROM"; 14 = "EPROM"; 15 = "CDRAM"
        16 = "3DRAM"; 17 = "SDRAM"; 18 = "SGRAM"; 19 = "RDRAM"; 20 = "DDR"
        21 = "DDR2"; 22 = "DDR2 FB-DIMM"; 24 = "DDR3"; 25 = "FBD2"; 26 = "DDR4"
        27 = "LPDDR"; 28 = "LPDDR2"; 29 = "LPDDR3"; 30 = "LPDDR4"; 31 = "Logical non-volatile"
        34 = "DDR5"; 35 = "LPDDR5"
    }

    try {
        $key = [int]$Code
        if ($map.ContainsKey($key)) {
            return $map[$key]
        }
        return "Unknown SMBIOS memory type $key"
    }
    catch {
        return "Unknown"
    }
}

function Get-AdrFormFactorName {
    param([object]$Code)

    if ($null -eq $Code) {
        return "Unknown"
    }

    $map = @{
        0 = "Unknown"; 1 = "Other"; 2 = "SIP"; 3 = "DIP"; 4 = "ZIP"; 5 = "SOJ"; 6 = "Proprietary"
        7 = "SIMM"; 8 = "DIMM"; 9 = "TSOP"; 10 = "PGA"; 11 = "RIMM"; 12 = "SODIMM"; 13 = "SRIMM"
        14 = "SMD"; 15 = "SSMP"; 16 = "QFP"; 17 = "TQFP"; 18 = "SOIC"; 19 = "LCC"; 20 = "PLCC"
        21 = "BGA"; 22 = "FPBGA"; 23 = "LGA"
    }

    try {
        $key = [int]$Code
        if ($map.ContainsKey($key)) {
            return $map[$key]
        }
        return "Unknown form factor $key"
    }
    catch {
        return "Unknown"
    }
}

function Get-AdrInstalledProgramsMatching {
    param([string[]]$Patterns)

    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $items = @()
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                $items += @(Get-ItemProperty -Path $path -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) })
            }
            catch {
                continue
            }
        }
    }

    if ($items.Count -eq 0) {
        return "Unavailable: uninstall registry could not be read"
    }

    $regex = ($Patterns | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $matches = @(
        $items |
            Where-Object { $_.DisplayName -match $regex } |
            Sort-Object DisplayName -Unique |
            Select-Object -First 25
    )

    if ($matches.Count -eq 0) {
        return "Not detected in standard uninstall registry"
    }

    return Join-AdrText ($matches | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_.DisplayVersion)) {
            "$($_.DisplayName) $($_.DisplayVersion)"
        }
        else {
            "$($_.DisplayName)"
        }
    })
}

function Get-AdrServicesMatching {
    param([string[]]$Patterns)

    $services = Get-AdrCim -ClassName Win32_Service
    if ($services.Count -eq 0) {
        return "Unavailable: services could not be read"
    }

    $regex = ($Patterns | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $matches = @(
        $services |
            Where-Object { $_.Name -match $regex -or $_.DisplayName -match $regex -or $_.PathName -match $regex } |
            Sort-Object DisplayName -Unique |
            Select-Object -First 25
    )

    if ($matches.Count -eq 0) {
        return "No matching services detected"
    }

    return Join-AdrText ($matches | ForEach-Object { "$($_.DisplayName) [$($_.State), start=$($_.StartMode)]" })
}

function Get-AdrPnpSummary {
    param(
        [string[]]$Classes,
        [string[]]$NamePatterns = @()
    )

    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        return "Unavailable: Get-PnpDevice command not present"
    }

    try {
        $devices = @()
        foreach ($class in $Classes) {
            $devices += @(Get-PnpDevice -Class $class -ErrorAction SilentlyContinue)
        }

        if ($NamePatterns.Count -gt 0) {
            $regex = ($NamePatterns | ForEach-Object { [regex]::Escape($_) }) -join "|"
            $devices = @($devices | Where-Object { $_.FriendlyName -match $regex -or $_.Name -match $regex })
        }

        $devices = @($devices | Where-Object { -not [string]::IsNullOrWhiteSpace($_.FriendlyName) } | Sort-Object FriendlyName -Unique)
        if ($devices.Count -eq 0) {
            return "Not detected by PnP inventory"
        }

        return Join-AdrText ($devices | Select-Object -First 15 | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" })
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrSecureBoot {
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        return "Unavailable: Confirm-SecureBootUEFI command not present"
    }

    try {
        return [string](Confirm-SecureBootUEFI -ErrorAction Stop)
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrBitLocker {
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            $volumes = @(Get-BitLockerVolume -ErrorAction Stop)
            if ($volumes.Count -eq 0) {
                return "Not detected"
            }

            return Join-AdrText ($volumes | ForEach-Object {
                "$($_.MountPoint): status=$($_.VolumeStatus), protection=$($_.ProtectionStatus), encryption=$($_.EncryptionPercentage)%"
            })
        }
        catch {
            return "Unavailable: $($_.Exception.Message)"
        }
    }

    if (Get-Command manage-bde -ErrorAction SilentlyContinue) {
        $text = Get-AdrExternalOutput -FileName "manage-bde" -Arguments @("-status")
        if ($text.Length -gt 2000) {
            return $text.Substring(0, 2000) + "..."
        }
        return $text
    }

    return "Unavailable: BitLocker commands not present"
}

function Get-AdrPendingReboot {
    $checks = @()

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $checks += "Component Based Servicing pending"
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $checks += "Windows Update pending"
    }

    try {
        $sessionManager = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager.PendingFileRenameOperations) {
            $checks += "Pending file rename operations"
        }
    }
    catch {
    }

    if ($checks.Count -eq 0) {
        return "No common pending reboot flags detected"
    }

    return Join-AdrText $checks
}

function Get-AdrSmartStatus {
    param([object[]]$PhysicalDisks)

    $lines = @()

    if ($PhysicalDisks.Count -gt 0) {
        foreach ($disk in $PhysicalDisks) {
            $lines += "$($disk.FriendlyName): health=$($disk.HealthStatus), operational=$($disk.OperationalStatus), media=$($disk.MediaType), size=$(Format-AdrBytes $disk.Size)"
        }
    }

    $predict = Get-AdrCim -Namespace "root/wmi" -ClassName MSStorageDriver_FailurePredictStatus
    if ($predict.Count -gt 0) {
        $failureLines = $predict | ForEach-Object { "Instance=$($_.InstanceName), PredictFailure=$($_.PredictFailure)" }
        $lines += "WMI failure prediction: $(Join-AdrText $failureLines)"
    }

    if ($lines.Count -eq 0) {
        return "Unavailable: SMART data not exposed through built-in Windows interfaces"
    }

    return Join-AdrText $lines
}

function Get-AdrTemperature {
    $thermal = Get-AdrCim -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature
    if ($thermal.Count -eq 0) {
        return "Unavailable: Windows did not expose ACPI thermal zones"
    }

    $temps = @()
    foreach ($zone in $thermal) {
        if ($zone.CurrentTemperature) {
            $celsius = ([double]$zone.CurrentTemperature / 10) - 273.15
            $temps += ("{0}: {1:N1} C" -f $zone.InstanceName, $celsius)
        }
    }

    return Join-AdrText $temps "Unavailable: no usable temperature values returned"
}

function Get-AdrRecentEvents {
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
        return "Unavailable: Get-WinEvent command not present"
    }

    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = "System"
            Level = 1, 2
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 10 -ErrorAction Stop)

        if ($events.Count -eq 0) {
            return "No critical/error System events found in the last 7 days"
        }

        return ConvertTo-AdrText ($events | ForEach-Object {
            "{0:u} EventID={1} Provider={2} Message={3}" -f $_.TimeCreated, $_.Id, $_.ProviderName, (($_.Message -replace "\s+", " ").Trim())
        })
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrNetworkSummary {
    $parts = @()

    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        try {
            $upAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" })
            if ($upAdapters.Count -gt 0) {
                $parts += "Up adapters: $(Join-AdrText ($upAdapters | ForEach-Object { "$($_.Name) [$($_.InterfaceDescription), $($_.LinkSpeed)]" }))"
            }
            else {
                $parts += "No network adapters currently report Up"
            }
        }
        catch {
            $parts += "Adapter inventory unavailable: $($_.Exception.Message)"
        }
    }
    else {
        $parts += "Adapter inventory unavailable: Get-NetAdapter command not present"
    }

    try {
        $pingOk = Test-Connection -ComputerName "1.1.1.1" -Count 2 -Quiet -ErrorAction Stop
        $parts += "Ping 1.1.1.1: $pingOk"
    }
    catch {
        $parts += "Ping 1.1.1.1: unavailable ($($_.Exception.Message))"
    }

    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            $dnsOk = @(Resolve-DnsName -Name "example.com" -ErrorAction Stop)
            $parts += "DNS example.com: $($dnsOk.Count -gt 0)"
        }
        catch {
            $parts += "DNS example.com: failed ($($_.Exception.Message))"
        }
    }
    else {
        $parts += "DNS example.com: unavailable (Resolve-DnsName command not present)"
    }

    return Join-AdrText $parts
}

function Get-AdrNetworkDetails {
    $details = @()

    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        try {
            $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4Address -or $_.IPv6Address })
            if ($configs.Count -gt 0) {
                $details += ConvertTo-AdrText ($configs | Select-Object InterfaceAlias, InterfaceDescription, IPv4Address, IPv6Address, DNSServer, IPv4DefaultGateway | Format-List)
            }
        }
        catch {
            $details += "IP configuration unavailable: $($_.Exception.Message)"
        }
    }

    if ($details.Count -eq 0) {
        return "Unavailable: no IP configuration returned"
    }

    return ConvertTo-AdrText $details
}

function ConvertTo-AdrRedactedIdentifier {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "Unavailable: no identifier returned"
    }

    $text = ([string]$Value).Trim()
    if ($text -match "^([^\\]+)\\(.+)$") {
        $prefix = $Matches[1]
        $account = $Matches[2]
        if ($account -match "^(.).+@(.+)$") {
            return "$prefix\$($Matches[1])***@$($Matches[2])"
        }
        return "$prefix\***"
    }

    if ($text -match "^(.).+@(.+)$") {
        return "$($Matches[1])***@$($Matches[2])"
    }

    return "***"
}

function ConvertFrom-AdrFileTime {
    param([object]$Value)

    try {
        $ticks = [int64]$Value
        if ($ticks -le 0) {
            return $null
        }

        return [DateTime]::FromFileTimeUtc($ticks).ToLocalTime()
    }
    catch {
        return $null
    }
}

function Get-AdrCurrentAccountSummary {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $name = First-AdrNonBlank @($identity.Name, "$env:USERDOMAIN\$env:USERNAME")
        $accountType = "Unknown"

        if ($name -match "^MicrosoftAccount\\") {
            $accountType = "Microsoft account"
        }
        elseif ($name -match "^AzureAD\\") {
            $accountType = "Microsoft Entra ID / Azure AD account"
        }
        elseif ($env:USERDOMAIN -and $env:COMPUTERNAME -and $env:USERDOMAIN.Equals($env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase)) {
            $accountType = "Local Windows account"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
            $accountType = "Active Directory domain account"
        }
        elseif ($name -match "\\") {
            $accountType = "Domain or local account"
        }

        $configuredAdmin = "Unavailable: local Administrators group membership could not be read"
        $adminGroupTypes = "Unavailable"
        if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
            try {
                $adminMembers = @(Get-LocalGroupMember -SID "S-1-5-32-544" -ErrorAction Stop)
                $currentSid = $identity.User.Value
                $configuredAdmin = if ($adminMembers | Where-Object { $_.SID -and $_.SID.Value -eq $currentSid }) { "Yes" } else { "No or indirect/group-based membership not directly listed" }
                $adminGroupTypes = Join-AdrText ($adminMembers | ForEach-Object { "$($_.ObjectClass): $(ConvertTo-AdrRedactedIdentifier $_.Name)" }) "No members returned"
            }
            catch {
                $configuredAdmin = "Unavailable: $($_.Exception.Message)"
            }
        }

        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $tokenAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        return "Current account type: $accountType; Identifier: $(ConvertTo-AdrRedactedIdentifier $name); Current token elevated/admin: $tokenAdmin; Current account directly listed in local Administrators: $configuredAdmin; Local Administrators group summary: $adminGroupTypes"
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrMicrosoftJoinSummary {
    if (-not (Get-Command dsregcmd.exe -ErrorAction SilentlyContinue)) {
        return "Unavailable: dsregcmd.exe command not present"
    }

    try {
        $output = @(dsregcmd.exe /status 2>$null)
        if ($output.Count -eq 0) {
            return "Unavailable: dsregcmd returned no output"
        }

        $wanted = @(
            "AzureAdJoined", "EnterpriseJoined", "DomainJoined", "WorkplaceJoined",
            "DeviceAuthStatus", "AzureAdPrt", "EnterprisePrt", "WamDefaultSet",
            "WamDefaultAuthority", "NgcSet"
        )
        $lines = @()
        foreach ($line in $output) {
            foreach ($key in $wanted) {
                if ($line -match "^\s*$([regex]::Escape($key))\s*:\s*(.+)\s*$") {
                    $lines += "$key=$($Matches[1])"
                    break
                }
            }
        }

        return Join-AdrText $lines "Unavailable: expected dsregcmd status fields not found"
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrOneDriveStatus {
    $parts = @()

    try {
        $processes = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
        $parts += "Process running: $($processes.Count -gt 0)"
    }
    catch {
        $parts += "Process running: Unavailable ($($_.Exception.Message))"
    }

    $possibleExePaths = @()
    foreach ($root in @($env:LOCALAPPDATA, $env:ProgramFiles, [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"))) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            if ($root -eq $env:LOCALAPPDATA) {
                $possibleExePaths += Join-Path $root "Microsoft\OneDrive\OneDrive.exe"
            }
            else {
                $possibleExePaths += Join-Path $root "Microsoft OneDrive\OneDrive.exe"
            }
        }
    }
    $parts += "Installed executable detected: $([bool]($possibleExePaths | Where-Object { Test-Path -LiteralPath $_ }))"

    $accountSummaries = @()
    $accountRoot = "HKCU:\Software\Microsoft\OneDrive\Accounts"
    if (Test-Path -LiteralPath $accountRoot) {
        try {
            $accountKeys = @(Get-ChildItem -LiteralPath $accountRoot -ErrorAction Stop)
            foreach ($key in $accountKeys) {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                $folderPresent = $false
                if ($props.UserFolder -and (Test-Path -LiteralPath $props.UserFolder)) {
                    $folderPresent = $true
                }

                $signedIn = if ($null -ne $props.ClientEverSignedIn) { [bool]$props.ClientEverSignedIn } else { "Unknown" }
                $accountSummaries += "$($key.PSChildName): signedIn=$signedIn, syncRootPresent=$folderPresent"
            }
        }
        catch {
            $accountSummaries += "Unavailable: $($_.Exception.Message)"
        }
    }

    $parts += "Configured accounts: $(Join-AdrText $accountSummaries "No OneDrive accounts found in current user's registry")"
    $parts += "Exact sync-complete state: Unavailable through safe built-in commands; inspect OneDrive client UI. ADR does not scan customer files."
    return Join-AdrText $parts
}

function Get-AdrCapabilityUsageSummary {
    param(
        [string]$Capability,
        [string]$Label
    )

    $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability"
    if (-not (Test-Path -LiteralPath $base)) {
        return "$Label privacy usage: Unavailable: consent store key not found"
    }

    try {
        $keys = @((Get-Item -LiteralPath $base -ErrorAction Stop))
        $keys += @(Get-ChildItem -LiteralPath $base -Recurse -ErrorAction SilentlyContinue)
        $entries = 0
        $allowed = 0
        $denied = 0
        $active = $false
        $lastUsed = $null
        $rootValue = (Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue).Value

        foreach ($key in $keys) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) {
                continue
            }

            if ($null -ne $props.Value -or $null -ne $props.LastUsedTimeStart -or $null -ne $props.LastUsedTimeStop) {
                $entries++
            }

            if ($props.Value -eq "Allow") {
                $allowed++
            }
            elseif ($props.Value -eq "Deny") {
                $denied++
            }

            $start = ConvertFrom-AdrFileTime $props.LastUsedTimeStart
            $stop = ConvertFrom-AdrFileTime $props.LastUsedTimeStop
            if ($start -and (-not $stop -or $start -gt $stop)) {
                $active = $true
            }

            foreach ($candidate in @($start, $stop)) {
                if ($candidate -and ($null -eq $lastUsed -or $candidate -gt $lastUsed)) {
                    $lastUsed = $candidate
                }
            }
        }

        $lastUsedText = if ($lastUsed) { $lastUsed.ToString("yyyy-MM-dd HH:mm:ss zzz") } else { "Not recorded" }
        return "$Label privacy usage: DefaultConsent=$(First-AdrNonBlank @($rootValue, "Unknown")); Entries=$entries; Allow=$allowed; Deny=$denied; ActiveNow=$active; LastUsed=$lastUsedText; App identifiers not listed"
    }
    catch {
        return "$Label privacy usage: Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrTpmSummary {
    if (-not (Get-Command Get-Tpm -ErrorAction SilentlyContinue)) {
        return "Unavailable: Get-Tpm command not present"
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $values = @(
            $tpm.TpmPresent, $tpm.TpmReady, $tpm.TpmEnabled,
            $tpm.TpmActivated, $tpm.TpmOwned, $tpm.AutoProvisioning
        ) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }
        if ($values.Count -eq 0) {
            return "Unavailable: Get-Tpm returned no populated fields"
        }

        return "Present=$(First-AdrNonBlank @($tpm.TpmPresent, "Unknown")); Ready=$(First-AdrNonBlank @($tpm.TpmReady, "Unknown")); Enabled=$(First-AdrNonBlank @($tpm.TpmEnabled, "Unknown")); Activated=$(First-AdrNonBlank @($tpm.TpmActivated, "Unknown")); Owned=$(First-AdrNonBlank @($tpm.TpmOwned, "Unknown")); AutoProvisioning=$(First-AdrNonBlank @($tpm.AutoProvisioning, "Unknown"))"
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }
}

function Get-AdrEnvValue {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $item = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        if ($item -and -not [string]::IsNullOrWhiteSpace($item.Value)) {
            return $item.Value
        }
    }

    return $null
}

function Normalize-AdrAiProvider {
    param([string]$Provider)

    $value = First-AdrNonBlank @($Provider, "auto")
    $value = $value.Trim().ToLowerInvariant()

    switch ($value) {
        "anthropic" { return "claude" }
        "google" { return "gemini" }
        "custom" { return "openai-compatible" }
        default { return $value }
    }
}

function Get-AdrAiKey {
    param([string]$Provider)

    switch ($Provider) {
        "openai" { return Get-AdrEnvValue @("OPENAI_API_KEY") }
        "claude" { return Get-AdrEnvValue @("ANTHROPIC_API_KEY", "CLAUDE_API_KEY") }
        "gemini" { return Get-AdrEnvValue @("GEMINI_API_KEY", "GOOGLE_API_KEY") }
        "perplexity" { return Get-AdrEnvValue @("PERPLEXITY_API_KEY") }
        "mistral" { return Get-AdrEnvValue @("MISTRAL_API_KEY") }
        "openai-compatible" { return Get-AdrEnvValue @("ADR_AI_API_KEY", "DIAG_AI_API_KEY", "OPENAI_API_KEY") }
        default { return $null }
    }
}

function Get-AdrAiModel {
    param(
        [string]$Provider,
        [string]$RequestedModel
    )

    $providerModel = switch ($Provider) {
        "openai" { Get-AdrEnvValue @("ADR_OPENAI_MODEL", "OPENAI_MODEL") }
        "claude" { Get-AdrEnvValue @("ADR_CLAUDE_MODEL", "ANTHROPIC_MODEL", "CLAUDE_MODEL") }
        "gemini" { Get-AdrEnvValue @("ADR_GEMINI_MODEL", "GEMINI_MODEL", "GOOGLE_AI_MODEL") }
        "perplexity" { Get-AdrEnvValue @("ADR_PERPLEXITY_MODEL", "PERPLEXITY_MODEL") }
        "mistral" { Get-AdrEnvValue @("ADR_MISTRAL_MODEL", "MISTRAL_MODEL") }
        default { $null }
    }

    $model = First-AdrNonBlank @($RequestedModel, $providerModel, (Get-AdrEnvValue @("ADR_AI_MODEL", "DIAG_AI_MODEL")))
    if (-not $model.StartsWith("Unavailable:")) {
        return $model
    }

    switch ($Provider) {
        "openai" { return "gpt-5.2" }
        "claude" { return "claude-sonnet-4-5" }
        "gemini" { return "gemini-2.5-flash" }
        "perplexity" { return "sonar" }
        "mistral" { return "mistral-large-latest" }
        "openai-compatible" { return "Unavailable: set -AiModel, ADR_AI_MODEL, or DIAG_AI_MODEL" }
        default { return "Unavailable: unsupported AI provider" }
    }
}

function Get-AdrAiEndpoint {
    param(
        [string]$Provider,
        [string]$Model,
        [string]$RequestedEndpoint
    )

    $providerEndpoint = switch ($Provider) {
        "openai" { Get-AdrEnvValue @("ADR_OPENAI_ENDPOINT", "OPENAI_API_ENDPOINT") }
        "claude" { Get-AdrEnvValue @("ADR_CLAUDE_ENDPOINT", "ANTHROPIC_API_ENDPOINT", "CLAUDE_API_ENDPOINT") }
        "gemini" { Get-AdrEnvValue @("ADR_GEMINI_ENDPOINT", "GEMINI_API_ENDPOINT", "GOOGLE_AI_ENDPOINT") }
        "perplexity" { Get-AdrEnvValue @("ADR_PERPLEXITY_ENDPOINT", "PERPLEXITY_API_ENDPOINT") }
        "mistral" { Get-AdrEnvValue @("ADR_MISTRAL_ENDPOINT", "MISTRAL_API_ENDPOINT") }
        default { $null }
    }

    $endpoint = First-AdrNonBlank @($RequestedEndpoint, $providerEndpoint, (Get-AdrEnvValue @("ADR_AI_ENDPOINT", "DIAG_AI_ENDPOINT")))
    if (-not $endpoint.StartsWith("Unavailable:")) {
        return $endpoint
    }

    switch ($Provider) {
        "openai" { return "https://api.openai.com/v1/chat/completions" }
        "claude" { return "https://api.anthropic.com/v1/messages" }
        "gemini" { return "https://generativelanguage.googleapis.com/v1beta/models/$Model`:generateContent" }
        "perplexity" { return "https://api.perplexity.ai/v1/sonar" }
        "mistral" { return "https://api.mistral.ai/v1/chat/completions" }
        "openai-compatible" { return "Unavailable: set -AiEndpoint, ADR_AI_ENDPOINT, or DIAG_AI_ENDPOINT" }
        default { return "Unavailable: unsupported AI provider" }
    }
}

function Resolve-AdrAiConfig {
    param(
        [string]$RequestedProvider,
        [string]$RequestedModel,
        [string]$RequestedEndpoint
    )

    $provider = Normalize-AdrAiProvider (First-AdrNonBlank @($RequestedProvider, (Get-AdrEnvValue @("ADR_AI_PROVIDER", "DIAG_AI_PROVIDER")), "auto"))

    if ($provider -eq "auto") {
        foreach ($candidate in @("openai", "claude", "gemini", "perplexity", "mistral")) {
            if (-not [string]::IsNullOrWhiteSpace((Get-AdrAiKey -Provider $candidate))) {
                $provider = $candidate
                break
            }
        }

        if ($provider -eq "auto") {
            return [pscustomobject]@{
                Provider = "auto"
                Model = "Unavailable: no provider selected"
                Endpoint = "Unavailable: no provider selected"
                ApiKey = $null
                Error = "Skipped: no supported AI API key found. Set one of OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, PERPLEXITY_API_KEY, or MISTRAL_API_KEY."
            }
        }
    }

    if ($provider -notin @("openai", "claude", "gemini", "perplexity", "mistral", "openai-compatible")) {
        return [pscustomobject]@{
            Provider = $provider
            Model = "Unavailable: unsupported AI provider"
            Endpoint = "Unavailable: unsupported AI provider"
            ApiKey = $null
            Error = "Skipped: unsupported AI provider '$provider'."
        }
    }

    $apiKey = Get-AdrAiKey -Provider $provider
    $model = Get-AdrAiModel -Provider $provider -RequestedModel $RequestedModel
    $endpoint = Get-AdrAiEndpoint -Provider $provider -Model $model -RequestedEndpoint $RequestedEndpoint

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        $keyNames = switch ($provider) {
            "openai" { "OPENAI_API_KEY" }
            "claude" { "ANTHROPIC_API_KEY or CLAUDE_API_KEY" }
            "gemini" { "GEMINI_API_KEY or GOOGLE_API_KEY" }
            "perplexity" { "PERPLEXITY_API_KEY" }
            "mistral" { "MISTRAL_API_KEY" }
            "openai-compatible" { "ADR_AI_API_KEY or DIAG_AI_API_KEY" }
        }

        return [pscustomobject]@{
            Provider = $provider
            Model = $model
            Endpoint = $endpoint
            ApiKey = $null
            Error = "Skipped: set $keyNames to enable $provider AI enrichment."
        }
    }

    if ($model.StartsWith("Unavailable:") -or $endpoint.StartsWith("Unavailable:")) {
        return [pscustomobject]@{
            Provider = $provider
            Model = $model
            Endpoint = $endpoint
            ApiKey = $apiKey
            Error = "Skipped: AI model or endpoint is not configured for $provider."
        }
    }

    return [pscustomobject]@{
        Provider = $provider
        Model = $model
        Endpoint = $endpoint
        ApiKey = $apiKey
        Error = $null
    }
}

function ConvertFrom-AdrAiContent {
    param([object]$Content)

    if ($null -eq $Content) {
        return $null
    }

    if ($Content -is [string]) {
        return $Content.Trim()
    }

    $parts = @()
    foreach ($part in @($Content)) {
        if ($null -eq $part) {
            continue
        }

        if ($part.PSObject.Properties.Name -contains "text" -and -not [string]::IsNullOrWhiteSpace($part.text)) {
            $parts += $part.text
        }
        elseif ($part.PSObject.Properties.Name -contains "content" -and -not [string]::IsNullOrWhiteSpace($part.content)) {
            $parts += $part.content
        }
    }

    return Join-AdrText $parts $null "`n"
}

function Invoke-AdrAiEnrichment {
    param(
        [System.Collections.IDictionary]$Facts,
        [string]$RequestedProvider,
        [string]$RequestedModel,
        [string]$RequestedEndpoint
    )

    $config = Resolve-AdrAiConfig -RequestedProvider $RequestedProvider -RequestedModel $RequestedModel -RequestedEndpoint $RequestedEndpoint
    if (-not [string]::IsNullOrWhiteSpace($config.Error)) {
        return [pscustomobject]@{
            Provider = $config.Provider
            Model = $config.Model
            Endpoint = $config.Endpoint
            Content = $config.Error
        }
    }

    $systemPrompt = "You help a computer repair shop enrich a diagnostic intake report. Do not invent measured facts. Keep the response concise and label uncertain suggestions."
    $factText = ($Facts.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$($_.Name): $(ConvertTo-AdrText $_.Value)"
    }) -join "`n"
    $userPrompt = "Measured local facts follow. Suggest likely model-year research terms, valuation research terms, missing-spec follow-ups, and technician checks. Do not overwrite any measured value.`n`n$factText"

    $headers = @{}
    $body = $null

    switch ($config.Provider) {
        "claude" {
            $headers["x-api-key"] = $config.ApiKey
            $headers["anthropic-version"] = "2023-06-01"
            $body = @{
                model = $config.Model
                max_tokens = 700
                system = $systemPrompt
                messages = @(
                    @{
                        role = "user"
                        content = $userPrompt
                    }
                )
            }
        }
        "gemini" {
            $headers["x-goog-api-key"] = $config.ApiKey
            $body = @{
                systemInstruction = @{
                    parts = @(
                        @{ text = $systemPrompt }
                    )
                }
                contents = @(
                    @{
                        role = "user"
                        parts = @(
                            @{ text = $userPrompt }
                        )
                    }
                )
                generationConfig = @{
                    temperature = 0.2
                    maxOutputTokens = 700
                }
            }
        }
        "openai" {
            $headers["Authorization"] = "Bearer $($config.ApiKey)"
            $body = @{
                model = $config.Model
                messages = @(
                    @{
                        role = "system"
                        content = $systemPrompt
                    },
                    @{
                        role = "user"
                        content = $userPrompt
                    }
                )
            }
        }
        default {
            $headers["Authorization"] = "Bearer $($config.ApiKey)"
            $body = @{
                model = $config.Model
                temperature = 0.2
                max_tokens = 700
                messages = @(
                    @{
                        role = "system"
                        content = $systemPrompt
                    },
                    @{
                        role = "user"
                        content = $userPrompt
                    }
                )
            }
        }
    }

    try {
        $json = $body | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $config.Endpoint -Method Post -Headers $headers -ContentType "application/json" -Body $json -ErrorAction Stop
        $content = $null

        switch ($config.Provider) {
            "claude" {
                $content = ConvertFrom-AdrAiContent $response.content
            }
            "gemini" {
                if ($response.candidates -and $response.candidates.Count -gt 0) {
                    $content = ConvertFrom-AdrAiContent $response.candidates[0].content.parts
                }
            }
            default {
                if ($response.choices -and $response.choices.Count -gt 0) {
                    $content = ConvertFrom-AdrAiContent $response.choices[0].message.content
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($content)) {
            $content = "AI enrichment returned no content."
        }

        return [pscustomobject]@{
            Provider = $config.Provider
            Model = $config.Model
            Endpoint = $config.Endpoint
            Content = $content.Trim()
        }
    }
    catch {
        return [pscustomobject]@{
            Provider = $config.Provider
            Model = $config.Model
            Endpoint = $config.Endpoint
            Content = "AI enrichment failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-AdrManualGui {
    param(
        [bool]$Skip,
        [bool]$SkipFromEnv,
        [string]$HostName = "Unknown",
        [string]$Timestamp = ""
    )

    $blank = "Skipped — fill in manually"
    $result = [ordered]@{
        display       = "Not tested"
        touch_screen  = "Not tested"
        keyboard      = "Not tested"
        trackpad      = "Not tested"
        left_speaker  = "Not tested"
        right_speaker = "Not tested"
        microphone    = "Not tested"
        webcam        = "Not tested"
        notes         = ""
        mode          = "Not run"
    }

    if ($Skip -or $SkipFromEnv) {
        foreach ($k in @("display","touch_screen","keyboard","trackpad","left_speaker","right_speaker","microphone","webcam")) {
            $result[$k] = $blank
        }
        $result.mode = "Skipped"
        return $result
    }

    $scriptBase = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot }
                  else { (Get-Location).Path }
    $guiScript  = Join-Path $scriptBase "adr_checks.py"
    $python     = $null

    foreach ($cmd in @("python3", "python")) {
        try {
            $ver = & $cmd --version 2>&1
            if ("$ver" -match "Python 3") { $python = $cmd; break }
        }
        catch { continue }
    }

    if ($null -eq $python) {
        Write-Host "Manual checks: Python 3 not found — section left blank for manual completion."
        $result.mode = "Unavailable: python3 not found"
        return $result
    }

    if (-not (Test-Path -LiteralPath $guiScript)) {
        Write-Host "Manual checks: adr_checks.py not found beside this script — section left blank."
        $result.mode = "Unavailable: adr_checks.py not found"
        return $result
    }

    $tmpBase = [System.IO.Path]::GetTempFileName()
    Remove-Item -LiteralPath $tmpBase -ErrorAction SilentlyContinue
    $tmpJson = $tmpBase -replace "\.tmp$", ".json"

    Write-Host "Launching manual hardware check window — complete the checks then click Save Results."
    try {
        & $python $guiScript --output-file $tmpJson --host $HostName --timestamp $Timestamp 2>$null

        if ((Test-Path -LiteralPath $tmpJson) -and (Get-Item $tmpJson).Length -gt 0) {
            $data = Get-Content -LiteralPath $tmpJson -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($k in @("display","touch_screen","keyboard","trackpad","left_speaker","right_speaker","microphone","webcam")) {
                $raw = "$($data.$k)"
                $result[$k] = if ([string]::IsNullOrWhiteSpace($raw)) { "Not tested" } else { $raw }
            }
            $result.notes = "$($data.notes)"
            $result.mode  = "$($data.mode)"
        }
        else {
            $result.mode = "Window closed without saving"
        }
    }
    catch {
        $result.mode = "Error: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tmpJson) {
            Remove-Item -LiteralPath $tmpJson -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Get-AdrSha256Hex {
    param([string]$Data)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Get-AdrHmacSha256Bytes {
    param([byte[]]$Key, [string]$Data)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
}

function Get-AdrSigV4SigningKey {
    param([string]$Secret, [string]$DateStamp, [string]$Region, [string]$Service)
    $kDate    = Get-AdrHmacSha256Bytes -Key ([System.Text.Encoding]::UTF8.GetBytes("AWS4$Secret")) -Data $DateStamp
    $kRegion  = Get-AdrHmacSha256Bytes -Key $kDate   -Data $Region
    $kService = Get-AdrHmacSha256Bytes -Key $kRegion -Data $Service
    return      Get-AdrHmacSha256Bytes -Key $kService -Data "aws4_request"
}

function Send-AdrSesEmail {
    param([string]$ReportPath, [string]$ComputerName, [string]$Timestamp)

    $sesFrom   = [System.Environment]::GetEnvironmentVariable("ADR_SES_FROM_EMAIL")
    $sesTo     = [System.Environment]::GetEnvironmentVariable("ADR_SES_TO_EMAIL")
    $sesKey    = [System.Environment]::GetEnvironmentVariable("ADR_SES_AWS_ACCESS_KEY_ID")
    $sesSecret = [System.Environment]::GetEnvironmentVariable("ADR_SES_AWS_SECRET_ACCESS_KEY")
    $sesRegion = [System.Environment]::GetEnvironmentVariable("ADR_SES_AWS_REGION")
    if ([string]::IsNullOrWhiteSpace($sesRegion)) { $sesRegion = "us-east-1" }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($sesFrom))   { $missing += "ADR_SES_FROM_EMAIL" }
    if ([string]::IsNullOrWhiteSpace($sesTo))     { $missing += "ADR_SES_TO_EMAIL" }
    if ([string]::IsNullOrWhiteSpace($sesKey))    { $missing += "ADR_SES_AWS_ACCESS_KEY_ID" }
    if ([string]::IsNullOrWhiteSpace($sesSecret)) { $missing += "ADR_SES_AWS_SECRET_ACCESS_KEY" }
    if ($missing.Count -gt 0) {
        Write-Host "SES: skipped — configure $($missing -join ', ')"
        return
    }

    $content = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) {
        Write-Warning "SES: could not read report file."
        return
    }

    $subject = "ADR Report: $ComputerName ($Timestamp)"
    $bodyObj = [ordered]@{
        FromEmailAddress = $sesFrom
        Destination      = @{ ToAddresses = @($sesTo) }
        Content          = @{
            Simple = @{
                Subject = @{ Data = $subject;  Charset = "UTF-8" }
                Body    = @{ Text = @{ Data = $content; Charset = "UTF-8" } }
            }
        }
    }
    $payload = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    $now        = [DateTime]::UtcNow
    $amzDate    = $now.ToString("yyyyMMddTHHmmssZ")
    $dateStamp  = $now.ToString("yyyyMMdd")
    $sesHost    = "email.$sesRegion.amazonaws.com"
    $sesUri     = "/v2/email/outbound-emails"

    $payloadHash   = Get-AdrSha256Hex -Data $payload
    $canonHeaders  = "content-type:application/json`nhost:$sesHost`nx-amz-date:$amzDate`n"
    $signedHeaders = "content-type;host;x-amz-date"
    $canonReq      = "POST`n$sesUri`n`n$canonHeaders`n$signedHeaders`n$payloadHash"
    $credScope     = "$dateStamp/$sesRegion/ses/aws4_request"
    $crHash        = Get-AdrSha256Hex -Data $canonReq
    $stringToSign  = "AWS4-HMAC-SHA256`n$amzDate`n$credScope`n$crHash"
    $signingKey    = Get-AdrSigV4SigningKey -Secret $sesSecret -DateStamp $dateStamp -Region $sesRegion -Service "ses"
    $hmacBytes     = Get-AdrHmacSha256Bytes -Key $signingKey -Data $stringToSign
    $signature     = -join ($hmacBytes | ForEach-Object { $_.ToString("x2") })
    $auth          = "AWS4-HMAC-SHA256 Credential=$sesKey/$credScope, SignedHeaders=$signedHeaders, Signature=$signature"

    try {
        $headers = @{
            "Content-Type" = "application/json"
            "X-Amz-Date"   = $amzDate
            "Authorization" = $auth
        }
        Invoke-RestMethod -Method POST -Uri "https://$sesHost$sesUri" `
            -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
        Write-Host "SES: report emailed successfully to $sesTo"
    }
    catch {
        Write-Warning "SES: send failed — $($_.Exception.Message)"
    }
}

function Get-AdrRootDriveAnomalies {
    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = "C:" }
    $root  = "$drive\"

    $normalDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @(
        "Windows","Program Files","Program Files (x86)","ProgramData",
        "Users",'$Recycle.Bin',"System Volume Information","Recovery",
        "Documents and Settings","MSOCache","PerfLogs","OneDriveTemp",
        "inetpub","AMD","NVIDIA","Intel","Logs",
        "hp","Dell","Lenovo","Acer","ASUS","Microsoft",
        "Packages","boot"
    ) | ForEach-Object { $normalDirs.Add($_) | Out-Null }

    $normalFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @(
        "pagefile.sys","swapfile.sys","hiberfil.sys","bootmgr","BOOTNXT",
        "boot.ini","autoexec.bat","config.sys","io.sys","msdos.sys","MSDOS.SYS",
        "DumpStack.log","DumpStack.log.tmp"
    ) | ForEach-Object { $normalFiles.Add($_) | Out-Null }

    $anomalies = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
            if ($item.PSIsContainer) {
                if (-not $normalDirs.Contains($item.Name)) {
                    $anomalies.Add("DIR  $($item.Name)  [modified $($item.LastWriteTime.ToString('yyyy-MM-dd'))]")
                }
            }
            else {
                if (-not $normalFiles.Contains($item.Name)) {
                    $kb = [Math]::Round($item.Length / 1024, 1)
                    $anomalies.Add("FILE $($item.Name)  [$kb KB, modified $($item.LastWriteTime.ToString('yyyy-MM-dd'))]")
                }
            }
        }
    }
    catch {
        return "Unavailable: $($_.Exception.Message)"
    }

    if ($anomalies.Count -eq 0) { return "No unexpected items found at $root" }
    return "Unexpected items at ${root}" + "`n" + ($anomalies -join "`n")
}

function Get-AdrRemoteAgents {
    $pf   = $env:ProgramFiles;          if (-not $pf)   { $pf   = "C:\Program Files" }
    $pf86 = ${env:ProgramFiles(x86)};   if (-not $pf86) { $pf86 = "C:\Program Files (x86)" }
    $pd   = $env:ProgramData;           if (-not $pd)   { $pd   = "C:\ProgramData" }
    $win  = $env:SystemRoot;            if (-not $win)  { $win  = "C:\Windows" }

    $agentDefs = @(
        [pscustomobject]@{ Name="ScreenConnect / ConnectWise Control"; Paths=@(
            "$pf\ScreenConnect Client *\ScreenConnect.ClientService.exe"
            "$pf86\ScreenConnect Client *\ScreenConnect.ClientService.exe"
            "$pd\ScreenConnect Client *\ScreenConnect.ClientService.exe" )}
        [pscustomobject]@{ Name="Atera Agent"; Paths=@(
            "$pf\ATERA Networks\AteraAgent\AteraAgent.exe" )}
        [pscustomobject]@{ Name="TeamViewer"; Paths=@(
            "$pf\TeamViewer\TeamViewer.exe"
            "$pf\TeamViewer\TeamViewer_Service.exe"
            "$pf86\TeamViewer\TeamViewer.exe" )}
        [pscustomobject]@{ Name="UltraViewer"; Paths=@(
            "$pf\UltraViewer\UltraViewer_Desktop.exe"
            "$pf86\UltraViewer\UltraViewer_Desktop.exe" )}
        [pscustomobject]@{ Name="AnyDesk"; Paths=@(
            "$pf\AnyDesk\AnyDesk.exe"
            "$pf86\AnyDesk\AnyDesk.exe"
            "$pd\AnyDesk\AnyDesk.exe" )}
        [pscustomobject]@{ Name="RustDesk"; Paths=@(
            "$pf\RustDesk\rustdesk.exe"
            "$pf86\RustDesk\rustdesk.exe" )}
        [pscustomobject]@{ Name="LogMeIn"; Paths=@(
            "$pf\LogMeIn\x64\LogMeIn.exe"
            "$pf86\LogMeIn\LogMeIn.exe" )}
        [pscustomobject]@{ Name="Splashtop"; Paths=@(
            "$pf\Splashtop\Splashtop Remote\Server\SRServer.exe"
            "$pf86\Splashtop\Splashtop Remote\Server\SRServer.exe" )}
        [pscustomobject]@{ Name="RemotePC"; Paths=@(
            "$pf\RemotePC\RemotePC.exe"
            "$pf86\RemotePC\RemotePC.exe" )}
        [pscustomobject]@{ Name="NinjaOne / NinjaRMM Agent"; Paths=@(
            "$pf\NinjaRMMAgent\ninjarmmagent.exe"
            "$pf\NinjaOne\ninjarmmagent.exe" )}
        [pscustomobject]@{ Name="Kaseya VSA Agent"; Paths=@(
            "$pf\Kaseya\*\KaseyaAgent.exe"
            "$pf86\Kaseya\*\KaseyaAgent.exe" )}
        [pscustomobject]@{ Name="N-able / N-central Agent"; Paths=@(
            "$pf\N-able Technologies\Windows Agent\bin\agent.exe"
            "$pf86\N-able Technologies\Windows Agent\bin\agent.exe" )}
        [pscustomobject]@{ Name="Datto RMM Agent (CentraStage)"; Paths=@(
            "$pf\CentraStage\AemAgent\AemAgent.exe"
            "$pf\Datto\RMM\*\AemAgent.exe" )}
        [pscustomobject]@{ Name="Pulseway"; Paths=@(
            "$pf\Pulseway\Pulseway.exe"
            "$pf86\Pulseway\Pulseway.exe" )}
        [pscustomobject]@{ Name="Supremo Remote Desktop"; Paths=@(
            "$pf\Supremo\Supremo.exe"
            "$pf86\Supremo\Supremo.exe" )}
        [pscustomobject]@{ Name="Radmin Server"; Paths=@(
            "$pf\Famatech\Remote Administrator Server\rserver30.exe"
            "$pf86\Famatech\Remote Administrator Server\rserver30.exe" )}
        [pscustomobject]@{ Name="RealVNC Server"; Paths=@(
            "$pf\RealVNC\VNC Server\vncserver.exe"
            "$pf86\RealVNC\VNC Server\vncserver.exe" )}
        [pscustomobject]@{ Name="TightVNC Server"; Paths=@(
            "$pf\TightVNC\tvnserver.exe"
            "$pf86\TightVNC\tvnserver.exe" )}
        [pscustomobject]@{ Name="UltraVNC Server"; Paths=@(
            "$pf\UltraVNC\winvnc.exe"
            "$pf86\UltraVNC\winvnc.exe" )}
        [pscustomobject]@{ Name="TigerVNC Server"; Paths=@(
            "$pf\TigerVNC\vncserver.exe" )}
        [pscustomobject]@{ Name="BeyondTrust / Bomgar Jump Client"; Paths=@(
            "$pf\Bomgar\*\bomgar-*.exe"
            "$pf\BeyondTrust\Remote Support Jump Client\*\bomgar-*.exe" )}
        [pscustomobject]@{ Name="DameWare Mini Remote Control"; Paths=@(
            "$pf\SolarWinds\DameWare Mini Remote Control\DWRCC.exe"
            "$pf86\SolarWinds\DameWare Mini Remote Control\DWRCC.exe"
            "$pf\SolarWinds\DameWare Remote Support\DWRCCSvc.exe" )}
        [pscustomobject]@{ Name="Zoho Assist"; Paths=@(
            "$pf\Zoho\ZohoAssist\ZAService.exe"
            "$pd\Zoho Corp\ZohoAssist\ZAService.exe" )}
        [pscustomobject]@{ Name="ManageEngine UEMS / Remote Access Plus"; Paths=@(
            "$pf\ManageEngine\UEMS_Agent\bin\dcagentservice.exe"
            "$pf\ManageEngine\Remote Access Plus\bin\MERAP.exe" )}
        [pscustomobject]@{ Name="Parsec"; Paths=@(
            "$pf\Parsec\parsecd.exe" )}
        [pscustomobject]@{ Name="MeshAgent (MeshCentral)"; Paths=@(
            "$pf\Mesh Agent\MeshAgent.exe"
            "C:\Windows\Mesh Agent\MeshAgent.exe" )}
        [pscustomobject]@{ Name="Action1 RMM Agent"; Paths=@(
            "$pf\Action1\Action1_Remote_Access.exe" )}
        [pscustomobject]@{ Name="Tactical RMM Agent"; Paths=@(
            "$pf\TacticalAgent\tacticalrmm.exe" )}
        [pscustomobject]@{ Name="NetSupport Manager"; Paths=@(
            "$pf\NetSupport\NetSupport Manager\client32.exe"
            "$pf86\NetSupport\NetSupport Manager\client32.exe"
            "$pf\NetSupport\NetSupport School\student32.exe" )}
        [pscustomobject]@{ Name="Huntress Agent"; Paths=@(
            "$pf\Huntress\HuntressAgent.exe" )}
        [pscustomobject]@{ Name="Level RMM Agent"; Paths=@(
            "$pf\Level\level-windows-amd64.exe"
            "$pf\Level\level.exe" )}
        [pscustomobject]@{ Name="ConnectWise Automate / LabTech Agent"; Paths=@(
            "$win\LTSvc\ltsvc.exe"
            "C:\Windows\LTSvc\ltsvc.exe" )}
        [pscustomobject]@{ Name="Syncro RMM Agent"; Paths=@(
            "$pf\Syncro\app\Syncro.App.Runner.exe" )}
        [pscustomobject]@{ Name="ISL Online / ISL AlwaysOn"; Paths=@(
            "$pd\ISL Online\ISLAlwaysOn-*.exe"
            "$pf\ISL Online\ISLLight.exe" )}
        [pscustomobject]@{ Name="DWService (DWAgent)"; Paths=@(
            "$pf\DWAgent\dwagsvc.exe" )}
        [pscustomobject]@{ Name="Remote Utilities Host"; Paths=@(
            "$pf\Remote Utilities - Host\rutserv.exe"
            "$pf86\Remote Utilities - Host\rutserv.exe" )}
        [pscustomobject]@{ Name="SimpleHelp Remote Support"; Paths=@(
            "$pf\SimpleHelp\remote\remote64.exe"
            "$pf\SimpleHelp\remote\remote.exe" )}
        [pscustomobject]@{ Name="Naverisk Agent"; Paths=@(
            "$pf\Naverisk\Agent\NaveriskAgent.exe" )}
        [pscustomobject]@{ Name="ImmyBot Agent"; Paths=@(
            "$pf\ImmyBot\ImmyAgent.exe" )}
        [pscustomobject]@{ Name="GoToMyPC"; Paths=@(
            "$pf\GoTo\GoToMyPC\g2svc.exe"
            "$pf\Citrix Online\GoToMyPC\g2svc.exe" )}
        [pscustomobject]@{ Name="N-able Take Control Agent"; Paths=@(
            "$pf\N-able Technologies\Take Control Agent\*\BASupportExpressNCST.exe"
            "$pf86\N-able Technologies\Take Control Agent\*\BASupportExpressNCST.exe" )}
        [pscustomobject]@{ Name="Ammyy Admin"; Paths=@(
            "$pf\Ammyy Admin\AA_v3.exe"
            "$pf86\Ammyy Admin\AA_v3.exe"
            "C:\Ammyy\AA_v3.exe" )}
        [pscustomobject]@{ Name="FixMe.IT Agent"; Paths=@(
            "$pf\FixMe.IT\FixMeIT.exe" )}
        [pscustomobject]@{ Name="HelpWire"; Paths=@(
            "$pf\HelpWire\HelpWireHost.exe" )}
        [pscustomobject]@{ Name="Citrix Virtual Apps/Desktops VDA"; Paths=@(
            "$pf\Citrix\ICAService\CtxSvcHost.exe" )}
        [pscustomobject]@{ Name="GoTo Resolve / GoTo Assist"; Paths=@(
            "$pf\GoTo\GoToResolve\GoToResolveAgent.exe"
            "$pf\GoTo\GoToAssist\GoToAssistAgentSvc.exe" )}
        [pscustomobject]@{ Name="Freshdesk / Freshservice Agent"; Paths=@(
            "$pf\Freshworks\Freshservice Device Agent\FreshserviceAgent.exe" )}
    )

    $sha256   = [System.Security.Cryptography.SHA256]::Create()
    $found    = [System.Collections.Generic.List[string]]::new()

    foreach ($def in $agentDefs) {
        foreach ($pat in $def.Paths) {
            $hits = @()
            try {
                $hits = @(Get-Item -Path $pat -Force -ErrorAction SilentlyContinue)
                if ($hits.Count -eq 0 -and $pat -match '\*') {
                    $hits = @(Get-ChildItem -Path $pat -Force -ErrorAction SilentlyContinue)
                }
            } catch {}
            foreach ($f in $hits) {
                if ($f.PSIsContainer) { continue }
                try {
                    $bytes   = [System.IO.File]::ReadAllBytes($f.FullName)
                    $hashHex = -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
                } catch {
                    $hashHex = "hash-unavailable"
                }
                $found.Add("  $($def.Name)")
                $found.Add("    Path:    $($f.FullName)")
                $found.Add("    SHA-256: $hashHex")
            }
        }
    }

    # Service-name sweep for agents that may live in non-standard paths
    $svcPatterns = @(
        "TeamViewer","AnyDesk","RustDesk","ScreenConnect","AteraAgent",
        "SRService","SplashtopBusiness","LogMeIn","parsecd","ninjarmmagent",
        "dwagsvc","MeshAgent","HuntressAgent","HuntressTray","ZohoAssist",
        "isllight","ISLAlwaysOn","ltsvc","Pulseway","pwdaemon","Supremo",
        "tvnserver","winvnc","vncserver","rserver30","DWRCC","bomgar",
        "TacticalRMM","client32","Level","Syncro","naverisk","ImmyAgent",
        "action1","rutserv","BASupportExpressNCST","NetSupportServer",
        "GoToAssist","GoToResolve","RemotePC","FreshserviceAgent"
    )
    $svcHits = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($svc in (Get-Service -ErrorAction SilentlyContinue)) {
            foreach ($pat in $svcPatterns) {
                if ($svc.Name -like "*$pat*" -or $svc.DisplayName -like "*$pat*") {
                    $svcHits.Add("  $($svc.DisplayName) [$($svc.Status)] (service name: $($svc.Name))")
                    break
                }
            }
        }
    } catch {}

    if ($found.Count -eq 0 -and $svcHits.Count -eq 0) {
        return "No known remote access agents detected in standard install locations or services"
    }

    $out = [System.Collections.Generic.List[string]]::new()
    if ($found.Count -gt 0) {
        $out.Add("Installed agent executables found (with SHA-256):")
        $out.AddRange($found)
    }
    if ($svcHits.Count -gt 0) {
        if ($out.Count -gt 0) { $out.Add("") }
        $out.Add("Agent-related Windows services detected:")
        $out.AddRange($svcHits)
    }
    return $out -join "`n"
}

Write-AdrBanner
$envFileStatus = Import-AdrEnvFile -RequestedPath $EnvFile
$outputDirectoryPath = Resolve-AdrOutputDirectory -RequestedDirectory $OutputDirectory
$computerName = First-AdrNonBlank @($env:COMPUTERNAME, "UNKNOWN")
$hostSafe = $computerName -replace "[^A-Za-z0-9_.-]", "_"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputFile = Join-Path $outputDirectoryPath "ADR-$hostSafe-$timestamp.txt"
$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
$isAdmin = Test-AdrAdmin

$skipManualEnv = ([System.Environment]::GetEnvironmentVariable("ADR_SKIP_MANUAL_CHECKS") -eq "true")
Write-AdrStatus "Launching manual hardware check GUI..."
$manualChecks  = Invoke-AdrManualGui -Skip $SkipManualChecks.IsPresent -SkipFromEnv $skipManualEnv `
                                     -HostName $computerName -Timestamp $timestamp

# ── Root drive anomaly check (always runs, lightweight) ────────────────────────
Write-AdrStatus "Scanning root drive for unexpected files..."
$rootDriveAnomalies = Get-AdrRootDriveAnomalies

# ── Remote agent scan (optional — Y/N prompt unless skipped by flag or env) ────
$skipAgentEnv    = ([System.Environment]::GetEnvironmentVariable("ADR_SKIP_AGENT_SCAN") -eq "true")
$remoteAgentData = "Scan skipped"
if (-not $SkipAgentScan.IsPresent -and -not $skipAgentEnv) {
    Write-Host ""
    Write-Host "Run remote access agent scan? (searches Program Files + services for known agents, computes SHA-256) [Y/n]: " -NoNewline
    if ($env:ADR_GUI_MODE -eq "true") { $agentAns = "y" }
    else { try { $agentAns = [Console]::ReadLine() } catch { $agentAns = "y" } }
    if ([string]::IsNullOrWhiteSpace($agentAns) -or $agentAns -match "^[Yy]") {
        Write-AdrStatus "Scanning for remote access agents..."
        $remoteAgentData = Get-AdrRemoteAgents
    }
}
elseif ($SkipAgentScan.IsPresent -or $skipAgentEnv) {
    $remoteAgentData = "Scan skipped (ADR_SKIP_AGENT_SCAN or -SkipAgentScan flag)"
}

Write-AdrStatus "Querying hardware and system inventory..."
$computerSystem = @(Get-AdrCim -ClassName Win32_ComputerSystem) | Select-Object -First 1
$bios = @(Get-AdrCim -ClassName Win32_BIOS) | Select-Object -First 1
$baseboard = @(Get-AdrCim -ClassName Win32_BaseBoard) | Select-Object -First 1
$os = @(Get-AdrCim -ClassName Win32_OperatingSystem) | Select-Object -First 1
$cpu = @(Get-AdrCim -ClassName Win32_Processor)
$video = @(Get-AdrCim -ClassName Win32_VideoController)
$memory = @(Get-AdrCim -ClassName Win32_PhysicalMemory)
$diskDrives = @(Get-AdrCim -ClassName Win32_DiskDrive)
$logicalDisks = @(Get-AdrCim -ClassName Win32_LogicalDisk -Filter "DriveType=3")
$batteries = @(Get-AdrCim -ClassName Win32_Battery)

$physicalDisks = @()
if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    try {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    }
    catch {
        $physicalDisks = @()
    }
}

$make = First-AdrNonBlank @($computerSystem.Manufacturer)
$model = First-AdrNonBlank @($computerSystem.Model)
$serial = First-AdrNonBlank @($bios.SerialNumber, $baseboard.SerialNumber)
$biosDate = Format-AdrDate $bios.ReleaseDate
$deviceAge = Get-AdrApproxAge $bios.ReleaseDate

if ($os) {
    $osVersion = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
    $lastBoot = Format-AdrDate $os.LastBootUpTime
}
else {
    $osVersion = "Unavailable: OS inventory not returned"
    $lastBoot = "Unavailable: OS inventory not returned"
}

$cpuSummary = Join-AdrText ($cpu | ForEach-Object {
    "$($_.Name) ($($_.NumberOfCores)c/$($_.NumberOfLogicalProcessors)t, max $($_.MaxClockSpeed) MHz)"
})

$gpuSummary = Join-AdrText ($video | ForEach-Object {
    $ram = if ($_.AdapterRAM) { ", VRAM=$(Format-AdrBytes $_.AdapterRAM)" } else { "" }
    "$($_.Name) [$($_.DriverVersion)$ram]"
})

$ramSize = if ($computerSystem.TotalPhysicalMemory) {
    Format-AdrBytes $computerSystem.TotalPhysicalMemory
}
else {
    Format-AdrBytes (($memory | Measure-Object -Property Capacity -Sum).Sum)
}

$ramSpeed = Join-AdrText ($memory | ForEach-Object {
    if ($_.ConfiguredClockSpeed) {
        "$($_.ConfiguredClockSpeed) MHz"
    }
    elseif ($_.Speed) {
        "$($_.Speed) MHz"
    }
})

$ramType = Join-AdrText ($memory | ForEach-Object {
    "$(Get-AdrMemoryTypeName $_.SMBIOSMemoryType) / $(Get-AdrFormFactorName $_.FormFactor)"
}) "Unavailable: memory module details not returned"

$memoryDetail = if ($memory.Count -gt 0) {
    ConvertTo-AdrText ($memory | ForEach-Object {
        "$($_.BankLabel) $($_.DeviceLocator): $(Format-AdrBytes $_.Capacity), $(Get-AdrMemoryTypeName $_.SMBIOSMemoryType), $(Get-AdrFormFactorName $_.FormFactor), speed=$($_.ConfiguredClockSpeed) MHz, manufacturer=$($_.Manufacturer), part=$($_.PartNumber)"
    })
}
else {
    "Unavailable: memory module details not returned"
}

if ($physicalDisks.Count -gt 0) {
    $driveType = Join-AdrText ($physicalDisks | ForEach-Object { "$($_.FriendlyName): $($_.MediaType)" })
    $driveSize = Join-AdrText ($physicalDisks | ForEach-Object { "$($_.FriendlyName): $(Format-AdrBytes $_.Size)" })
}
elseif ($diskDrives.Count -gt 0) {
    $driveType = Join-AdrText ($diskDrives | ForEach-Object {
        $type = First-AdrNonBlank @($_.MediaType, $_.InterfaceType, "Unknown media type")
        if ($_.Model -match "SSD|NVMe|Solid") {
            $type = "Likely SSD/NVMe ($type)"
        }
        "$($_.Model): $type"
    })
    $driveSize = Join-AdrText ($diskDrives | ForEach-Object { "$($_.Model): $(Format-AdrBytes $_.Size)" })
}
else {
    $driveType = "Unavailable: disk inventory not returned"
    $driveSize = "Unavailable: disk inventory not returned"
}

$freeSpace = if ($logicalDisks.Count -gt 0) {
    Join-AdrText ($logicalDisks | ForEach-Object {
        "$($_.DeviceID) free=$(Format-AdrBytes $_.FreeSpace) of $(Format-AdrBytes $_.Size)"
    })
}
else {
    "Unavailable: logical disk inventory not returned"
}

$smartStatus = Get-AdrSmartStatus -PhysicalDisks $physicalDisks
$idleTemp = Get-AdrTemperature

$batteryStatic = @(Get-AdrCim -Namespace "root/wmi" -ClassName BatteryStaticData)
$batteryFull = @(Get-AdrCim -Namespace "root/wmi" -ClassName BatteryFullChargedCapacity)
$batteryStatusMap = @{
    1 = "Discharging"; 2 = "AC/Not discharging"; 3 = "Fully Charged"; 4 = "Low"; 5 = "Critical"
    6 = "Charging"; 7 = "Charging High"; 8 = "Charging Low"; 9 = "Charging Critical"; 10 = "Undefined"; 11 = "Partially Charged"
}

if ($batteries.Count -gt 0) {
    $batteryLines = @()
    foreach ($battery in $batteries) {
        $statusCode = [int]$battery.BatteryStatus
        $statusText = if ($batteryStatusMap.ContainsKey($statusCode)) { $batteryStatusMap[$statusCode] } else { "Status code $statusCode" }
        $batteryLines += "$($battery.Name): charge=$($battery.EstimatedChargeRemaining)%, status=$statusText"
    }
    $batteryRuntime = Join-AdrText $batteryLines
}
else {
    $batteryRuntime = "Unavailable: no battery detected or Win32_Battery returned no data"
}

$batteryHealth = "Unavailable: design/full charge capacity not exposed"
if ($batteryStatic.Count -gt 0 -and $batteryFull.Count -gt 0) {
    $healthLines = @()
    for ($i = 0; $i -lt [math]::Min($batteryStatic.Count, $batteryFull.Count); $i++) {
        $design = [double]$batteryStatic[$i].DesignedCapacity
        $full = [double]$batteryFull[$i].FullChargedCapacity
        if ($design -gt 0 -and $full -gt 0) {
            $healthLines += ("Battery {0}: {1:N1}% ({2}/{3} mWh)" -f ($i + 1), (($full / $design) * 100), $full, $design)
        }
    }
    $batteryHealth = Join-AdrText $healthLines "Unavailable: design/full charge capacity not exposed"
}

$chargingFunctional = if ($batteries.Count -eq 0) {
    "Unavailable: no battery detected"
}
else {
    $chargingStatuses = @($batteries | ForEach-Object { [int]$_.BatteryStatus })
    if ($chargingStatuses | Where-Object { $_ -in @(2, 3, 6, 7, 8, 9) }) {
        "Yes (OS reports AC/charging/charged state; inspect port physically)"
    }
    elseif ($chargingStatuses | Where-Object { $_ -eq 1 }) {
        "No or not connected (OS reports discharging; verify adapter and port manually)"
    }
    else {
        "Manual Check Required (battery status code did not confirm charging)"
    }
}

$officeInstalled = Get-AdrInstalledProgramsMatching -Patterns @("Microsoft 365", "Microsoft Office", "Office 16", "Office 15", "LibreOffice", "OpenOffice", "WPS Office", "OnlyOffice")

$antivirusProducts = @(Get-AdrCim -Namespace "root/SecurityCenter2" -ClassName AntivirusProduct)
$defenderStatus = if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        "Microsoft Defender: AMService=$($mp.AMServiceEnabled), RealTime=$($mp.RealTimeProtectionEnabled), AVEnabled=$($mp.AntivirusEnabled), Signatures=$($mp.AntivirusSignatureLastUpdated)"
    }
    catch {
        "Microsoft Defender status unavailable: $($_.Exception.Message)"
    }
}
else {
    "Microsoft Defender status unavailable: Get-MpComputerStatus command not present"
}

$antivirusSoftware = Join-AdrText @(
    Join-AdrText ($antivirusProducts | ForEach-Object { "$($_.displayName) [state=$($_.productState)]" }) "No SecurityCenter2 antivirus products returned"
    $defenderStatus
)

$backupApps = Get-AdrInstalledProgramsMatching -Patterns @("Windows Backup", "Acronis", "Backblaze", "Carbonite", "Veeam", "Macrium", "CrashPlan", "Datto", "Synology Drive", "AOMEI Backupper", "EaseUS Todo Backup", "Duplicati", "Dropbox", "OneDrive")
$backupServices = Get-AdrServicesMatching -Patterns @("wbengine", "FileHistory", "Acronis", "Backblaze", "Carbonite", "Veeam", "Macrium", "CrashPlan", "Datto", "Synology", "Duplicati", "OneDrive")
$backupStatus = "Apps: $backupApps | Services: $backupServices"

$problemDevices = @(Get-AdrCim -ClassName Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
$driversMissing = if ($problemDevices.Count -gt 0) {
    Join-AdrText ($problemDevices | Select-Object -First 25 | ForEach-Object { "$($_.Name) [ConfigManagerErrorCode=$($_.ConfigManagerErrorCode)]" })
}
else {
    "No PnP problem devices detected through Win32_PnPEntity"
}

$encryptionActive = Get-AdrBitLocker
$secureBoot = Get-AdrSecureBoot
$pendingReboot = Get-AdrPendingReboot
$recentHotfixes = try {
    ConvertTo-AdrText (Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn)
}
catch {
    "Unavailable: $($_.Exception.Message)"
}

$recentErrors = Get-AdrRecentEvents
$networkSummary = Get-AdrNetworkSummary
$networkDetails = Get-AdrNetworkDetails

$displayDetection = Join-AdrText @(
    Join-AdrText ($video | ForEach-Object { "$($_.Name) [$($_.VideoModeDescription)]" }) "No video controllers returned"
    Get-AdrPnpSummary -Classes @("Monitor")
)
$touchDetection = Join-AdrText @(
    Get-AdrPnpSummary -Classes @("HIDClass") -NamePatterns @("Touch Screen", "Touchscreen")
)
$keyboardDetection = Get-AdrPnpSummary -Classes @("Keyboard")
$trackpadDetection = Join-AdrText @(
    Get-AdrPnpSummary -Classes @("Mouse", "HIDClass") -NamePatterns @("Touchpad", "Trackpad", "Precision Touchpad", "Pointing")
)
$webcamDetection = Join-AdrText @(
    Get-AdrPnpSummary -Classes @("Camera", "Image")
)
$audioDetection = Get-AdrPnpSummary -Classes @("MEDIA") -NamePatterns @("Audio", "Microphone", "Speaker", "Sound")
$currentAccountSummary = Get-AdrCurrentAccountSummary
$microsoftJoinSummary = Get-AdrMicrosoftJoinSummary
$oneDriveStatus = Get-AdrOneDriveStatus
$microphoneUsage = Get-AdrCapabilityUsageSummary -Capability "microphone" -Label "Microphone"
$cameraUsage = Get-AdrCapabilityUsageSummary -Capability "webcam" -Label "Camera"
$tpmStatus = Get-AdrTpmSummary

Write-AdrStatus "Compiling diagnostic report..."
$facts = [ordered]@{
    GeneratedAt = $generatedAt
    ComputerName = $computerName
    IsAdmin = $isAdmin
    OSVersion = $osVersion
    Make = $make
    Model = $model
    Serial = $serial
    BIOSDate = $biosDate
    DeviceAge = $deviceAge
    CPU = $cpuSummary
    GPU = $gpuSummary
    RAMSize = $ramSize
    RAMSpeed = $ramSpeed
    RAMType = $ramType
    DriveType = $driveType
    DriveSize = $driveSize
    FreeSpace = $freeSpace
    SMART = $smartStatus
    BatteryHealth = $batteryHealth
    BatteryRuntime = $batteryRuntime
    Charging = $chargingFunctional
    Temperature = $idleTemp
    Office = $officeInstalled
    Antivirus = $antivirusSoftware
    Backup = $backupStatus
    Encryption = $encryptionActive
    Drivers = $driversMissing
    Network = $networkSummary
    CurrentAccount = $currentAccountSummary
    MicrosoftJoin = $microsoftJoinSummary
    OneDrive = $oneDriveStatus
    MicrophoneUsage = $microphoneUsage
    CameraUsage = $cameraUsage
    TPM = $tpmStatus
    RootDriveAnomalies = $rootDriveAnomalies
    RemoteAgents = $remoteAgentData
}

$aiResult = $null
if ($UseAiEnrichment) {
    $aiResult = Invoke-AdrAiEnrichment -Facts $facts -RequestedProvider $AiProvider -RequestedModel $AiModel -RequestedEndpoint $AiEndpoint
}

$reportLines = New-Object System.Collections.Generic.List[string]
function Add-AdrLine {
    param([string]$Text = "")
    [void]$script:reportLines.Add($Text)
}

function Add-AdrSection {
    param([string]$Title)
    Add-AdrLine ""
    Add-AdrLine "## $Title"
    Add-AdrLine ("-" * ($Title.Length + 3))
}

Add-AdrLine "ADR - Automated Diagnostic Report"
Add-AdrLine "================================="

Add-AdrSection "Report Metadata"
Add-AdrLine "Generated: $generatedAt"
Add-AdrLine "Computer Name: $computerName"
Add-AdrLine "Run As Admin: $isAdmin"
Add-AdrLine "Script Path: $PSCommandPath"
Add-AdrLine "Output File: $outputFile"
Add-AdrLine "Environment File: $envFileStatus"
Add-AdrLine "Privacy Guardrail: Does not collect passwords, Wi-Fi keys, browser history, product keys, or customer file contents."

Add-AdrSection "Original Intake Checklist"
Add-AdrLine "Device Age: $deviceAge"
Add-AdrLine "Serial: $serial"
Add-AdrLine "Make: $make"
Add-AdrLine "Model: $model"
Add-AdrLine "Estimated Device Value: Manual Check Required (optional AI section can provide research terms)"
Add-AdrLine "CPU: $cpuSummary"
Add-AdrLine "GPU: $gpuSummary"
Add-AdrLine "RAM Size: $ramSize"
Add-AdrLine "RAM Speed: $ramSpeed"
Add-AdrLine "RAM Type: $ramType"
Add-AdrLine "Cooling Type: Manual Check Required (OS does not reliably report cooling design)"
Add-AdrLine "OS Version: $osVersion"
Add-AdrLine "Office Installed: $officeInstalled"
Add-AdrLine "Antivirus Software: $antivirusSoftware"
Add-AdrLine "Backup Software Active: $backupStatus"
Add-AdrLine "Admin / BIOS Password Provided: Manual Check Required (do not collect or store passwords)"
Add-AdrLine ""
Add-AdrLine "Display & Visuals"
Add-AdrLine ""
Add-AdrLine "Display Intact/No Cracks (manual): $($manualChecks.display)"
Add-AdrLine "Touch Screen Responsive (manual): $($manualChecks.touch_screen) (detected: $touchDetection)"
Add-AdrLine "External Video Output OK (detected): $displayDetection"
Add-AdrLine ""
Add-AdrLine "Input & Peripheral Health"
Add-AdrLine ""
Add-AdrLine "Keyboard Working (manual): $($manualChecks.keyboard) (detected: $keyboardDetection)"
Add-AdrLine "Trackpad Working (manual): $($manualChecks.trackpad) (detected: $trackpadDetection)"
Add-AdrLine "Webcam Working (manual): $($manualChecks.webcam) (detected: $webcamDetection)"
Add-AdrLine "Internet/WiFi Working: $networkSummary"
Add-AdrLine "Left Speaker Working (manual): $($manualChecks.left_speaker)"
Add-AdrLine "Right Speaker Working (manual): $($manualChecks.right_speaker)"
Add-AdrLine "Microphone Working (manual): $($manualChecks.microphone) (usage: $microphoneUsage)"
Add-AdrLine ""
Add-AdrLine "Power & Thermal Stats"
Add-AdrLine ""
Add-AdrLine "DC Jack/Type-C Port Condition: Manual Check Required"
Add-AdrLine "Charging Functional: (Yes/No) $chargingFunctional"
Add-AdrLine "Battery Health %: $batteryHealth"
Add-AdrLine "Idle Temp: (deg C) $idleTemp"
Add-AdrLine ""
Add-AdrLine "Storage & Logic"
Add-AdrLine ""
Add-AdrLine "Drive Type: $driveType"
Add-AdrLine "Drive Size: $driveSize"
Add-AdrLine "Free Space: $freeSpace"
Add-AdrLine "SMART Drive Status: $smartStatus"
Add-AdrLine "Drivers Missing/Errors: $driversMissing"
Add-AdrLine "BitLocker/Encryption Active: $encryptionActive"
Add-AdrLine ""
Add-AdrLine "Technician's Assessment"
Add-AdrLine ""
Add-AdrLine "Physical Condition: (Dust, dents, missing screws) Manual Check Required"
Add-AdrLine "Previous Repair Evidence: Manual Check Required"
Add-AdrLine "Initial Issue: Manual Check Required"
Add-AdrLine "Secondary Risks/Issues Found: Manual Check Required"
Add-AdrLine "Required Parts/Labor: Manual Check Required"

Add-AdrSection "Expanded Automated Diagnostics"
Add-AdrLine "BIOS/Firmware Date: $biosDate"
Add-AdrLine "BIOS Version: $(First-AdrNonBlank @($bios.SMBIOSBIOSVersion, $bios.BIOSVersion))"
Add-AdrLine "Baseboard: $(First-AdrNonBlank @($baseboard.Manufacturer)) $(First-AdrNonBlank @($baseboard.Product))"
Add-AdrLine "Last Boot: $lastBoot"
Add-AdrLine "CPU Detail: $cpuSummary"
Add-AdrLine "GPU Detail: $gpuSummary"
Add-AdrLine "Memory Detail:"
Add-AdrLine $memoryDetail
Add-AdrLine "Disk Detail:"
Add-AdrLine (ConvertTo-AdrText ($diskDrives | Select-Object Model, InterfaceType, MediaType, Size, SerialNumber | Format-Table -AutoSize))
Add-AdrLine "Recent Hotfixes:"
Add-AdrLine $recentHotfixes
Add-AdrLine "Pending Reboot: $pendingReboot"
Add-AdrLine "Recent Critical/Error System Events:"
Add-AdrLine $recentErrors

Add-AdrSection "Security / Backup / Encryption"
Add-AdrLine "Secure Boot: $secureBoot"
Add-AdrLine "TPM: $tpmStatus"
Add-AdrLine "BitLocker/Encryption: $encryptionActive"
Add-AdrLine "Antivirus: $antivirusSoftware"
Add-AdrLine "Backup Software/Services: $backupStatus"

Add-AdrSection "Cloud / Account Status"
Add-AdrLine "Current Windows Account: $currentAccountSummary"
Add-AdrLine "Microsoft Join / Work Account State: $microsoftJoinSummary"
Add-AdrLine "OneDrive Status: $oneDriveStatus"

Add-AdrSection "Storage / Battery / Thermal"
Add-AdrLine "Drive Type: $driveType"
Add-AdrLine "Drive Size: $driveSize"
Add-AdrLine "Free Space: $freeSpace"
Add-AdrLine "SMART/Health: $smartStatus"
Add-AdrLine "Battery Runtime State: $batteryRuntime"
Add-AdrLine "Battery Health: $batteryHealth"
Add-AdrLine "Charging State: $chargingFunctional"
Add-AdrLine "Thermal Sensors: $idleTemp"

Add-AdrSection "Network / Peripheral Detection"
Add-AdrLine "Network Summary: $networkSummary"
Add-AdrLine "Network Details:"
Add-AdrLine $networkDetails
Add-AdrLine "Display/Monitor Detection: $displayDetection"
Add-AdrLine "Touch Detection: $touchDetection"
Add-AdrLine "Keyboard Detection: $keyboardDetection"
Add-AdrLine "Trackpad/Pointing Detection: $trackpadDetection"
Add-AdrLine "Webcam Detection: $webcamDetection"
Add-AdrLine "Camera Privacy Usage: $cameraUsage"
Add-AdrLine "Audio Detection: $audioDetection"
Add-AdrLine "Microphone Privacy Usage: $microphoneUsage"

Add-AdrSection "Manual Checks Required"
Add-AdrLine "Manual Check Mode: $($manualChecks.mode)"
Add-AdrLine ""
Add-AdrLine "Hardware Tests"
Add-AdrLine "Display (no cracks, backlight even): $($manualChecks.display)"
Add-AdrLine "Touch Screen: $($manualChecks.touch_screen)"
Add-AdrLine "Keyboard (all keys responding): $($manualChecks.keyboard)"
Add-AdrLine "Trackpad / Pointing Device: $($manualChecks.trackpad)"
Add-AdrLine "Left Speaker: $($manualChecks.left_speaker)"
Add-AdrLine "Right Speaker: $($manualChecks.right_speaker)"
Add-AdrLine "Microphone: $($manualChecks.microphone)"
Add-AdrLine "Webcam (live image visible): $($manualChecks.webcam)"
if (-not [string]::IsNullOrWhiteSpace($manualChecks.notes)) {
    Add-AdrLine "Technician Notes: $($manualChecks.notes)"
}
Add-AdrLine ""
Add-AdrLine "Physical Inspection (fill in manually)"
Add-AdrLine "Estimated device value and device age confirmation"
Add-AdrLine "DC jack/USB-C port tightness, charger compatibility, liquid damage, dust, dents, and missing screws"
Add-AdrLine "Admin/BIOS password availability without recording the password"
Add-AdrLine "Previous repair evidence, initial issue, secondary risks, and parts/labor quote"

Add-AdrSection "Root Drive / Filesystem Anomalies"
Add-AdrLine $rootDriveAnomalies

Add-AdrSection "Remote Access Agents"
Add-AdrLine $remoteAgentData

if ($UseAiEnrichment) {
    Add-AdrSection "AI Research Suggestions"
    Add-AdrLine "Provider: $($aiResult.Provider)"
    Add-AdrLine "Endpoint: $($aiResult.Endpoint)"
    Add-AdrLine "Model: $($aiResult.Model)"
    Add-AdrLine $aiResult.Content
}

Set-Content -LiteralPath $outputFile -Value $reportLines -Encoding UTF8
Write-AdrStatus "Writing report to disk..."
Write-Host ""
Write-Host "Diagnostic report written to: $outputFile"

if ([System.Environment]::GetEnvironmentVariable("ADR_SES_ENABLED") -eq "true") {
    Send-AdrSesEmail -ReportPath $outputFile -ComputerName $computerName -Timestamp $timestamp
}

