# Terraform Registry Compatibility

This module is compatible with the Terraform Registry (both public and private).

## Registry Requirements Checklist

✅ **Module Structure**
- `main.tf` - Main module logic
- `variables.tf` - Variable definitions with descriptions
- `outputs.tf` - Output definitions with descriptions
- `README.md` - Comprehensive documentation
- `LICENSE` - MIT License file
- `.gitignore` - Excludes sensitive files

✅ **Examples**
- `examples/windows-gdp-gim/` - Complete working example

✅ **Documentation**
- Comprehensive README.md with:
  - Overview and features
  - Installation instructions
  - Configuration examples
  - Usage examples
  - Troubleshooting guide

## Publishing to Terraform Registry

### Public Terraform Registry

**Requirements:**
1. GitHub repository (public)
2. Repository name format: `terraform-<PROVIDER>-<NAME>` (e.g., `terraform-guardium-gim`)
3. Version tags: `v1.0.0`, `v1.1.0`, etc.
4. LICENSE file (MIT, Apache 2.0, or MPL 2.0)
5. README.md in root
6. Module structure in root or `modules/` subdirectory

**Steps:**
1. Ensure repository follows naming convention
2. Create version tags:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. Sign up at https://registry.terraform.io
4. Publish module via GitHub integration

**Current Status:**
- ✅ Module structure: Compatible
- ✅ README.md: Complete
- ✅ LICENSE: MIT License added
- ⚠️ Repository naming: May need to rename to `terraform-guardium-gim`
- ⚠️ Version tags: Need to create git tags for releases

### Private Terraform Registry

**Requirements:**
1. Terraform Cloud/Enterprise account
2. Module repository (GitHub, GitLab, Bitbucket, or direct upload)
3. Version tags (same as public)

**Steps:**
1. Create Terraform Cloud/Enterprise account
2. Create private module registry
3. Connect repository
4. Create version tags
5. Module will appear in private registry

## Module Usage

### From Public Registry

```hcl
module "guardium_gim" {
  source  = "your-org/guardium-gim/guardium"
  version = "~> 1.0"

  inventory_csv_path = "./inventory/servers.csv"
  gim_server         = "9.80.59.143"
  # ... other variables
}
```

### From Private Registry

```hcl
module "guardium_gim" {
  source  = "app.terraform.io/your-org/guardium-gim/guardium"
  version = "~> 1.0"

  inventory_csv_path = "./inventory/servers.csv"
  gim_server         = "9.80.59.143"
  # ... other variables
}
```

### From Git Repository

```hcl
module "guardium_gim" {
  source = "git::https://github.com/your-org/terraform-guardium-gim.git?ref=v1.0.0"

  inventory_csv_path = "./inventory/servers.csv"
  gim_server         = "9.80.59.143"
  # ... other variables
}
```

## Versioning

Follow [Semantic Versioning](https://semver.org/):
- `MAJOR.MINOR.PATCH` (e.g., `1.0.0`)
- `MAJOR` - Breaking changes
- `MINOR` - New features, backward compatible
- `PATCH` - Bug fixes, backward compatible

**Creating a Release:**
```bash
# Update version in code/docs if needed
git add .
git commit -m "Release v1.0.0"
git tag v1.0.0
git push origin main
git push origin v1.0.0
```

## Module Structure for Registry

The current structure works for registry publication:

```
terraform-guardium-gim/
├── README.md          # Required - comprehensive documentation
├── LICENSE            # Required - MIT License
├── .gitignore         # Recommended
├── main.tf            # Required - module logic
├── variables.tf       # Required - variable definitions
├── outputs.tf         # Required - output definitions
├── scripts/           # Module scripts
│   ├── unix/
│   └── windows/
└── examples/          # Recommended - usage examples
    └── basic/
```

## Notes

- The module uses `null_resource` with `local-exec` provisioners, which is compatible with registry
- Scripts are bundled with the module (no external dependencies)
- Examples directory provides complete working examples
- All variables have descriptions (required for registry)

## Next Steps for Registry Publication

1. **Rename repository** (if needed) to follow naming convention
2. **Create initial version tag:**
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. **Publish to registry:**
   - Public: https://registry.terraform.io (via GitHub)
   - Private: Terraform Cloud/Enterprise
