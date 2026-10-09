# Buildat: util/windows/sandbox_firewall.ps1
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# [SEC_WIN_NET] A sandboxed server on Windows connects by TCP only to the ports
# Linux's sandbox allows: 80, 443, 465, 587, 29500, 29595 and the ones given in
# -ConnectPorts (as <user>\connect_ports or --connect-ports give them on
# Linux). An AppContainer has no port rules of its own; this adds a Windows
# Firewall rule per app's sandbox (its package SID) that blocks outbound TCP to every
# other port. A block rule wins over any allow rule.
#
# Run as an administrator, from the account that runs buildat (or with
# -Sid), and again after an app has run sandboxed for the first time: its
# sandbox is made then. Run it again to change the ports; -Remove takes the rules
# away.
#
#   powershell -ExecutionPolicy Bypass -File sandbox_firewall.ps1 [-ConnectPorts 8080,2525] [-Remove]
param(
	[int[]]$ConnectPorts = @(),
	[string[]]$Sid = @(),
	[switch]$Remove
)
$ErrorActionPreference = "Stop"

# The boxes: buildat.<app> in the AppContainer mappings of every loaded
# user hive -- the logged-in users'
$boxes = @{}
foreach ($hive in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue) {
	$m = "Registry::$($hive.Name)\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Mappings"
	if (-not (Test-Path $m -ErrorAction SilentlyContinue)) { continue }
	foreach ($k in Get-ChildItem $m -ErrorAction SilentlyContinue) {
		$moniker = (Get-ItemProperty $k.PSPath).Moniker
		if ($moniker -like "buildat.*") { $boxes[$k.PSChildName] = $moniker }
	}
}
foreach ($s in $Sid) { $boxes[$s] = $s }
if ($boxes.Count -eq 0) {
	Write-Output "No buildat sandbox found: run a sandboxed server once first, from the account that will run it"
	exit 1
}

# Every port but the allowed ones, as ranges
$allowed = @(80, 443, 465, 587, 29500, 29595) + $ConnectPorts |
	Where-Object { $_ -gt 0 -and $_ -lt 65536 } | Sort-Object -Unique
$ranges = @()
$from = 1
foreach ($p in $allowed) {
	if ($p -gt $from) { $ranges += "$from-$($p - 1)" }
	$from = $p + 1
}
if ($from -le 65535) { $ranges += "$from-65535" }

foreach ($s in $boxes.Keys) {
	# simplified: the rule keeps its first name, so a rule made before
	# [SANDBOX_WORDING] is replaced, not doubled
	$name = "buildat box $($boxes[$s])"
	Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
		Remove-NetFirewallRule
	if ($Remove) {
		Write-Output "${name}: removed"
		continue
	}
	New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block `
		-Protocol TCP -RemotePort $ranges -Package $s | Out-Null
	Write-Output "${name}: TCP out only to $($allowed -join ', ') ($s)"
}
