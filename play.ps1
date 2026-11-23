# One-line installer & auto-updater for Goose Bomberman on Windows 10/11 (64-bit).
# Usage: irm https://colemanbroad.github.io/bomberman/play.ps1 | iex
$ErrorActionPreference = 'Stop'

$Repo = 'colemanbroad/bomberman'
$Dir = Join-Path $env:LOCALAPPDATA 'Bomberman'
$BinDir = Join-Path $Dir 'bin'
$Exe = Join-Path $BinDir 'bomberman.exe'
$VerFile = Join-Path $Dir 'version.txt'
$Launcher = Join-Path $Dir 'launch.ps1'

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

function Get-LatestTag {
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.Timeout = 4000
        $resp = $req.GetResponse()
        $loc = $resp.Headers['Location']
        $resp.Close()
        if ($loc) { return ($loc.TrimEnd('/') -split '/')[-1] }
    } catch { }
    return ''
}

$Latest = Get-LatestTag
$Cur = if (Test-Path $VerFile) { (Get-Content $VerFile -Raw).Trim() } else { '' }

if (!(Test-Path $Exe) -or ($Latest -and $Latest -ne $Cur)) {
    Write-Host "Downloading Goose Bomberman $(if ($Latest) { $Latest } else { 'latest' })..."
    $TmpZip = Join-Path $env:TEMP 'bomberman-windows.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest/download/bomberman-windows.zip" -OutFile $TmpZip
    Expand-Archive -Force -Path $TmpZip -DestinationPath $BinDir
    Remove-Item -Force $TmpZip -ErrorAction SilentlyContinue
    Get-ChildItem -Path $BinDir -File | Unblock-File -ErrorAction SilentlyContinue
    if ($Latest) { Set-Content -Path $VerFile -Value $Latest -NoNewline }
}

# Save local auto-updating launcher and create a Desktop shortcut
@'
$ErrorActionPreference = 'SilentlyContinue'
$Repo = 'colemanbroad/bomberman'
$Dir = Join-Path $env:LOCALAPPDATA 'Bomberman'
$BinDir = Join-Path $Dir 'bin'
$Exe = Join-Path $BinDir 'bomberman.exe'
$VerFile = Join-Path $Dir 'version.txt'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$Latest = ''
try {
    $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
    $req.AllowAutoRedirect = $false
    $req.Timeout = 4000
    $resp = $req.GetResponse()
    $loc = $resp.Headers['Location']
    $resp.Close()
    if ($loc) { $Latest = ($loc.TrimEnd('/') -split '/')[-1] }
} catch { }
$Cur = if (Test-Path $VerFile) { (Get-Content $VerFile -Raw).Trim() } else { '' }
if (!(Test-Path $Exe) -or ($Latest -and $Latest -ne $Cur)) {
    $TmpZip = Join-Path $env:TEMP 'bomberman-windows.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest/download/bomberman-windows.zip" -OutFile $TmpZip
    if (Test-Path $TmpZip) {
        Expand-Archive -Force -Path $TmpZip -DestinationPath $BinDir
        Remove-Item -Force $TmpZip
        Get-ChildItem -Path $BinDir -File | Unblock-File
        if ($Latest) { Set-Content -Path $VerFile -Value $Latest -NoNewline }
    }
}
Start-Process -FilePath $Exe -WorkingDirectory $BinDir -ArgumentList $args
'@ | Set-Content -Path $Launcher -Encoding UTF8

try {
    $Desktop = [Environment]::GetFolderPath('Desktop')
    $Lnk = Join-Path $Desktop 'Bomberman.lnk'
    $Wsh = New-Object -ComObject WScript.Shell
    $Sc = $Wsh.CreateShortcut($Lnk)
    $Sc.TargetPath = 'powershell.exe'
    $Sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Launcher`""
    $Sc.WorkingDirectory = $BinDir
    $Sc.IconLocation = "$Exe,0"
    $Sc.Save()
    Write-Host "Created Desktop shortcut: Bomberman (auto-updates on launch)."
} catch { }

Start-Process -FilePath $Exe -WorkingDirectory $BinDir
