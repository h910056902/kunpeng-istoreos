#Requires -Version 5.1
<#
.SYNOPSIS
  Upload kunpeng-istore.sh via PuTTY pscp and run on router (same LAN).

.EXAMPLE
  .\ssh-deploy-kunpeng.ps1
  .\ssh-deploy-kunpeng.ps1 -Action deps
  $env:KP_ROUTER_PASS = 'yoursecret'; .\ssh-deploy-kunpeng.ps1
#>
param(
    [string] $RouterIP = '192.168.66.1',
    [ValidateSet('one', 'deps')]
    [string] $Action = 'one',
    [string[]] $PasswordCandidates = @()
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$localSh = Join-Path $here 'kunpeng-istore.sh'
if (-not (Test-Path -LiteralPath $localSh)) {
    throw "Missing kunpeng-istore.sh: $localSh"
}

$plink = Join-Path $env:ProgramFiles 'PuTTY\plink.exe'
$pscp = Join-Path $env:ProgramFiles 'PuTTY\pscp.exe'
if (-not (Test-Path -LiteralPath $plink)) {
    $plink = Join-Path ${env:ProgramFiles(x86)} 'PuTTY\plink.exe'
}
if (-not (Test-Path -LiteralPath $pscp)) {
    $pscp = Join-Path ${env:ProgramFiles(x86)} 'PuTTY\pscp.exe'
}
if (-not (Test-Path -LiteralPath $plink) -or -not (Test-Path -LiteralPath $pscp)) {
    throw 'PuTTY plink.exe / pscp.exe not found. Install PuTTY.'
}

if ($PasswordCandidates.Count -eq 0) {
    if ($env:KP_ROUTER_PASS) {
        $PasswordCandidates = @($env:KP_ROUTER_PASS)
    } else {
        $PasswordCandidates = @('password', 'admin')
    }
}

function Test-SshPassword {
    param([string] $Pass)
    $argLine = 'echo y| "' + $plink + '" -ssh root@' + $RouterIP + ' -pw ' + $Pass + ' "echo kp-ssh-ok" 2>nul'
    $null = cmd.exe /c $argLine
    return ($LASTEXITCODE -eq 0)
}

Write-Host ("Target: root@{0}, run: sh /tmp/kunpeng-istore.sh {1}" -f $RouterIP, $Action) -ForegroundColor Cyan

$workingPass = $null
foreach ($pw in $PasswordCandidates) {
    Write-Host 'Trying SSH password...' -ForegroundColor DarkGray
    if (Test-SshPassword -Pass $pw) {
        $workingPass = $pw
        break
    }
}
if (-not $workingPass) {
    throw ('SSH failed after trying: ' + ($PasswordCandidates -join ', ') + '. Check IP, Dropbear, or set KP_ROUTER_PASS.')
}

Write-Host 'Uploading kunpeng-istore.sh ...' -ForegroundColor Green
$remotePath = '/tmp/kunpeng-istore.sh'
# 避免中文路径 + CRLF：复制到 TEMP 并转为 Unix LF（否则 OpenWrt 上 sh 可能直接失败或装包无效）
$staging = Join-Path $env:TEMP 'kunpeng-istore-deploy.sh'
$raw = [System.IO.File]::ReadAllText($localSh)
$raw = $raw -replace "`r`n", "`n" -replace "`r", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($staging, $raw, $utf8NoBom)

$uploadLine = 'echo y| "' + $pscp + '" -scp -pw ' + $workingPass + ' "' + $staging + '" "root@' + $RouterIP + ':' + $remotePath + '" 2>nul'
$null = cmd.exe /c $uploadLine
Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) {
    throw ('pscp failed exit ' + $LASTEXITCODE + '. Check path, disk space on router /tmp, or run PuTTY/pscp once to accept host key.')
}

Write-Host 'Running on router (stream log; may take several minutes)...' -ForegroundColor Green
# 远程写日志并打印，便于确认 opkg/主题是否真在执行
# 保留 sh 的退出码（若仅以 tail 结尾，plink 会误报 0）
$remoteCmd = 'chmod +x ' + $remotePath + ' && sh ' + $remotePath + ' ' + $Action +
    ' > /tmp/kunpeng-last.log 2>&1; _ec=$?; echo ====LOG====; tail -n 120 /tmp/kunpeng-last.log; exit $_ec'
$plinkArgs = @('-batch', '-ssh', ('root@{0}' -f $RouterIP), '-pw', $workingPass, $remoteCmd)
& $plink @plinkArgs
$code = $LASTEXITCODE
$color = if ($code -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ('Remote exit code: ' + $code) -ForegroundColor $color
if ($code -ne 0) {
    Write-Host 'Fetch full log: plink -ssh root@ROUTER -pw PASS "cat /tmp/kunpeng-last.log"' -ForegroundColor DarkYellow
}
exit $code
