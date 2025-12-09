#!/bin/bash
# ==============================================================================================
# Script: setup_firewalld_kvm.sh
# Description: Configure firewalld for KVM bridges and VLANs with host-to-host trust rules
# Author: Mahdi Bahmani
# Date: 2025-12-09
# Usage: ./setup_firewalld_kvm.sh
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
# br2           Linux Cluster/ONTAP Select Internal          ens193, ens225    untagged     cluster
# virbr0        Default NAT (Libvirt internal) internal          –            libvirt
#
# ----------------------------------------------------------------------------------------------
# Trusted Pairs (Rich Rules)
#
# 172.28.150.150 <--> 172.28.150.151   (Management, br0, trusted zone) Change it based on your environment
# 172.28.153.150 <--> 172.28.153.151   (Live Migration, br1-vlan153, data zone) Change it based on your environment
#
# ==============================================================================================

set -ex
LOGFILE="/var/log/setup_firewalld_kvm.sh.log"
exec > >(tee -a "$LOGFILE") 2>&1

#############################################
# VARIABLES – EDIT FOR YOUR ENVIRONMENT
#############################################

BR_MGMT="br0"
BR_DATA="br1"
BR_CLUSTER=""            # If there is br2 set it BR_CLUSTER="br2". If you set this empty → cluster zone is skipped
BR_LIBVIRT="virbr0"

NMC_CONFIGURED="no"     # Set this to yes if interfaces are managed by NetworkManager (nmcli)
# Physical OVS slave interfaces (no zone)
OVS_SLAVES=(
  "ovs-br0-if-eno3"
  "ovs-br0-if-eno4"
  "ovs-br1-if-eno1"
  "ovs-br1-if-eno2"
#  "ovs-br2-if-ens224"
#  "ovs-br2-if-ens39"
)

DATA_VLANS=("br1-vlan151" "br1-vlan152" "br1-vlan153")

ZONE_MGMT="public"
ZONE_DATA="data"
ZONE_LIBVIRT="libvirt"
ZONE_CLUSTER="cluster"

TRUST_PUBLIC=("172.28.150.15" "172.28.150.16")
TRUST_CLUSTER=("172.28.153.150" "172.28.153.151")

DATA_PORTS_TCP=("2049" "3260" "49152-49261" "16509" "16514" "443")
DATA_PORTS_UDP=("2049")

#############################################
# FUNCTIONS
#############################################

create_zone_if_missing() {
    local Z=$1
    if ! firewall-cmd --permanent --get-zones | grep -qw "$Z"; then
        echo "Creating zone: $Z"
        firewall-cmd --permanent --new-zone="$Z"
    fi
}

#############################################
# START
#############################################

echo "===== Starting firewalld configuration ====="

# Always create: data + libvirt zones
create_zone_if_missing "$ZONE_DATA"
create_zone_if_missing "$ZONE_LIBVIRT"

#############################################
# OPTIONAL CLUSTER ZONE (ONLY IF BROADER EXISTS)
#############################################

if [[ -n "$BR_CLUSTER" && "$BR_CLUSTER" == "br2" ]]; then
    echo "Cluster interface br2 detected – enabling cluster zone"
    create_zone_if_missing "$ZONE_CLUSTER"
    firewall-cmd --permanent --zone="$ZONE_CLUSTER" --add-interface="$BR_CLUSTER"
else
    echo "No dedicated br2 cluster interface configured – skipping cluster zone"
fi

#############################################
# BRIDGE → ZONE assignment
#############################################

firewall-cmd --permanent --zone="$ZONE_MGMT" --add-interface="$BR_MGMT"
firewall-cmd --permanent --zone="$ZONE_DATA" --add-interface="$BR_DATA"

for vlan in "${DATA_VLANS[@]}"; do
    firewall-cmd --permanent --zone="$ZONE_DATA" --add-interface="$vlan"
done

firewall-cmd --permanent --zone="$ZONE_LIBVIRT" --add-interface="$BR_LIBVIRT"

#############################################
# MANAGEMENT ZONE RULES
#############################################

firewall-cmd --permanent --zone="$ZONE_MGMT" --add-service=ssh
firewall-cmd --permanent --zone="$ZONE_MGMT" --add-service=cockpit
firewall-cmd --permanent --zone="$ZONE_MGMT" --add-port=443/tcp  # ONTAP Select Deploy API/HTTPS
firewall-cmd --permanent --zone="$ZONE_MGMT" --add-port=3260/tcp # iSCSI (mailbox / internal storage paths)

# ONTAP Select Deploy and KVM require ICMP allowed.


#############################################
# DATA ZONE RULES
#############################################

firewall-cmd --permanent --zone="$ZONE_DATA" --add-service=ssh

for p in "${DATA_PORTS_TCP[@]}"; do
    firewall-cmd --permanent --zone="$ZONE_DATA" --add-port="${p}/tcp"
done
for p in "${DATA_PORTS_UDP[@]}"; do
    firewall-cmd --permanent --zone="$ZONE_DATA" --add-port="${p}/udp"
done

firewall-cmd --permanent --zone="$ZONE_DATA" --remove-masquerade || true

# ONTAP Select Deploy and KVM require ICMP allowed.


#############################################
# TRUSTED HOSTS
#############################################

for ip in "${TRUST_PUBLIC[@]}"; do
    firewall-cmd --permanent --zone="$ZONE_MGMT" \
    --add-rich-rule="rule family=ipv4 source address=$ip accept"
done

# If cluster zone exists, trust cluster there
if firewall-cmd --permanent --get-zones | grep -qw "$ZONE_CLUSTER"; then
    for ip in "${TRUST_CLUSTER[@]}"; do
        firewall-cmd --permanent --zone="$ZONE_CLUSTER" \
        --add-rich-rule="rule family=ipv4 source address=$ip accept"
    done
else
    # Cluster on shared br1 (data)
    for ip in "${TRUST_CLUSTER[@]}"; do
        firewall-cmd --permanent --zone="$ZONE_DATA" \
        --add-rich-rule="rule family=ipv4 source address=$ip accept"
    done
fi

#############################################
# FINALIZE
#############################################

firewall-cmd --reload

echo ""
echo "===== ACTIVE CONFIGURATION ====="
firewall-cmd --get-active-zones
firewall-cmd --list-all --zone="$ZONE_MGMT"
firewall-cmd --list-all --zone="$ZONE_DATA"
firewall-cmd --list-all --zone="$ZONE_LIBVIRT"

if firewall-cmd --permanent --get-zones | grep -qw "$ZONE_CLUSTER"; then
    firewall-cmd --list-all --zone="$ZONE_CLUSTER"
fi

#############################################
# NETWORKMANAGER ZONE ASSIGNMENTS (optional)
#############################################

if [[ "$NMC_CONFIGURED" == "yes" ]]; then
    echo "Applying NetworkManager zone assignments..."

    # OVS slave interfaces -> no zone
	if [[ ${#OVS_SLAVES[@]} -gt 0 ]]; then
		for iface in "${OVS_SLAVES[@]}"; do
			nmcli connection modify "$iface" connection.zone ""
		done
	fi


    # Bridges
    [[ -n "$BR_MGMT" ]]   && nmcli connection modify "$BR_MGMT"   connection.zone "$ZONE_MGMT"
    [[ -n "$BR_DATA" ]]   && nmcli connection modify "$BR_DATA"   connection.zone "$ZONE_DATA"
    [[ -n "$BR_LIBVIRT" ]] && nmcli connection modify "$BR_LIBVIRT" connection.zone "$ZONE_LIBVIRT"
	
	# Cluster (only if BR_CLUSTER=br2)
	if [[ -n "$BR_CLUSTER" && "$BR_CLUSTER" == "br2" ]]; then
		nmcli connection modify "$BR_CLUSTER" connection.zone "$ZONE_CLUSTER"
	fi

    # VLAN subinterfaces
    for vlan in "${DATA_VLANS[@]}"; do
        nmcli connection modify "$vlan" connection.zone "$ZONE_DATA"
    done

    # Apply changes
    nmcli connection reload
    [[ -n "$BR_MGMT" ]]   && nmcli connection up "$BR_MGMT"   || true
    [[ -n "$BR_DATA" ]]   && nmcli connection up "$BR_DATA"   || true
    [[ -n "$BR_CLUSTER" ]] && nmcli connection up "$BR_CLUSTER" || true
    [[ -n "$BR_LIBVIRT" ]] && nmcli connection up "$BR_LIBVIRT" || true
	
	echo "===== NetworkManager zone assignment complete ====="
else
    echo "NetworkManager configuration skipped."
fi


echo "===== firewalld configuration complete ====="

