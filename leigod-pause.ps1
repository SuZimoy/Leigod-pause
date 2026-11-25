<#
  Leigod (LeiShen) billing auto-pause / status / recover helper.
  Reads account_token from the Leigod client HTTP logs, then calls
  https://webapi.leigod.com/api/user/(pause|info|recover).

  The client install folder is auto-discovered (running process, uninstall
  registry entry, client Preferences, Start Menu shortcuts, common paths).
  No hardcoded drive letter is needed; leigod-pause.ini can still pin log_dir.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File leigod-pause.ps1 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File leigod-pause.ps1 -Pause
    powershell -NoProfile -ExecutionPolicy Bypass -File leigod-pause.ps1 -Recover
    powershell -NoProfile -ExecutionPolicy Bypass -File leigod-pause.ps1 -Pause -DryRun

  Exit codes: 0 ok, 2 no token, 3 network fail, 4 token expired, 5 api error
#>
param(
  [switch]$Pause,
  [switch]$Status,
  [switch]$Recover,
  [string]$Token = "",
  [string]$TokenFile = "",
  [string]$ConfigFile = "",
  [int]$TimeoutSec = 4,
  [int]$Retry = 2,
  [switch]$DryRun,
  [switch]$SkipProcess
)

$ErrorActionPreference = "Stop"
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$LogFile = Join-Path $ScriptDir "leigod-pause.log"
if (-not $ConfigFile) { $ConfigFile = Join-Path $ScriptDir "leigod-pause.ini" }
if (-not $TokenFile) { $TokenFile = Join-Path $ScriptDir "account_token.txt" }

$LeigodLogDir = ""
if (Test-Path -LiteralPath $ConfigFile) {
  $ini = Get-Content -LiteralPath $ConfigFile -Raw -ErrorAction SilentlyContinue
  if ($ini -match "(?im)^\s*log_dir\s*=\s*(.+)$") {
    $v = $Matches[1].Trim()
    if ($v) { $LeigodLogDir = $v }
  }
}

$script:LogDirUsed = ""
$script:DirsTried = @()

function Write-Log([string]$msg) {
  $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $msg
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
  Write-Host $line
}

# Given a client exe/folder path, return the folder that actually holds http-*.log.
function Find-LogDirUnder([string]$basePath) {
  if (-not $basePath) { return $null }
  $cands = New-Object System.Collections.Generic.List[string]
  try {
    if (Test-Path -LiteralPath $basePath -PathType Leaf) {
      $cands.Add((Split-Path -Parent $basePath))
    } elseif (Test-Path -LiteralPath $basePath -PathType Container) {
      $cands.Add($basePath)
      $pp = Split-Path -Parent $basePath
      if ($pp) { $cands.Add($pp) }
    } else {
      return $null
    }
  } catch { return $null }

  foreach ($c in $cands) {
    if (-not $c) { continue }
    if (Get-ChildItem -LiteralPath $c -Filter "http-*.log" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $c }
    $res = Join-Path $c "resources"
    if (Test-Path -LiteralPath $res -PathType Container) {
      foreach ($s in (Get-ChildItem -LiteralPath $res -Directory -ErrorAction SilentlyContinue)) {
        if (Get-ChildItem -LiteralPath $s.FullName -Filter "http-*.log" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $s.FullName }
      }
      if (Get-ChildItem -LiteralPath $res -Filter "http-*.log" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $res }
    }
    # some installs keep logs in <client>\llogs or <client>\logs
    foreach ($sub in @("llogs","logs","log")) {
      $p = Join-Path $c $sub
      if (Test-Path -LiteralPath $p -PathType Container) {
        if (Get-ChildItem -LiteralPath $p -Filter "http-*.log" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $p }
      }
    }
  }
  return $null
}

function Get-InstallBases {
  $bases = New-Object System.Collections.Generic.List[string]

  # 1) running client process
  if (-not $SkipProcess) {
  foreach ($n in @("leigod","LeiGod","LeiGod_Acc","leiniao")) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($procs) {
      foreach ($p in $procs) {
        try { if ($p.Path) { $bases.Add($p.Path) } } catch { }
      }
    }
  }
  }

  # 2) uninstall registry entries
  $roots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
  )
  foreach ($r in $roots) {
    foreach ($it in (Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
      $prop = Get-ItemProperty -LiteralPath $it.PSPath -ErrorAction SilentlyContinue
      if (-not $prop) { continue }
      $dn = "" + $prop.DisplayName
      if ($dn -match "雷神|LeiGod|leigod|leiniao") {
        if ($prop.InstallLocation) { $bases.Add(("" + $prop.InstallLocation).Trim('"')) }
        if ($prop.DisplayIcon) {
          $ic = ("" + $prop.DisplayIcon).Trim('"')
          $ic = $ic -replace ',\d+$', ''
          if ($ic) { $bases.Add($ic) }
        }
      }
    }
  }

  # 3) client Preferences JSON (Chromium userData) holds absolute install paths
  if ($env:APPDATA) {
    foreach ($pd in (Get-ChildItem -LiteralPath $env:APPDATA -Directory -Filter "leigod*" -ErrorAction SilentlyContinue)) {
      foreach ($fn in @("Preferences","Local State")) {
        $pf = Join-Path $pd.FullName $fn
        if (Test-Path -LiteralPath $pf) {
          $txt = Get-Content -LiteralPath $pf -Raw -ErrorAction SilentlyContinue
          if ($txt) {
            $txt = $txt -replace 'file:[\\/]{2,}', ''
            foreach ($m in [regex]::Matches($txt, '[A-Za-z]:[\\/][^"\r\n]*')) {
              $v = $m.Value
              if ($v -match "LeiGod|leigod|leiniao|雷神") { $bases.Add($v) }
            }
          }
        }
      }
    }
  }

  # 4) Start Menu / Desktop shortcuts
  $lnkDirs = @()
  $lnkDirs += [Environment]::GetFolderPath("Desktop")
  $lnkDirs += [Environment]::GetFolderPath("CommonDesktopDirectory")
  if ($env:APPDATA) { $lnkDirs += (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") }
  if ($env:ProgramData) { $lnkDirs += (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs") }
  try {
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($ld in $lnkDirs) {
      if (-not $ld) { continue }
      foreach ($lnk in (Get-ChildItem -LiteralPath $ld -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue)) {
        if ($lnk.Name -match "雷神|LeiGod|leiniao") {
          try {
            $sc = $wsh.CreateShortcut($lnk.FullName)
            if ($sc.TargetPath) { $bases.Add($sc.TargetPath) }
          } catch { }
        }
      }
    }
  } catch { }

  # 5) common folder names on every fixed drive
  $names = @("LeiGod_Acc","LeiGodAcc","leigod","LeiGod","leiniao","雷神加速器")
  $parents = @("", "Program Files", "Program Files (x86)", "Software", "Programs", "Games")
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match "^[A-Za-z]:\\$" })) {
    foreach ($par in $parents) {
      foreach ($nm in $names) {
        if ($par) { $bases.Add((Join-Path (Join-Path $d.Root $par) $nm)) }
        else { $bases.Add((Join-Path $d.Root $nm)) }
      }
    }
  }

  return $bases
}

function Find-LeigodLogDir {
  $bases = Get-InstallBases
  $seen = New-Object System.Collections.Generic.HashSet[string]
  foreach ($b in $bases) {
    if (-not $b) { continue }
    $key = $b.ToLowerInvariant()
    if (-not $seen.Add($key)) { continue }
    $script:DirsTried += $b
    $found = Find-LogDirUnder $b
    if ($found) { return $found }
  }
  return $null
}

function Get-TokenValue {
  if ($Token) { return $Token.Trim() }
  if (Test-Path -LiteralPath $TokenFile) {
    $t = Get-Content -LiteralPath $TokenFile -Raw -ErrorAction SilentlyContinue
    if ($t) {
      $t = $t.Trim()
      if ($t) { return $t }
    }
  }

  $dirs = New-Object System.Collections.Generic.List[string]
  if ($LeigodLogDir) { $dirs.Add($LeigodLogDir) }
  $auto = Find-LeigodLogDir
  if ($auto) { $dirs.Add($auto) }

  foreach ($d in ($dirs | Select-Object -Unique)) {
    if (-not $d) { continue }
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $files = @()
    try {
      $files = Get-ChildItem -LiteralPath $d -Filter "http-*.log" -ErrorAction Stop | Sort-Object LastWriteTime -Descending
    } catch { continue }
    foreach ($f in $files) {
      $txt = $null
      try { $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
      if (-not $txt) { continue }
      $ms = [regex]::Matches($txt, 'account_token=([^&"'' ]+)')
      if ($ms.Count -gt 0) {
        $raw = $ms[$ms.Count - 1].Groups[1].Value
        $t = [System.Uri]::UnescapeDataString($raw)
        if ($t) {
          $script:LogDirUsed = $d
          return $t
        }
      }
    }
  }
  return $null
}

function Invoke-LeigodApi([string]$apiPath, [string]$tok) {
  $hosts = @("https://webapi.leigod.com", "https://webapi.nn.com")
  $body = '{"account_token":"' + $tok + '"}'
  $lastErr = ""
  foreach ($h in $hosts) {
    $uri = $h + $apiPath
    for ($i = 1; $i -le $Retry; $i++) {
      try {
        return Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSec
      } catch {
        $lastErr = $_.Exception.Message
        Start-Sleep -Milliseconds 500
      }
    }
  }
  throw $lastErr
}

$action = "pause"
if ($Status) { $action = "info" }
elseif ($Recover) { $action = "recover" }

$tok = Get-TokenValue
if (-not $tok) {
  Write-Log ("[" + $action + "] ERROR no token found. Start the Leigod client once, or put the token into " + $TokenFile)
  if ($script:DirsTried.Count -gt 0) {
    Write-Log ("[" + $action + "] searched " + $script:DirsTried.Count + " candidate install paths, e.g. " + ($script:DirsTried | Select-Object -First 5 -join " | "))
  }
  Write-Log ("[" + $action + "] hint: set log_dir=<client>\resources\llogs in " + $ConfigFile)
  exit 2
}
Write-Log ("[" + $action + "] token len=" + $tok.Length)
if ($script:LogDirUsed) { Write-Log ("[" + $action + "] log dir: " + $script:LogDirUsed) }

if ($DryRun) {
  $shown = $tok.Substring(0, [Math]::Min(6, $tok.Length)) + "***"
  Write-Log ("[" + $action + "] DRY-RUN token=" + $shown + " target=/api/user/" + $action)
  exit 0
}

try {
  $r = Invoke-LeigodApi ("/api/user/" + $action) $tok
} catch {
  Write-Log ("[" + $action + "] NETWORK FAIL: " + $_.Exception.Message)
  exit 3
}

$code = "" + $r.code
$msgText = "" + $r.msg
Write-Log ("[" + $action + "] code=" + $code + " msg=" + $msgText)

$expiredCodes = @("400006","400007","400008","400816","400334","400027")

if ($action -eq "pause") {
  if ($code -eq "0") { Write-Log "[pause] OK - billing paused"; exit 0 }
  if ($code -eq "400803") { Write-Log "[pause] OK - already paused (400803)"; exit 0 }
}
elseif ($action -eq "recover") {
  if ($code -eq "0") { Write-Log "[recover] OK - billing resumed"; exit 0 }
}
elseif ($action -eq "info") {
  if ($code -eq "0") {
    $d = $r.data
    if ($d) {
      Write-Log ("[info] pause_status_id=" + $d.pause_status_id + " exp_time=" + $d.exp_time + " mobile=" + $d.mobile_num)
    } else { Write-Log "[info] empty data" }
    exit 0
  }
}

if ($expiredCodes -contains $code) {
  Write-Log ("[" + $action + "] TOKEN EXPIRED code=" + $code + " - reopen the Leigod client to refresh the token")
  exit 4
}
Write-Log ("[" + $action + "] API ERROR code=" + $code)
exit 5
