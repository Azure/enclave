# Generated ARM templates

Run the repository-pinned Bicep compiler from the repository root:

```powershell
pwsh ./eng/Build-ArmTemplates.ps1
```

The script verifies the standalone compiler checksum, builds and lints all Bicep files, regenerates the five published ARM JSON files, and validates their scopes, metadata, mappings, and README deployment paths. Use `-Check` to reproduce the read-only CI drift check.

## Updating Bicep

1. Choose an official [Bicep release](https://github.com/Azure/bicep/releases).
2. Update the exact version and every platform SHA-256 in `arm-template-generation.json` from the release assets' GitHub `digest` values.
3. Run the generator and review the `_generator` version and all artifact changes.
4. Commit the config and all regenerated JSON files together.
