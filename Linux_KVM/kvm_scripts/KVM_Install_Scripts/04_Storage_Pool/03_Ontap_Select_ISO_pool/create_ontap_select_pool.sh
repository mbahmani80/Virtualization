#!/bin/bash
#===============================================================================
# Script Name: create_ontap_pool.sh
# Description: Create LVM-based libvirt storage pool for ONTAP Select
# Author: Mahdi Bahmani
# Date: 2025-08-27
#===============================================================================

set -e

# ---- Variables ----
DISK="/dev/sdc"              # Change this to the desired disk
VG_NAME="ontap_select"
POOL_NAME="ontap_select"
POOL_XML="/tmp/${POOL_NAME}_pool.xml"

# ---- Create Physical Volume ----
echo ">>> Creating Physical Volume on ${DISK}..."
pvcreate "${DISK}"

# ---- Create Volume Group ----
echo ">>> Creating Volume Group ${VG_NAME}..."
vgcreate "${VG_NAME}" "${DISK}"

# ---- Generate XML definition ----
echo ">>> Generating storage pool XML at ${POOL_XML}..."
cat > "${POOL_XML}" <<EOF
<pool type='logical'>
  <name>${POOL_NAME}</name>
  <source>
    <name>${VG_NAME}</name>
    <format type='lvm2'/>
  </source>
  <target>
    <path>/dev/${VG_NAME}</path>
  </target>
</pool>
EOF

# ---- Define, Start, and Enable Autostart for Pool ----
echo ">>> Defining libvirt storage pool ${POOL_NAME}..."
virsh pool-define "${POOL_XML}"

echo ">>> Starting storage pool ${POOL_NAME}..."
virsh pool-start "${POOL_NAME}"

echo ">>> Enabling autostart for ${POOL_NAME}..."
virsh pool-autostart "${POOL_NAME}"

# ---- Show Result ----
echo ">>> Storage pools currently configured:"
virsh pool-list --details
