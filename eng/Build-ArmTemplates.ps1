#Requires -Version 7.2

[CmdletBinding()]
param(
    [switch] $Check,
    [switch] $TestReadmeDeploymentLinks
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

function Assert-WellFormedPercentEncoding {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Description
    )

    if ($Value -match '%(?![0-9A-Fa-f]{2})') {
        throw "$Description contains malformed percent-encoding."
    }
}

function Get-ReadmeDeploymentLinks {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    $labelPattern = '(?i)Deploy\s+To\s+Azure'
    $linkPattern = @'
(?isx)
\[
    (?:
        !\[\s*Deploy\s+To\s+Azure\s*\]\([^)]+\)
        |
        \s*Deploy\s+To\s+Azure\s*
    )
\]
\(
    \s*(?<href>[^)\s]+)\s*
\)
'@

    $labelCount = [regex]::Matches($Readme, $labelPattern).Count
    $linkMatches = [regex]::Matches($Readme, $linkPattern)
    if ($labelCount -eq 0) {
        throw "$ReadmeName contains no Deploy To Azure buttons or links."
    }
    if ($linkMatches.Count -ne $labelCount) {
        throw "$ReadmeName contains $labelCount Deploy To Azure label(s), but only $($linkMatches.Count) use a supported Markdown button/link form."
    }

    return @($linkMatches | ForEach-Object { $_.Groups['href'].Value })
}

function Get-DeploymentTemplateArtifactPath {
    param(
        [Parameter(Mandatory)][string] $DeploymentLink,
        [Parameter(Mandatory)][string] $ReadmeName,
        [Parameter(Mandatory)][int] $LinkNumber,
        [Parameter(Mandatory)][string[]] $MappedArtifacts
    )

    $description = "$ReadmeName deployment link #$LinkNumber"
    Assert-WellFormedPercentEncoding -Value $DeploymentLink -Description $description

    $templateParameters = @(
        [regex]::Matches(
            $DeploymentLink,
            '(?i)[?&](?<name>template(?:uri)?)=') |
            ForEach-Object { $_.Groups['name'].Value.ToLowerInvariant() }
    )
    if ($templateParameters.Count -gt 1) {
        throw "$description contains duplicate or ambiguous template parameters."
    }
    if ($templateParameters.Count -eq 1) {
        throw "$description uses an unsupported template query parameter in addition to, or instead of, the Template URI route."
    }

    $portalUri = $null
    if (-not [System.Uri]::TryCreate(
            $DeploymentLink,
            [System.UriKind]::Absolute,
            [ref]$portalUri)) {
        throw "$description is not a well-formed absolute deployment URL."
    }
    if ($portalUri.Scheme -ne 'https' -or
        $portalUri.Host -ne 'portal.azure.com' -or
        -not [string]::IsNullOrEmpty($portalUri.UserInfo) -or
        -not $portalUri.IsDefaultPort) {
        throw "$description must use https://portal.azure.com with no user information or custom port."
    }
    if ($portalUri.AbsolutePath -ne '/' -or
        -not [string]::IsNullOrEmpty($portalUri.Query)) {
        throw "$description must not use an outer path or query string."
    }

    $routePrefix = '#create/Microsoft.Template/uri/'
    if (-not $portalUri.Fragment.StartsWith(
            $routePrefix,
            [System.StringComparison]::Ordinal)) {
        throw "$description must use the exact '$routePrefix<Template URI>' route."
    }

    $encodedTemplateUri = $portalUri.Fragment.Substring($routePrefix.Length)
    if ([string]::IsNullOrWhiteSpace($encodedTemplateUri)) {
        throw "$description has an empty Template URI."
    }
    if ($encodedTemplateUri.Contains('?') -or $encodedTemplateUri.Contains('#')) {
        throw "$description contains query or fragment data after the Template URI."
    }

    Assert-WellFormedPercentEncoding `
        -Value $encodedTemplateUri `
        -Description "$description Template URI"

    if ($encodedTemplateUri.StartsWith(
            'https://',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($encodedTemplateUri.Contains('%')) {
            throw "$description Template URI mixes raw and percent-encoded forms."
        }
        $templateUriText = $encodedTemplateUri
    }
    elseif ($encodedTemplateUri -match '(?i)^https%3A%2F%2F') {
        if ($encodedTemplateUri -match '[:/\\?#]') {
            throw "$description Template URI is only partially percent-encoded."
        }
        try {
            $templateUriText = [System.Uri]::UnescapeDataString($encodedTemplateUri)
        }
        catch {
            throw "$description Template URI could not be URL-decoded: $($_.Exception.Message)"
        }
        if ($templateUriText.Contains('%')) {
            throw "$description Template URI contains nested or ambiguous percent-encoding."
        }
    }
    else {
        throw "$description Template URI must be either a raw or fully percent-encoded HTTPS URI."
    }

    if ($templateUriText -match '[\x00-\x20\x7f\\]') {
        throw "$description Template URI contains whitespace, control characters, or backslashes."
    }
    if ($templateUriText.Contains('?') -or $templateUriText.Contains('#')) {
        throw "$description Template URI must not contain a query string or fragment."
    }

    $rawPathMatch = [regex]::Match(
        $templateUriText,
        '(?i)^https://[^/]+/(?<path>[^?#]+)$')
    if (-not $rawPathMatch.Success) {
        throw "$description Template URI is malformed."
    }

    $segments = @($rawPathMatch.Groups['path'].Value.Split('/'))
    if ($segments.Count -lt 4 -or
        @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "$description Template URI contains an empty or traversal path segment."
    }

    $templateUri = $null
    if (-not [System.Uri]::TryCreate(
            $templateUriText,
            [System.UriKind]::Absolute,
            [ref]$templateUri)) {
        throw "$description Template URI is not a well-formed absolute URI."
    }
    if ($templateUri.Scheme -ne 'https' -or
        $templateUri.Host -ne 'raw.githubusercontent.com' -or
        -not [string]::IsNullOrEmpty($templateUri.UserInfo) -or
        -not $templateUri.IsDefaultPort) {
        throw "$description Template URI must use https://raw.githubusercontent.com with no user information or custom port."
    }
    if (-not [string]::IsNullOrEmpty($templateUri.Query) -or
        -not [string]::IsNullOrEmpty($templateUri.Fragment)) {
        throw "$description Template URI must not contain a query string or fragment."
    }

    $owner = $segments[0]
    $repository = $segments[1]
    $ref = $segments[2]
    $artifactPath = $segments[3..($segments.Count - 1)] -join '/'
    if ($owner -ine 'Azure') {
        throw "$description Template URI owner '$owner' is not 'Azure'."
    }
    if ($repository -ine 'enclave') {
        throw "$description Template URI repository '$repository' is not 'enclave'."
    }
    if ($ref -cne 'main') {
        throw "$description Template URI ref '$ref' is not 'main'."
    }
    if ($artifactPath -cnotin $MappedArtifacts) {
        throw "$description Template URI artifact path '$artifactPath' is not an explicit generated artifact mapping."
    }

    return $artifactPath
}

function Assert-ReadmeDeploymentPaths {
    param(
        [string] $Readme,
        [string] $ReadmeName = 'README.md'
    )

    if ([string]::IsNullOrEmpty($Readme)) {
        $Readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    }

    $mappedArtifacts = @($config.templates | ForEach-Object { [string]$_.artifact })
    $deploymentLinks = @(Get-ReadmeDeploymentLinks -Readme $Readme -ReadmeName $ReadmeName)
    for ($index = 0; $index -lt $deploymentLinks.Count; $index++) {
        $artifactPath = Get-DeploymentTemplateArtifactPath `
            -DeploymentLink $deploymentLinks[$index] `
            -ReadmeName $ReadmeName `
            -LinkNumber ($index + 1) `
            -MappedArtifacts $mappedArtifacts
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $artifactPath) -PathType Leaf)) {
            throw "$ReadmeName deployment link #$($index + 1) artifact '$artifactPath' does not exist locally."
        }
    }

    Write-Host "Validated all $($deploymentLinks.Count) $ReadmeName deployment button/link Template URI(s) locally."
}

function Invoke-ReadmeDeploymentLinkTests {
    $badge = 'https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg'
    function New-DeploymentButton {
        param([Parameter(Mandatory)][string] $DeploymentLink)

        return "[![Deploy To Azure]($badge)]($DeploymentLink)"
    }
    function New-PortalLink {
        param([Parameter(Mandatory)][string] $TemplateUri)

        return "https://portal.azure.com/#create/Microsoft.Template/uri/$TemplateUri"
    }
    function ConvertTo-EncodedTemplateUri {
        param([Parameter(Mandatory)][string] $TemplateUri)

        return [System.Uri]::EscapeDataString($TemplateUri)
    }

    Assert-ReadmeDeploymentPaths

    $validTemplateUri = ConvertTo-EncodedTemplateUri `
        'https://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json'
    $validButton = New-DeploymentButton (New-PortalLink $validTemplateUri)
    Assert-ReadmeDeploymentPaths `
        -Readme (New-DeploymentButton (New-PortalLink `
            'https://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json')) `
        -ReadmeName 'valid raw Template URI case'

    $failureCases = @(
        @{
            Name = 'unexpected Template URI scheme'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'http://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json'))
            Error = 'HTTPS URI'
        },
        @{
            Name = 'changed owner'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json'))
            Error = 'owner'
        },
        @{
            Name = 'changed repository'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Azure/not-enclave/main/quickstart-templates/azure-enclave-saca.json'))
            Error = 'repository'
        },
        @{
            Name = 'changed branch'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Azure/enclave/develop/quickstart-templates/azure-enclave-saca.json'))
            Error = 'ref'
        },
        @{
            Name = 'non-GitHub host'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://templates.example.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json'))
            Error = 'raw\.githubusercontent\.com'
        },
        @{
            Name = 'unmapped JSON'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/unmapped.json'))
            Error = 'explicit generated artifact mapping'
        },
        @{
            Name = 'encoded traversal'
            Readme = New-DeploymentButton (New-PortalLink `
                'https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Fenclave%2Fmain%2Fquickstart-templates%2F%2E%2E%2Fazure-enclave-saca.json')
            Error = 'traversal'
        },
        @{
            Name = 'malformed Template URI'
            Readme = New-DeploymentButton (New-PortalLink `
                'https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Fenclave%2Fmain%2Fquickstart-templates%2Fbad%ZZ.json')
            Error = 'malformed percent-encoding'
        },
        @{
            Name = 'duplicate template parameter'
            Readme = New-DeploymentButton `
                "https://portal.azure.com/?template=one&template=two#create/Microsoft.Template/uri/$validTemplateUri"
            Error = 'duplicate or ambiguous template parameters'
        },
        @{
            Name = 'Template URI query trick'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json?ref=other'))
            Error = 'query string or fragment'
        },
        @{
            Name = 'Template URI fragment trick'
            Readme = New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Azure/enclave/main/quickstart-templates/azure-enclave-saca.json#other'))
            Error = 'query string or fragment'
        },
        @{
            Name = 'invalid link alongside valid links'
            Readme = "$validButton`n`n$(New-DeploymentButton (New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')))"
            Error = 'owner'
        }
    )

    foreach ($case in $failureCases) {
        $failedAsExpected = $false
        try {
            Assert-ReadmeDeploymentPaths `
                -Readme ([string]$case.Readme) `
                -ReadmeName "regression case '$($case.Name)'"
        }
        catch {
            if ($_.Exception.Message -notmatch [string]$case.Error) {
                throw "Regression case '$($case.Name)' failed for the wrong reason: $($_.Exception.Message)"
            }
            $failedAsExpected = $true
        }

        if (-not $failedAsExpected) {
            throw "Regression case '$($case.Name)' unexpectedly passed."
        }
        Write-Host "Passed: rejected $($case.Name)."
    }

    Write-Host "Passed all $($failureCases.Count) README deployment-link regression tests."
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

if ($TestReadmeDeploymentLinks) {
    Invoke-ReadmeDeploymentLinkTests
    return
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
