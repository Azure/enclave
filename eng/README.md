# Generated ARM templates

Run the repository-pinned Bicep compiler from the repository root:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1
```

The script verifies the standalone compiler checksum, builds and lints all Bicep files, regenerates the five published ARM JSON files, and validates their scopes, metadata, mappings, and every README deployment button. A bounded parser discovers inline, full-reference, collapsed-reference, and shortcut-reference Markdown image links plus direct HTML `<a><img></a>` buttons, independent of alt text. Any supported construct containing the official badge or an Azure deployment portal destination is validated; malformed, ambiguous, encoded, or unsupported constructs containing those markers fail closed. The badge and Template URI are then validated structurally and locally without fetching private or public raw GitHub content. Use `-Check` to reproduce the read-only CI drift check.

Run the focused adversarial deployment-link tests with:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1 -TestReadmeDeploymentLinks
```

## Updating Bicep

1. Choose an official [Bicep release](https://github.com/Azure/bicep/releases).
2. Update the exact version and every platform SHA-256 in `arm-template-generation.json` from the release assets' GitHub `digest` values.
3. Run the generator and review the `_generator` version and all artifact changes.
4. Commit the config and all regenerated JSON files together.
