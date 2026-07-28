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
$script:MaxReadmeCharacters = 1024 * 1024
$script:MarkdownPipeline = $null

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

function ConvertFrom-MarkdownBackslashEscapes {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

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

function Read-HtmlTag {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $StartIndex,
        [Parameter(Mandatory)][string] $ExpectedName,
        [switch] $Closing
    )

    $failure = {
        param([string] $Message)

        return [pscustomobject]@{
            Success     = $false
            Attributes  = @{}
            EndIndex    = -1
            SelfClosing = $false
            Error       = $Message
        }
    }

    if ($StartIndex -ge $Text.Length -or $Text[$StartIndex] -ne '<') {
        return & $failure 'missing opening angle bracket'
    }

    $index = $StartIndex + 1
    if ($Closing) {
        if ($index -ge $Text.Length -or $Text[$index] -ne '/') {
            return & $failure 'missing closing-tag slash'
        }
        $index++
    }
    elseif ($index -lt $Text.Length -and $Text[$index] -eq '/') {
        return & $failure 'unexpected closing tag'
    }

    $nameStart = $index
    while ($index -lt $Text.Length -and
        ([char]::IsLetterOrDigit($Text[$index]) -or $Text[$index] -in @('-', ':'))) {
        $index++
    }
    $name = $Text.Substring($nameStart, $index - $nameStart)
    if ($name -ine $ExpectedName) {
        return & $failure "expected <$ExpectedName> tag"
    }

    $attributes = @{}
    while ($index -lt $Text.Length) {
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
        }
        if ($index -ge $Text.Length) {
            return & $failure 'unterminated tag'
        }
        if ($Text[$index] -eq '>') {
            return [pscustomobject]@{
                Success     = $true
                Attributes  = $attributes
                EndIndex    = $index
                SelfClosing = $false
                Error       = ''
            }
        }
        if (-not $Closing -and $Text[$index] -eq '/' -and
            $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq '>') {
            return [pscustomobject]@{
                Success     = $true
                Attributes  = $attributes
                EndIndex    = $index + 1
                SelfClosing = $true
                Error       = ''
            }
        }
        if ($Closing) {
            return & $failure 'closing tag contains unexpected content'
        }

        $attributeStart = $index
        while ($index -lt $Text.Length -and
            ([char]::IsLetterOrDigit($Text[$index]) -or
                $Text[$index] -in @('-', '_', ':'))) {
            $index++
        }
        if ($index -eq $attributeStart) {
            return & $failure 'invalid attribute name'
        }
        $attributeName = $Text.Substring($attributeStart, $index - $attributeStart).ToLowerInvariant()
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
        }
        if ($index -ge $Text.Length -or $Text[$index] -ne '=') {
            return & $failure "attribute '$attributeName' must have a quoted value"
        }
        $index++
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
        }
        if ($index -ge $Text.Length -or $Text[$index] -notin @('"', "'")) {
            return & $failure "attribute '$attributeName' must use quotes"
        }
        $quote = $Text[$index++]
        $valueStart = $index
        while ($index -lt $Text.Length -and $Text[$index] -ne $quote) {
            $index++
        }
        if ($index -ge $Text.Length) {
            return & $failure "attribute '$attributeName' has an unterminated value"
        }
        if ($attributes.ContainsKey($attributeName)) {
            return & $failure "duplicate attribute '$attributeName'"
        }
        $attributes[$attributeName] = $Text.Substring($valueStart, $index - $valueStart)
        $index++
    }

    return & $failure 'unterminated tag'
}

function Get-HtmlTagTokens {
    param(
        [Parameter(Mandatory)][string] $Text
    )

    $tokens = [System.Collections.Generic.List[object]]::new()
    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -ne '<') {
            $index++
            continue
        }

        $tagStart = $index
        $candidate = $index + 1
        $closing = $false
        if ($candidate -lt $Text.Length -and $Text[$candidate] -eq '/') {
            $closing = $true
            $candidate++
        }
        $nameStart = $candidate
        while ($candidate -lt $Text.Length -and
            ([char]::IsLetterOrDigit($Text[$candidate]) -or
                $Text[$candidate] -eq '-')) {
            $candidate++
        }
        if ($candidate -eq $nameStart) {
            $index++
            continue
        }
        $name = $Text.Substring($nameStart, $candidate - $nameStart).ToLowerInvariant()
        if ($candidate -lt $Text.Length -and
            -not [char]::IsWhiteSpace($Text[$candidate]) -and
            $Text[$candidate] -notin @('>', '/')) {
            $index++
            continue
        }

        $quote = [char]0
        while ($candidate -lt $Text.Length) {
            $character = $Text[$candidate]
            if ($quote -ne [char]0) {
                if ($character -eq $quote) {
                    $quote = [char]0
                }
            }
            elseif ($character -in @('"', "'")) {
                $quote = $character
            }
            elseif ($character -eq '>') {
                break
            }
            $candidate++
        }

        $complete = $candidate -lt $Text.Length -and $Text[$candidate] -eq '>'
        $tagEnd = if ($complete) { $candidate } else { $Text.Length - 1 }
        $tokens.Add([pscustomobject]@{
                Name     = $name
                Closing  = $closing
                Complete = $complete
                Start    = $tagStart
                End      = $tagEnd
            })
        if (-not $complete) {
            break
        }
        $index = $candidate + 1
    }
    return $tokens
}

function Assert-SafeDeploymentHtml {
    param(
        [Parameter(Mandatory)][hashtable] $AnchorAttributes,
        [Parameter(Mandatory)][hashtable] $ImageAttributes,
        [Parameter(Mandatory)][string] $Description
    )

    foreach ($name in $AnchorAttributes.Keys) {
        if ($name -notin @('href', 'title', 'aria-label')) {
            throw "$Description contains unsafe or unsupported HTML anchor attribute '$name'."
        }
    }
    foreach ($name in $ImageAttributes.Keys) {
        if ($name -notin @('src', 'alt', 'title', 'width', 'height')) {
            throw "$Description contains unsafe or unsupported HTML image attribute '$name'."
        }
    }
    foreach ($attribute in @(
            @{ Name = 'href'; Value = [string]$AnchorAttributes['href'] },
            @{ Name = 'src'; Value = [string]$ImageAttributes['src'] })) {
        $decoded = [System.Net.WebUtility]::HtmlDecode([string]$attribute.Value)
        if ($decoded -cne [string]$attribute.Value) {
            throw "$Description $($attribute.Name) must not use HTML entity encoding."
        }
        if ([string]$attribute.Value -match '[\x00-\x20\x7f\\]') {
            throw "$Description $($attribute.Name) contains whitespace, control characters, or backslashes."
        }
    }
}

function Get-UrlInspectionVariants {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    $variants = [System.Collections.Generic.List[string]]::new()
    $candidate = [System.Net.WebUtility]::HtmlDecode(
        (ConvertFrom-MarkdownBackslashEscapes -Value $Value)).Trim()
    $variants.Add($candidate)
    for ($decodePass = 0; $decodePass -lt 2; $decodePass++) {
        if ($candidate -match '%(?![0-9A-Fa-f]{2})') {
            break
        }
        try {
            $decoded = [System.Uri]::UnescapeDataString($candidate)
        }
        catch {
            break
        }
        if ($decoded -ceq $candidate) {
            break
        }
        $variants.Add($decoded)
        $candidate = $decoded
    }

    return @($variants)
}

function Test-LooksLikeDeployToAzureBadge {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    $variants = @(Get-UrlInspectionVariants -Value $Value)
    foreach ($variant in $variants) {
        if ($variant -match '(?i)(?:^|[/\\])deploytoazure\.svg(?:[\s"''()?#]|$)') {
            return $true
        }
    }

    $uri = $null
    $candidate = [string]$variants[0]
    return [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -and
        $uri.Host -ieq 'raw.githubusercontent.com' -and
        $uri.AbsolutePath -ieq '/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg'
}

function Test-LooksLikeAzureDeploymentPortal {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    $variants = @(Get-UrlInspectionVariants -Value $Value)
    $candidate = [string]$variants[0]
    $uri = $null
    if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -and
        $uri.Host -ieq 'portal.azure.com') {
        return $true
    }

    foreach ($variant in $variants) {
        if ($variant -match '(?i)https://portal\.azure\.com(?:[/:?#]|$)') {
            return $true
        }
    }

    return $false
}

function Assert-DeployToAzureBadge {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $BadgeSource,
        [Parameter(Mandatory)][string] $Description
    )

    $badgePattern = '^https://raw\.githubusercontent\.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure\.svg(?:\?sanitize=true)?$'
    if ($BadgeSource -cnotmatch $badgePattern) {
        throw "$Description must use the exact official Deploy-to-Azure badge image URL."
    }
}

function Get-MarkdownPipeline {
    if ($null -eq $script:MarkdownPipeline) {
        # Force-load the in-box Markdig assembly that backs the PowerShell ConvertFrom-Markdown cmdlet.
        # This uses only components shipped with PowerShell 7 on the CI runner: no network access and no
        # dependency fetched from a public package registry. It gives us a standards-compliant CommonMark/GFM
        # parser and its rendered token stream, replacing the previous custom raw-text masking parser.
        $null = ConvertFrom-Markdown -InputObject ([string]::Empty)
        $script:MarkdownPipeline = ([Markdig.MarkdownPipelineBuilder]::new()).Build()
    }
    return $script:MarkdownPipeline
}

function Test-MarkdownHtmlBlockRenders {
    param([Parameter(Mandatory)][object] $Block)

    # Only raw HTML blocks that GitHub renders as live markup can contain a clickable deployment button.
    # Comments, CDATA, processing instructions, declarations, and script/style/pre are not rendered as tags.
    return $Block.Type -in @(
        [Markdig.Syntax.HtmlBlockType]::InterruptingBlock,
        [Markdig.Syntax.HtmlBlockType]::NonInterruptingBlock)
}

function Test-MarkdownHtmlInlineIsTag {
    param([Parameter(Mandatory)][object] $Inline)

    $tag = [string]$Inline.Tag
    # Skip comments and processing instructions/declarations (`<!--`, `<!`, `<?`); those never render as tags.
    return -not ($tag.StartsWith('<!') -or $tag.StartsWith('<?'))
}

function Get-MarkdownLeafBlocks {
    param([Parameter(Mandatory)][object] $Container)

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($block in $Container) {
        if ($block -is [Markdig.Syntax.LinkReferenceDefinitionGroup]) {
            continue    # reference definitions are consumed by the parser and never rendered as content
        }
        if ($block -is [Markdig.Syntax.ContainerBlock]) {
            foreach ($inner in (Get-MarkdownLeafBlocks -Container $block)) {
                $result.Add($inner)
            }
        }
        else {
            $result.Add($block)
        }
    }
    return $result
}

function Add-MarkdownDeploymentCandidates {
    param(
        [Parameter(Mandatory)][object] $Inline,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][object] $Links,
        [Parameter(Mandatory)][object] $Consumed
    )

    foreach ($node in $Inline) {
        if ($node -is [Markdig.Syntax.Inlines.LinkInline]) {
            if (-not $node.IsImage) {
                $imageChild = $null
                foreach ($child in $node) {
                    if ($child -is [Markdig.Syntax.Inlines.LinkInline] -and $child.IsImage) {
                        $imageChild = $child
                        break
                    }
                }
                $destination = [string]$node.Url
                $badgeSource = if ($null -ne $imageChild) { [string]$imageChild.Url } else { '' }
                $isDeploymentButton =
                    (Test-LooksLikeAzureDeploymentPortal -Value $destination) -or
                    ($null -ne $imageChild -and (Test-LooksLikeDeployToAzureBadge -Value $badgeSource))
                if ($isDeploymentButton) {
                    $Links.Add([pscustomobject]@{
                            BadgeSource = $badgeSource
                            Destination = $destination
                            Location    = $Location
                        })
                    [void]$Consumed.Add($node)
                    continue    # the whole rendered anchor is accounted for; do not descend into it
                }
            }
            # A non-button link, or a bare image: descend to discover any nested rendered buttons.
            Add-MarkdownDeploymentCandidates -Inline $node -Location $Location -Links $Links -Consumed $Consumed
        }
        elseif ($node -is [Markdig.Syntax.Inlines.AutolinkInline]) {
            if (Test-LooksLikeAzureDeploymentPortal -Value ([string]$node.Url)) {
                $Links.Add([pscustomobject]@{
                        BadgeSource = ''
                        Destination = [string]$node.Url
                        Location    = $Location
                    })
                [void]$Consumed.Add($node)
            }
        }
        elseif ($node -is [Markdig.Syntax.Inlines.ContainerInline]) {
            Add-MarkdownDeploymentCandidates -Inline $node -Location $Location -Links $Links -Consumed $Consumed
        }
    }
}

function Build-InlineHtmlView {
    param(
        [Parameter(Mandatory)][object] $Inline,
        [Parameter(Mandatory)][object] $Builder,
        [Parameter(Mandatory)][char] $Sentinel
    )

    foreach ($node in $Inline) {
        if ($node -is [Markdig.Syntax.Inlines.HtmlInline]) {
            if (Test-MarkdownHtmlInlineIsTag -Inline $node) {
                [void]$Builder.Append([string]$node.Tag)
            }
            else {
                [void]$Builder.Append([string]::new(' ', ([string]$node.Tag).Length))
            }
        }
        elseif ($node -is [Markdig.Syntax.Inlines.LiteralInline]) {
            [void]$Builder.Append([string]$node.Content.ToString())
        }
        elseif ($node -is [Markdig.Syntax.Inlines.LineBreakInline]) {
            [void]$Builder.Append(' ')
        }
        elseif ($node -is [Markdig.Syntax.Inlines.CodeInline]) {
            # Inline code is rendered as text, not markup; keep its width but never scan it for tags.
            [void]$Builder.Append([string]::new(' ', ([string]$node.Content).Length + 2))
        }
        elseif ($node -is [Markdig.Syntax.Inlines.LinkInline] -or
            $node -is [Markdig.Syntax.Inlines.AutolinkInline]) {
            # Markdown links are handled by the Markdown pass; a sentinel breaks raw-HTML tag adjacency.
            [void]$Builder.Append($Sentinel)
        }
        elseif ($node -is [Markdig.Syntax.Inlines.ContainerInline]) {
            Build-InlineHtmlView -Inline $node -Builder $Builder -Sentinel $Sentinel
        }
        else {
            [void]$Builder.Append(' ')
        }
    }
}

function Get-UnconsumedInlineUrls {
    param(
        [Parameter(Mandatory)][object] $Inline,
        [Parameter(Mandatory)][object] $Consumed
    )

    $sb = [System.Text.StringBuilder]::new()
    foreach ($node in $Inline) {
        if ($Consumed.Contains($node)) {
            continue    # part of a validated deployment button; excluded from the residual scan
        }
        if ($node -is [Markdig.Syntax.Inlines.LinkInline]) {
            [void]$sb.Append(' ').Append([string]$node.Url)
            [void]$sb.Append(' ').Append((Get-UnconsumedInlineUrls -Inline $node -Consumed $Consumed))
        }
        elseif ($node -is [Markdig.Syntax.Inlines.AutolinkInline]) {
            [void]$sb.Append(' ').Append([string]$node.Url)
        }
        elseif ($node -is [Markdig.Syntax.Inlines.ContainerInline]) {
            [void]$sb.Append(' ').Append((Get-UnconsumedInlineUrls -Inline $node -Consumed $Consumed))
        }
    }
    return $sb.ToString()
}

function Get-HtmlDeploymentButton {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $HtmlText,
        [Parameter(Mandatory)][string] $ReadmeName,
        [Parameter(Mandatory)][string] $Location
    )

    $buttons = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($HtmlText)) {
        return $buttons
    }

    $tokens = @(Get-HtmlTagTokens -Text $HtmlText)
    for ($tokenIndex = 0; $tokenIndex -lt $tokens.Count; $tokenIndex++) {
        $anchorToken = $tokens[$tokenIndex]
        if (-not $anchorToken.Complete -or $anchorToken.Closing -or $anchorToken.Name -ne 'a') {
            continue
        }

        $anchor = Read-HtmlTag -Text $HtmlText -StartIndex ([int]$anchorToken.Start) -ExpectedName 'a'
        if (-not $anchor.Success) {
            continue
        }
        $href = [string]$anchor.Attributes['href']

        $imageToken = if ($tokenIndex + 1 -lt $tokens.Count) { $tokens[$tokenIndex + 1] } else { $null }
        $imageGapIsWhitespace = $null -ne $imageToken
        if ($imageGapIsWhitespace) {
            for ($i = $anchor.EndIndex + 1; $i -lt [int]$imageToken.Start; $i++) {
                if (-not [char]::IsWhiteSpace($HtmlText[$i])) { $imageGapIsWhitespace = $false; break }
            }
        }
        $image = if ($imageGapIsWhitespace -and $imageToken.Complete -and
            -not $imageToken.Closing -and $imageToken.Name -eq 'img') {
            Read-HtmlTag -Text $HtmlText -StartIndex ([int]$imageToken.Start) -ExpectedName 'img'
        }
        else { $null }
        $source = if ($null -ne $image -and $image.Success) { [string]$image.Attributes['src'] } else { '' }

        $closingToken = if ($tokenIndex + 2 -lt $tokens.Count) { $tokens[$tokenIndex + 2] } else { $null }
        $closingGapIsWhitespace = $null -ne $image -and $image.Success -and $null -ne $closingToken
        if ($closingGapIsWhitespace) {
            for ($i = $image.EndIndex + 1; $i -lt [int]$closingToken.Start; $i++) {
                if (-not [char]::IsWhiteSpace($HtmlText[$i])) { $closingGapIsWhitespace = $false; break }
            }
        }
        $closingAnchor = if ($closingGapIsWhitespace -and $closingToken.Complete -and
            $closingToken.Closing -and $closingToken.Name -eq 'a') {
            Read-HtmlTag -Text $HtmlText -StartIndex ([int]$closingToken.Start) -ExpectedName 'a' -Closing
        }
        else { $null }

        $isDeploymentButton =
            (Test-LooksLikeAzureDeploymentPortal -Value $href) -or
            (Test-LooksLikeDeployToAzureBadge -Value $source)
        if (-not $isDeploymentButton) {
            continue
        }
        if ($null -eq $image -or -not $image.Success -or
            $null -eq $closingAnchor -or -not $closingAnchor.Success) {
            throw "$ReadmeName contains a malformed HTML deployment button ($Location)."
        }
        if ($anchor.SelfClosing -or $closingAnchor.SelfClosing) {
            throw "$ReadmeName contains invalid HTML anchor nesting for a deployment button ($Location)."
        }
        if (-not $anchor.Attributes.ContainsKey('href') -or -not $image.Attributes.ContainsKey('src')) {
            throw "$ReadmeName HTML deployment button must contain href and src attributes ($Location)."
        }

        Assert-SafeDeploymentHtml `
            -AnchorAttributes $anchor.Attributes `
            -ImageAttributes $image.Attributes `
            -Description "$ReadmeName HTML deployment button ($Location)"
        $buttons.Add([pscustomobject]@{
                BadgeSource = $source
                Destination = $href
                Location    = $Location
                Start       = [int]$anchorToken.Start
                End         = [int]$closingAnchor.EndIndex
            })
        $tokenIndex += 2
    }
    return $buttons
}

function Add-HtmlButtonsToResidual {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $HtmlText,
        [Parameter(Mandatory)][string] $ReadmeName,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][object] $Links,
        [Parameter(Mandatory)][object] $Residual
    )

    $htmlButtons = @(Get-HtmlDeploymentButton -HtmlText $HtmlText -ReadmeName $ReadmeName -Location $Location)
    $characters = $HtmlText.ToCharArray()
    foreach ($button in $htmlButtons) {
        $Links.Add([pscustomobject]@{
                BadgeSource = $button.BadgeSource
                Destination = $button.Destination
                Location    = $button.Location
            })
        for ($i = [int]$button.Start; $i -le [int]$button.End -and $i -lt $characters.Length; $i++) {
            $characters[$i] = ' '    # exclude the validated button span from the residual marker scan
        }
    }
    [void]$Residual.Append((-join $characters)).Append(' ')
}

function Get-ReadmeDeploymentParseResult {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    if ($Readme.Length -gt $script:MaxReadmeCharacters) {
        throw "$ReadmeName exceeds the maximum supported README size of $script:MaxReadmeCharacters characters."
    }

    $pipeline = Get-MarkdownPipeline
    try {
        $document = [Markdig.Markdown]::Parse($Readme, $pipeline)
    }
    catch {
        # Markdig enforces structural limits (for example, pathologically deep delimiter nesting). Rather
        # than let unparseable input slip past discovery, fail closed: a document the CommonMark parser
        # rejects cannot be trusted to render only the deployment buttons we validated.
        throw "$ReadmeName could not be parsed as CommonMark and is rejected (failing closed): $($_.Exception.Message)"
    }

    $deploymentLinks = [System.Collections.Generic.List[object]]::new()
    $consumed = [System.Collections.Generic.HashSet[object]]::new(
        [System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    $residual = [System.Text.StringBuilder]::new()
    $sentinel = [char]0xFFFF

    foreach ($block in (Get-MarkdownLeafBlocks -Container $document)) {
        $location = "line $([int]$block.Line + 1)"

        if ($block -is [Markdig.Syntax.HtmlBlock]) {
            if (-not (Test-MarkdownHtmlBlockRenders -Block $block)) {
                continue    # comment / CDATA / PI / declaration / script-style block: not rendered as markup
            }
            Add-HtmlButtonsToResidual `
                -HtmlText ([string]$block.Lines.ToString()) `
                -ReadmeName $ReadmeName -Location $location `
                -Links $deploymentLinks -Residual $residual
            continue
        }

        if ($block -is [Markdig.Syntax.CodeBlock]) {
            continue    # fenced or indented code is never rendered as a link
        }

        if ($block -is [Markdig.Syntax.LeafBlock] -and $null -ne $block.Inline) {
            # Markdown pass: discover rendered LinkInline / AutolinkInline deployment buttons.
            Add-MarkdownDeploymentCandidates `
                -Inline $block.Inline -Location $location `
                -Links $deploymentLinks -Consumed $consumed

            # Raw inline HTML pass over the rendered token stream, plus its residual contribution.
            $htmlView = [System.Text.StringBuilder]::new()
            Build-InlineHtmlView -Inline $block.Inline -Builder $htmlView -Sentinel $sentinel
            Add-HtmlButtonsToResidual `
                -HtmlText ($htmlView.ToString()) `
                -ReadmeName $ReadmeName -Location $location `
                -Links $deploymentLinks -Residual $residual

            # Unconsumed Markdown link / autolink destinations that still render as clickable targets.
            [void]$residual.Append(
                (Get-UnconsumedInlineUrls -Inline $block.Inline -Consumed $consumed)).Append(' ')
            continue
        }
    }

    # Residual marker backstop: inspects the rendered token stream (never masked raw text). Any official
    # badge image or Azure deployment-portal destination that rendered but was not accounted for as a
    # validated button fails closed here.
    $residualText = $residual.ToString()
    if ((Test-LooksLikeDeployToAzureBadge -Value $residualText) -or
        (Test-LooksLikeAzureDeploymentPortal -Value $residualText)) {
        throw "$ReadmeName contains a rendered Deploy-to-Azure marker (official badge image or Azure portal destination) that is not part of a validated deployment button."
    }

    if ($deploymentLinks.Count -eq 0) {
        throw "$ReadmeName contains no recognized Deploy-to-Azure Markdown or HTML image-links."
    }

    return [pscustomobject]@{
        Links = @($deploymentLinks)
    }
}

function Get-ReadmeDeploymentLinks {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    return @(
        (Get-ReadmeDeploymentParseResult `
            -Readme $Readme `
            -ReadmeName $ReadmeName).Links
    )
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
        $location = [string]$deploymentLinks[$index].Location
        $description = "$ReadmeName deployment link #$($index + 1) ($location)"
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
    function Assert-RenderedDeploymentCase {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][string] $Readme,
            [Parameter(Mandatory)][int] $ExpectedCount
        )

        $result = Get-ReadmeDeploymentParseResult `
            -Readme $Readme `
            -ReadmeName $Name
        if ($result.Links.Count -ne $ExpectedCount) {
            throw "$Name discovered $($result.Links.Count) rendered deployment buttons; expected $ExpectedCount."
        }
        Assert-ReadmeDeploymentPaths -Readme $Readme -ReadmeName $Name
    }
    function Assert-BoundedParserRejection {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][string] $Readme,
            [Parameter(Mandatory)][string] $Error
        )

        try {
            [void](Get-ReadmeDeploymentParseResult -Readme $Readme -ReadmeName $Name)
        }
        catch {
            if ($_.Exception.Message -notmatch $Error) {
                throw "$Name failed for the wrong reason: $($_.Exception.Message)"
            }
            Write-Host "Passed: bounded rejection for $Name."
            return
        }
        throw "$Name unexpectedly passed."
    }
    function Assert-RenderedButtonCount {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][string] $Readme,
            [Parameter(Mandatory)][int] $ExpectedCount,
            [int] $MaxMilliseconds = 30000
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Get-ReadmeDeploymentParseResult -Readme $Readme -ReadmeName $Name
        $stopwatch.Stop()
        if ($result.Links.Count -ne $ExpectedCount) {
            throw "$Name discovered $($result.Links.Count) rendered deployment buttons; expected $ExpectedCount."
        }
        if ($stopwatch.ElapsedMilliseconds -gt $MaxMilliseconds) {
            throw "$Name took $($stopwatch.ElapsedMilliseconds) ms to parse $($Readme.Length) characters; sanity bound was $MaxMilliseconds ms."
        }
        Write-Host "Passed: $Name parsed $($Readme.Length) characters in $($stopwatch.ElapsedMilliseconds) ms (found $($result.Links.Count) button(s))."
    }
    function New-PathologicalCommentReadme {
        param(
            [Parameter(Mandatory)][int] $Length,
            [Parameter(Mandatory)][string] $RenderedButton
        )

        $suffix = "`n$RenderedButton"
        if ($Length -lt $suffix.Length) {
            throw "Pathological README length $Length is smaller than its rendered button suffix."
        }
        $payloadLength = $Length - $suffix.Length
        $unit = '<!-->'
        $repeatCount = [int][Math]::Floor($payloadLength / $unit.Length)
        $remainder = $payloadLength % $unit.Length
        return ($unit * $repeatCount) + ('x' * $remainder) + $suffix
    }
    function Assert-PathologicalParserScaling {
        param([Parameter(Mandatory)][string] $RenderedButton)

        # Feed adversarial inputs of increasing size up to the 1 MiB cap and prove the standards-compliant
        # CommonMark parser handles them deterministically within a generous wall-clock sanity bound (no
        # quadratic blow-up and no bypass: exactly one rendered button is always discovered).
        $sizes = @(7680, 14950, 29696, 58982, $script:MaxReadmeCharacters)
        $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($size in $sizes) {
            $readme = New-PathologicalCommentReadme -Length $size -RenderedButton $RenderedButton
            $sanityMilliseconds = if ($size -eq $script:MaxReadmeCharacters) { 60000 } else { 20000 }
            Assert-RenderedButtonCount `
                -Name "pathological invalid comment input $size" `
                -Readme $readme -ExpectedCount 1 -MaxMilliseconds $sanityMilliseconds
        }
        $totalStopwatch.Stop()
        if ($totalStopwatch.ElapsedMilliseconds -gt 120000) {
            throw "Pathological scaling suite took $($totalStopwatch.ElapsedMilliseconds) ms; sanity bound was 120000 ms."
        }
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
    Assert-ReadmeDeploymentPaths `
        -Readme "[![Deploy][BadgeRef]][DeployRef]`n`n[badgeref]: <$badge>`n[DEPLOYREF]: <$(New-PortalLink $validTemplateUri)>" `
        -ReadmeName 'valid case-insensitive full references'
    Assert-ReadmeDeploymentPaths `
        -Readme "[![Deploy][]]($(New-PortalLink $validTemplateUri))`n`n[deploy]: <$badge>" `
        -ReadmeName 'valid collapsed image reference'
    Assert-ReadmeDeploymentPaths `
        -Readme "[![Deploy]]($(New-PortalLink $validTemplateUri))`n`n[deploy]: <$badge>" `
        -ReadmeName 'valid shortcut image reference'
    Assert-ReadmeDeploymentPaths `
        -Readme "<a href=`"$(New-PortalLink $validTemplateUri)`"><img alt=`"Deploy`" src=`"$badge`"></a>" `
        -ReadmeName 'valid HTML deployment button'
    Assert-ReadmeDeploymentPaths `
        -Readme "<A`n  ARIA-LABEL = 'Deploy' HREF = '$(New-PortalLink $validTemplateUri)'>`n  <IMG WIDTH = '200' SRC = '$badge' ALT = 'Deploy' />`n</A>" `
        -ReadmeName 'valid HTML casing whitespace and attribute order'
    Assert-ReadmeDeploymentPaths `
        -Readme "$validButton`n`n[Documentation][docs]`n`n[docs]: https://learn.microsoft.com/`n`n![Architecture](images/architecture.svg)`n`n<a href=`"https://learn.microsoft.com/`"><img src=`"images/architecture.svg`" alt=`"Architecture`"></a>" `
        -ReadmeName 'valid button with unrelated Markdown and HTML constructs'
    Assert-ReadmeDeploymentPaths `
        -Readme "[![Deploy][badge]](<$(New-PortalLink $validTemplateUri)>)`n`n[badge]: <$badge>" `
        -ReadmeName 'valid reference-style clickable badge with angle-bracket destination'
    Assert-ReadmeDeploymentPaths `
        -Readme "[![Deploy][badge]]($(New-PortalLink $validTemplateUri))`n`n[badge]: <$badge>`n[BADGE]: <https://example.com/deploy.svg>" `
        -ReadmeName 'valid first-precedence official badge reference definition'

    $attackerButton = New-DeploymentButton `
        (New-PortalLink (ConvertTo-EncodedTemplateUri `
            'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json'))
    $htmlAttackerButton = "<a href=`"https://example.com/redirect`"><img src=`"$badge`" alt=`"Deploy`"></a>"
    $backtickFence = [string]::new([char]0x60, 4)
    $tildeFence = '~~~~~'
    $singleBacktick = [string]::new([char]0x60, 1)
    $tripleBacktick = [string]::new([char]0x60, 3)
    $shortBackticks = [string]::new([char]0x60, 2)
    $hiddenBrackets = [string]::new('[', 256)
    Assert-RenderedDeploymentCase `
        -Name 'backtick fence with hidden valid and attacker buttons' `
        -Readme "$backtickFence powershell`n$tripleBacktick`n$hiddenBrackets`n$validButton`n$attackerButton`n$backtickFence`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'tilde fence with hidden valid and attacker buttons' `
        -Readme "$tildeFence markdown`n~~~`n$hiddenBrackets`n$validButton`n$attackerButton`n$tildeFence`n`n$validButton" `
        -ExpectedCount 1

    Assert-RenderedDeploymentCase `
        -Name 'single-backtick inline code hides button' `
        -Readme "${singleBacktick}${attackerButton}${singleBacktick}`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'variable-backtick inline code hides shorter delimiters and button' `
        -Readme "${tripleBacktick}x${singleBacktick}a${shortBackticks}b${attackerButton}${tripleBacktick}`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'HTML comment hides Markdown and HTML buttons' `
        -Readme "<!--`n${singleBacktick}$hiddenBrackets`n$attackerButton`n$htmlAttackerButton`n-->`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'valid unclosed HTML comment hides following buttons' `
        -Readme "$validButton`n`n<!--`n$attackerButton`n$htmlAttackerButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'indented code hides deployment button' `
        -Readme "    $attackerButton`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'blockquote fenced example hides deployment button' `
        -Readme "> $backtickFence markdown`n> $attackerButton`n> $backtickFence`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'list fenced example hides deployment button' `
        -Readme "- $tildeFence markdown`n  $attackerButton`n  $tildeFence`n`n$validButton" `
        -ExpectedCount 1
    Assert-RenderedDeploymentCase `
        -Name 'blockquote indented code hides deployment button' `
        -Readme ">     $attackerButton`n`n$validButton" `
        -ExpectedCount 1

    $hiddenOnlyReadme = @"
$backtickFence example
$validButton
$backtickFence

$tildeFence
$attackerButton
$tildeFence

${singleBacktick}${validButton}${singleBacktick}

<!-- $htmlAttackerButton -->
"@
    Assert-BoundedParserRejection `
        -Name 'mixed hidden examples with zero rendered buttons' `
        -Readme $hiddenOnlyReadme `
        -Error 'no recognized Deploy-to-Azure'
    Assert-RenderedDeploymentCase `
        -Name 'mixed hidden examples with exactly one rendered button' `
        -Readme "$hiddenOnlyReadme`n`n$validButton" `
        -ExpectedCount 1

    # Adversarial delimiter floods that CommonMark still parses to a bounded structure: prove they neither
    # hang the parser nor fabricate/hide buttons (the one real button is always found), within a time bound.
    $unterminatedImages6Kb = ('![x' * 400) -join ''
    Assert-RenderedButtonCount `
        -Name 'repeated unterminated image delimiters (accepted, no bypass)' `
        -Readme "$validButton`n$unterminatedImages6Kb" `
        -ExpectedCount 1
    $unterminatedBrackets6Kb = [string]::new('[', 400)
    Assert-RenderedButtonCount `
        -Name 'repeated unterminated brackets (accepted, no bypass)' `
        -Readme "$validButton`n$unterminatedBrackets6Kb" `
        -ExpectedCount 1

    $unterminatedBackticks64Kb = (
        1..362 | ForEach-Object {
            [string]::new([char]0x60, $_) + 'x'
        }) -join ''
    Assert-RenderedButtonCount `
        -Name '64 KB repeated unterminated backtick runs' `
        -Readme "$validButton`n$unterminatedBackticks64Kb" `
        -ExpectedCount 1
    $unterminatedComments = ('<!--' * 4096) -join ''
    Assert-RenderedButtonCount `
        -Name 'repeated unterminated HTML comments' `
        -Readme "$validButton`n$unterminatedComments" `
        -ExpectedCount 1
    $unterminatedFencePayload = ('![x[' * 4096) -join ''
    Assert-RenderedButtonCount `
        -Name 'unterminated tilde fence with repeated delimiters' `
        -Readme "$validButton`n~~~ example`n$unterminatedFencePayload" `
        -ExpectedCount 1
    Assert-PathologicalParserScaling -RenderedButton $validButton

    # Pathologically deep delimiter nesting exceeds CommonMark structural limits and must fail closed
    # (rather than hang), quickly and deterministically.
    Assert-BoundedParserRejection `
        -Name 'deeply nested image delimiters fail closed' `
        -Readme ('![x' * 20000) `
        -Error 'failing closed'
    Assert-BoundedParserRejection `
        -Name 'deeply nested brackets fail closed' `
        -Readme ([string]::new('[', 65536)) `
        -Error 'failing closed'
    Assert-BoundedParserRejection `
        -Name 'README maximum input size' `
        -Readme ('x' * ($script:MaxReadmeCharacters + 1)) `
        -Error 'maximum supported README size'

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
            Name = 'backslash-obfuscated attacker portal destination'
            Readme = New-DeploymentButton `
                "https://portal\.azure\.com/#create/Microsoft.Template/uri/$(ConvertTo-EncodedTemplateUri `
                    'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json')" `
                -AltText 'Deploy'
            Error = 'owner'
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
            Name = 'malformed Markdown target renders bare badge image and portal text'
            Readme = "[![Deploy]($badge)]($(New-PortalLink $validTemplateUri)"
            Error = 'not part of a validated deployment button'
        },
        @{
            Name = 'full reference badge with attacker destination'
            Readme = "[![Deploy][badge]](<https://example.com/redirect>)`n`n[badge]: <$badge>"
            Error = 'exact .*portal\.azure\.com'
        },
        @{
            Name = 'first-precedence attacker badge reference definition'
            Readme = "[![Deploy][badge]]($(New-PortalLink $validTemplateUri))`n`n[badge]: <https://example.com/deploy.svg>`n[BADGE]: <$badge>"
            Error = 'official Deploy-to-Azure badge'
        },
        @{
            Name = 'unresolved badge reference with portal destination'
            Readme = "[![Deploy][missing]]($(New-PortalLink $validTemplateUri))"
            Error = 'official Deploy-to-Azure badge'
        },
        @{
            Name = 'HTML entity encoded attacker destination'
            Readme = "<a href=`"https&#58;//example.com/redirect`"><img src=`"$badge`" alt=`"Deploy`"></a>"
            Error = 'HTML entity encoding'
        },
        @{
            Name = 'Markdown escaped attacker destination'
            Readme = "[![Deploy][badge]](<https\://example.com/redirect>)`n`n[badge]: <$badge>"
            Error = 'exact .*portal\.azure\.com'
        },
        @{
            Name = 'encoded portal redirect with nonstandard HTML badge'
            Readme = "<a href=`"https://example.com/redirect?next=https%3A%2F%2Fportal.azure.com%2F`"><img src=`"https://example.com/deploy.svg`" alt=`"Deploy`"></a>"
            Error = 'official Deploy-to-Azure badge'
        },
        @{
            Name = 'unsafe HTML event attribute'
            Readme = "<a href=`"$(New-PortalLink $validTemplateUri)`"><img src=`"$badge`" alt=`"Deploy`" onerror=`"alert(1)`"></a>"
            Error = 'unsafe or unsupported HTML image attribute'
        },
        @{
            Name = 'malformed HTML nesting'
            Readme = "<a href=`"$(New-PortalLink $validTemplateUri)`"><span><img src=`"$badge`"></span></a>"
            Error = 'malformed HTML deployment button'
        },
        @{
            Name = 'valid inline plus invalid reference button'
            Readme = "$validButton`n`n[![Deploy][badge]](<https://example.com/redirect>)`n`n[badge]: <$badge>"
            Error = 'exact .*portal\.azure\.com'
        },
        @{
            Name = 'valid inline plus invalid HTML button'
            Readme = "$validButton`n`n<a href=`"https://example.com/redirect`"><img src=`"$badge`" alt=`"Deploy`"></a>"
            Error = 'exact .*portal\.azure\.com'
        },
        @{
            Name = 'blockquote fence container transition exposes attacker button'
            Readme = "> ~~~`n$attackerButton`n~~~"
            Error = 'owner'
        },
        @{
            Name = 'paragraph continuation exposes four-space attacker button'
            Readme = "paragraph`n    $attackerButton"
            Error = 'owner'
        },
        @{
            Name = 'list continuation paragraph exposes attacker button'
            Readme = "- paragraph`n    $attackerButton"
            Error = 'owner'
        },
        @{
            Name = 'invalid short HTML comment opener exposes attacker button'
            Readme = "<!-->`n$attackerButton`n-->"
            Error = 'owner'
        },
        @{
            Name = 'invalid dash HTML comment opener exposes attacker button'
            Readme = "<!--->`n$attackerButton`n-->"
            Error = 'owner'
        },
        @{
            Name = 'valid button plus blockquote fence transition attacker'
            Readme = "$validButton`n`n> ~~~`n$attackerButton`n~~~"
            Error = 'owner'
        },
        @{
            Name = 'valid button plus paragraph continuation attacker'
            Readme = "$validButton`n`nparagraph`n    $attackerButton"
            Error = 'owner'
        },
        @{
            Name = 'valid button plus list continuation attacker'
            Readme = "$validButton`n`n- paragraph`n    $attackerButton"
            Error = 'owner'
        },
        @{
            Name = 'valid button plus invalid short comment opener attacker'
            Readme = "$validButton`n`n<!-->`n$attackerButton`n-->"
            Error = 'owner'
        },
        @{
            Name = 'valid button plus invalid dash comment opener attacker'
            Readme = "$validButton`n`n<!--->`n$attackerButton`n-->"
            Error = 'owner'
        },
        @{
            # Regression for PR #6 blocker r3648123266: a mid-line HTML comment opener without a same-block
            # closer is rendered literally by GFM, so a following Deploy-to-Azure button still renders and
            # must be validated. The previous masking parser hid everything through the next '-->' or EOF.
            Name = 'blocker r3648123266 mid-line HTML comment does not mask following button'
            Readme = "$validButton`n`ntext <!--`n`n$attackerButton"
            Error = 'owner'
        },
        @{
            Name = 'blocker r3648123266 cross-blank-line HTML comment closer does not mask following button'
            Readme = "$validButton`n`ntext <!--`n`n$attackerButton`n`n-->"
            Error = 'owner'
        },
        @{
            # Regression for PR #6 blocker r3648123329: CommonMark inline parsing is block-scoped, so equal
            # backtick runs in separate paragraphs do not pair into a code span and the enclosed button
            # still renders. The previous run-map paired backticks across the whole document.
            Name = 'blocker r3648123329 cross-paragraph single backticks do not mask button'
            Readme = "$validButton`n`n$singleBacktick`n`n$attackerButton`n`n$singleBacktick"
            Error = 'owner'
        },
        @{
            Name = 'blocker r3648123329 cross-paragraph double backticks do not mask button'
            Readme = "$validButton`n`n$shortBackticks`n`n$attackerButton`n`n$shortBackticks"
            Error = 'owner'
        },
        @{
            # Regression for PR #5 finding r3647275746 (tracked to #6): a reference-style clickable official
            # badge whose destination is an attacker portal must be discovered and fail closed.
            Name = 'finding r3647275746 reference-style clickable badge with attacker portal'
            Readme = "$validButton`n`n[![Deploy][badge]](<$(New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json'))>)`n`n[badge]: <$badge>"
            Error = 'owner'
        },
        @{
            Name = 'finding r3647275746 HTML anchor-image badge with attacker portal'
            Readme = "$validButton`n`n<a href=`"$(New-PortalLink (ConvertTo-EncodedTemplateUri `
                'https://raw.githubusercontent.com/Contoso/enclave/main/quickstart-templates/azure-enclave-saca.json'))`"><img src=`"$badge`" alt=`"Deploy`"></a>"
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
$topLevelJsonExclusions = @($config.topLevelJsonExclusions)
$excludedRootJsonFiles = [System.Collections.Generic.List[string]]::new()
foreach ($exclusion in $topLevelJsonExclusions) {
    $pattern = ([string]$exclusion.pattern).Replace('\', '/')
    $schema = [string]$exclusion.schema
    $reason = [string]$exclusion.reason
    if ([string]::IsNullOrWhiteSpace($pattern) -or
        [System.IO.Path]::IsPathRooted($pattern) -or
        $pattern.Split('/') -contains '..') {
        throw "Top-level JSON exclusion pattern '$pattern' must remain inside the repository."
    }
    if ([string]::IsNullOrWhiteSpace($schema) -or [string]::IsNullOrWhiteSpace($reason)) {
        throw "Top-level JSON exclusion '$pattern' must declare its expected schema and reason."
    }

    $matches = @($rootJsonFiles | Where-Object { $_ -like $pattern })
    if ($matches.Count -eq 0) {
        throw "Top-level JSON exclusion '$pattern' does not match any files."
    }
    foreach ($match in $matches) {
        if ($excludedRootJsonFiles.Contains($match)) {
            throw "Top-level JSON file '$match' matches more than one exclusion policy."
        }
        try {
            $document = Get-Content -LiteralPath (Join-Path $repoRoot $match) -Raw |
                ConvertFrom-Json -Depth 100
        }
        catch {
            throw "Excluded hand-authored JSON '$match' is not valid JSON: $($_.Exception.Message)"
        }
        if ([string]$document.'$schema' -ne $schema) {
            throw "Excluded hand-authored JSON '$match' does not use its policy schema '$schema'."
        }
        $excludedRootJsonFiles.Add($match)
    }
}

$generatedRootJsonFiles = @(
    $rootJsonFiles | Where-Object { $_ -cnotin $excludedRootJsonFiles }
)
Assert-SamePathSet -Name 'Top-level Bicep source mappings' -Expected $rootBicepFiles -Actual $mappedSources
Assert-SamePathSet -Name 'Generated ARM artifact mappings' -Expected $generatedRootJsonFiles -Actual $mappedArtifacts

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
