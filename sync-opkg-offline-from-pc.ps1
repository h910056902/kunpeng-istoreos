#Requires -Version 5.1
param(
    [string] $RouterIP = '192.168.66.1',
    [switch] $Restore,
    [string[]] $PasswordCandidates = @(),
    # When router still points at removed 21.02-SNAPSHOT trees, try stable paths (may not match mtk7987 vendor kernel; then use vendor mirror URLs in distfeeds).
    [string] $SnapshotToRelease = '21.02.7'
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$plink = Join-Path $env:ProgramFiles 'PuTTY\plink.exe'
$pscp = Join-Path $env:ProgramFiles 'PuTTY\pscp.exe'
if (-not (Test-Path -LiteralPath $plink)) {
    $plink = Join-Path ${env:ProgramFiles(x86)} 'PuTTY\plink.exe'
}
if (-not (Test-Path -LiteralPath $pscp)) {
    $pscp = Join-Path ${env:ProgramFiles(x86)} 'PuTTY\pscp.exe'
}
if (-not (Test-Path -LiteralPath $plink) -or -not (Test-Path -LiteralPath $pscp)) {
    throw 'Need PuTTY plink.exe and pscp.exe.'
}

if ($PasswordCandidates.Count -eq 0) {
    if ($env:KP_ROUTER_PASS) {
        $PasswordCandidates = @($env:KP_ROUTER_PASS)
    }
    else {
        $PasswordCandidates = @('password', 'admin')
    }
}

function Get-WorkingPassword {
    foreach ($pw in $PasswordCandidates) {
        $argLine = 'echo y| "' + $plink + '" -batch -ssh root@' + $RouterIP + ' -pw ' + $pw + ' "echo kp-opkg-ok" 2>nul'
        $null = cmd.exe /c $argLine
        if ($LASTEXITCODE -eq 0) { return $pw }
    }
    throw ('SSH failed, tried: ' + ($PasswordCandidates -join ', '))
}

function Invoke-Plink {
    param([string] $RemoteCmd, [string] $Pass)
    $args = @('-batch', '-ssh', ('root@{0}' -f $RouterIP), '-pw', $Pass, $RemoteCmd)
    & $plink @args
    return $LASTEXITCODE
}

function Get-PackagesGzUrlCandidates {
    param([string] $Primary, [string] $ReleaseFallback)
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($Primary) | Out-Null
    if ($Primary -match '21\.02-SNAPSHOT' -and $ReleaseFallback) {
        foreach ($rel in @($ReleaseFallback, '21.02.6', '21.02.5')) {
            $list.Add(($Primary -replace '21\.02-SNAPSHOT', $rel)) | Out-Null
        }
        if ($Primary -match 'downloads\.openwrt\.org') {
            foreach ($rel in @($ReleaseFallback, '21.02.6')) {
                $mir = ($Primary -replace 'downloads\.openwrt\.org', 'mirrors.aliyun.com/openwrt') -replace '21\.02-SNAPSHOT', $rel
                $list.Add($mir) | Out-Null
            }
        }
    }
    return ($list | Select-Object -Unique)
}

function Save-FirstWorkingPackagesGz {
    param([string] $OutFile, [string[]] $Urls)
    foreach ($u in $Urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
            if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item $OutFile).Length -ge 64)) {
                return $u
            }
        }
        catch {
            continue
        }
    }
    return $null
}

$workingPass = Get-WorkingPassword

if ($Restore) {
    Write-Host 'Restore distfeeds from .kp.bak ...' -ForegroundColor Cyan
    $assetRestore = Join-Path $here 'assets\kp-offline-restore.sh'
    if (-not (Test-Path -LiteralPath $assetRestore)) { throw "Missing $assetRestore" }
    $upLine = 'echo y| "' + $pscp + '" -scp -pw ' + $workingPass + ' "' + $assetRestore + '" "root@' + $RouterIP + ':/tmp/kp-offline-restore.sh" 2>nul'
    $null = cmd.exe /c $upLine
    if ($LASTEXITCODE -ne 0) { throw 'pscp restore script failed' }
    Invoke-Plink -RemoteCmd 'sh /tmp/kp-offline-restore.sh' -Pass $workingPass
    exit $LASTEXITCODE
}

Write-Host ("Fetch distfeeds from router root@{0}" -f $RouterIP) -ForegroundColor Cyan
$distfeeds = & $plink @('-batch', '-ssh', ('root@{0}' -f $RouterIP), '-pw', $workingPass, 'cat /etc/opkg/distfeeds.conf 2>/dev/null')
$distfeedsLines = @($distfeeds -split "`n", [System.StringSplitOptions]::RemoveEmptyEntries)
if ($distfeedsLines.Count -eq 0) {
    throw 'Empty distfeeds.conf'
}

$lines = $distfeedsLines | Where-Object { $_ -match 'src/gz' }
if ($lines.Count -eq 0) {
    throw 'No src/gz lines in distfeeds.conf'
}

$feeds = @()
foreach ($line in $lines) {
    if ($line -match 'src/gz\s+(\S+)\s+(\S+)\s*$') {
        $name = $Matches[1]
        $url = $Matches[2]
        if ($url -match '^file://') {
            Write-Host ("Skip file feed: {0}" -f $name) -ForegroundColor DarkGray
            continue
        }
        $base = $url.TrimEnd('/')
        $pkgUrl = $base + '/Packages.gz'
        $feeds += [pscustomobject]@{ Name = $name; PackagesGzUrl = $pkgUrl }
    }
}

if ($feeds.Count -eq 0) {
    throw 'No HTTP(S) feeds to mirror'
}

$stageRoot = Join-Path $env:TEMP ('kp-offline-feed-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
try {
    foreach ($f in $feeds) {
        $dir = Join-Path $stageRoot $f.Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $out = Join-Path $dir 'Packages.gz'
        Write-Host ('Download: ' + $f.Name) -ForegroundColor Green
        $cands = @(Get-PackagesGzUrlCandidates -Primary $f.PackagesGzUrl -ReleaseFallback $SnapshotToRelease)
        $okUrl = Save-FirstWorkingPackagesGz -OutFile $out -Urls $cands
        if (-not $okUrl) {
            Write-Warning ('Skip (no URL worked): ' + $f.Name)
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host ('  OK: ' + $okUrl) -ForegroundColor DarkGray
        }
    }

    $uploadDirs = Get-ChildItem -LiteralPath $stageRoot -Directory
    if ($uploadDirs.Count -eq 0) {
        throw 'No Packages.gz downloaded. PC offline, 404 on all fallbacks, or vendor-only feed (edit router distfeeds to a reachable mirror, then re-run).'
    }

    Write-Host 'Upload to /tmp/kp-offline-feed/ ...' -ForegroundColor Green
    Invoke-Plink -RemoteCmd 'rm -rf /tmp/kp-offline-feed && mkdir -p /tmp/kp-offline-feed' -Pass $workingPass
    foreach ($d in $uploadDirs) {
        $upLine = 'echo y| "' + $pscp + '" -scp -r -pw ' + $workingPass + ' "' + $d.FullName + '" "root@' + $RouterIP + ':/tmp/kp-offline-feed/" 2>nul'
        $null = cmd.exe /c $upLine
        if ($LASTEXITCODE -ne 0) {
            throw ('pscp failed: ' + $d.Name)
        }
    }

    $assetApply = Join-Path $here 'assets\kp-offline-apply.sh'
    if (-not (Test-Path -LiteralPath $assetApply)) { throw "Missing $assetApply" }
    Write-Host 'Apply file:// distfeeds + opkg update ...' -ForegroundColor Cyan
    $upSh = 'echo y| "' + $pscp + '" -scp -pw ' + $workingPass + ' "' + $assetApply + '" "root@' + $RouterIP + ':/tmp/kp-offline-apply.sh" 2>nul'
    $null = cmd.exe /c $upSh
    if ($LASTEXITCODE -ne 0) { throw 'pscp apply script failed' }

    Invoke-Plink -RemoteCmd 'chmod +x /tmp/kp-offline-apply.sh 2>/dev/null; sh /tmp/kp-offline-apply.sh' -Pass $workingPass
    $code = $LASTEXITCODE

    Write-Host ''
    Write-Host 'Backup: /etc/opkg/distfeeds.conf.kp.bak' -ForegroundColor Yellow
    Write-Host 'Restore HTTPS feeds: .\sync-opkg-offline-from-pc.ps1 -Restore' -ForegroundColor Yellow
    Write-Host 'Then run: .\ssh-deploy-kunpeng.ps1 (iStore still needs DNS for istore.linkease.com)' -ForegroundColor DarkYellow

    exit $code
}
finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
