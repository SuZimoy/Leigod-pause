# Leigod shutdown pause via Task Scheduler (NO resident process).
# Works on Windows Home editions where gpedit.msc / local GPO scripts are unavailable.
# Self-elevates through UAC; needs administrator once.
$ErrorActionPreference = "Stop"
$script:LogFile = Join-Path $PSScriptRoot "shutdown-task.log"

function Say([string]$m) {
  $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $m
  Write-Host $line
  try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "Requesting administrator rights (UAC)..." -ForegroundColor Yellow
  Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $PSCommandPath + '"')) -Verb RunAs
  Write-Host "If a UAC prompt appeared, confirm it; this window can be closed."
  Start-Sleep -Seconds 2
  exit
}

Say "=== install start (admin) ==="

$core = Join-Path $PSScriptRoot "leigod-pause.ps1"
if (-not (Test-Path -LiteralPath $core)) { throw "leigod-pause.ps1 not found next to this script" }

# --- 1. stage the pause script where SYSTEM can always read it --------------
$dest = Join-Path $env:ProgramData "LeigodGuard"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$coreDest = Join-Path $dest "leigod-pause.ps1"
Copy-Item -LiteralPath $core -Destination $coreDest -Force
Say "staged: $coreDest"

# --- 2. pin the client log dir (SYSTEM has a different %APPDATA%) -----------
$probeLog = Join-Path $PSScriptRoot "leigod-pause.log"
if (Test-Path -LiteralPath $probeLog) { Remove-Item -LiteralPath $probeLog -Force }
try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core -Pause -DryRun 2>&1 | Out-Null } catch { }
$logDir = ""
if (Test-Path -LiteralPath $probeLog) {
  $hit = Select-String -LiteralPath $probeLog -Pattern 'log dir: (.+)$' | Select-Object -Last 1
  if ($hit) { $logDir = $hit.Matches[0].Groups[1].Value.Trim() }
}
if ($logDir) {
  Set-Content -LiteralPath (Join-Path $dest "leigod-pause.ini") -Value ("log_dir=" + $logDir) -Encoding ASCII
  Say "log_dir pinned: $logDir"
} else {
  Say "WARNING: log dir not detected; SYSTEM run will fall back to registry + disk scan"
}

# --- 3. register the scheduled task -----------------------------------------
$taskName = "LeigodPauseOnShutdown"
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Pause Leigod billing right before Windows shuts down. No resident process.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='User32'] and (EventID=1074)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Kernel-General'] and (EventID=13)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$coreDest" -Pause</Arguments>
    </Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
Say "scheduled task registered: $taskName (trigger: System event 1074 / 13, run as SYSTEM)"

$t = Get-ScheduledTask -TaskName $taskName
Say ("state: " + $t.State + "  |  action arg: " + $t.Actions[0].Arguments.Substring(0, [Math]::Min(90, $t.Actions[0].Arguments.Length)) + "...")

# (logon catch-up task intentionally not registered)

Say ""
Say "Next shutdown will pause Leigod billing automatically."
Say "Verify after reboot:  Get-ScheduledTaskInfo -TaskName '$taskName'"
Say "Manual test (pauses now, recover with -Recover):"
Say ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $coreDest + '" -Pause')
Say ""
if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
