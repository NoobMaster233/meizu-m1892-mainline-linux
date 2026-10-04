# SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-M1892Port {
    $devices = @(Get-PnpDevice -PresentOnly -Class Ports | Where-Object {
        $_.Class -eq 'Ports' -and $_.InstanceId -like 'USB\VID_1D6B&PID_0104*'
    })
    if ($devices.Count -ne 1) { throw "Expected one installation ACM port; found $($devices.Count)." }
    $match = [regex]::Match($devices[0].FriendlyName, '\((COM[0-9]+)\)')
    if (-not $match.Success) { throw 'ACM port name unavailable.' }
    return $match.Groups[1].Value
}

function Invoke-M1892Console {
    param([Parameter(Mandatory)][string]$Command, [int]$TimeoutSeconds = 30, [switch]$Interrupt)
    # The complete nonce is never transmitted literally. Only output between
    # execution markers is returned, so terminal echo cannot satisfy checks.
    $nonce = 'M1892_' + [guid]::NewGuid().ToString('N')
    $left = $nonce.Substring(0, 20); $right = $nonce.Substring(20)
    $line = "printf '\n%s%s_BEGIN\n' '$left' '$right'; { $Command; }; result=`$?; printf " +
        "'\n%s%s_END:%s\n' '$left' '$right' " + '"$result"'
    # BusyBox interactive line editing can be smaller than the kernel's
    # canonical 4096-byte input limit. Never base64-expand a long command.
    if ($line.Length -gt 900) { throw 'Console command exceeds bounded BusyBox line.' }
    $port = [IO.Ports.SerialPort]::new((Get-M1892Port), 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
    $port.DtrEnable = $true; $port.RtsEnable = $true
    $port.WriteTimeout = 3000; $port.ReadTimeout = 500
    $buffer = [Text.StringBuilder]::new()
    try {
        $port.Open(); Start-Sleep -Milliseconds 250; [void]$port.ReadExisting()
        if ($Interrupt) { $port.Write([string][char]3); Start-Sleep -Milliseconds 250; [void]$port.ReadExisting() }
        $port.Write($line + "`n")
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 100
            [void]$buffer.Append($port.ReadExisting())
            $normalized = $buffer.ToString().Replace("`r", '')
            $match = [regex]::Match($normalized, '(?s)\n' + $nonce + '_BEGIN\n(.*?)\n' + $nonce + '_END:([0-9]+)\n')
            if ($match.Success) {
                if ($match.Groups[2].Value -ne '0') { throw "Device command failed: $($match.Groups[1].Value)" }
                return $match.Groups[1].Value.Trim()
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "ACM execution timeout. Output: $($buffer.ToString())"
    } finally { if ($port.IsOpen) { $port.Close() }; $port.Dispose() }
}

function Assert-M1892Installer {
    param([switch]$RequireSystemd)
    $out = Invoke-M1892Console 'printf "MODEL="; tr -d "\000" </sys/firmware/devicetree/base/model; echo; printf "PID1="; cat /proc/1/comm; cat /run/m1892-installer-boot-identity; if [ -f /etc/m1892-rootfs-identity ]; then cat /etc/m1892-rootfs-identity; fi' -TimeoutSeconds 5
    if ($out -notmatch '(?m)^MODEL=Meizu 16th Plus \(M1892\)$') { throw 'ACM returned a different device model.' }
    if ($out -notmatch '(?m)^mode=m1892-installer-initramfs$') { throw 'Different boot environment; RAM writes rejected.' }
    if ($RequireSystemd -and ($out -notmatch '(?m)^PID1=systemd$' -or
        $out -notmatch '(?m)^rootfs_id=m1892-debian13-installer-ram$' -or
        $out -notmatch '(?m)^root_mode=ram-loopback$')) { throw 'RAM commissioning identity not ready.' }
    return $out
}

function Send-M1892RamFile {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$Sha256)
    if ($Destination -notmatch '^/run/m1892-[A-Za-z0-9_.-]+$' -or $Destination.Contains('..')) { throw 'RAM destination rejected.' }
    $sourcePath = (Resolve-Path -LiteralPath $Source).ProviderPath
    $bytes = (Get-Item -LiteralPath $sourcePath).Length
    [void](Assert-M1892Installer)
    $adapters = @(Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match '^UsbNcm Host Device(?: #[0-9]+)?$' -and $_.Status -eq 'Up' -and
        ($_.MacAddress -replace '[-:]', '').ToLowerInvariant() -eq '020000451893'
    })
    if ($adapters.Count -ne 1) { throw "Expected one active USB NCM adapter; found $($adapters.Count)." }
    $address = [Net.IPAddress]::Parse("fe80::ff:fe45:1892%$($adapters[0].ifIndex)")
    # A transfer never replaces another file or kills an unrelated process.
    $file = [IO.File]::OpenRead($sourcePath)
    $client = [Net.Sockets.TcpClient]::new($address.AddressFamily)
    try {
        $start = "if test ! -e '$Destination' && test ! -e '$Destination.part'; then " +
            "busybox nc -l -p 8091 </dev/null >'$Destination.part' & else false; fi"
        [void](Invoke-M1892Console $start)
        $client.SendTimeout = 120000
        $connect = $client.ConnectAsync($address, 8091)
        if (-not $connect.Wait(15000)) { throw 'USB NCM connect timeout.' }
        $stream = $client.GetStream(); $buffer = [byte[]]::new(1MB); $sent = 0L
        while (($count = $file.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $stream.Write($buffer, 0, $count); $sent += $count
            Write-Progress -Activity 'Sending installation file over USB' -Status "$sent / $bytes bytes" -PercentComplete ([int](100 * $sent / $bytes))
        }
        $stream.Flush(); $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
        Write-Progress -Activity 'Sending installation file over USB' -Completed
        # EOF and a complete device-side hash are the receipt, not socket write success.
        $verify = "for i in `$(seq 1 120); do [ `"`$(stat -c %s '$Destination.part' 2>/dev/null)`" = '$bytes' ] && break; sleep 1; done; " +
            "test `"`$(stat -c %s '$Destination.part')`" = '$bytes' && " +
            "test `"`$(sha256sum '$Destination.part' | awk '{print `$1}')`" = '$Sha256' && " +
            "mv '$Destination.part' '$Destination' && touch '$Destination.ready'"
        [void](Invoke-M1892Console $verify -TimeoutSeconds 180)
    } finally { $file.Dispose(); $client.Dispose() }
}

Export-ModuleMember -Function Get-M1892Port, Invoke-M1892Console, Assert-M1892Installer, Send-M1892RamFile
