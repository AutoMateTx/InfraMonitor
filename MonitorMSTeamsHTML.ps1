# monitor.ps1 - Fully compatible with Windows PowerShell 5.1
param(
    [string]$ConfigFile = "config.ini",
    [string]$ServersFile = "servers.ini",
    [string]$OutputFile = "server-status.json",
    [switch]$DebugMode
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $log = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR" { Write-Host $log -ForegroundColor Red }
        "WARN"  { Write-Host $log -ForegroundColor Yellow }
        default { Write-Host $log -ForegroundColor Cyan }
    }
    if ($DebugMode) {
        Add-Content -Path "monitor.log" -Value $log -Encoding UTF8
    }
}

function Get-IniContent {
    param([string]$filePath)
    if (-not (Test-Path $filePath)) {
        Write-Log "Config file not found: $filePath" "ERROR"
        exit 1
    }
    $ini = @{}
    $section = "General"
    $ini[$section] = @{}
    foreach ($line in Get-Content $filePath) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            $ini[$section] = @{}
        } elseif ($line -match '^(.+?)\s*=\s*(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            $ini[$section][$name] = $value
        }
    }
    return $ini
}

function IsValidIPv4 {
    param([string]$ip)
    if (!$ip -or $ip -eq "N/A" -or $ip.Trim() -eq "") { return $false }
    $blocks = $ip -split '\.'
    if ($blocks.Count -ne 4) { return $false }
    foreach ($block in $blocks) {
        if ($block -notmatch '^\d+$') { return $false }
        $num = [int]$block
        if ($num -lt 0 -or $num -gt 255) { return $false }
        if ($block.Length -gt 1 -and $block.StartsWith('0')) { return $false } # no leading zeros
    }
    return $true
}

Write-Log "Starting server monitor..." "INFO"

try {
    $config = Get-IniContent $ConfigFile
    $servers = Get-IniContent $ServersFile

    $pingInterval = if ($config["Ping"] -and $config["Ping"]["Interval"]) { [int]$config["Ping"]["Interval"] } else { 30 }
    $pingTimeoutMs = if ($config["Ping"] -and $config["Ping"]["Timeout"]) { [int]$config["Ping"]["Timeout"] } else { 1000 }
    $pingBufferSize = if ($config["Ping"] -and $config["Ping"]["BufferSize"]) { [int]$config["Ping"]["BufferSize"] } else { 32 }
    $pingCount = if ($config["Ping"] -and $config["Ping"]["Count"]) { [int]$config["Ping"]["Count"] } else { 4 }

    Write-Log "Ping config: Interval=$pingInterval, Timeout=$pingTimeoutMs ms, Buffer=$pingBufferSize, Count=$pingCount"

    while ($true) {
        $results = @()
        $totalServers = $servers.Keys.Count
        Write-Log "Checking $totalServers servers..."

        foreach ($serverKey in $servers.Keys) {
            $server = $servers[$serverKey]
            $name = if ($server.Name) { $server.Name } else { $serverKey }
            $ip = $server.IP
            if (-not $ip) {
                Write-Log "Skipping $($name): Missing IP" "WARN"
                continue
            }

            $successCount = 0
            Write-Log "Pinging $($name) ($ip)..." "DEBUG"

            for ($i = 0; $i -lt $pingCount; $i++) {
                $ping = $null
                try {
                    $ping = New-Object System.Net.NetworkInformation.Ping
                    $buffer = New-Object Byte[] $pingBufferSize
                    $reply = $ping.Send($ip, $pingTimeoutMs, $buffer)
                    if ($reply.Status -eq 'Success') {
                        $successCount++
                    }
                }
                catch {
                    Write-Log "Ping failed for $ip (attempt $([int]$i+1)): $($_.Exception.Message)" "DEBUG"
                }
                finally {
                    if ($ping -ne $null) {
                        $ping.Dispose()
                    }
                }
                Start-Sleep -Milliseconds 100
            }

            $successPct = [math]::Round(($successCount / $pingCount) * 100, 2)
            $result = [PSCustomObject]@{
                Name              = $name
                IP                = $ip
                Application       = if ($server.Application) { $server.Application } else { "N/A" }
                Environment       = if ($server.Environment) { $server.Environment } else { "N/A" }
                Type              = if ($server.Type) { $server.Type } else { "N/A" }
                SuccessPercentage = $successPct
                LastChecked       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $results += $result

            $statusText = if ($successPct -ge 100) { "ONLINE" } elseif ($successPct -gt 0) { "PARTIAL" } else { "OFFLINE" }
            Write-Log "$($name) ($ip): $successPct% success → $statusText"
        }

        # Output clean UTF8 JSON (no BOM)
        $json = $results | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines((Resolve-Path $OutputFile).Path, $json, $utf8NoBom)
        Write-Log "Wrote status to $OutputFile"

        # === MS Teams + HTML Notification Logic ===
        if ($config["Notify"] -and 
            $config["Notify"]["NotifySummary"] -and 
            $config["Notify"]["NotifySummary"].Trim() -eq "true" -and
            $config["Notify"]["TeamsWebhookURL"]) {

            $now = Get-Date
            $today = $now.ToString("yyyy-MM-dd")
            $currentTime = $now.ToString("HH:mm")
            $currentDay = $now.DayOfWeek.ToString()

            $notifyTime = if ($config["Notify"]["NotifyTime"]) { $config["Notify"]["NotifyTime"].Trim() } else { $null }
            $notifyDaysRaw = if ($config["Notify"]["NotifyDays"]) { $config["Notify"]["NotifyDays"].Split(',').Trim() } else { @() }
            $webhookUrl = $config["Notify"]["TeamsWebhookURL"].Trim()

            $isNotifyDay = $notifyDaysRaw -contains $currentDay
            $isNotifyTime = $currentTime -eq $notifyTime

            $notifyStateFile = "last-notify.txt"
            $lastNotifyDate = if (Test-Path $notifyStateFile) { Get-Content $notifyStateFile -TotalCount 1 } else { "" }

            if ($isNotifyDay -and $isNotifyTime -and $lastNotifyDate -ne $today) {
	        Write-Log "Preparing daily notification..." "INFO"

                $offlineList = @()
                $invalidList = @()

                foreach ($s in $results) {
                    if ($s.SuccessPercentage -eq 0) {
                        $offlineList += "$($s.Name) [App: $($s.Application), Env: $($s.Environment)]"
                    }
                    if (-not (IsValidIPv4 $s.IP)) {
                        $invalidList += "$($s.Name) [App: $($s.Application), Env: $($s.Environment)]"
                    }
                }

                $online = @($results | Where-Object { $_.SuccessPercentage -ge 100 }).Count
                $partial = @($results | Where-Object { $_.SuccessPercentage -gt 0 -and $_.SuccessPercentage -lt 100 }).Count
                $offline = $offlineList.Count
                $invalid = $invalidList.Count

                $offlineText = if ($offlineList.Count -gt 0) { $offlineList -join "`n  • " } else { "None" }
                $invalidText = if ($invalidList.Count -gt 0) { $invalidList -join "`n  • " } else { "None" }

                # Teams message
                $summaryText = @"
**Server Status Summary**  
📅 *$($now.ToString("dddd, MMM dd, yyyy"))*  
⏰ *$notifyTime*

🟢 Online: $online  
🟡 Partial: $partial  
🔴 Offline: $offline  
🔵 Invalid IP: $invalid  

**Offline Servers**:  
  • $offlineText

**Invalid IP Servers**:  
  • $invalidText

Total: $($results.Count) servers
"@

                $teamsMessage = @{ text = $summaryText } | ConvertTo-Json

                try {
                    #Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $teamsMessage -ContentType 'application/json' | Out-Null
                    Write-Log "MS Teams notification sent." "INFO"
                    Set-Content -Path $notifyStateFile -Value $today -Encoding UTF8

                    # --- Generate HTML Preview ---
                    $htmlPreviewFile = "teams-preview-$($today.Replace('-','')).html"

                    $offlineHtml = if ($offlineList.Count -gt 0) {
                        ($offlineList | ForEach-Object { "• $_" }) -join "<br>"
                    } else { "None" }

                    $invalidHtml = if ($invalidList.Count -gt 0) {
                        ($invalidList | ForEach-Object { "• $_" }) -join "<br>"
                    } else { "None" }

                    $htmlContent = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='UTF-8' />
  <meta name='viewport' content='width=device-width, initial-scale=1.0'/>
  <title>Teams Notification Preview</title>
  <style>
    :root {
      --green: #4CAF50;
      --amber: #FF9800;
      --red: #F44336;
      --blue: #2196F3;
      --dark: #2C3E50;
      --light: #f8f9fa;
      --border: #dee2e6;
      --gray: #6c757d;
    }
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      background: #f5f7fb;
      color: var(--dark);
      padding: 20px;
      margin: 0;
    }
    .container { max-width: 700px; margin: 0 auto; }
    .card {
      background: white;
      border-radius: 12px;
      padding: 24px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.08);
    }
    h2 {
      font-size: 1.6rem;
      font-weight: 600;
      margin-bottom: 16px;
      color: var(--dark);
    }
    .timestamp {
      font-size: 1.1rem;
      margin-bottom: 20px;
      color: var(--gray);
    }
    .summary-line {
      margin: 8px 0;
      font-size: 1.05rem;
      line-height: 1.5;
    }
    .section-title {
      font-weight: 600;
      margin-top: 16px;
      margin-bottom: 8px;
      color: var(--dark);
    }
    .server-list {
      padding-left: 20px;
      line-height: 1.6;
    }
    .footer {
      margin-top: 24px;
      padding-top: 16px;
      border-top: 1px solid var(--border);
      color: var(--gray);
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <div class='container'>
    <div class='card'>
      <h2>Server Status Summary</h2>
      <div class='timestamp'>📅 $($now.ToString("dddd, MMM dd, yyyy"))<br>⏰ $notifyTime</div>
      
      <div class='summary-line'>🟢 <strong>Online</strong>: $online</div>
      <div class='summary-line'>🟡 <strong>Partial</strong>: $partial</div>
      <div class='summary-line'>🔴 <strong>Offline</strong>: $offline</div>
      <div class='summary-line'>🔵 <strong>Invalid IP</strong>: $invalid</div>

      <div class='section-title'>Offline Servers:</div>
      <div class='server-list'>$offlineHtml</div>

      <div class='section-title'>Invalid IP Servers:</div>
      <div class='server-list'>$invalidHtml</div>

      <div class='summary-line' style='margin-top:16px;'><strong>Total:</strong> $($results.Count) servers</div>

      <div class='footer'>Preview generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
    </div>
  </div>
</body>
</html>
"@
                    Set-Content -Path $htmlPreviewFile -Value $htmlContent -Encoding UTF8
                    Write-Log "HTML preview saved to $htmlPreviewFile" "INFO"
                }
                catch {
                    Write-Log "Failed to send notification or save HTML: $($_.Exception.Message)" "ERROR"
                }
            }
        }

        Write-Log "Sleeping for $pingInterval seconds..."
        Start-Sleep -Seconds $pingInterval
    }
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" "ERROR"
    exit 1
}