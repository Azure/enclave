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

function Find-MarkdownClosingBracket {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $OpenIndex
    )

    $depth = 0
    for ($index = $OpenIndex; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
            $index++
            continue
        }
        if ($Text[$index] -eq '[') {
            $depth++
        }
        elseif ($Text[$index] -eq ']') {
            $depth--
            if ($depth -eq 0) {
                return $index
            }
        }
    }

    return -1
}

function Read-MarkdownInlineTarget {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $OpenParenthesisIndex
    )

    $failure = {
        param([string] $Message)

        return [pscustomobject]@{
            Success  = $false
            Value    = ''
            EndIndex = -1
            Error    = $Message
        }
    }

    if ($OpenParenthesisIndex -ge $Text.Length -or
        $Text[$OpenParenthesisIndex] -ne '(') {
        return & $failure 'missing opening parenthesis'
    }

    $index = $OpenParenthesisIndex + 1
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $index++
    }
    if ($index -ge $Text.Length) {
        return & $failure 'missing target and closing parenthesis'
    }

    if ($Text[$index] -eq '<') {
        $targetStart = ++$index
        while ($index -lt $Text.Length -and $Text[$index] -ne '>') {
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $Text.Length) {
            return & $failure 'unterminated angle-bracket target'
        }
        $target = $Text.Substring($targetStart, $index - $targetStart)
        $index++
    }
    else {
        $targetStart = $index
        $parenthesisDepth = 0
        while ($index -lt $Text.Length) {
            $character = $Text[$index]
            if ($character -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            if ([char]::IsWhiteSpace($character)) {
                break
            }
            if ($character -eq '(') {
                $parenthesisDepth++
            }
            elseif ($character -eq ')') {
                if ($parenthesisDepth -eq 0) {
                    break
                }
                $parenthesisDepth--
            }
            $index++
        }
        $target = $Text.Substring($targetStart, $index - $targetStart)
    }

    if ([string]::IsNullOrEmpty($target)) {
        return & $failure 'empty target'
    }
    $hadTrailingWhitespace = $false
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $hadTrailingWhitespace = $true
        $index++
    }
    if ($hadTrailingWhitespace -and $index -lt $Text.Length -and
        $Text[$index] -in @('"', "'", '(')) {
        $titleOpen = $Text[$index]
        $titleClose = if ($titleOpen -eq '(') { ')' } else { $titleOpen }
        $index++
        while ($index -lt $Text.Length -and $Text[$index] -ne $titleClose) {
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $Text.Length) {
            return & $failure 'unterminated target title'
        }
        $index++
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
        }
    }
    if ($index -ge $Text.Length -or $Text[$index] -ne ')') {
        return & $failure 'missing closing parenthesis or target contains unescaped whitespace'
    }

    return [pscustomobject]@{
        Success  = $true
        Value    = $target
        EndIndex = $index
        Error    = ''
    }
}

function ConvertFrom-MarkdownBackslashEscapes {
    param([Parameter(Mandatory)][string] $Value)

    $result = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq '\' -and $index + 1 -lt $Value.Length) {
            $next = [int][char]$Value[$index + 1]
            $isAsciiPunctuation =
                ($next -ge 0x21 -and $next -le 0x2f) -or
                ($next -ge 0x3a -and $next -le 0x40) -or
                ($next -ge 0x5b -and $next -le 0x60) -or
                ($next -ge 0x7b -and $next -le 0x7e)
            if ($isAsciiPunctuation) {
                [void]$result.Append($Value[++$index])
                continue
            }
        }
        [void]$result.Append($character)
    }

    return $result.ToString()
}

function Test-LooksLikeDeployToAzureBadge {
    param([Parameter(Mandatory)][string] $Value)

    $candidate = (ConvertFrom-MarkdownBackslashEscapes -Value $Value).Trim()
    if ($candidate -match '(?i)(?:^|[/\\]|%2f)deploytoazure\.svg(?:[\s"''()?#]|$)') {
        return $true
    }

    $uri = $null
    return [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -and
        $uri.Host -ieq 'raw.githubusercontent.com' -and
        $uri.AbsolutePath -ieq '/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg'
}

function Test-LooksLikeAzureDeploymentPortal {
    param([Parameter(Mandatory)][string] $Value)

    $candidate = (ConvertFrom-MarkdownBackslashEscapes -Value $Value).Trim()
    $uri = $null
    if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -and
        $uri.Host -ieq 'portal.azure.com') {
        return $true
    }

    if ($candidate -notmatch '%(?![0-9A-Fa-f]{2})') {
        try {
            $decoded = [System.Uri]::UnescapeDataString($candidate)
            return $decoded -match '(?i)^https://portal\.azure\.com(?:[/:?#]|$)'
        }
        catch {
            return $false
        }
    }

    return $false
}

function Assert-DeployToAzureBadge {
    param(
        [Parameter(Mandatory)][string] $BadgeSource,
        [Parameter(Mandatory)][string] $Description
    )

    $badgePattern = '^https://raw\.githubusercontent\.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure\.svg(?:\?sanitize=true)?$'
    if ($BadgeSource -cnotmatch $badgePattern) {
        throw "$Description must use the exact official Deploy-to-Azure badge image URL."
    }
}

function Get-ReadmeDeploymentLinks {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    $deploymentLinks = [System.Collections.Generic.List[object]]::new()
    $searchIndex = 0
    while (($imageStart = $Readme.IndexOf('![', $searchIndex, [System.StringComparison]::Ordinal)) -ge 0) {
        $altOpen = $imageStart + 1
        $altClose = Find-MarkdownClosingBracket -Text $Readme -OpenIndex $altOpen
        if ($altClose -lt 0) {
            break
        }

        $imageTargetOpen = $altClose + 1
        while ($imageTargetOpen -lt $Readme.Length -and
            [char]::IsWhiteSpace($Readme[$imageTargetOpen])) {
            $imageTargetOpen++
        }
        if ($imageTargetOpen -ge $Readme.Length -or $Readme[$imageTargetOpen] -ne '(') {
            $searchIndex = $altClose + 1
            continue
        }

        $imageTarget = Read-MarkdownInlineTarget `
            -Text $Readme `
            -OpenParenthesisIndex $imageTargetOpen
        if (-not $imageTarget.Success) {
            $searchIndex = $imageTargetOpen + 1
            continue
        }

        $badgeSource = [string]$imageTarget.Value
        $outerOpen = $imageStart - 1
        while ($outerOpen -ge 0 -and [char]::IsWhiteSpace($Readme[$outerOpen])) {
            $outerOpen--
        }
        if ($outerOpen -lt 0 -or $Readme[$outerOpen] -ne '[') {
            $searchIndex = $imageTarget.EndIndex + 1
            continue
        }

        $outerLabelClose = $imageTarget.EndIndex + 1
        while ($outerLabelClose -lt $Readme.Length -and
            [char]::IsWhiteSpace($Readme[$outerLabelClose])) {
            $outerLabelClose++
        }
        if ($outerLabelClose -ge $Readme.Length -or $Readme[$outerLabelClose] -ne ']') {
            if (Test-LooksLikeDeployToAzureBadge -Value $badgeSource) {
                throw "$ReadmeName contains an official Deploy-to-Azure badge in a malformed Markdown image-link."
            }
            $searchIndex = $imageTarget.EndIndex + 1
            continue
        }

        $outerTargetOpen = $outerLabelClose + 1
        while ($outerTargetOpen -lt $Readme.Length -and
            [char]::IsWhiteSpace($Readme[$outerTargetOpen])) {
            $outerTargetOpen++
        }
        if ($outerTargetOpen -ge $Readme.Length -or $Readme[$outerTargetOpen] -ne '(') {
            if (Test-LooksLikeDeployToAzureBadge -Value $badgeSource) {
                throw "$ReadmeName contains an official Deploy-to-Azure badge without a supported inline Markdown destination."
            }
            $searchIndex = $outerLabelClose + 1
            continue
        }

        $outerTarget = Read-MarkdownInlineTarget `
            -Text $Readme `
            -OpenParenthesisIndex $outerTargetOpen
        if (-not $outerTarget.Success) {
            $targetRemainder = $Readme.Substring($outerTargetOpen + 1)
            if ((Test-LooksLikeDeployToAzureBadge -Value $badgeSource) -or
                (Test-LooksLikeAzureDeploymentPortal -Value $targetRemainder)) {
                throw "$ReadmeName contains a deployment button with a malformed Markdown target: $($outerTarget.Error)."
            }
            $searchIndex = $outerTargetOpen + 1
            continue
        }

        $destination = [string]$outerTarget.Value
        if ((Test-LooksLikeDeployToAzureBadge -Value $badgeSource) -or
            (Test-LooksLikeAzureDeploymentPortal -Value $destination)) {
            $deploymentLinks.Add([pscustomobject]@{
                    BadgeSource = $badgeSource
                    Destination = $destination
                })
        }

        $searchIndex = $outerTarget.EndIndex + 1
    }

    if ($deploymentLinks.Count -eq 0) {
        throw "$ReadmeName contains no recognized Deploy-to-Azure Markdown image-links."
    }

    return @($deploymentLinks)
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

    $portalRoutePrefix = 'https://portal.azure.com/#create/Microsoft.Template/uri/'
    if (-not $DeploymentLink.StartsWith(
            $portalRoutePrefix,
            [System.StringComparison]::Ordinal)) {
        throw "$description must use the exact '$portalRoutePrefix<Template URI>' URL, including casing and spacing."
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
        $description = "$ReadmeName deployment link #$($index + 1)"
        Assert-DeployToAzureBadge `
            -BadgeSource ([string]$deploymentLinks[$index].BadgeSource) `
            -Description $description
        $artifactPath = Get-DeploymentTemplateArtifactPath `
            -DeploymentLink ([string]$deploymentLinks[$index].Destination) `
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
        param(
            [Parameter(Mandatory)][string] $DeploymentLink,
            [AllowEmptyString()][string] $AltText = 'Deploy To Azure',
            [string] $BadgeSource = $badge
        )

        return "[![$AltText]($BadgeSource)]($DeploymentLink)"
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
    Assert-ReadmeDeploymentPaths `
        -Readme "$validButton`n`n[Documentation](https://learn.microsoft.com/)`n`n![Architecture](images/architecture.svg)`n`n[![Build](https://example.com/build.svg)](https://github.com/Azure/enclave/actions)" `
        -ReadmeName 'valid button with unrelated links and images'

    $failureCases = @(
        @{
            Name = 'official badge with short alt text and attacker template'
            Readme = New-DeploymentButton `
                (New-PortalLink (ConvertTo-EncodedTemplateUri `
                    'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')) `
                -AltText 'Deploy'
            Error = 'owner'
        },
        @{
            Name = 'official badge with empty alt text and attacker template'
            Readme = New-DeploymentButton `
                (New-PortalLink (ConvertTo-EncodedTemplateUri `
                    'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')) `
                -AltText ''
            Error = 'owner'
        },
        @{
            Name = 'official badge with arbitrary alt text and attacker template'
            Readme = New-DeploymentButton `
                (New-PortalLink (ConvertTo-EncodedTemplateUri `
                    'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')) `
                -AltText 'Launch this environment'
            Error = 'owner'
        },
        @{
            Name = 'official portal destination with nonstandard badge'
            Readme = New-DeploymentButton `
                (New-PortalLink $validTemplateUri) `
                -AltText 'Deploy' `
                -BadgeSource 'https://example.com/deploy.svg'
            Error = 'official Deploy-to-Azure badge'
        },
        @{
            Name = 'official badge pointed at non-portal destination'
            Readme = New-DeploymentButton `
                'https://example.com/redirect' `
                -AltText 'Deploy'
            Error = 'exact .*portal\.azure\.com'
        },
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
            Readme = "$validButton`n`n$(New-DeploymentButton `
                (New-PortalLink (ConvertTo-EncodedTemplateUri `
                    'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')) `
                -AltText 'Deploy')"
            Error = 'owner'
        },
        @{
            Name = 'mixed-case portal destination'
            Readme = New-DeploymentButton `
                "https://PORTAL.AZURE.COM/#create/Microsoft.Template/uri/$validTemplateUri" `
                -AltText 'Deploy'
            Error = 'including casing and spacing'
        },
        @{
            Name = 'backslash-escaped portal destination'
            Readme = New-DeploymentButton `
                "https://portal\.azure\.com/#create/Microsoft.Template/uri/$validTemplateUri" `
                -AltText 'Deploy'
            Error = 'including casing and spacing'
        },
        @{
            Name = 'mixed-case official badge path'
            Readme = New-DeploymentButton `
                (New-PortalLink $validTemplateUri) `
                -AltText 'Deploy' `
                -BadgeSource 'https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/DeployToAzure.svg'
            Error = 'official Deploy-to-Azure badge'
        },
        @{
            Name = 'fully encoded portal destination'
            Readme = New-DeploymentButton `
                (ConvertTo-EncodedTemplateUri (New-PortalLink $validTemplateUri)) `
                -AltText 'Deploy'
            Error = 'including casing and spacing'
        },
        @{
            Name = 'render-equivalent Markdown whitespace around attacker target'
            Readme = "[  ![Deploy]($badge)  ](`n  $(New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json'))`n)"
            Error = 'owner'
        },
        @{
            Name = 'badge image title with attacker target'
            Readme = "[![Deploy]($badge `"Official badge`")]($(New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')))"
            Error = 'owner'
        },
        @{
            Name = 'malformed Markdown target'
            Readme = "[![Deploy]($badge)]($(New-PortalLink $validTemplateUri)"
            Error = 'malformed Markdown target'
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
