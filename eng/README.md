# Generated ARM templates

Run the repository-pinned Bicep compiler from the repository root:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1
```

The script verifies the standalone compiler checksum, builds and lints all Bicep files, regenerates the five published ARM JSON files, and validates their scopes, metadata, mappings, and every README deployment button. Every top-level Bicep file must map to its generated JSON artifact. Hand-authored `*-createUiDefinition.json` portal forms are explicitly excluded by schema-backed policy; every other top-level JSON file must be a mapped Bicep output, so unexpected deployment artifacts fail validation. Deployment-button discovery parses the README with the in-box CommonMark/GFM parser that backs PowerShell's `ConvertFrom-Markdown` cmdlet (Markdig, shipped with PowerShell 7 on the CI runner — no network access and nothing fetched from a public package registry), then walks the resulting rendered token stream rather than masking raw text. It discovers only elements that actually render: inline, full-reference, collapsed-reference, and shortcut-reference Markdown image links, autolinked portal destinations, and direct HTML `<a><img></a>` buttons, independent of alt text. Because the parser is standards-compliant, fenced and indented code, inline code spans of any backtick length, HTML comments (including mid-line and multiline), and reference definitions never contribute rendered links, while paragraph and list continuation content, cross-paragraph text, and post-comment content correctly do. The residual marker backstop inspects that rendered token stream — never masked raw text — so any official badge image or Azure deployment-portal destination that rendered but was not accounted for as a validated button fails closed. README input is capped at 1 MiB, and inputs the parser rejects as pathologically nested also fail closed. Both the badge and Template URI are then validated structurally and locally without fetching private or public raw GitHub content. Use `-Check` to reproduce the read-only CI drift check.

Run the focused adversarial deployment-link tests with:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1 -TestReadmeDeploymentLinks
```

## Updating Bicep

1. Choose an official [Bicep release](https://github.com/Azure/bicep/releases).
2. Update the exact version and every platform SHA-256 in `arm-template-generation.json` from the release assets' GitHub `digest` values.
3. Run the generator and review the `_generator` version and all artifact changes.
4. Commit the config and all regenerated JSON files together.
