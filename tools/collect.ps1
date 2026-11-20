param(
    [string]$Out = "C:\svgpu\logs"
)
$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = Join-Path $Out $ts
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Get-PnpDevice -Class Display | Out-File "$dir\pnp-display.txt" -Encoding utf8
Get-CimInstance Win32_VideoController | Out-File "$dir\video-controller.txt" -Encoding utf8
Get-WinEvent -LogName System -MaxEvents 200 | Out-File "$dir\system-events.txt" -Encoding utf8
bcdedit /enum | Out-File "$dir\bcdedit.txt" -Encoding utf8

$dx = Join-Path $dir "dxdiag.txt"
Start-Process -FilePath "dxdiag.exe" -ArgumentList "/t", $dx -Wait
for ($i = 0; $i -lt 30 -and -not (Test-Path $dx); $i++) { Start-Sleep -Milliseconds 500 }

Copy-Item "C:\Windows\MEMORY.DMP" $dir -ErrorAction SilentlyContinue
Copy-Item "C:\Windows\Minidump\*.dmp" $dir -ErrorAction SilentlyContinue

$zip = "$dir.zip"
Compress-Archive -Path "$dir\*" -DestinationPath $zip -Force
Write-Host "[collect] $zip"
