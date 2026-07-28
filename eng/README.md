# Generated ARM templates

Run the repository-pinned Bicep compiler from the repository root:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1
```

The script verifies the standalone compiler checksum, builds and lints all Bicep files, regenerates the five published ARM JSON files, and validates their scopes, metadata, mappings, and every README deployment button. Every top-level Bicep file must map to its generated JSON artifact. Hand-authored `*-createUiDefinition.json` portal forms are explicitly excluded by schema-backed policy; every other top-level JSON file must be a mapped Bicep output, so unexpected deployment artifacts fail validation. Buttons are discovered from the official badge identity or Azure portal destination, independent of alt text; both the badge and Template URI are then validated structurally and locally without fetching private or public raw GitHub content. Use `-Check` to reproduce the read-only CI drift check.

Run the focused adversarial deployment-link tests with:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1 -TestReadmeDeploymentLinks
```

## Updating Bicep

1. Choose an official [Bicep release](https://github.com/Azure/bicep/releases).
2. Update the exact version and every platform SHA-256 in `arm-template-generation.json` from the release assets' GitHub `digest` values.
3. Run the generator and review the `_generator` version and all artifact changes.
4. Commit the config and all regenerated JSON files together.
