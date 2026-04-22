# Check TCP Port Usage
# Per-process TCP connection breakdown with port exhaustion risk assessment.

# Parse dynamic port range to calculate exhaustion %
$portRange = netsh int ipv4 show dynamicport tcp
$startPort = 0; $portCount = 0
$portRange | ForEach-Object {
    if ($_ -match 'Start Port\s*:\s*(\d+)')      { $startPort = [int]$Matches[1] }
    if ($_ -match 'Number of Ports\s*:\s*(\d+)')  { $portCount = [int]$Matches[1] }
}

# Parse netstat for PID, state, and local port
$lines = netstat -ano | Select-String '^\s+TCP'
$conns = @()
foreach ($l in $lines) {
    if ($l -match 'TCP\s+[\d\.]+:(\d+)\s+[\d\.]+:\d+\s+(\w+)\s+(\d+)') {
        $conns += [PSCustomObject]@{
            LocalPort = [int]$Matches[1]
            State     = $Matches[2]
            PID       = [int]$Matches[3]
        }
    }
}

# Map PIDs to process names
$procNames = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $procNames[$_.Id] = $_.ProcessName
}

# Count ephemeral ports in use (ports within the dynamic range)
$ephemeral = $conns | Where-Object {
    $_.LocalPort -ge $startPort -and $_.LocalPort -lt ($startPort + $portCount)
}

# Per-process breakdown: group by process name, sum all connections per process
Write-Output "=== Per-Process TCP Connections (top 15) ==="
$conns | ForEach-Object {
    $p = $_.PID
    $_ | Add-Member -NotePropertyName 'ProcName' -NotePropertyValue $(
        if ($procNames.ContainsKey($p)) { $procNames[$p] } else { "PID:$p" }
    ) -PassThru
} | Group-Object ProcName | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    $states = $_.Group | Group-Object State
    $est = ($states | Where-Object Name -eq 'ESTABLISHED').Count
    $tw  = ($states | Where-Object Name -eq 'TIME_WAIT').Count
    $cw  = ($states | Where-Object Name -eq 'CLOSE_WAIT').Count
    [PSCustomObject]@{
        Process   = $_.Name
        Total     = $_.Count
        Estab     = $est
        TimeWait  = $tw
        CloseWait = $cw
    }
} | Format-Table -AutoSize

# State summary
Write-Output "`n=== Connection State Summary ==="
$conns | Group-Object State | Sort-Object Count -Descending |
    Select-Object @{N='State';E={$_.Name}}, Count | Format-Table -AutoSize

# Port exhaustion risk
$used = ($ephemeral | Measure-Object).Count
$pct = if ($portCount -gt 0) { [math]::Round(($used / $portCount) * 100, 1) } else { 0 }
Write-Output "=== Ephemeral Port Usage ==="
Write-Output "Dynamic range : $startPort - $($startPort + $portCount - 1) ($portCount ports)"
Write-Output "Ports in use  : $used / $portCount ($pct%)"
if ($pct -ge 80) {
    Write-Output "WARNING: Port usage above 80% - exhaustion risk!"
} elseif ($pct -ge 50) {
    Write-Output "CAUTION: Port usage above 50%"
} else {
    Write-Output "OK: Port usage is healthy"
}
