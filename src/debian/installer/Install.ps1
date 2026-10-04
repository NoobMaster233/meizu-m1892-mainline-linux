# SPDX-License-Identifier: MIT
param([string]$FastbootPath = '', [switch]$VerifyOnly, [switch]$YesErase)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
Import-Module (Join-Path $package 'Transport.psm1') -Force
$manifest = Get-Content -Raw -LiteralPath (Join-Path $package 'manifest.json') | ConvertFrom-Json
$publicDeviceFirmware = $manifest.schema -eq 2 -and $manifest.scope -eq 'public-device-firmware'
if ($manifest.model -ne 'Meizu 16th Plus (M1892)' -or
    (-not $publicDeviceFirmware -and ($manifest.schema -ne 1 -or $manifest.scope -ne 'owner-local-complete'))) {
    throw 'Unsupported or incomplete package.'
}
if (@($manifest.assets).Count -ne 5) { throw 'Package requires exactly five assets.' }
if ($publicDeviceFirmware -and $manifest.firmware_manifest_sha256 -notmatch '^[a-f0-9]{64}$') {
    throw 'Missing or malformed per-device firmware contract.'
}
if (-not $VerifyOnly) {
    if (-not $FastbootPath) {
        $local = Join-Path $package 'platform-tools\fastboot.exe'
        if (Test-Path -LiteralPath $local) { $FastbootPath = $local }
        else { $FastbootPath = (Get-Command fastboot.exe -ErrorAction Stop).Source }
    }
    if (-not (Test-Path -LiteralPath $FastbootPath)) { throw 'Install official Google platform-tools first.' }
    foreach ($command in @('Get-PnpDevice', 'Get-NetAdapter')) { [void](Get-Command $command -ErrorAction Stop) }
}
# Complete all cheap path/size/role checks before hashing multi-GiB files.
foreach ($asset in $manifest.assets) {
    if ($asset.file -notmatch '^[A-Za-z0-9_.-]+$' -or $asset.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid manifest path/hash.' }
    $path = Join-Path $package $asset.file
    if ((Get-Item -LiteralPath $path).Length -ne $asset.bytes) { throw "Package size failed: $($asset.file)" }
}
function Asset([string]$Role) {
    $found = @($manifest.assets | Where-Object { $_.role -eq $Role })
    if ($found.Count -ne 1) { throw "Asset role is absent/duplicated: $Role" }; return $found[0]
}
$ramBoot = Asset 'installer-boot'; $ramRoot = Asset 'installer-rootfs'
$root = Asset 'userdata'; $boot = Asset 'system-boot'; $recovery = Asset 'system-recovery'
foreach ($image in @($ramBoot, $boot, $recovery)) { if ($image.bytes -ne 67108864) { throw 'Boot/recovery size mismatch.' } }
if ($manifest.root_image_sha256 -notmatch '^[a-f0-9]{64}$' -or
    $manifest.root_image_bytes -lt 3221225472 -or $manifest.root_image_bytes -gt 8589934592 -or
    ($manifest.root_image_bytes % 4194304) -ne 0) { throw 'Invalid userdata image contract.' }
foreach ($asset in $manifest.assets) {
    if ((Get-FileHash -LiteralPath (Join-Path $package $asset.file) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) { throw "Package hash failed: $($asset.file)" }
}
if ($VerifyOnly) { Write-Output 'M1892_PACKAGE_VERIFY_PASS'; exit 0 }
$fastbootSerial = ''
function Fastboot([string[]]$Arguments, [int]$TimeoutSeconds = 180) {
    # Fastboot writes successful getvar output to stderr. Windows PowerShell 5
    # must not treat that as a terminating NativeCommandError.
    $process = [Diagnostics.Process]::new()
    try {
        if ($fastbootSerial) { $Arguments = @('-s', $fastbootSerial) + $Arguments }
        $quoted = @($Arguments | ForEach-Object {
            if ($_ -match '["\r\n]') { throw 'Unsafe Fastboot argument.' }; '"' + $_ + '"'
        })
        $process.StartInfo.FileName = $FastbootPath
        $process.StartInfo.Arguments = $quoted -join ' '
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw 'Fastboot command timeout.' }
        $process.WaitForExit()
        $result = $stdout.Result + $stderr.Result
        if ($process.ExitCode -ne 0) { throw "Fastboot command failed: $result" }
        return [string]$result
    } finally { $process.Dispose() }
}
$enumerated = Fastboot -Arguments @('devices') -TimeoutSeconds 5
$devices = @($enumerated -split "`n" | Where-Object { $_ -match '^\S+\s+fastboot\s*$' })
if ($devices.Count -ne 1) { throw 'Connect exactly one unlocked M1892 in Fastboot mode.' }
$fastbootSerial = ($devices[0].Trim() -split '\s+')[0]
$product = Fastboot -Arguments @('getvar', 'product') -TimeoutSeconds 5
$unlocked = Fastboot -Arguments @('getvar', 'unlocked') -TimeoutSeconds 5
if ($product -notmatch '(?im)product:\s*M1892\s*$' -or $unlocked -notmatch '(?im)unlocked:\s*yes\s*$') { throw 'M1892 identity/unlock check failed.' }
if (-not $YesErase) {
    Write-Host 'WARNING: installation erases ALL userdata (Android/Linux files and saves).'
    if ((Read-Host 'Type ERASE-M1892-USERDATA to continue') -cne 'ERASE-M1892-USERDATA') { throw 'Cancelled without writing.' }
}
[void](Fastboot -Arguments @('flash', 'boot', (Join-Path $package $ramBoot.file)))
[void](Fastboot -Arguments @('reboot'))
$ready = $false
for ($deadline = [DateTime]::UtcNow.AddSeconds(180); [DateTime]::UtcNow -lt $deadline;) {
    try { [void](Assert-M1892Installer); $ready = $true; break } catch { Start-Sleep -Seconds 2 }
}
if (-not $ready) { throw 'RAM USB console unavailable. No userdata was written. See recovery instructions.' }
Send-M1892RamFile (Join-Path $package $ramRoot.file) '/run/m1892-installer-rootfs.ext4.gz' $ramRoot.sha256
$ready = $false
for ($deadline = [DateTime]::UtcNow.AddSeconds(120); [DateTime]::UtcNow -lt $deadline;) {
    try { [void](Assert-M1892Installer -RequireSystemd); $ready = $true; break } catch { Start-Sleep -Seconds 2 }
}
if (-not $ready) { throw 'RAM systemd environment unavailable; userdata was not written.' }
[void](Invoke-M1892Console ('date -u -s "' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + '"'))
[void](Invoke-M1892Console 'mount -o remount,size=3072m /run')
$firmwareArgument = ''
if ($publicDeviceFirmware) {
    # Complete all model firmware and recovery checks BEFORE userdata is erased.
    Write-Host 'Checking stock firmware read-only; userdata has not been changed.'
    Write-Output (Invoke-M1892Console '/usr/libexec/m1892/install-device-firmware prepare /run/m1892-device-firmware' -TimeoutSeconds 180)
    $manifestPath = Join-Path $package 'manifest.json'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Send-M1892RamFile $manifestPath '/run/m1892-package-manifest.json' $manifestHash
    Send-M1892RamFile (Join-Path $package $boot.file) ('/run/' + $boot.file) $boot.sha256
    Send-M1892RamFile (Join-Path $package $recovery.file) ('/run/' + $recovery.file) $recovery.sha256
    Write-Output (Invoke-M1892Console '/usr/libexec/m1892/install-final-boot prepare /run/m1892-package-manifest.json' -TimeoutSeconds 60)
    $firmwareArgument = " '/run/m1892-device-firmware'"
}
Send-M1892RamFile (Join-Path $package $root.file) '/run/m1892-userdata.ext4.gz' $root.sha256
$commissionArguments = "'/run/m1892-userdata.ext4.gz' '$($root.sha256)' '$($manifest.root_image_sha256)' '$($manifest.root_image_bytes)'" + $firmwareArgument
Write-Output (Invoke-M1892Console "/usr/libexec/m1892/commission-stage7-userdata --check $commissionArguments" -TimeoutSeconds 180)
Write-Output (Invoke-M1892Console "/usr/libexec/m1892/commission-stage7-userdata --flash ERASE-M1892-USERDATA $commissionArguments" -TimeoutSeconds 600)
if ($publicDeviceFirmware) {
    Write-Output (Invoke-M1892Console '/usr/libexec/m1892/install-final-boot write /run/m1892-package-manifest.json' -TimeoutSeconds 120)
    Write-Output 'M1892_INSTALL_WRITE_READBACK_PASS: system partitions verified; first-start account setup is still required.'
    try {
        [void](Invoke-M1892Console 'sync; systemctl --no-block reboot' -TimeoutSeconds 15)
        Write-Host 'Reboot request accepted. Complete account setup on the phone.'
    } catch {
        Write-Warning 'Boot and userdata readback passed, but reboot acknowledgement was not confirmed. Inspect the phone before retrying.'
        throw
    }
    exit 0
}
# Use the standard shutdown path. Do not assume a lost USB port means Fastboot.
try { [void](Invoke-M1892Console 'sync; systemctl reboot --reboot-argument=bootloader' -TimeoutSeconds 15) } catch { Write-Host 'Waiting for standard reboot to Fastboot...' }
$ready = $false
for ($deadline = [DateTime]::UtcNow.AddSeconds(180); [DateTime]::UtcNow -lt $deadline;) {
    try {
        $p = Fastboot -Arguments @('getvar', 'product') -TimeoutSeconds 5
        $u = Fastboot -Arguments @('getvar', 'unlocked') -TimeoutSeconds 5
        if ($p -match '(?im)product:\s*M1892\s*$' -and $u -match '(?im)unlocked:\s*yes\s*$') { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $ready) { throw 'Use power + volume-down to return to Fastboot, then follow recovery instructions. Userdata is installed.' }
[void](Fastboot -Arguments @('flash', 'recovery', (Join-Path $package $recovery.file)))
[void](Fastboot -Arguments @('flash', 'boot', (Join-Path $package $boot.file)))
[void](Fastboot -Arguments @('reboot'))
Write-Output 'M1892_INSTALL_PASS: complete first-start account setup on the phone.'
