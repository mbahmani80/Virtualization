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
exec > >(tee -a "$LOGFILE") 2>&1

#############################################
# VARIABLES
#############################################

# Interfaces
BR_MGMT="br0"                       # Public/Management (CIFS, SSH, Cockpit)
BR_DATA="br1"                       # Data network
BR_CLUSTER="br2"                    # Cluster network (ONTAP internal)
#BR_CLUSTER="br1"                    # Cluster network (ONTAP internal)
BR_LIBVIRT="virbr0"                 # Libvirt bridge

# VLAN subinterfaces (Data zone)
DATA_VLANS=("br1-vlan151" "br1-vlan152" "br1-vlan153")

# Physical OVS slave interfaces (no zone)
OVS_SLAVES=(
  "ovs-br0-if-eno3"
  "ovs-br0-if-eno4"
  "ovs-br1-if-eno1"
  "ovs-br1-if-eno2"
#  "ovs-br2-if-ens224"
#  "ovs-br2-if-ens39"
)

# Host-to-host trust IPs
TRUST_PUBLIC=("172.28.150.15" "172.28.150.16")
TRUST_DATA=("192.168.150.15" "192.168.150.16")

#############################################
# SCRIPT
#############################################

# Detect all physical interfaces
echo "Detecting physical interfaces ..."
IFACES=$(ls /sys/class/net | grep -vE '^(lo|virbr|vnet|tap)')
echo "Found physical interfaces: $IFACES"

# Remove all physical interfaces from zones
for iface in $IFACES; do
  current_zone=$(firewall-cmd --get-active-zones | grep -w "$iface" -B1 | head -n1 | awk '{print $1}')
  if [ -n "$current_zone" ]; then
    echo "Removing $iface from $current_zone"
    firewall-cmd --zone="$current_zone" --remove-interface="$iface"
    firewall-cmd --zone="$current_zone" --remove-interface="$iface" --permanent
  fi
done



echo "Starting firewalld configuration for KVM..."

# Function: create zone if missing
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

# Assign bridges to zones
echo "Assigning interfaces to zones..."
firewall-cmd --permanent --zone=public  --add-interface="$BR_MGMT"
firewall-cmd --permanent --zone=data    --add-interface="$BR_DATA"
for vlan in "${DATA_VLANS[@]}"; do
  firewall-cmd --permanent --zone=data --add-interface="$vlan"
done
firewall-cmd --permanent --zone=cluster --add-interface="$BR_CLUSTER"
firewall-cmd --permanent --zone=libvirt --add-interface="$BR_LIBVIRT"

# Services/ports
firewall-cmd --permanent --zone=public --add-service=ssh
firewall-cmd --permanent --zone=public --add-service=cockpit

firewall-cmd --permanent --zone=data --add-service=ssh
firewall-cmd --permanent --zone=data --add-port=2049/tcp   # NFS
firewall-cmd --permanent --zone=data --add-port=2049/udp   # NFS
firewall-cmd --permanent --zone=data --add-port=3260/tcp   # iSCSI
firewall-cmd --permanent --zone=data --add-port=49152-49261/tcp # Migration
firewall-cmd --permanent --zone=data --add-port=16509/tcp  # Libvirt
firewall-cmd --permanent --zone=data --add-port=16514/tcp  # Libvirt

# Disable masquerading (default)
firewall-cmd --permanent --zone=data --remove-masquerade || true

# Trust rules
echo "Adding host-to-host trust rules..."
for ip in "${TRUST_PUBLIC[@]}"; do
  firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=$ip accept"
done
for ip in "${TRUST_DATA[@]}"; do
  firewall-cmd --permanent --zone=cluster --add-rich-rule="rule family=ipv4 source address=$ip accept"
done

# Detect all physical interfaces from public zone
echo "Detecting physical interfaces from public zone ..."
IFACES=$(ls /sys/class/net | grep -vE '^(lo|br|idrac|ovs|virbr|vnet|tap)')
echo "Found physical interfaces: $IFACES"


for iface in $IFACES; do
  current_zone=$(firewall-cmd --get-active-zones | grep -w "$iface" -B1 | head -n1 | awk '{print $1}')
  if [ -n "$current_zone" ]; then
    echo "Removing $iface from $current_zone"
    firewall-cmd --zone="$current_zone" --remove-interface="$iface"
    firewall-cmd --zone="$current_zone" --remove-interface="$iface" --permanent
  fi
done


# Reload
echo "Reloading firewall..."
firewall-cmd --reload

echo "firewalld configuration completed."
firewall-cmd --get-active-zones
firewall-cmd --list-all --zone=public
firewall-cmd --list-all --zone=data
firewall-cmd --list-all --zone=cluster
firewall-cmd --list-all --zone=libvirt

#############################################
# NETWORKMANAGER ZONE ASSIGNMENTS
#############################################

# OVS slave interfaces -> no zone
for iface in "${OVS_SLAVES[@]}"; do
  nmcli connection modify "$iface" connection.zone ""
done

# Bridges
nmcli connection modify "$BR_MGMT"   connection.zone trusted
nmcli connection modify "$BR_DATA"   connection.zone data
nmcli connection modify "$BR_CLUSTER" connection.zone data
nmcli connection modify "$BR_LIBVIRT" connection.zone libvirt

# VLAN subinterfaces
for vlan in "${DATA_VLANS[@]}"; do
  nmcli connection modify "$vlan" connection.zone data
done

# Apply changes
nmcli connection reload
nmcli connection up "$BR_MGMT"   || true
nmcli connection up "$BR_DATA"   || true
nmcli connection up "$BR_CLUSTER" || true
nmcli connection up "$BR_LIBVIRT" || true

# Control
firewall-cmd --get-active-zones
firewall-cmd --zone=trusted --list-all
firewall-cmd --zone=data --list-all
firewall-cmd --zone=libvirt --list-all
