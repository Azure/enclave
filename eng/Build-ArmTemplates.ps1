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
$script:MaxMarkdownDelimiterNesting = 128
$script:MarkdownParserOperationsPerCharacter = 24

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

function Add-MarkdownParserOperations {
    param(
        [Parameter(Mandatory)][pscustomobject] $State,
        [Parameter(Mandatory)][long] $Count
    )

    $State.Operations = [long]$State.Operations + $Count
    if ($State.Operations -gt $State.OperationLimit) {
        throw "$($State.ReadmeName) exceeded the bounded Markdown parser operation budget."
    }
}

function Test-MarkdownCharacterEscaped {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $Index
    )

    $backslashCount = 0
    for ($candidate = $Index - 1;
        $candidate -ge 0 -and $Text[$candidate] -eq '\';
        $candidate--) {
        $backslashCount++
    }
    return ($backslashCount % 2) -eq 1
}

function Set-MarkdownHiddenRange {
    param(
        [Parameter(Mandatory)][char[]] $Characters,
        [Parameter(Mandatory)][int] $Start,
        [Parameter(Mandatory)][int] $EndExclusive
    )

    for ($index = $Start;
        $index -lt [Math]::Min($EndExclusive, $Characters.Length);
        $index++) {
        if ($Characters[$index] -ne "`r" -and $Characters[$index] -ne "`n") {
            $Characters[$index] = ' '
        }
    }
}

function Get-MarkdownIndent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][int] $Start,
        [Parameter(Mandatory)][int] $End
    )

    $index = $Start
    $columns = 0
    while ($index -lt $End) {
        if ($Line[$index] -eq ' ') {
            $columns++
        }
        elseif ($Line[$index] -eq "`t") {
            $columns += 4 - ($columns % 4)
        }
        else {
            break
        }
        $index++
    }

    return [pscustomobject]@{
        Columns = $columns
        Index   = $index
    }
}

function Get-MarkdownIndexAfterIndent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][int] $Start,
        [Parameter(Mandatory)][int] $End,
        [Parameter(Mandatory)][int] $RequiredColumns
    )

    $index = $Start
    $columns = 0
    while ($index -lt $End -and $columns -lt $RequiredColumns) {
        if ($Line[$index] -eq ' ') {
            $columns++
        }
        elseif ($Line[$index] -eq "`t") {
            $columns += 4 - ($columns % 4)
        }
        else {
            break
        }
        $index++
    }

    if ($columns -lt $RequiredColumns) {
        return -1
    }
    return $index
}

function Get-MarkdownBlockquotePrefix {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][int] $End,
        [int] $RequiredDepth = -1
    )

    $index = 0
    $depth = 0
    while ($index -lt $End -and ($RequiredDepth -lt 0 -or $depth -lt $RequiredDepth)) {
        $candidate = $index
        $spaces = 0
        while ($candidate -lt $End -and $spaces -lt 3 -and $Line[$candidate] -eq ' ') {
            $candidate++
            $spaces++
        }
        if ($candidate -ge $End -or $Line[$candidate] -ne '>') {
            break
        }
        $depth++
        $index = $candidate + 1
        if ($index -lt $End -and $Line[$index] -in @(' ', "`t")) {
            $index++
        }
    }

    if ($RequiredDepth -ge 0 -and $depth -ne $RequiredDepth) {
        return $null
    }
    return [pscustomobject]@{
        Depth = $depth
        Index = $index
    }
}

function Get-MarkdownLineStructure {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][int] $End
    )

    $blockquote = Get-MarkdownBlockquotePrefix -Line $Line -End $End
    $containerStart = [int]$blockquote.Index
    $indent = Get-MarkdownIndent -Line $Line -Start $containerStart -End $End
    $markerStart = [int]$indent.Index
    $markerEnd = $markerStart

    if ($markerStart -lt $End -and $indent.Columns -le 3) {
        if ($Line[$markerStart] -in @('-', '+', '*')) {
            $markerEnd = $markerStart + 1
        }
        elseif ([char]::IsDigit($Line[$markerStart])) {
            while ($markerEnd -lt $End -and
                $markerEnd - $markerStart -lt 9 -and
                [char]::IsDigit($Line[$markerEnd])) {
                $markerEnd++
            }
            if ($markerEnd -eq $markerStart -or $markerEnd -ge $End -or
                $Line[$markerEnd] -notin @('.', ')')) {
                $markerEnd = $markerStart
            }
            else {
                $markerEnd++
            }
        }
    }

    $hasListMarker = $false
    $listContentStart = $containerStart
    $listIndent = 0
    if ($markerEnd -gt $markerStart -and
        $markerEnd -lt $End -and
        $Line[$markerEnd] -in @(' ', "`t")) {
        $paddingStart = $markerEnd
        $paddingColumns = 0
        while ($markerEnd -lt $End -and $paddingColumns -lt 4 -and
            $Line[$markerEnd] -in @(' ', "`t")) {
            if ($Line[$markerEnd] -eq ' ') {
                $paddingColumns++
            }
            else {
                $paddingColumns += 4 - ($paddingColumns % 4)
            }
            $markerEnd++
        }
        if ($paddingColumns -gt 4) {
            $markerEnd = $paddingStart + 1
        }
        $hasListMarker = $true
        $listContentStart = $markerEnd
        $listIndent = [int]$indent.Columns +
            ($paddingStart - $markerStart) +
            [Math]::Min($paddingColumns, 4)
    }

    return [pscustomobject]@{
        QuoteDepth          = [int]$blockquote.Depth
        QuoteContentStart   = $containerStart
        LeadingIndent       = [int]$indent.Columns
        FirstNonWhitespace  = [int]$indent.Index
        HasListMarker       = $hasListMarker
        ListContentStart    = $listContentStart
        ListIndent          = $listIndent
        IsBlank             = [int]$indent.Index -ge $End
    }
}

function Get-MarkdownFence {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][int] $Start,
        [Parameter(Mandatory)][int] $End,
        [char] $ExpectedCharacter = [char]0,
        [int] $MinimumLength = 3,
        [switch] $Closing
    )

    $indent = Get-MarkdownIndent -Line $Line -Start $Start -End $End
    if ($indent.Columns -gt 3 -or $indent.Index -ge $End) {
        return $null
    }

    $index = [int]$indent.Index
    $fenceCharacter = $Line[$index]
    if (($ExpectedCharacter -ne [char]0 -and $fenceCharacter -ne $ExpectedCharacter) -or
        $fenceCharacter -notin @([char]0x60, '~')) {
        return $null
    }

    $fenceStart = $index
    while ($index -lt $End -and $Line[$index] -eq $fenceCharacter) {
        $index++
    }
    $fenceLength = $index - $fenceStart
    if ($fenceLength -lt $MinimumLength) {
        return $null
    }

    if ($Closing) {
        while ($index -lt $End) {
            if ($Line[$index] -notin @(' ', "`t")) {
                return $null
            }
            $index++
        }
    }
    elseif ($fenceCharacter -eq [char]0x60) {
        while ($index -lt $End) {
            if ($Line[$index] -eq [char]0x60) {
                return $null
            }
            $index++
        }
    }

    return [pscustomobject]@{
        Character = $fenceCharacter
        Length    = $fenceLength
    }
}

function ConvertTo-RenderedMarkdownView {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    if ($Readme.Length -gt $script:MaxReadmeCharacters) {
        throw "$ReadmeName exceeds the maximum supported README size of $script:MaxReadmeCharacters characters."
    }

    $operationLimit = [Math]::Max(
        4096,
        [long]$Readme.Length * $script:MarkdownParserOperationsPerCharacter)
    $state = [pscustomobject]@{
        ReadmeName     = $ReadmeName
        Operations     = [long]0
        OperationLimit = $operationLimit
    }
    $characters = $Readme.ToCharArray()
    $lineStarts = [System.Collections.Generic.List[int]]::new()
    $lineStarts.Add(0)
    $fenceCharacter = [char]0
    $fenceLength = 0
    $fenceQuoteDepth = 0
    $fenceListIndent = 0
    $activeListQuoteDepth = -1
    $activeListIndent = 0
    $paragraphActive = $false
    $indentedCodeActive = $false
    $indentedCodeQuoteDepth = 0
    $indentedCodeListIndent = 0
    $lineStart = 0
    $blockScanOperations = 0

    while ($lineStart -le $Readme.Length) {
        $lineEnd = $Readme.IndexOf("`n", $lineStart, [System.StringComparison]::Ordinal)
        if ($lineEnd -lt 0) {
            $lineEnd = $Readme.Length
        }
        $contentEnd = $lineEnd
        if ($contentEnd -gt $lineStart -and $Readme[$contentEnd - 1] -eq "`r") {
            $contentEnd--
        }
        $line = $Readme.Substring($lineStart, $contentEnd - $lineStart)
        $lineLength = $line.Length
        $structure = Get-MarkdownLineStructure -Line $line -End $lineLength
        $blockScanOperations += $line.Length + 1
        $hideLine = $false
        $processedAsFence = $false

        if ($fenceCharacter -ne [char]0) {
            $requiredQuote = Get-MarkdownBlockquotePrefix `
                -Line $line `
                -End $lineLength `
                -RequiredDepth $fenceQuoteDepth
            $fenceContentStart = -1
            if ($null -ne $requiredQuote) {
                $fenceContentStart = [int]$requiredQuote.Index
                if ($fenceListIndent -gt 0) {
                    $indent = Get-MarkdownIndent `
                        -Line $line `
                        -Start $fenceContentStart `
                        -End $lineLength
                    if ($indent.Index -ge $lineLength) {
                        $fenceContentStart = $lineLength
                    }
                    elseif ($indent.Columns -lt $fenceListIndent) {
                        $fenceContentStart = -1
                    }
                    else {
                        $fenceContentStart = Get-MarkdownIndexAfterIndent `
                            -Line $line `
                            -Start $fenceContentStart `
                            -End $lineLength `
                            -RequiredColumns $fenceListIndent
                    }
                }
            }

            if ($fenceContentStart -ge 0) {
                $hideLine = $true
                $processedAsFence = $true
                $closingFence = Get-MarkdownFence `
                    -Line $line `
                    -Start $fenceContentStart `
                    -End $lineLength `
                    -ExpectedCharacter $fenceCharacter `
                    -MinimumLength $fenceLength `
                    -Closing
                if ($null -ne $closingFence) {
                    $fenceCharacter = [char]0
                    $fenceLength = 0
                    $fenceQuoteDepth = 0
                    $fenceListIndent = 0
                }
            }
            else {
                $fenceCharacter = [char]0
                $fenceLength = 0
                $fenceQuoteDepth = 0
                $fenceListIndent = 0
            }
        }

        if (-not $processedAsFence) {
            $currentListIndent = 0
            $effectiveContentStart = [int]$structure.QuoteContentStart
            if ($structure.HasListMarker) {
                $currentListIndent = [int]$structure.ListIndent
                $effectiveContentStart = [int]$structure.ListContentStart
                $activeListQuoteDepth = [int]$structure.QuoteDepth
                $activeListIndent = $currentListIndent
            }
            elseif ($activeListIndent -gt 0 -and
                $activeListQuoteDepth -eq [int]$structure.QuoteDepth) {
                if ($structure.IsBlank) {
                    $currentListIndent = $activeListIndent
                    $effectiveContentStart = $lineLength
                }
                elseif ($structure.LeadingIndent -ge $activeListIndent) {
                    $currentListIndent = $activeListIndent
                    $effectiveContentStart = Get-MarkdownIndexAfterIndent `
                        -Line $line `
                        -Start ([int]$structure.QuoteContentStart) `
                        -End $lineLength `
                        -RequiredColumns $activeListIndent
                }
                else {
                    $activeListQuoteDepth = -1
                    $activeListIndent = 0
                }
            }
            elseif (-not $structure.IsBlank) {
                $activeListQuoteDepth = -1
                $activeListIndent = 0
            }

            $openingFence = Get-MarkdownFence `
                -Line $line `
                -Start $effectiveContentStart `
                -End $lineLength
            if ($null -ne $openingFence) {
                $hideLine = $true
                $fenceCharacter = $openingFence.Character
                $fenceLength = $openingFence.Length
                $fenceQuoteDepth = [int]$structure.QuoteDepth
                $fenceListIndent = $currentListIndent
                $paragraphActive = $false
                $indentedCodeActive = $false
            }
            else {
                $contentIndent = Get-MarkdownIndent `
                    -Line $line `
                    -Start $effectiveContentStart `
                    -End $lineLength
                $isBlank = $contentIndent.Index -ge $lineLength

                if ($indentedCodeActive) {
                    $sameIndentedContainer =
                        $indentedCodeQuoteDepth -eq [int]$structure.QuoteDepth -and
                        $indentedCodeListIndent -eq $currentListIndent
                    if ($sameIndentedContainer -and
                        ($isBlank -or $contentIndent.Columns -ge 4)) {
                        $hideLine = $true
                    }
                    else {
                        $indentedCodeActive = $false
                    }
                }

                if (-not $hideLine) {
                    if ($isBlank) {
                        $paragraphActive = $false
                    }
                    elseif ($contentIndent.Columns -ge 4 -and -not $paragraphActive) {
                        $hideLine = $true
                        $indentedCodeActive = $true
                        $indentedCodeQuoteDepth = [int]$structure.QuoteDepth
                        $indentedCodeListIndent = $currentListIndent
                    }
                    else {
                        $paragraphActive = $true
                    }
                }
            }
        }

        if ($hideLine) {
            Set-MarkdownHiddenRange `
                -Characters $characters `
                -Start $lineStart `
                -EndExclusive $contentEnd
        }

        if ($lineEnd -ge $Readme.Length) {
            break
        }
        $lineStart = $lineEnd + 1
        $lineStarts.Add($lineStart)
    }
    Add-MarkdownParserOperations -State $state -Count $blockScanOperations

    $blockVisibleText = -join $characters
    $nextBacktickRun = @{}
    $lastBacktickRunByLength = @{}
    $index = 0
    $backtickScanOperations = 0
    while ($index -lt $blockVisibleText.Length) {
        $backtickScanOperations++
        if ($blockVisibleText[$index] -ne [char]0x60 -or
            (Test-MarkdownCharacterEscaped -Text $blockVisibleText -Index $index)) {
            $index++
            continue
        }

        $runStart = $index
        while ($index -lt $blockVisibleText.Length -and
            $blockVisibleText[$index] -eq [char]0x60) {
            $index++
            $backtickScanOperations++
        }
        $runLength = $index - $runStart
        if ($lastBacktickRunByLength.ContainsKey($runLength)) {
            $nextBacktickRun[[int]$lastBacktickRunByLength[$runLength]] = $runStart
        }
        $lastBacktickRunByLength[$runLength] = $runStart
    }
    Add-MarkdownParserOperations -State $state -Count $backtickScanOperations

    $index = 0
    $inlineScanOperations = 0
    while ($index -lt $blockVisibleText.Length) {
        $inlineScanOperations++
        $isCommentStart =
            $index + 3 -lt $blockVisibleText.Length -and
            $blockVisibleText[$index] -eq '<' -and
            $blockVisibleText[$index + 1] -eq '!' -and
            $blockVisibleText[$index + 2] -eq '-' -and
            $blockVisibleText[$index + 3] -eq '-'
        if ($isCommentStart -and
            -not (Test-MarkdownCharacterEscaped -Text $blockVisibleText -Index $index)) {
            $commentContentStart = $index + 4
            $invalidOpener =
                ($commentContentStart -lt $blockVisibleText.Length -and
                    $blockVisibleText[$commentContentStart] -eq '>') -or
                ($commentContentStart + 1 -lt $blockVisibleText.Length -and
                    $blockVisibleText[$commentContentStart] -eq '-' -and
                    $blockVisibleText[$commentContentStart + 1] -eq '>')
            if (-not $invalidOpener) {
                $commentEnd = $commentContentStart
                while ($commentEnd + 2 -lt $blockVisibleText.Length -and
                    -not ($blockVisibleText[$commentEnd] -eq '-' -and
                        $blockVisibleText[$commentEnd + 1] -eq '-' -and
                        $blockVisibleText[$commentEnd + 2] -eq '>')) {
                    $commentEnd++
                    $inlineScanOperations++
                }
                $endExclusive = if ($commentEnd + 2 -ge $blockVisibleText.Length) {
                    $blockVisibleText.Length
                }
                else {
                    $commentEnd + 3
                }
                Set-MarkdownHiddenRange `
                    -Characters $characters `
                    -Start $index `
                    -EndExclusive $endExclusive
                $inlineScanOperations += $endExclusive - $index
                $index = $endExclusive
                continue
            }
        }

        if ($blockVisibleText[$index] -eq [char]0x60 -and
            -not (Test-MarkdownCharacterEscaped -Text $blockVisibleText -Index $index)) {
            $runStart = $index
            while ($index -lt $blockVisibleText.Length -and
                $blockVisibleText[$index] -eq [char]0x60) {
                $index++
            }
            if ($nextBacktickRun.ContainsKey($runStart)) {
                $closingRunStart = [int]$nextBacktickRun[$runStart]
                $runLength = $index - $runStart
                $endExclusive = $closingRunStart + $runLength
                Set-MarkdownHiddenRange `
                    -Characters $characters `
                    -Start $runStart `
                    -EndExclusive $endExclusive
                $inlineScanOperations += $endExclusive - $runStart
                $index = $endExclusive
            }
            continue
        }
        $index++
    }
    Add-MarkdownParserOperations -State $state -Count $inlineScanOperations

    return [pscustomobject]@{
        Text       = -join $characters
        LineStarts = $lineStarts
        State      = $state
    }
}

function Get-MarkdownLocation {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[int]] $LineStarts,
        [Parameter(Mandatory)][int] $Index
    )

    $low = 0
    $high = $LineStarts.Count - 1
    while ($low -le $high) {
        $middle = [int](($low + $high) / 2)
        if ($LineStarts[$middle] -le $Index) {
            $low = $middle + 1
        }
        else {
            $high = $middle - 1
        }
    }
    $lineIndex = [Math]::Max(0, $high)
    return "line $($lineIndex + 1), column $($Index - $LineStarts[$lineIndex] + 1)"
}

function Get-MarkdownDelimiterMaps {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][pscustomobject] $State,
        [Parameter(Mandatory)][System.Collections.Generic.List[int]] $LineStarts
    )

    $bracketStack = [System.Collections.Generic.Stack[int]]::new()
    $parenthesisStack = [System.Collections.Generic.Stack[int]]::new()
    $bracketPairs = @{}
    $parenthesisPairs = @{}
    $operations = 0

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $operations++
        if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
            $index++
            $operations++
            continue
        }

        switch ($Text[$index]) {
            '[' {
                if ($bracketStack.Count -ge $script:MaxMarkdownDelimiterNesting) {
                    $location = Get-MarkdownLocation -LineStarts $LineStarts -Index $index
                    throw "$($State.ReadmeName) exceeds the Markdown bracket nesting limit at $location."
                }
                $bracketStack.Push($index)
            }
            ']' {
                if ($bracketStack.Count -gt 0) {
                    $openIndex = $bracketStack.Pop()
                    $bracketPairs[$openIndex] = $index
                }
            }
            '(' {
                if ($parenthesisStack.Count -ge $script:MaxMarkdownDelimiterNesting) {
                    $location = Get-MarkdownLocation -LineStarts $LineStarts -Index $index
                    throw "$($State.ReadmeName) exceeds the Markdown parenthesis nesting limit at $location."
                }
                $parenthesisStack.Push($index)
            }
            ')' {
                if ($parenthesisStack.Count -gt 0) {
                    $openIndex = $parenthesisStack.Pop()
                    $parenthesisPairs[$openIndex] = $index
                }
            }
        }
    }
    Add-MarkdownParserOperations -State $State -Count $operations

    return [pscustomobject]@{
        Brackets    = $bracketPairs
        Parentheses = $parenthesisPairs
    }
}

function Read-MarkdownInlineTarget {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $OpenParenthesisIndex,
        [Parameter(Mandatory)][hashtable] $ParenthesisPairs,
        [Parameter(Mandatory)][pscustomobject] $State
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
    if (-not $ParenthesisPairs.ContainsKey($OpenParenthesisIndex)) {
        return & $failure 'missing closing parenthesis'
    }

    $closingParenthesisIndex = [int]$ParenthesisPairs[$OpenParenthesisIndex]
    $index = $OpenParenthesisIndex + 1
    $operations = 0
    while ($index -lt $closingParenthesisIndex -and [char]::IsWhiteSpace($Text[$index])) {
        $index++
        $operations++
    }
    if ($index -ge $closingParenthesisIndex) {
        Add-MarkdownParserOperations -State $State -Count $operations
        return & $failure 'missing target and closing parenthesis'
    }

    if ($Text[$index] -eq '<') {
        $targetStart = ++$index
        while ($index -lt $closingParenthesisIndex -and $Text[$index] -ne '>') {
            $operations++
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $closingParenthesisIndex) {
            Add-MarkdownParserOperations -State $State -Count $operations
            return & $failure 'unterminated angle-bracket target'
        }
        $target = $Text.Substring($targetStart, $index - $targetStart)
        $index++
    }
    else {
        $targetStart = $index
        $parenthesisDepth = 0
        while ($index -lt $closingParenthesisIndex) {
            $operations++
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
        Add-MarkdownParserOperations -State $State -Count $operations
        return & $failure 'empty target'
    }
    $hadTrailingWhitespace = $false
    while ($index -lt $closingParenthesisIndex -and [char]::IsWhiteSpace($Text[$index])) {
        $hadTrailingWhitespace = $true
        $index++
        $operations++
    }
    if ($hadTrailingWhitespace -and $index -lt $closingParenthesisIndex -and
        $Text[$index] -in @('"', "'", '(')) {
        $titleOpen = $Text[$index]
        $titleClose = if ($titleOpen -eq '(') { ')' } else { $titleOpen }
        $index++
        while ($index -lt $closingParenthesisIndex -and $Text[$index] -ne $titleClose) {
            $operations++
            if ($Text[$index] -eq '\' -and $index + 1 -lt $Text.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $closingParenthesisIndex) {
            Add-MarkdownParserOperations -State $State -Count $operations
            return & $failure 'unterminated target title'
        }
        $index++
        while ($index -lt $closingParenthesisIndex -and [char]::IsWhiteSpace($Text[$index])) {
            $index++
            $operations++
        }
    }
    Add-MarkdownParserOperations -State $State -Count $operations
    if ($index -ne $closingParenthesisIndex) {
        return & $failure 'missing closing parenthesis or target contains unescaped whitespace'
    }

    return [pscustomobject]@{
        Success  = $true
        Value    = $target
        EndIndex = $closingParenthesisIndex
        Error    = ''
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

function Get-NormalizedMarkdownReferenceLabel {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Label)

    $unescaped = (ConvertFrom-MarkdownBackslashEscapes -Value $Label).Trim()
    return ([regex]::Replace($unescaped, '\s+', ' ')).ToLowerInvariant()
}

function Read-MarkdownTarget {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $StartIndex,
        [Parameter(Mandatory)][AllowEmptyString()][string] $FallbackLabel,
        [Parameter(Mandatory)][hashtable] $BracketPairs,
        [Parameter(Mandatory)][hashtable] $ParenthesisPairs,
        [Parameter(Mandatory)][pscustomobject] $State
    )

    $index = $StartIndex
    while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) {
        $index++
    }

    if ($index -lt $Text.Length -and $Text[$index] -eq '(') {
        $inlineTarget = Read-MarkdownInlineTarget `
            -Text $Text `
            -OpenParenthesisIndex $index `
            -ParenthesisPairs $ParenthesisPairs `
            -State $State
        return [pscustomobject]@{
            Success  = $inlineTarget.Success
            Kind     = 'Inline'
            Value    = $inlineTarget.Value
            Label    = ''
            EndIndex = $inlineTarget.EndIndex
            Error    = $inlineTarget.Error
        }
    }

    if ($index -lt $Text.Length -and $Text[$index] -eq '[') {
        if (-not $BracketPairs.ContainsKey($index)) {
            return [pscustomobject]@{
                Success  = $false
                Kind     = 'Reference'
                Value    = ''
                Label    = ''
                EndIndex = -1
                Error    = 'unterminated reference label'
            }
        }
        $referenceClose = [int]$BracketPairs[$index]

        $label = $Text.Substring($index + 1, $referenceClose - $index - 1)
        if ([string]::IsNullOrEmpty($label)) {
            $label = $FallbackLabel
        }
        $normalizedLabel = Get-NormalizedMarkdownReferenceLabel -Label $label
        return [pscustomobject]@{
            Success  = -not [string]::IsNullOrEmpty($normalizedLabel)
            Kind     = 'Reference'
            Value    = ''
            Label    = $normalizedLabel
            EndIndex = $referenceClose
            Error    = if ([string]::IsNullOrEmpty($normalizedLabel)) {
                'empty reference label'
            }
            else {
                ''
            }
        }
    }

    $shortcutLabel = Get-NormalizedMarkdownReferenceLabel -Label $FallbackLabel
    return [pscustomobject]@{
        Success  = -not [string]::IsNullOrEmpty($shortcutLabel)
        Kind     = 'Reference'
        Value    = ''
        Label    = $shortcutLabel
        EndIndex = $StartIndex - 1
        Error    = if ([string]::IsNullOrEmpty($shortcutLabel)) {
            'empty shortcut reference label'
        }
        else {
            ''
        }
    }
}

function Read-MarkdownReferenceDefinitionTarget {
    param(
        [Parameter(Mandatory)][string] $TargetText,
        [Parameter(Mandatory)][pscustomobject] $State
    )

    $failure = {
        param([string] $Message)

        return [pscustomobject]@{
            Success = $false
            Value   = ''
            Error   = $Message
        }
    }

    $index = 0
    $operations = 0
    while ($index -lt $TargetText.Length -and [char]::IsWhiteSpace($TargetText[$index])) {
        $index++
        $operations++
    }
    if ($index -ge $TargetText.Length) {
        Add-MarkdownParserOperations -State $State -Count $operations
        return & $failure 'empty reference target'
    }

    if ($TargetText[$index] -eq '<') {
        $targetStart = ++$index
        while ($index -lt $TargetText.Length -and $TargetText[$index] -ne '>') {
            $operations++
            if ($TargetText[$index] -eq '\' -and $index + 1 -lt $TargetText.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $TargetText.Length) {
            Add-MarkdownParserOperations -State $State -Count $operations
            return & $failure 'unterminated angle-bracket target'
        }
        $target = $TargetText.Substring($targetStart, $index - $targetStart)
        $index++
    }
    else {
        $targetStart = $index
        while ($index -lt $TargetText.Length -and
            -not [char]::IsWhiteSpace($TargetText[$index])) {
            $operations++
            if ($TargetText[$index] -eq '\' -and $index + 1 -lt $TargetText.Length) {
                $index += 2
                continue
            }
            $index++
        }
        $target = $TargetText.Substring($targetStart, $index - $targetStart)
    }

    if ([string]::IsNullOrEmpty($target)) {
        Add-MarkdownParserOperations -State $State -Count $operations
        return & $failure 'empty reference target'
    }

    while ($index -lt $TargetText.Length -and [char]::IsWhiteSpace($TargetText[$index])) {
        $index++
        $operations++
    }
    if ($index -lt $TargetText.Length) {
        if ($TargetText[$index] -notin @('"', "'", '(')) {
            Add-MarkdownParserOperations -State $State -Count $operations
            return & $failure 'unsupported reference definition content'
        }
        $titleOpen = $TargetText[$index]
        $titleClose = if ($titleOpen -eq '(') { ')' } else { $titleOpen }
        $index++
        while ($index -lt $TargetText.Length -and $TargetText[$index] -ne $titleClose) {
            $operations++
            if ($TargetText[$index] -eq '\' -and $index + 1 -lt $TargetText.Length) {
                $index += 2
                continue
            }
            $index++
        }
        if ($index -ge $TargetText.Length) {
            Add-MarkdownParserOperations -State $State -Count $operations
            return & $failure 'unterminated reference title'
        }
        $index++
        while ($index -lt $TargetText.Length -and [char]::IsWhiteSpace($TargetText[$index])) {
            $index++
            $operations++
        }
    }
    Add-MarkdownParserOperations -State $State -Count $operations

    if ($index -ne $TargetText.Length) {
        return & $failure 'unsupported reference definition content'
    }
    return [pscustomobject]@{
        Success = $true
        Value   = $target
        Error   = ''
    }
}

function Get-MarkdownReferenceDefinitions {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][hashtable] $BracketPairs,
        [Parameter(Mandatory)][pscustomobject] $State
    )

    $definitions = @{}
    $lineStart = 0
    $operations = 0
    while ($lineStart -le $Readme.Length) {
        $lineEnd = $Readme.IndexOf("`n", $lineStart, [System.StringComparison]::Ordinal)
        if ($lineEnd -lt 0) {
            $lineEnd = $Readme.Length
        }
        $line = $Readme.Substring($lineStart, $lineEnd - $lineStart).TrimEnd("`r")
        $operations += $line.Length + 1
        $index = 0
        while ($index -lt $line.Length -and $index -lt 4 -and $line[$index] -eq ' ') {
            $index++
        }

        if ($index -le 3 -and $index -lt $line.Length -and $line[$index] -eq '[') {
            $absoluteOpen = $lineStart + $index
            $absoluteClose = if ($BracketPairs.ContainsKey($absoluteOpen)) {
                [int]$BracketPairs[$absoluteOpen]
            }
            else {
                -1
            }
            $labelClose = $absoluteClose - $lineStart
            if ($labelClose -gt $index -and $absoluteClose -le $lineStart + $line.Length -and
                $labelClose + 1 -lt $line.Length -and
                $line[$labelClose + 1] -eq ':') {
                $label = Get-NormalizedMarkdownReferenceLabel `
                    -Label $line.Substring($index + 1, $labelClose - $index - 1)
                if (-not [string]::IsNullOrEmpty($label)) {
                    $targetText = $line.Substring($labelClose + 2)
                    $target = Read-MarkdownReferenceDefinitionTarget `
                        -TargetText $targetText `
                        -State $State
                    $entry = [pscustomobject]@{
                        Success = $target.Success
                        Value   = if ($target.Success) { [string]$target.Value } else { '' }
                        Error   = if ($target.Success) { '' } else { [string]$target.Error }
                        Start   = $lineStart
                        End     = if ($lineEnd -lt $Readme.Length) { $lineEnd } else { $lineEnd - 1 }
                    }
                    if (-not $definitions.ContainsKey($label)) {
                        $definitions[$label] = [System.Collections.Generic.List[object]]::new()
                    }
                    $definitions[$label].Add($entry)
                }
            }
        }

        if ($lineEnd -ge $Readme.Length) {
            break
        }
        $lineStart = $lineEnd + 1
    }
    Add-MarkdownParserOperations -State $State -Count $operations

    return $definitions
}

function Resolve-MarkdownReference {
    param(
        [Parameter(Mandatory)][hashtable] $Definitions,
        [Parameter(Mandatory)][string] $Label
    )

    if (-not $Definitions.ContainsKey($Label)) {
        return [pscustomobject]@{
            Status  = 'Unresolved'
            Value   = ''
            Entries = @()
        }
    }

    $entries = @($Definitions[$Label])
    if ($entries.Count -ne 1) {
        return [pscustomobject]@{
            Status  = 'Duplicate'
            Value   = ''
            Entries = $entries
        }
    }
    if (-not $entries[0].Success) {
        return [pscustomobject]@{
            Status  = 'Malformed'
            Value   = ''
            Entries = $entries
        }
    }

    return [pscustomobject]@{
        Status  = 'Resolved'
        Value   = [string]$entries[0].Value
        Entries = $entries
    }
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
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][pscustomobject] $State
    )

    $tokens = [System.Collections.Generic.List[object]]::new()
    $index = 0
    $operations = 0
    while ($index -lt $Text.Length) {
        $operations++
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
            $operations++
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
            $operations++
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
    Add-MarkdownParserOperations -State $State -Count $operations
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
        [Parameter(Mandatory)][string] $BadgeSource,
        [Parameter(Mandatory)][string] $Description
    )

    $badgePattern = '^https://raw\.githubusercontent\.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure\.svg(?:\?sanitize=true)?$'
    if ($BadgeSource -cnotmatch $badgePattern) {
        throw "$Description must use the exact official Deploy-to-Azure badge image URL."
    }
}

function Get-ReadmeDeploymentParseResult {
    param(
        [Parameter(Mandatory)][string] $Readme,
        [Parameter(Mandatory)][string] $ReadmeName
    )

    $renderedView = ConvertTo-RenderedMarkdownView `
        -Readme $Readme `
        -ReadmeName $ReadmeName
    $state = $renderedView.State
    $renderedText = [string]$renderedView.Text
    $htmlTokens = @(Get-HtmlTagTokens -Text $renderedText -State $state)
    $markdownCharacters = $renderedText.ToCharArray()
    $htmlMaskOperations = 0
    foreach ($token in $htmlTokens) {
        Set-MarkdownHiddenRange `
            -Characters $markdownCharacters `
            -Start ([int]$token.Start) `
            -EndExclusive ([int]$token.End + 1)
        $htmlMaskOperations += [int]$token.End - [int]$token.Start + 1
    }
    Add-MarkdownParserOperations -State $state -Count $htmlMaskOperations
    $markdownText = -join $markdownCharacters
    $delimiterMaps = Get-MarkdownDelimiterMaps `
        -Text $markdownText `
        -State $state `
        -LineStarts $renderedView.LineStarts
    $definitions = Get-MarkdownReferenceDefinitions `
        -Readme $markdownText `
        -BracketPairs $delimiterMaps.Brackets `
        -State $state
    $deploymentLinks = [System.Collections.Generic.List[object]]::new()
    $handledSpans = [System.Collections.Generic.List[object]]::new()
    $markdownScanOperations = 0
    for ($imageStart = 0; $imageStart + 1 -lt $markdownText.Length; $imageStart++) {
        $markdownScanOperations++
        if ($markdownText[$imageStart] -ne '!' -or
            $markdownText[$imageStart + 1] -ne '[' -or
            (Test-MarkdownCharacterEscaped -Text $markdownText -Index $imageStart)) {
            continue
        }

        $altOpen = $imageStart + 1
        if (-not $delimiterMaps.Brackets.ContainsKey($altOpen)) {
            continue
        }
        $altClose = [int]$delimiterMaps.Brackets[$altOpen]

        $altText = $markdownText.Substring($altOpen + 1, $altClose - $altOpen - 1)
        $imageTarget = Read-MarkdownTarget `
            -Text $markdownText `
            -StartIndex ($altClose + 1) `
            -FallbackLabel $altText `
            -BracketPairs $delimiterMaps.Brackets `
            -ParenthesisPairs $delimiterMaps.Parentheses `
            -State $state
        if (-not $imageTarget.Success) {
            continue
        }

        $outerOpen = $imageStart - 1
        while ($outerOpen -ge 0 -and [char]::IsWhiteSpace($markdownText[$outerOpen])) {
            $outerOpen--
            $markdownScanOperations++
        }
        if ($outerOpen -lt 0 -or $markdownText[$outerOpen] -ne '[') {
            $imageStart = [Math]::Max($imageStart, $imageTarget.EndIndex)
            continue
        }

        $outerLabelClose = $imageTarget.EndIndex + 1
        while ($outerLabelClose -lt $markdownText.Length -and
            [char]::IsWhiteSpace($markdownText[$outerLabelClose])) {
            $outerLabelClose++
            $markdownScanOperations++
        }
        if ($outerLabelClose -ge $markdownText.Length -or
            $markdownText[$outerLabelClose] -ne ']' -or
            -not $delimiterMaps.Brackets.ContainsKey($outerOpen) -or
            [int]$delimiterMaps.Brackets[$outerOpen] -ne $outerLabelClose) {
            $imageStart = [Math]::Max($imageStart, $imageTarget.EndIndex)
            continue
        }

        $outerLabel = $markdownText.Substring($outerOpen + 1, $outerLabelClose - $outerOpen - 1)
        $outerTarget = Read-MarkdownTarget `
            -Text $markdownText `
            -StartIndex ($outerLabelClose + 1) `
            -FallbackLabel $outerLabel `
            -BracketPairs $delimiterMaps.Brackets `
            -ParenthesisPairs $delimiterMaps.Parentheses `
            -State $state
        if (-not $outerTarget.Success) {
            $imageStart = $outerLabelClose
            continue
        }

        $imageResolution = if ($imageTarget.Kind -eq 'Inline') {
            [pscustomobject]@{
                Status  = 'Resolved'
                Value   = [string]$imageTarget.Value
                Entries = @()
            }
        }
        else {
            Resolve-MarkdownReference -Definitions $definitions -Label $imageTarget.Label
        }
        $outerResolution = if ($outerTarget.Kind -eq 'Inline') {
            [pscustomobject]@{
                Status  = 'Resolved'
                Value   = [string]$outerTarget.Value
                Entries = @()
            }
        }
        else {
            Resolve-MarkdownReference -Definitions $definitions -Label $outerTarget.Label
        }

        $possibleBadgeSources = @(
            if ($imageResolution.Status -eq 'Resolved') {
                [string]$imageResolution.Value
            }
            else {
                $imageResolution.Entries | ForEach-Object { [string]$_.Value }
            }
        )
        $possibleDestinations = @(
            if ($outerResolution.Status -eq 'Resolved') {
                [string]$outerResolution.Value
            }
            else {
                $outerResolution.Entries | ForEach-Object { [string]$_.Value }
            }
        )
        $isDeploymentButton =
            @($possibleBadgeSources | Where-Object {
                    Test-LooksLikeDeployToAzureBadge -Value $_
                }).Count -gt 0 -or
            @($possibleDestinations | Where-Object {
                    Test-LooksLikeAzureDeploymentPortal -Value $_
                }).Count -gt 0

        if ($isDeploymentButton) {
            foreach ($resolution in @(
                    @{ Name = 'image'; Value = $imageResolution },
                    @{ Name = 'destination'; Value = $outerResolution })) {
                if ($resolution.Value.Status -eq 'Unresolved') {
                    throw "$ReadmeName contains a deployment button with unresolved Markdown $($resolution.Name) reference."
                }
                if ($resolution.Value.Status -eq 'Duplicate') {
                    throw "$ReadmeName contains a deployment button with duplicate or ambiguous Markdown $($resolution.Name) reference."
                }
                if ($resolution.Value.Status -eq 'Malformed') {
                    throw "$ReadmeName contains a deployment button with malformed Markdown $($resolution.Name) reference definition."
                }
            }

            $badgeSource = [string]$imageResolution.Value
            $destination = [string]$outerResolution.Value
            $location = Get-MarkdownLocation `
                -LineStarts $renderedView.LineStarts `
                -Index $outerOpen
            $deploymentLinks.Add([pscustomobject]@{
                    BadgeSource = $badgeSource
                    Destination = $destination
                    StartIndex  = $outerOpen
                    Location    = $location
                })
            $handledSpans.Add([pscustomobject]@{
                    Start = $outerOpen
                    End   = $outerTarget.EndIndex
                })
            foreach ($entry in @($imageResolution.Entries + $outerResolution.Entries)) {
                $handledSpans.Add([pscustomobject]@{
                        Start = [int]$entry.Start
                        End   = [int]$entry.End
                    })
            }
        }

        $imageStart = [Math]::Max($imageStart, $outerTarget.EndIndex)
    }
    Add-MarkdownParserOperations -State $state -Count $markdownScanOperations

    $htmlScanOperations = 0
    for ($tokenIndex = 0; $tokenIndex -lt $htmlTokens.Count; $tokenIndex++) {
        $htmlScanOperations++
        $anchorToken = $htmlTokens[$tokenIndex]
        if (-not $anchorToken.Complete -or $anchorToken.Closing -or
            $anchorToken.Name -ne 'a') {
            continue
        }

        $anchor = Read-HtmlTag `
            -Text $renderedText `
            -StartIndex ([int]$anchorToken.Start) `
            -ExpectedName 'a'
        $htmlScanOperations += [int]$anchorToken.End - [int]$anchorToken.Start + 1
        if (-not $anchor.Success) {
            continue
        }

        $href = [string]$anchor.Attributes['href']
        $imageToken = if ($tokenIndex + 1 -lt $htmlTokens.Count) {
            $htmlTokens[$tokenIndex + 1]
        }
        else {
            $null
        }
        $imageGapIsWhitespace = $null -ne $imageToken
        if ($imageGapIsWhitespace) {
            for ($index = $anchor.EndIndex + 1; $index -lt [int]$imageToken.Start; $index++) {
                    $htmlScanOperations++
                    if (-not [char]::IsWhiteSpace($renderedText[$index])) {
                        $imageGapIsWhitespace = $false
                        break
                    }
            }
        }

        $image = if ($imageGapIsWhitespace -and $imageToken.Complete -and
            -not $imageToken.Closing -and $imageToken.Name -eq 'img') {
            Read-HtmlTag `
                    -Text $renderedText `
                    -StartIndex ([int]$imageToken.Start) `
                    -ExpectedName 'img'
        }
        else {
            $null
        }
        if ($null -ne $imageToken) {
            $htmlScanOperations += [int]$imageToken.End - [int]$imageToken.Start + 1
        }
        $source = if ($null -ne $image -and $image.Success) {
            [string]$image.Attributes['src']
        }
        else {
            ''
        }

        $closingToken = if ($tokenIndex + 2 -lt $htmlTokens.Count) {
            $htmlTokens[$tokenIndex + 2]
        }
        else {
            $null
        }
        $closingGapIsWhitespace = $null -ne $image -and $image.Success -and
            $null -ne $closingToken
        if ($closingGapIsWhitespace) {
            for ($index = $image.EndIndex + 1; $index -lt [int]$closingToken.Start; $index++) {
                    $htmlScanOperations++
                    if (-not [char]::IsWhiteSpace($renderedText[$index])) {
                        $closingGapIsWhitespace = $false
                        break
                    }
            }
        }
        $closingAnchor = if ($closingGapIsWhitespace -and $closingToken.Complete -and
            $closingToken.Closing -and $closingToken.Name -eq 'a') {
            Read-HtmlTag `
                    -Text $renderedText `
                    -StartIndex ([int]$closingToken.Start) `
                    -ExpectedName 'a' `
                    -Closing
        }
        else {
            $null
        }
        if ($null -ne $closingToken) {
            $htmlScanOperations += [int]$closingToken.End - [int]$closingToken.Start + 1
        }

        $isDeploymentButton =
            (Test-LooksLikeAzureDeploymentPortal -Value $href) -or
            (Test-LooksLikeDeployToAzureBadge -Value $source)
        if (-not $isDeploymentButton) {
            continue
        }
        if ($null -eq $image -or -not $image.Success -or
            $null -eq $closingAnchor -or -not $closingAnchor.Success) {
            throw "$ReadmeName contains a malformed HTML deployment button."
        }
        if ($anchor.SelfClosing -or $closingAnchor.SelfClosing) {
            throw "$ReadmeName contains invalid HTML anchor nesting for a deployment button."
        }
        if (-not $anchor.Attributes.ContainsKey('href') -or
            -not $image.Attributes.ContainsKey('src')) {
            throw "$ReadmeName HTML deployment button must contain href and src attributes."
        }

        Assert-SafeDeploymentHtml `
            -AnchorAttributes $anchor.Attributes `
            -ImageAttributes $image.Attributes `
            -Description "$ReadmeName HTML deployment button"
        $deploymentLinks.Add([pscustomobject]@{
                BadgeSource = $source
                Destination = $href
                StartIndex  = [int]$anchorToken.Start
                Location    = Get-MarkdownLocation `
                    -LineStarts $renderedView.LineStarts `
                    -Index ([int]$anchorToken.Start)
            })
        $handledSpans.Add([pscustomobject]@{
                Start = [int]$anchorToken.Start
                End   = $closingAnchor.EndIndex
            })
        $tokenIndex += 2
    }
    Add-MarkdownParserOperations -State $state -Count $htmlScanOperations

    $remainingCharacters = $renderedText.ToCharArray()
    $handledMaskOperations = 0
    foreach ($span in $handledSpans) {
        if ($span.Start -lt 0 -or $span.End -lt $span.Start) {
            continue
        }
        Set-MarkdownHiddenRange `
            -Characters $remainingCharacters `
            -Start ([int]$span.Start) `
            -EndExclusive ([int]$span.End + 1)
        $handledMaskOperations += [int]$span.End - [int]$span.Start + 1
    }
    Add-MarkdownParserOperations -State $state -Count $handledMaskOperations
    $unhandled = -join $remainingCharacters
    if ((Test-LooksLikeDeployToAzureBadge -Value $unhandled) -or
        (Test-LooksLikeAzureDeploymentPortal -Value $unhandled)) {
        throw "$ReadmeName contains an unsupported or malformed deployment-button construct."
    }

    if ($deploymentLinks.Count -eq 0) {
        throw "$ReadmeName contains no recognized Deploy-to-Azure Markdown or HTML image-links."
    }

    return [pscustomobject]@{
        Links          = @($deploymentLinks)
        OperationCount = [long]$state.Operations
        OperationLimit = [long]$state.OperationLimit
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
    function Assert-ParserOperationBound {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][string] $Readme,
            [Parameter(Mandatory)][int] $ExpectedCount
        )

        $result = Get-ReadmeDeploymentParseResult `
            -Readme $Readme `
            -ReadmeName $Name
        if ($result.Links.Count -ne $ExpectedCount) {
            throw "$Name discovered $($result.Links.Count) buttons; expected $ExpectedCount."
        }
        $conservativeBound = [long]$Readme.Length * 20 + 4096
        if ($result.OperationCount -gt $conservativeBound) {
            throw "$Name used $($result.OperationCount) parser operations; bound was $conservativeBound."
        }
        Write-Host "Passed: $Name used $($result.OperationCount) bounded parser operations for $($Readme.Length) characters."
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

        $sizes = @(7680, 14950, 29696, 58982, $script:MaxReadmeCharacters)
        $previousLength = 0
        $previousOperations = [long]0
        $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($size in $sizes) {
            $readme = New-PathologicalCommentReadme `
                -Length $size `
                -RenderedButton $RenderedButton
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Get-ReadmeDeploymentParseResult `
                -Readme $readme `
                -ReadmeName "pathological invalid comment input $size"
            $stopwatch.Stop()

            if ($result.Links.Count -ne 1) {
                throw "Pathological input $size discovered $($result.Links.Count) buttons; expected 1."
            }
            $operationBound = [long]$readme.Length * 20 + 4096
            if ($result.OperationCount -gt $operationBound) {
                throw "Pathological input $size used $($result.OperationCount) operations; bound was $operationBound."
            }
            if ($previousLength -gt 0) {
                $deltaCharacters = $readme.Length - $previousLength
                $deltaOperations = [long]$result.OperationCount - $previousOperations
                if ($deltaOperations -gt ([long]$deltaCharacters * 20 + 4096)) {
                    throw "Pathological parser work grew faster than its deterministic linear bound between $previousLength and $($readme.Length) characters."
                }
            }
            $sanityMilliseconds = if ($size -eq $script:MaxReadmeCharacters) {
                120000
            }
            else {
                30000
            }
            if ($stopwatch.ElapsedMilliseconds -gt $sanityMilliseconds) {
                throw "Pathological input $size took $($stopwatch.ElapsedMilliseconds) ms; sanity bound was $sanityMilliseconds ms."
            }
            Write-Host "Passed: pathological input $size used $($result.OperationCount) operations in $($stopwatch.ElapsedMilliseconds) ms."
            $previousLength = $readme.Length
            $previousOperations = [long]$result.OperationCount
        }
        $totalStopwatch.Stop()
        if ($totalStopwatch.ElapsedMilliseconds -gt 180000) {
            throw "Pathological scaling suite took $($totalStopwatch.ElapsedMilliseconds) ms; sanity bound was 180000 ms."
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

    $unterminatedImages16Kb = ('![x' * 5462) -join ''
    Assert-BoundedParserRejection `
        -Name '16 KB repeated unterminated image delimiters' `
        -Readme $unterminatedImages16Kb `
        -Error 'bracket nesting limit'
    $unterminatedBrackets64Kb = [string]::new('[', 65536)
    Assert-BoundedParserRejection `
        -Name '64 KB repeated unterminated brackets' `
        -Readme $unterminatedBrackets64Kb `
        -Error 'bracket nesting limit'

    $unterminatedBackticks64Kb = (
        1..362 | ForEach-Object {
            [string]::new([char]0x60, $_) + 'x'
        }) -join ''
    Assert-ParserOperationBound `
        -Name '64 KB repeated unterminated backtick runs' `
        -Readme "$validButton`n$unterminatedBackticks64Kb" `
        -ExpectedCount 1
    $unterminatedComments = ('<!--' * 4096) -join ''
    Assert-ParserOperationBound `
        -Name 'repeated unterminated HTML comments' `
        -Readme "$validButton`n$unterminatedComments" `
        -ExpectedCount 1
    $unterminatedFencePayload = ('![x[' * 4096) -join ''
    Assert-ParserOperationBound `
        -Name 'unterminated tilde fence with repeated delimiters' `
        -Readme "$validButton`n~~~ example`n$unterminatedFencePayload" `
        -ExpectedCount 1
    Assert-PathologicalParserScaling -RenderedButton $validButton
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
        },
        @{
            Name = 'full reference badge with attacker destination'
            Readme = "[![Deploy][badge]](<https://example.com/redirect>)`n`n[badge]: <$badge>"
            Error = 'exact .*portal\.azure\.com'
        },
        @{
            Name = 'duplicate case-insensitive badge reference definitions'
            Readme = "[![Deploy][badge]]($(New-PortalLink $validTemplateUri))`n`n[badge]: <$badge>`n[BADGE]: <https://example.com/deploy.svg>"
            Error = 'duplicate or ambiguous Markdown image reference'
        },
        @{
            Name = 'unresolved badge reference with portal destination'
            Readme = "[![Deploy][missing]]($(New-PortalLink $validTemplateUri))"
            Error = 'unresolved Markdown image reference'
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
