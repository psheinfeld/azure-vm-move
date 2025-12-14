#!/bin/bash
set -e

# =============================================================================
# Azure VM Region Migration Script
# =============================================================================
# This script migrates a VM from one Azure region to another by:
# 1. Capturing VM metadata
# 2. Creating snapshots of all disks
# 3. Copying snapshots to target region
# 4. Recreating the VM in the target region with identical configuration
# =============================================================================

# Variables - Configure these
VM_URI="$1"  # Full resource ID of the source VM
TARGET_REGION="$2"  # Target region (e.g., eastus2, westeurope)
TARGET_RESOURCE_GROUP="$3"  # Target resource group name
TARGET_VNET="$4"  # Target VNet name
TARGET_SUBNET="$5"  # Target subnet name

# Validate input parameters
if [ -z "$VM_URI" ] || [ -z "$TARGET_REGION" ] || [ -z "$TARGET_RESOURCE_GROUP" ] || [ -z "$TARGET_VNET" ] || [ -z "$TARGET_SUBNET" ]; then
    echo "Usage: $0 <VM_URI> <TARGET_REGION> <TARGET_RESOURCE_GROUP> <TARGET_VNET> <TARGET_SUBNET>"
    echo "Example: $0 '/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1' eastus2 rg-target vnet-target subnet-target"
    exit 1
fi

echo "=== Starting VM Migration ==="
echo "Source VM URI: $VM_URI"
echo "Target Region: $TARGET_REGION"
echo "Target Resource Group: $TARGET_RESOURCE_GROUP"
echo "Target VNet: $TARGET_VNET"
echo "Target Subnet: $TARGET_SUBNET"



# Extract source VM details from URI
SOURCE_SUBSCRIPTION=$(echo "$VM_URI" | sed -n 's|.*/subscriptions/\([^/]*\).*|\1|p')
SOURCE_RG=$(echo "$VM_URI" | sed -n 's|.*/resourceGroups/\([^/]*\).*|\1|p')
SOURCE_VM_NAME=$(echo "$VM_URI" | sed -n 's|.*/virtualMachines/\([^/]*\).*|\1|p')

echo ""
echo "=== Extracted Source Details ==="
echo "Subscription: $SOURCE_SUBSCRIPTION"
echo "Resource Group: $SOURCE_RG"
echo "VM Name: $SOURCE_VM_NAME"

# Set subscription context
CMD="az account set --subscription \"$SOURCE_SUBSCRIPTION\""
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD"

# Step 1: Get VM metadata
echo ""
echo "=== Step 1: Retrieving VM Metadata ==="
CMD="az vm show --ids \"$VM_URI\" --output json"
echo "$(date +%H:%M) : <command>$CMD</command>"
VM_JSON=$(eval "$CMD")
VM_JSON="${VM_JSON//$'\r'/}"

# Extract VM properties
VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
VM_LOCATION=$(echo "$VM_JSON" | jq -r '.location')
OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id')
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')
OS_TYPE=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType')

# Get OS disk SKU
CMD="az disk show --ids \"$OS_DISK_ID\" --query sku.name -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
OS_DISK_SKU=$(eval "$CMD")
OS_DISK_SKU="${OS_DISK_SKU//$'\r'/}"
VM_ZONE=$(echo "$VM_JSON" | jq -r '.zones[0] // empty')
ADMIN_USERNAME=$(echo "$VM_JSON" | jq -r '.osProfile.adminUsername // empty')
COMPUTER_NAME=$(echo "$VM_JSON" | jq -r '.osProfile.computerName // empty')

# Get data disks
DATA_DISK_IDS=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[].managedDisk.id // empty')
DATA_DISK_SKUS=()

# Get network interface
NIC_ID=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[0].id')
CMD="az network nic show --ids \"$NIC_ID\" --output json"
echo "$(date +%H:%M) : <command>$CMD</command>"
NIC_JSON=$(eval "$CMD")
NIC_JSON="${NIC_JSON//$'\r'/}"
ENABLE_ACCELERATED_NETWORKING=$(echo "$NIC_JSON" | jq -r '.enableAcceleratedNetworking // false')

# Get NSG if attached
NSG_ID=$(echo "$NIC_JSON" | jq -r '.networkSecurityGroup.id // empty')

# Get public IP if exists
PUBLIC_IP_ID=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].publicIPAddress.id // empty')

# Get tags
VM_TAGS=$(echo "$VM_JSON" | jq -r '.tags // {} | to_entries | map("\\(.key)=\\(.value)") | join(" ")')

echo "VM Size: $VM_SIZE"
echo "Source Location: $VM_LOCATION"
echo "OS Disk: $OS_DISK_NAME"
echo "OS Type: $OS_TYPE"
echo "Availability Zone: ${VM_ZONE:-none}"
echo "Accelerated Networking: $ENABLE_ACCELERATED_NETWORKING"

# Step 2: Stop and deallocate the VM
echo ""
echo "=== Step 2: Deallocating Source VM ==="
CMD="az vm deallocate --ids \"$VM_URI\""
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD"
echo "VM deallocated successfully"

# Step 3: Create snapshots of all disks
echo ""
echo "=== Step 3: Creating Disk Snapshots ==="
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Create OS disk snapshot
OS_SNAPSHOT_NAME="${SOURCE_VM_NAME}-os-snapshot-${TIMESTAMP}"
echo "Creating OS disk snapshot: $OS_SNAPSHOT_NAME"
CMD="az snapshot create \\
    --resource-group \"$SOURCE_RG\" \\
    --name \"$OS_SNAPSHOT_NAME\" \\
    --source \"$OS_DISK_ID\" \\
    --location \"$VM_LOCATION\" \\
    --incremental true \\
    --sku Standard_LRS"
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD"

CMD="az snapshot show --name \""$OS_SNAPSHOT_NAME"\" --resource-group \""$SOURCE_RG"\" --query id -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
OS_SNAPSHOT_ID=$(eval $CMD)
OS_SNAPSHOT_ID="${OS_SNAPSHOT_ID//$'\r'/}"

# Create data disk snapshots
DATA_SNAPSHOT_IDS=()
if [ -n "$DATA_DISK_IDS" ]; then
    DISK_COUNT=0
    for DISK_ID in $DATA_DISK_IDS; do
        DATA_DISK_NAME=$(echo "$DISK_ID" | sed -n 's|.*/disks/\([^/]*\).*|\1|p')
        
        # Get data disk SKU
        CMD="az disk show --ids \"$DISK_ID\" --query sku.name -o tsv"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        DISK_SKU=$(eval "$CMD")
        DISK_SKU="${DISK_SKU//$'\r'/}"
        DATA_DISK_SKUS+=("$DISK_SKU")
        
        DATA_SNAPSHOT_NAME="${SOURCE_VM_NAME}-data${DISK_COUNT}-snapshot-${TIMESTAMP}"
        echo "Creating data disk snapshot: $DATA_SNAPSHOT_NAME"
        
        CMD="az snapshot create \\
            --resource-group \"$SOURCE_RG\" \\
            --name \"$DATA_SNAPSHOT_NAME\" \\
            --source \"$DISK_ID\" \\
            --location \"$VM_LOCATION\" \\
            --incremental true \\
            --sku Standard_LRS"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        eval "$CMD"
        
        CMD="az snapshot show --name \"$DATA_SNAPSHOT_NAME\" --resource-group \"$SOURCE_RG\" --query id -o tsv"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        SNAPSHOT_ID=$(eval "$CMD")
        SNAPSHOT_ID="${SNAPSHOT_ID//$'\r'/}"
        DATA_SNAPSHOT_IDS+=("$SNAPSHOT_ID")
        ((DISK_COUNT++))
    done
fi


#======================================================================================================================================================
#======================================================================================================================================================
#======================================================================================================================================================

# Step 4: Copy snapshots to target region
echo ""
echo "=== Step 4: Copying Snapshots to Target Region ==="
# echo ""
# echo "Waiting for 1 minute before proceeding..."
# sleep 60
# Ensure target resource group exists
CMD="az group create --name \""$TARGET_RESOURCE_GROUP"\" --location \""$TARGET_REGION"\""
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD" || true



# Copy OS snapshot
# OS_SNAPSHOT_ID="/subscriptions/8bf13cf3-0d95-4585-a685-f5ee82060c02/resourceGroups/rg-move-vm/providers/Microsoft.Compute/snapshots/vm-move-vm-os-snapshot-20251213-225613"
#echo "$OS_SNAPSHOT_ID"
#OS_SNAPSHOT_ID="\""$OS_SNAPSHOT_ID"\""
OS_SNAPSHOT_ID="${OS_SNAPSHOT_ID//$'\r'/}"
TARGET_OS_SNAPSHOT_NAME="${OS_SNAPSHOT_NAME}-os-snapshot-${TARGET_REGION}"
echo "Copying OS snapshot to $TARGET_REGION..."
CMD='az snapshot create --resource-group "'$TARGET_RESOURCE_GROUP'" --name "'$TARGET_OS_SNAPSHOT_NAME'"    --location "'$TARGET_REGION'"   --source "'$OS_SNAPSHOT_ID'"    --sku Standard_LRS   --incremental true   --copy-start   --no-wait'
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD"
# Wait for OS snapshot copy to complete
echo "Waiting for OS snapshot copy to complete..."
CMD="az snapshot show --name \"$TARGET_OS_SNAPSHOT_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query \"completionPercent\" -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
while true; do
    PERCENT=$(eval "$CMD")
    PERCENT="${PERCENT//$'\r'/}"
    if [ "$PERCENT" == 100.0 ]; then
        break
    fi
    echo "Current completion: $PERCENT% - waiting..."
    sleep 10
done
echo "OS snapshot copied successfully"

CMD="az snapshot show --name \"$TARGET_OS_SNAPSHOT_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
TARGET_OS_SNAPSHOT_ID=$(eval "$CMD")
TARGET_OS_SNAPSHOT_ID="${TARGET_OS_SNAPSHOT_ID//$'\r'/}"

# Copy data snapshots
TARGET_DATA_SNAPSHOT_IDS=()
if [ ${#DATA_SNAPSHOT_IDS[@]} -gt 0 ]; then
    DISK_COUNT=0
    for SNAPSHOT_ID in "${DATA_SNAPSHOT_IDS[@]}"; do
        TARGET_DATA_SNAPSHOT_NAME="${SOURCE_VM_NAME}-data${DISK_COUNT}-snapshot-${TARGET_REGION}"
        echo "Copying data snapshot ${DISK_COUNT} to $TARGET_REGION..."
        
        CMD="az snapshot create \\
            --resource-group \"$TARGET_RESOURCE_GROUP\" \\
            --name \"$TARGET_DATA_SNAPSHOT_NAME\" \\
            --location \"$TARGET_REGION\" \\
            --source \"$SNAPSHOT_ID\" \\
            --sku Standard_LRS \\
            --copy-start"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        eval "$CMD"
        
        # Wait for copy to complete
        echo "Waiting for data snapshot ${DISK_COUNT} copy to complete..."
        while true; do
            CMD="az snapshot show --name \"$TARGET_DATA_SNAPSHOT_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query \"provisioningState\" -o tsv"
            echo "$(date +%H:%M) : <command>$CMD</command>"
            STATE=$(eval "$CMD")
            if [ "$STATE" == "Succeeded" ]; then
                break
            fi
            echo "Current state: $STATE - waiting..."
            sleep 30
        done
        echo "Data snapshot ${DISK_COUNT} copied successfully"
        
        CMD="az snapshot show --name \"$TARGET_DATA_SNAPSHOT_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        TARGET_SNAPSHOT_ID=$(eval "$CMD")
        TARGET_SNAPSHOT_ID="${TARGET_SNAPSHOT_ID//$'\r'/}"
        TARGET_DATA_SNAPSHOT_IDS+=("$TARGET_SNAPSHOT_ID")
        ((DISK_COUNT++))
    done
fi

# Step 5: Create managed disks from snapshots
echo ""
echo "=== Step 5: Creating Managed Disks in Target Region ==="

# Create OS disk
TARGET_OS_DISK_NAME="${SOURCE_VM_NAME}-os-disk"
echo "Creating OS disk: $TARGET_OS_DISK_NAME"
CMD="az disk create \\
    --resource-group \"$TARGET_RESOURCE_GROUP\" \\
    --name \"$TARGET_OS_DISK_NAME\" \\
    --location \"$TARGET_REGION\" \\
    --source \"$TARGET_OS_SNAPSHOT_ID\" \\
    --sku $OS_DISK_SKU"
echo "$(date +%H:%M) : <command>$CMD</command>"
eval "$CMD"

CMD="az disk show --name \"$TARGET_OS_DISK_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
TARGET_OS_DISK_ID=$(eval "$CMD")
TARGET_OS_DISK_ID="${TARGET_OS_DISK_ID//$'\r'/}"

# Create data disks
TARGET_DATA_DISK_IDS=()
if [ ${#TARGET_DATA_SNAPSHOT_IDS[@]} -gt 0 ]; then
    DISK_COUNT=0
    for SNAPSHOT_ID in "${TARGET_DATA_SNAPSHOT_IDS[@]}"; do
        TARGET_DATA_DISK_NAME="${SOURCE_VM_NAME}-data-disk-${DISK_COUNT}"
        echo "Creating data disk: $TARGET_DATA_DISK_NAME"
        
        # Get LUN from original data disk
        LUN=$(echo "$VM_JSON" | jq -r ".storageProfile.dataDisks[${DISK_COUNT}].lun")
        DISK_SKU="${DATA_DISK_SKUS[$DISK_COUNT]}"
        
        CMD="az disk create \
            --resource-group \"$TARGET_RESOURCE_GROUP\" \
            --name \"$TARGET_DATA_DISK_NAME\" \
            --location \"$TARGET_REGION\" \
            --source \"$SNAPSHOT_ID\" \
            --sku $DISK_SKU"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        eval "$CMD"
        
        CMD="az disk show --name \"$TARGET_DATA_DISK_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
        echo "$(date +%H:%M) : <command>$CMD</command>"
        DISK_ID=$(eval "$CMD")
        DISK_ID="${DISK_ID//$'\r'/}"
        TARGET_DATA_DISK_IDS+=("$DISK_ID:$LUN")
        ((DISK_COUNT++))
    done
fi

# Step 6: Create network resources in target region
echo ""
echo "=== Step 6: Creating Network Resources ==="

# Get target subnet ID
CMD="az network vnet subnet show \\
    --resource-group \"$TARGET_RESOURCE_GROUP\" \\
    --vnet-name \"$TARGET_VNET\" \\
    --name \"$TARGET_SUBNET\" \\
    --query id -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
TARGET_SUBNET_ID=$(eval "$CMD")
TARGET_SUBNET_ID="${TARGET_SUBNET_ID//$'\r'/}"
# Create NSG in target region if it existed
if [ -n "$NSG_ID" ]; then
    SOURCE_NSG_NAME=$(echo "$NSG_ID" | sed -n 's|.*/networkSecurityGroups/\([^/]*\).*|\1|p')
    TARGET_NSG_NAME="${SOURCE_VM_NAME}-nsg"
    
    echo "Creating NSG: $TARGET_NSG_NAME"
    # Get NSG rules
    CMD="az network nsg show --ids \"$NSG_ID\" --query \"securityRules\" -o json"
    echo "$(date +%H:%M) : <command>$CMD</command>"
    NSG_RULES=$(eval "$CMD")
    NSG_RULES="${NSG_RULES//$'\r'/}"
    
    CMD="az network nsg create \\
        --resource-group \"$TARGET_RESOURCE_GROUP\" \\
        --name \"$TARGET_NSG_NAME\" \\
        --location \"$TARGET_REGION\""
    echo "$(date +%H:%M) : <command>$CMD</command>"
    eval "$CMD"
    
    CMD="az network nsg show --name \"$TARGET_NSG_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
    echo "$(date +%H:%M) : <command>$CMD</command>"
    TARGET_NSG_ID=$(eval "$CMD")
    TARGET_NSG_ID="${TARGET_NSG_ID//$'\r'/}"
    
    # Copy NSG rules (simplified - you may want to iterate through each rule)
    echo "Note: NSG rules may need to be manually copied if complex"
fi

# Create public IP if it existed
if [ -n "$PUBLIC_IP_ID" ]; then
    TARGET_PUBLIC_IP_NAME="${SOURCE_VM_NAME}-pip"
    echo "Creating public IP: $TARGET_PUBLIC_IP_NAME"
    
    CMD="az network public-ip create \\
        --resource-group \"$TARGET_RESOURCE_GROUP\" \\
        --name \"$TARGET_PUBLIC_IP_NAME\" \\
        --location \"$TARGET_REGION\" \\
        --sku Standard \\
        --allocation-method Static"
    echo "$(date +%H:%M) : <command>$CMD</command>"
    eval "$CMD"
    
    CMD="az network public-ip show --name \"$TARGET_PUBLIC_IP_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
    echo "$(date +%H:%M) : <command>$CMD</command>"
    TARGET_PUBLIC_IP_ID=$(eval "$CMD")
    TARGET_PUBLIC_IP_ID="${TARGET_PUBLIC_IP_ID//$'\r'/}"
fi

# Create network interface
TARGET_NIC_NAME="${SOURCE_VM_NAME}-nic"
echo "Creating network interface: $TARGET_NIC_NAME"

NIC_CREATE_CMD="az network nic create \\
    --resource-group \"$TARGET_RESOURCE_GROUP\" \\
    --name \"$TARGET_NIC_NAME\" \\
    --location \"$TARGET_REGION\" \\
    --subnet \"$TARGET_SUBNET_ID\" \\
    --accelerated-networking $ENABLE_ACCELERATED_NETWORKING"

if [ -n "$TARGET_NSG_ID" ]; then
    NIC_CREATE_CMD="$NIC_CREATE_CMD --network-security-group \"$TARGET_NSG_ID\""
fi

if [ -n "$TARGET_PUBLIC_IP_ID" ]; then
    NIC_CREATE_CMD="$NIC_CREATE_CMD --public-ip-address \"$TARGET_PUBLIC_IP_ID\""
fi

echo "$(date +%H:%M) : <command>$NIC_CREATE_CMD</command>"
eval "$NIC_CREATE_CMD"

CMD="az network nic show --name \"$TARGET_NIC_NAME\" --resource-group \"$TARGET_RESOURCE_GROUP\" --query id -o tsv"
echo "$(date +%H:%M) : <command>$CMD</command>"
TARGET_NIC_ID=$(eval "$CMD")
TARGET_NIC_ID="${TARGET_NIC_ID//$'\r'/}"

# Step 7: Create the VM in target region
echo ""
echo "=== Step 7: Creating VM in Target Region ==="
TARGET_VM_NAME="${SOURCE_VM_NAME}"

VM_CREATE_CMD="az vm create \\
    --resource-group \"$TARGET_RESOURCE_GROUP\" \\
    --name \"$TARGET_VM_NAME\" \\
    --location \"$TARGET_REGION\" \\
    --size \"$VM_SIZE\" \\
    --attach-os-disk \"$TARGET_OS_DISK_ID\" \\
    --os-type \"$OS_TYPE\" \\
    --nics \"$TARGET_NIC_ID\""

if [ -n "$VM_ZONE" ]; then
    VM_CREATE_CMD="$VM_CREATE_CMD --zone \"$VM_ZONE\""
fi

if [ -n "$VM_TAGS" ]; then
    VM_CREATE_CMD="$VM_CREATE_CMD --tags $VM_TAGS"
fi

echo "$(date +%H:%M) : <command>$VM_CREATE_CMD</command>"
eval "$VM_CREATE_CMD"

echo "VM created successfully"

# Step 8: Attach data disks
if [ ${#TARGET_DATA_DISK_IDS[@]} -gt 0 ]; then
    echo ""
    echo "=== Step 8: Attaching Data Disks ==="
    
    for DISK_INFO in "${TARGET_DATA_DISK_IDS[@]}"; do
        DISK_ID="${DISK_INFO%%:*}"
        LUN="${DISK_INFO##*:}"
        
        echo "Attaching disk with LUN $LUN"
        CMD="az vm disk attach \\
            --resource-group \"$TARGET_RESOURCE_GROUP\" \\
            --vm-name \"$TARGET_VM_NAME\" \\
            --name \"$DISK_ID\" \\
            --lun \"$LUN\""
        echo "$(date +%H:%M) : <command>$CMD</command>"
        eval "$CMD"
    done
    
    echo "All data disks attached"
fi

# Final summary
echo ""
echo "=== Migration Complete ==="
echo "Source VM: $SOURCE_VM_NAME (${VM_LOCATION})"
echo "Target VM: $TARGET_VM_NAME (${TARGET_REGION})"
echo "Target Resource Group: $TARGET_RESOURCE_GROUP"
echo ""
echo "Next steps:"
echo "1. Start the target VM: az vm start --resource-group $TARGET_RESOURCE_GROUP --name $TARGET_VM_NAME"
echo "2. Verify the VM is working correctly"
echo "3. Update DNS records if necessary"
echo "4. Consider deleting source VM and snapshots after verification"
echo ""
echo "Source snapshots created:"
echo "  - $OS_SNAPSHOT_NAME"
if [ ${#DATA_SNAPSHOT_IDS[@]} -gt 0 ]; then
    echo "  - ${#DATA_SNAPSHOT_IDS[@]} data disk snapshot(s)"
fi
