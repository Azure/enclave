#Requires -Version 7.2

[CmdletBinding()]
param(
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $PSScriptRoot 'arm-template-generation.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100

function Get-RepositoryRelativePath {
    param([Parameter(Mandatory)][string] $Path)

    return [System.IO.Path]::GetRelativePath($repoRoot, $Path).Replace('\', '/')
}

function Assert-UniquePaths {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string[]] $Paths
    )

    $duplicates = @($Paths | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count -gt 0) {
        throw "$Name contains duplicate paths: $($duplicates -join ', ')"
    }
}

function Assert-SamePathSet {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string[]] $Actual
    )

    $difference = @(Compare-Object -ReferenceObject ($Expected | Sort-Object) -DifferenceObject ($Actual | Sort-Object))
    if ($difference.Count -gt 0) {
        $details = $difference | ForEach-Object {
            $side = if ($_.SideIndicator -eq '<=') { 'missing from mappings' } else { 'missing from disk' }
            "  $($_.InputObject) ($side)"
        }
        throw "$Name is incomplete:`n$($details -join "`n")"
    }
}

function Get-PlatformKey {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64')) {
        throw "Unsupported processor architecture '$architecture'. Supported architectures: x64, arm64."
    }

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return "win-$architecture"
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Linux)) {
        return "linux-$architecture"
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return "osx-$architecture"
    }

    throw "Unsupported operating system '$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)'."
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSha256
    )

    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "SHA-256 verification failed for '$Path'. Expected $ExpectedSha256, got $actualSha256."
    }
}

function Get-BicepCompiler {
    $version = [string]$config.compiler.version
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Compiler version '$version' must be an exact semantic version."
    }

    $platformKey = Get-PlatformKey
    $platformProperty = $config.compiler.platforms.PSObject.Properties[$platformKey]
    if ($null -eq $platformProperty) {
        throw "No compiler checksum is pinned for platform '$platformKey'."
    }

    $asset = [string]$platformProperty.Value.asset
    $expectedSha256 = [string]$platformProperty.Value.sha256
    if ($expectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "The pinned SHA-256 for '$platformKey' is invalid."
    }

    $cacheDirectory = Join-Path $PSScriptRoot ".cache/bicep/$version/$platformKey"
    $compilerPath = Join-Path $cacheDirectory $asset
    if (Test-Path -LiteralPath $compilerPath) {
        try {
            Assert-FileHash -Path $compilerPath -ExpectedSha256 $expectedSha256
        }
        catch {
            Write-Warning "Removing cached Bicep compiler because checksum verification failed."
            Remove-Item -LiteralPath $compilerPath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $compilerPath)) {
        New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        $downloadPath = "$compilerPath.download"
        $downloadUrl = "https://github.com/Azure/bicep/releases/download/v$version/$asset"
        Write-Host "Downloading Bicep $version for $platformKey..."
        try {
            Invoke-WebRequest `
                -Uri $downloadUrl `
                -OutFile $downloadPath `
                -Headers @{ 'User-Agent' = 'Azure-enclave-arm-template-builder' } `
                -MaximumRetryCount 3 `
                -RetryIntervalSec 2
            Assert-FileHash -Path $downloadPath -ExpectedSha256 $expectedSha256
            Move-Item -LiteralPath $downloadPath -Destination $compilerPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    Assert-FileHash -Path $compilerPath -ExpectedSha256 $expectedSha256
    if (-not $IsWindows) {
        & chmod +x $compilerPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to mark '$compilerPath' executable."
        }
    }

    $versionOutput = (& $compilerPath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch [regex]::Escape($version)) {
        throw "Downloaded compiler did not report pinned version $version. Output: $versionOutput"
    }

    Write-Host "Using $versionOutput ($platformKey; SHA-256 verified)."
    return $compilerPath
}

function Normalize-GeneratedJson {
    param([Parameter(Mandatory)][string] $Path)

    $content = [System.IO.File]::ReadAllText($Path)
    $content = $content.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        [System.Text.UTF8Encoding]::new($false))
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory)][string] $CompilerPath,
        [Parameter(Mandatory)][string] $SourcePath,
        [string] $ArtifactPath
    )

    $relativeSource = Get-RepositoryRelativePath -Path $SourcePath
    Write-Host "Building $relativeSource"
    if ($ArtifactPath) {
        & $CompilerPath build $SourcePath --outfile $ArtifactPath
    }
    else {
        & $CompilerPath build $SourcePath --stdout 1>$null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Bicep build failed for '$relativeSource'."
    }
}

function Get-DeclaredScope {
    param([Parameter(Mandatory)][string] $SourcePath)

    $source = Get-Content -LiteralPath $SourcePath -Raw
    $scopeMatch = [regex]::Match(
        $source,
        "^\s*targetScope\s*=\s*'(?<scope>[^']+)'",
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($scopeMatch.Success) {
        return $scopeMatch.Groups['scope'].Value
    }

    return 'resourceGroup'
}

function Assert-GeneratedArtifacts {
    $schemas = @{
        resourceGroup = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        subscription  = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
    }
    $pinnedVersion = [string]$config.compiler.version

    foreach ($mapping in $config.templates) {
        $sourcePath = Join-Path $repoRoot ([string]$mapping.source)
        $artifactPath = Join-Path $repoRoot ([string]$mapping.artifact)
        $configuredScope = [string]$mapping.scope
        $declaredScope = Get-DeclaredScope -SourcePath $sourcePath
        if ($declaredScope -ne $configuredScope) {
            throw "'$($mapping.source)' declares scope '$declaredScope', but the mapping says '$configuredScope'."
        }
        if (-not $schemas.ContainsKey($configuredScope)) {
            throw "Unsupported deployment scope '$configuredScope' in '$configPath'."
        }

        try {
            $artifact = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json -Depth 100
        }
        catch {
            throw "Generated artifact '$($mapping.artifact)' is not valid JSON: $($_.Exception.Message)"
        }

        if ([string]$artifact.'$schema' -ne $schemas[$configuredScope]) {
            throw "'$($mapping.artifact)' has the wrong ARM schema for $configuredScope scope."
        }
        if ([string]$artifact.metadata._generator.name -ne 'bicep') {
            throw "'$($mapping.artifact)' is missing authoritative Bicep _generator metadata."
        }

        $generatorVersion = [string]$artifact.metadata._generator.version
        if ($generatorVersion -notmatch "^$([regex]::Escape($pinnedVersion))(?:\.|$)") {
            throw "'$($mapping.artifact)' was generated by Bicep $generatorVersion, not pinned version $pinnedVersion."
        }
        if ([string]::IsNullOrWhiteSpace([string]$artifact.metadata._generator.templateHash)) {
            throw "'$($mapping.artifact)' is missing the Bicep template hash."
        }
    }
}

function Assert-ReadmeDeploymentPaths {
    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    $patterns = @(
        '(?i)https%3A%2F%2Fraw\.githubusercontent\.com%2Fazure%2Fenclave%2Fmain%2F(?<path>[^)\s]+?\.json)',
        '(?i)https://raw\.githubusercontent\.com/azure/enclave/main/(?<path>[^)\s]+?\.json)'
    )
    $paths = @(
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($readme, $pattern)) {
                [System.Uri]::UnescapeDataString($match.Groups['path'].Value).Replace('\', '/')
            }
        }
    ) | Sort-Object -Unique

    if ($paths.Count -eq 0) {
        throw 'README.md contains no Azure/enclave deployment-button template paths.'
    }

    $mappedArtifacts = @($config.templates | ForEach-Object { [string]$_.artifact })
    foreach ($path in $paths) {
        if ($path -notin $mappedArtifacts) {
            throw "README.md deployment path '$path' is not a generated artifact mapping."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $path) -PathType Leaf)) {
            throw "README.md deployment path '$path' does not exist locally."
        }
    }

    Write-Host "Validated $($paths.Count) README deployment-button path(s) locally."
}

$templateMappings = @($config.templates)
if ($templateMappings.Count -eq 0) {
    throw "'$configPath' contains no template mappings."
}

$mappedSources = @($templateMappings | ForEach-Object { ([string]$_.source).Replace('\', '/') })
$mappedArtifacts = @($templateMappings | ForEach-Object { ([string]$_.artifact).Replace('\', '/') })
Assert-UniquePaths -Name 'Template sources' -Paths $mappedSources
Assert-UniquePaths -Name 'Template artifacts' -Paths $mappedArtifacts

foreach ($path in @($mappedSources + $mappedArtifacts)) {
    if ([System.IO.Path]::IsPathRooted($path) -or $path.Split('/') -contains '..') {
        throw "Mapping path '$path' must remain inside the repository."
    }
}
foreach ($source in $mappedSources) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $source) -PathType Leaf)) {
        throw "Mapped Bicep source '$source' does not exist."
    }
}

$quickstartRoot = Join-Path $repoRoot 'quickstart-templates'
$rootBicepFiles = @(
    Get-ChildItem -LiteralPath $quickstartRoot -File -Filter '*.bicep' |
        ForEach-Object { Get-RepositoryRelativePath -Path $_.FullName }
)
$rootJsonFiles = @(
    Get-ChildItem -LiteralPath $quickstartRoot -File -Filter '*.json' |
        ForEach-Object { Get-RepositoryRelativePath -Path $_.FullName }
)
Assert-SamePathSet -Name 'Top-level Bicep source mappings' -Expected $rootBicepFiles -Actual $mappedSources
Assert-SamePathSet -Name 'Generated ARM artifact mappings' -Expected $rootJsonFiles -Actual $mappedArtifacts

$allBicepFiles = @(Get-ChildItem -LiteralPath $quickstartRoot -Recurse -File -Filter '*.bicep' | Sort-Object FullName)
if ($allBicepFiles.Count -ne [int]$config.expectedBicepFileCount) {
    throw "Expected $($config.expectedBicepFileCount) Bicep files, but found $($allBicepFiles.Count). Update the config intentionally when adding or removing templates."
}

$compilerPath = Get-BicepCompiler
$mappingBySource = @{}
foreach ($mapping in $templateMappings) {
    $mappingBySource[[string]$mapping.source] = $mapping
}

foreach ($bicepFile in $allBicepFiles) {
    $relativeSource = Get-RepositoryRelativePath -Path $bicepFile.FullName
    if ($mappingBySource.ContainsKey($relativeSource)) {
        $artifactPath = Join-Path $repoRoot ([string]$mappingBySource[$relativeSource].artifact)
        Invoke-BicepBuild -CompilerPath $compilerPath -SourcePath $bicepFile.FullName -ArtifactPath $artifactPath
        Normalize-GeneratedJson -Path $artifactPath
    }
    else {
        Invoke-BicepBuild -CompilerPath $compilerPath -SourcePath $bicepFile.FullName
    }
}

Assert-GeneratedArtifacts
Assert-ReadmeDeploymentPaths
Write-Host "Validated all $($allBicepFiles.Count) Bicep files and $($templateMappings.Count) generated ARM artifacts."

if ($Check) {
    $status = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all -- @mappedArtifacts)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect generated artifacts with git.'
    }
    if ($status.Count -gt 0) {
        Write-Host ''
        Write-Host 'Generated ARM JSON is stale. Run: pwsh ./eng/Build-ArmTemplates.ps1'
        Write-Host 'Commit the regenerated artifacts together with their Bicep sources.'
        Write-Host ''
        & git -C $repoRoot --no-pager diff -- @mappedArtifacts
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Host '::error title=Generated ARM templates are stale::Run eng/Build-ArmTemplates.ps1 and commit the resulting JSON changes.'
        }
        throw "Generated ARM drift detected: $($status -join ', ')"
    }

    Write-Host 'Generated ARM artifacts match the committed files.'
}
