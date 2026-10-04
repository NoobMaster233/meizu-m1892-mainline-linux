# SPDX-License-Identifier: MIT
param([string]$Installer = (Join-Path $PSScriptRoot '..\installer\Install.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors }
$function = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Fastboot'}, $true)
if ($function.Count -ne 1) { throw 'Fastboot function not unique.' }
Invoke-Expression $function[0].Extent.Text
$fastbootSerial = ''
$FastbootPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ok = Fastboot -Arguments @('-NoProfile', '-Command', 'Write-Output HELPER_SUCCESS') -TimeoutSeconds 5
if ($ok.Trim() -ne 'HELPER_SUCCESS') { throw 'Successful child/stdout rejected.' }
$errorOutput = Fastboot -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine(123); exit 0') -TimeoutSeconds 5
if ($errorOutput.Trim() -ne '123') { throw 'Successful stderr rejected.' }
$rejected = $false
try { [void](Fastboot -Arguments @('-NoProfile', '-Command', 'exit 7') -TimeoutSeconds 5) }
catch { if ($_.Exception.Message -notmatch 'Fastboot command failed:') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Nonzero child exit accepted.' }
$rejected = $false
try { [void](Fastboot -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -TimeoutSeconds 1) }
catch { if ($_.Exception.Message -notmatch 'Fastboot command timeout') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Unbounded child accepted.' }
Write-Output 'M1892_INSTALLER_FASTBOOT_TEST_PASS cases=4'
