# Azure VM Region Migration Script

A Bash script to migrate Azure VMs from one region to another while preserving all configuration, disks, and network settings.

## Features

- Captures complete VM metadata (size, OS type, zones, networking, disk SKUs)
- Creates incremental snapshots of all VM disks (OS and data disks)
- Copies snapshots directly to target region with cross-region replication
- Recreates managed disks with matching storage SKU (Premium_LRS, Standard_LRS, etc.)
- Recreates VM in target region with identical configuration
- Preserves network security groups and public IPs
- Supports availability zones
- Supports multiple data disks with proper LUN mapping
- Preserves VM tags

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Appropriate permissions in source and target subscriptions
- Target VNet and subnet must already exist
- `jq` installed
- Bash 4.0+

## Usage

```bash
./vm-move.sh \
  <VM_URI> \
  <TARGET_REGION> \
  <TARGET_RESOURCE_GROUP> \
  <TARGET_VNET> \
  <TARGET_SUBNET>
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| VM_URI | Yes | Full resource ID of the source VM |
| TARGET_REGION | Yes | Target Azure region (e.g., eastus2, westeurope) |
| TARGET_RESOURCE_GROUP | Yes | Target resource group name |
| TARGET_VNET | Yes | Target virtual network name |
| TARGET_SUBNET | Yes | Target subnet name |

## Example

```bash
./vm-move.sh \
  '/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-source/providers/Microsoft.Compute/virtualMachines/myvm' \
  eastus2 \
  rg-target \
  vnet-target \
  subnet-default
```

## Migration Process

The script performs the following steps:

1. **Extract Source VM Details** - Retrieves subscription, resource group, and VM name from URI
2. **Retrieve VM Metadata** - Captures VM size, OS type, disk SKU, tags, network configuration, and availability zones
3. **Deallocate Source VM** - Stops and deallocates the VM for consistency
4. **Create Snapshots** - Creates incremental snapshots of OS and data disks in the source region
5. **Copy Snapshots to Target** - Uses Azure's cross-region snapshot copy feature
6. **Wait for Copy Completion** - Monitors replication progress and waits for completion
7. **Create Managed Disks** - Creates new managed disks from snapshots with matching storage SKU
8. **Create Network Resources** - Recreates NSG, public IP, and network interface in target region
9. **Create VM** - Creates the VM in target region with identical configuration
10. **Attach Data Disks** - Attaches all data disks with correct LUN assignments## Post-Migration Steps

After the migration completes:

1. Start the target VM:
   ```bash
   az vm start --resource-group <TARGET_RESOURCE_GROUP> --name <VM_NAME>
   ```

2. Verify the VM is working correctly:
   - Connect to the VM
   - Verify all disks are attached and accessible
   - Test applications and services

3. Update DNS records if necessary

4. Clean up source resources after verification:
   - Delete source VM
   - Delete snapshots
   - Delete source disks

## Important Notes

- **Downtime**: The source VM will be deallocated during the migration process for consistency
- **Disk SKU Preservation**: The script automatically detects and recreates disks with the same storage SKU (Premium_LRS, Standard_LRS, etc.)
- **Incremental Snapshots**: Uses incremental snapshots for faster and more efficient copying
- **Network Configuration**: NSG rules may need manual copying for complex configurations
- **VM Extensions**: VM extensions are not migrated and need to be reinstalled
- **Managed Identities**: Managed identities are not preserved and need to be reconfigured
- **Accelerated Networking**: Setting is preserved if available in target VM size

## Troubleshooting

### Script Fails to Run
- Ensure `jq` is installed: `sudo apt-get install jq` (Linux) or `brew install jq` (macOS)
- Verify Azure CLI is authenticated: `az account show`
- Check that VM URI is correctly formatted

### Copy Timeout
Large disks may take considerable time to copy between regions. The script monitors progress and waits automatically.

### NSG Rules Not Copied
NSG creation is attempted, but complex rules may need manual migration. Export the source NSG and recreate rules in the target:
```bash
az network nsg rule list --resource-group <SOURCE_RG> --nsg-name <NSG_NAME> -o json
```

## License

This project is provided as-is for migration purposes.
