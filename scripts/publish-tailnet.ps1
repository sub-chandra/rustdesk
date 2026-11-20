
[CmdletBinding()]
param(
    [string] $Bundle
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (!$Bundle) {
    $Bundle = Join-Path $project 'flutter\build\windows\x64\runner\Release'
}
$source = (Get-Item -LiteralPath $Bundle).FullName.TrimEnd('\', '/')
$runner = if (Test-Path -LiteralPath (Join-Path $source 'RustDeskTailnet.exe')) {
    'RustDeskTailnet.exe'
} else {
    'rustdesk.exe'
}
foreach ($path in @($runner, 'librustdesk.dll', 'data\app.so')) {
    if (!(Test-Path -LiteralPath (Join-Path $source $path) -PathType Leaf)) {
        throw "Missing Windows release component $path"
    }
}
$releaseDir = Join-Path $project 'releases'
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
$destination = Join-Path $releaseDir 'RustDeskTailnet-windows-x64.zip'
$id = [Guid]::NewGuid().ToString('N')
$temporary = Join-Path $releaseDir ".$id.tmp"
$backup = Join-Path $releaseDir ".$id.bak"

Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $entry = $file.FullName.Substring($source.Length + 1).Replace('\', '/')
            if ($entry.EndsWith('.toml', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Configuration found in release bundle: $entry"
            }
            if ($entry -ieq $runner) {
                $entry = 'RustDeskTailnet.exe'
            }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }

    if (Test-Path -LiteralPath $destination) {
        [IO.File]::Replace($temporary, $destination, $backup)
    } else {
        [IO.File]::Move($temporary, $destination)
    }
    Get-Item -LiteralPath $destination
} finally {
    foreach ($path in @($temporary, $backup)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path
        }
    }
}
