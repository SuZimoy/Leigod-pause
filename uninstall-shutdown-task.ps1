# Remove the shutdown task and staged files created by install-shutdown-task.ps1.
# Self-elevates through UAC.
$ErrorActionPreference = "Continue"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "Requesting administrator rights (UAC)..." -ForegroundColor Yellow
  Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $PSCommandPath + '"')) -Verb RunAs
  exit
}
foreach ($taskName in @("LeigodPauseOnShutdown", "LeigodPauseOnLogon")) {
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($t) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "removed scheduled task: $taskName"
  } else { Write-Host ("scheduled task not found (already removed): " + $taskName) }
}
$dest = Join-Path $env:ProgramData "LeigodGuard"
if (Test-Path -LiteralPath $dest) {
  Remove-Item -LiteralPath $dest -Recurse -Force
  Write-Host "removed staged folder: $dest"
}

if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
