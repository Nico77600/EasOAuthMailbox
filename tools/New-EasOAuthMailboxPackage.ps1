<#
.SYNOPSIS
    Copies the files needed to run EAS OAuth Mailbox into a separate folder, ready to be zipped.

.DESCRIPTION
    The package contains only what Invoke-EasOAuthMailbox.ps1 needs at run time, plus the HTML guides:
        package\Invoke-EasOAuthMailbox.ps1, package\EasOAuthMailbox.psd1, package\EasOAuthMailbox.psm1,
        package\src\, package\config\, package\templates\, package\docs\EasOAuthMailbox-UserGuide.html,
        package\docs\EasOAuthMailbox-Guide.html,
        package\README.md, CHANGELOG.md, package\LICENSE, package\THIRD-PARTY-NOTICES.md
    The HTML guides are rebuilt first from their Markdown sources (tools\Build-Documentation.ps1):
    they are self-contained (images inline), so the Markdown sources and the images are not copied.
    It never copies reports\, logs\, artifacts\, tests\ (with the simulator) or tools\.

    The configuration is copied as delivered (contoso.test example values). The script checks the
    content of the package and that the module loads from it.

.PARAMETER Destination
    Package folder. Default: package\EasOAuthMailbox-<version>, next to the tool folder.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder that contains reports\
    or logs\ (a package that has been run) is never replaced.

.EXAMPLE
    .\tools\New-EasOAuthMailboxPackage.ps1
    Creates ..\package\EasOAuthMailbox-1.2.1.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$packageRoot = Join-Path $root 'package'
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $packageRoot 'EasOAuthMailbox.psd1')).ModuleVersion
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\EasOAuthMailbox-$version" }
$Destination = [IO.Path]::GetFullPath($Destination, (Get-Location).Path).TrimEnd('\')
$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $rootPrefix.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The destination must be outside the tool folder: $Destination"
}
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "The destination already exists: $Destination. Use -Force to replace it." }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-EasOAuthMailbox.ps1'))) { throw "The destination is not an EAS OAuth Mailbox package, it is not replaced: $Destination" }
    foreach ($used in 'reports', 'logs') {
        if (Test-Path -LiteralPath (Join-Path $Destination $used)) { throw "The destination contains a $used folder (a package that has been run), it is not replaced: $Destination" }
    }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# ---- HTML guide, rebuilt from the Markdown source -------------------------------------------------
& (Join-Path $PSScriptRoot 'Build-Documentation.ps1') | Out-Null

# ---- Files needed at run time -------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-EasOAuthMailbox.ps1', 'EasOAuthMailbox.psd1', 'EasOAuthMailbox.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md',
    'config\EasOAuthMailbox.config.psd1', 'templates\Report.template.html', 'docs\EasOAuthMailbox-UserGuide.html', 'docs\EasOAuthMailbox-Guide.html') { $files.Add($f) }
Get-ChildItem -LiteralPath (Join-Path $packageRoot 'src') -Filter '*.ps1' -File | ForEach-Object { $files.Add("src\$($_.Name)") }
foreach ($f in $files) {
    $source = Join-Path $packageRoot $f
    if ($f -eq 'CHANGELOG.md') { $source = Join-Path $root $f }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing file in the tool folder: $f" }
    $target = Join-Path $Destination $f
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target
}

# ---- Checks ---------------------------------------------------------------------------------------
$problems = [Collections.Generic.List[string]]::new()
foreach ($name in 'reports', 'logs', 'tests', 'artifacts', 'tools', 'docs\images') {
    if (Test-Path -LiteralPath (Join-Path $Destination $name)) { $problems.Add("Folder $name\ must not be in the package.") }
}
Get-ChildItem -LiteralPath $Destination -Recurse -File -Include '*.log', '*.csv', '*.json', '*.png', '*.Tests.ps1', '*Simulator*' |
    ForEach-Object { $problems.Add("Not a run-time file: $($_.Name)") }
foreach ($part in 'Console', 'Config', 'Http', 'Core', 'Checks', 'Browser', 'Report', 'Gui') {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination "src\EasOAuthMailbox.$part.ps1"))) { $problems.Add("Missing in the package: src\EasOAuthMailbox.$part.ps1") }
}
$config = [IO.File]::ReadAllText((Join-Path $Destination 'config\EasOAuthMailbox.config.psd1'))
if ($config -notmatch 'contoso\.test') { $problems.Add('The configuration of the package must keep the contoso.test example values.') }
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }

# Same scenarios as the source code, and reports written under the package folder.
$expected = [string](& pwsh -NoProfile -Command "Import-Module '$packageRoot\EasOAuthMailbox.psd1'; (Get-EomTestCatalog).Count")
$loaded = & pwsh -NoProfile -Command "Import-Module '$Destination\EasOAuthMailbox.psd1'; (Get-EomTestCatalog).Count; (Import-EomConfiguration).OutputPath"
if ($LASTEXITCODE -ne 0 -or $loaded[0] -ne $expected -or -not ([string]$loaded[1]).StartsWith($Destination)) { throw "The module does not load correctly from the package (expected $expected scenarios): $loaded" }

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
Write-Host ''
Write-Host "  EAS OAuth Mailbox $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
Write-Host "  Check    : module loads, $expected scenarios, reports written under the package folder"
Write-Host "  Config   : contoso.test example values - fill in Target before the first run (guide, chapter 11)"
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,10:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
