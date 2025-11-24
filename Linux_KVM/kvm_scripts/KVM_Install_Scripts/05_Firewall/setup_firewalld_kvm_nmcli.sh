#!/bin/bash
# ==============================================================================================
# Script: setup_firewalld_kvm_nmcli.sh
# Description: Configure firewalld for KVM bridges and VLANs with host-to-host trust rules
# Author: Mahdi Bahmani
# Date: 2025-08-28
# Usage: ./setup_firewalld_kvm_nmcli.sh
# ==============================================================================================
#
# ----------------------------------------------------------------------------------------------
# Network and Zone Overview
#
# Bridge        Purpose                        Interfaces        VLANs        firewalld Zone
# ------------------------------------------------------------------------------------------
# br0           Management, CIFS               ens192, ens224    untagged 150 public
# br1           Data traffic (NFS, iSCSI,      ens256, ens161    Trunk 151–153 data
#               Live Migration)
# br1-vlan151   VLAN 151 – iSCSI               virtual           151          data
# br1-vlan152   VLAN 152 – NFS                 virtual           152          data
# br1-vlan153   VLAN 153 – Live Migration      virtual           153          data
# br2           ONTAP Select Internal          ens193, ens225    untagged     cluster
# virbr0        Default NAT (Libvirt internal) internal          –            libvirt
#
# ----------------------------------------------------------------------------------------------
# Trusted Pairs (Rich Rules)
#
# 172.28.150.150 <--> 172.28.150.151   (Management, br0, trusted zone) Change it based on your environment
# 172.28.153.150 <--> 172.28.153.151   (Live Migration, br1-vlan153, data zone) Change it based on your environment
#
# ==============================================================================================

set -e
LOGFILE=/var/log/setup_firewalld_kvm.log
exec > >(tee -a $LOGFILE) 2>&1

# List of all physical interfaces
echo "Detecting physical interfaces ..."
IFACES=$(ls /sys/class/net | grep -vE '^(lo|virbr|vnet|tap)')

echo "Found physical interfaces: $IFACES"

# Remove all physical interfaces from all zones
for iface in $IFACES; do
  current_zone=$(firewall-cmd --get-active-zones | grep -w $iface -B1 | head -n1 | awk '{print $1}')
  if [ -n "$current_zone" ]; then
    echo "Removing $iface from $current_zone"
    firewall-cmd --zone=$current_zone --remove-interface=$iface
    firewall-cmd --zone=$current_zone --remove-interface=$iface --permanent
  fi
done

echo "Starting firewalld configuration for KVM..."

# Create 'data' and 'cluster' zone if they don't exist
create_zone_if_missing() {
  local ZONE=$1
  if ! firewall-cmd --permanent --get-zones | grep -qw "$ZONE"; then
    echo "Creating zone $ZONE..."
    firewall-cmd --permanent --new-zone="$ZONE"
  else
    echo "Zone $ZONE already exists, skipping."
  fi
}
create_zone_if_missing data
create_zone_if_missing cluster

# Assign interfaces to appropriate zones
echo "Assigning interfaces to zones..."

# br0 = public (Management, CIFS)
firewall-cmd --permanent --zone=public --add-interface=br0

# br1 and VLAN interfaces go to data zone
for iface in br1 br1-vlan151 br1-vlan152 br1-vlan153; do
  firewall-cmd --permanent --zone=data --add-interface=$iface
done

# br2 = cluster (ONTAP Select Internal)
firewall-cmd --permanent --zone=cluster --add-interface=br2

# virbr0 stays in libvirt zone
firewall-cmd --permanent --zone=libvirt --add-interface=virbr0

# Ports and services for public zone (br0)
firewall-cmd --permanent --zone=public --add-service=ssh
firewall-cmd --permanent --zone=public --add-service=cockpit

# Ports and services for data zone (Storage & Migration)
firewall-cmd --permanent --zone=data --add-service=ssh
firewall-cmd --permanent --zone=data --add-port=2049/tcp   # NFS
firewall-cmd --permanent --zone=data --add-port=2049/udp   # NFS
firewall-cmd --permanent --zone=data --add-port=3260/tcp   # iSCSI
firewall-cmd --permanent --zone=data --add-port=49152-49261/tcp # Libvirt QEMU migration, etc.
firewall-cmd --permanent --zone=data --add-port=16509/tcp  # Libvirt
firewall-cmd --permanent --zone=data --add-port=16514/tcp  # Libvirt

# Disable masquerading (default)
firewall-cmd --permanent --zone=data --remove-masquerade || true

# Add rich rules for host-to-host trust
echo "Adding host-to-host trust rules..."

for ip in 172.28.150.150 172.28.150.151; do
  firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=$ip accept"
done
for ip in 172.28.153.150 172.28.153.151; do
  firewall-cmd --permanent --zone=data --add-rich-rule="rule family=ipv4 source address=$ip accept"
done

# Reload firewall to apply changes
echo "Reloading firewall..."
firewall-cmd --reload

echo "firewalld configuration completed."
firewall-cmd --get-active-zones
firewall-cmd --list-all --zone=public
firewall-cmd --list-all --zone=data
firewall-cmd --list-all --zone=cluster
firewall-cmd --list-all --zone=libvirt

### --- NETWORKMANAGER ZONE ASSIGNMENTS --- ###
# Physical OVS slave interfaces -> no zone
nmcli connection modify ovs-br0-if-ens160 connection.zone ""
nmcli connection modify ovs-br0-if-ens37  connection.zone ""
nmcli connection modify ovs-br1-if-ens192 connection.zone ""
nmcli connection modify ovs-br1-if-ens38  connection.zone ""
nmcli connection modify ovs-br2-if-ens224 connection.zone ""
nmcli connection modify ovs-br2-if-ens39  connection.zone ""

# Bridges: Assign zone
nmcli connection modify br0 connection.zone trusted
nmcli connection modify br1 connection.zone data
nmcli connection modify br2 connection.zone data
nmcli connection modify virbr0 connection.zone libvirt

# VLAN subinterfaces
nmcli connection modify ovs-if-br1-vlan151 connection.zone data
nmcli connection modify ovs-if-br1-vlan152 connection.zone data
nmcli connection modify ovs-if-br1-vlan153 connection.zone data

# Apply changes
nmcli connection reload
nmcli connection up br0 || true
nmcli connection up br1 || true
nmcli connection up br2 || true
nmcli connection up virbr0 || true

# Control
firewall-cmd --get-active-zones
firewall-cmd --zone=trusted --list-all
firewall-cmd --zone=data --list-all
firewall-cmd --zone=libvirt --list-all




