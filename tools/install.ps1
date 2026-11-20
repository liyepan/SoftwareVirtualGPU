param(
    [string]$Package = "C:\svgpu\in"
)
$ErrorActionPreference = "Stop"
$inf = Get-ChildItem -Path $Package -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $inf) { throw "no .inf under $Package" }
Write-Host "[install] $($inf.FullName)"
pnputil /add-driver $inf.FullName /install
if ($LASTEXITCODE -ne 0) { throw "pnputil failed: $LASTEXITCODE" }
pnputil /scan-devices
Start-Sleep -Seconds 2
Get-PnpDevice -Class Display | Format-Table -AutoSize
