[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int] $TestPort
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $env:APPDATA 'RustDesk\config'
$destination = Join-Path $env:APPDATA 'RustDeskTailnet\config'
if (!(Test-Path -LiteralPath (Join-Path $source 'RustDesk2.toml'))) {
    throw 'RustDesk settings were not found for the current Windows account.'
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($suffix in @('', '2', '_local', '_default')) {
    $original = Join-Path $source "RustDesk$suffix.toml"
    $target = Join-Path $destination "RustDeskTailnet$suffix.toml"
    if ((Test-Path -LiteralPath $original) -and !(Test-Path -LiteralPath $target)) {
        if ($suffix -eq '2' -and $PSBoundParameters.ContainsKey('TestPort')) {
            $config = [IO.File]::ReadAllText($original)
            $config = [regex]::Replace($config, '(?m)^direct-access-port\s*=.*\r?\n?', '')
            $options = [regex]::new('(?m)^\[options\]\s*\r?\n')
            if ($options.IsMatch($config)) {
                $config = $options.Replace($config, "[options]`r`ndirect-access-port = '$TestPort'`r`n", 1)
            } else {
                $config += "`r`n[options]`r`ndirect-access-port = '$TestPort'`r`n"
            }
            [IO.File]::WriteAllText($target, $config, [Text.UTF8Encoding]::new($false))
        } else {
            Copy-Item -LiteralPath $original -Destination $target
        }
    }
}

$originalPeers = Join-Path $source 'peers'
if (Test-Path -LiteralPath $originalPeers) {
    $targetPeers = Join-Path $destination 'peers'
    New-Item -ItemType Directory -Path $targetPeers -Force | Out-Null
    foreach ($peer in Get-ChildItem -LiteralPath $originalPeers -File -Filter '*.toml') {
        $target = Join-Path $targetPeers $peer.Name
        if (!(Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $peer.FullName -Destination $target
        }
    }
}
Write-Output "RustDesk Tailnet settings imported to $destination"
