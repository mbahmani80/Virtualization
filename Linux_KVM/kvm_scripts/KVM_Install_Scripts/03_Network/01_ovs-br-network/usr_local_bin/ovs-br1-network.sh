#!/bin/bash
#===============================================================================
# Script Name: ovs-br1-network.sh
# Description: Manage Open vSwitch bridge (br1) with bonding and static IP setup
# with logging and safety checks
# Author: Mahdi Bahmani
# Date: 2025-11-21
# Usage: ./ovs-br1-network.sh {create|delete|recreate|start|stop|status|help}
# Version: 2.2
#-------------------------------------------------------------------------------
#===============================================================================
# Target Network Topology
#
# Bridge: br1
#  ├── Port:br1bond1(Bonded: IFACE3 + IFACE4), trunks: [151, 152, 153]
#  ├── Port: br1              
#  ├── Port: br1-vlan151      (VLAN 151 → IP: 172.28.151.151/24) NFS
#  ├── Port: br1-vlan152      (VLAN 152 → IP: 172.28.152.151/24) iSCSI
#  └── Port: br1-vlan153      (VLAN 153 → IP: 172.28.153.151/24) Live KVM VM Migration
#-------------------------------------------------------------------------------
#===============================================================================
#OPEN vSWITCH (OVS) BONDING MODES & SWITCH REQUIREMENTS
#===============================================================================
#
#-------------------------------------------------------------------------------
# 1: ACTIVE_BACKUP (Failover Only)
#-------------------------------------------------------------------------------
## 1.1 CATEGORY: Failover Only (Passive)
## 1.2 LOAD BALANCING: None. Only one link is active at a time.
## 1.3 LINUX SIDE TOPOLOGY:
###    1.3.1 Recommended: Connect each NIC to a separate, independent physical switch for the highest redundancy (protects against switch failure).
###    1.3.2 Alternative: Connect both NICs to a single physical switch.
## 1.4 SWITCH REQUIREMENTS:
###    1.4.1 Switches Needed: One OR Two (Independent).
###    1.4.2 Configuration:None Required.
###    1.4.3 Port Setup: Configure ports as standard Access or Trunk ports.
###    1.4.4 LAG/PC: DO NOT configure a Link Aggregation Group (LAG) or Port-Channel (PC).

#-------------------------------------------------------------------------------
# 2: BALANCE_SLB (Source Load Balancing)
#-------------------------------------------------------------------------------
## 2.1 CATEGORY: Active/Active (Limited Load Balancing)
## 2.2 LOAD BALANCING: Based on Source MAC address (and VLAN). OVS handles balancing internally.
## 2.3 LINUX SIDE TOPOLOGY:
###    2.3.1 Required: Connect both NICs to a single logical switch (e.g., a standalone switch or a stack of switches operating as one unit).
###    2.3.2 CRITICAL: Must NOT span two independent switches, as this causes MAC flapping and loops.
## 2.4 SWITCH REQUIREMENTS:
###    2.4.1 Switches Needed: One logical unit.
###    2.4.2 Configuration: None Required.
###    2.4.3 Port Setup: Configure ports as standard Access or Trunk ports.
###    2.4.4 LAG/PC: DO NOT configure a Port-Channel (PC) or LAG.

#-------------------------------------------------------------------------------
# 3: LACP with BALANCE_TCP
#-------------------------------------------------------------------------------
## 3.1 CATEGORY: Active/Active (Advanced Load Balancing)
## 3.2 LOAD BALANCING: Flow-based, utilizing Layer 2, Layer 3, and Layer 4 fields (MAC, IP, Ports). Requires switch cooperation via LACP.
## 3.3 LINUX SIDE TOPOLOGY:
###    3.3.1 Required: Connect both NICs to a single logical aggregate.
###    3.3.2 Common Setup: Two Cisco Nexus switches configured as a vPC Peer Domain.
## 3.4 SWITCH REQUIREMENTS:
###    3.4.1 Switches Needed: Two MLAG/vPC-capable switches (e.g., Cisco Nexus 5000/7000/9000).
###    3.4.2 Configuration: REQUIRED
###    3.4.3 Switch Feature: Must have Multi-Chassis Link Aggregation (MLAG/vPC) configured.
###    3.4.4 Port Setup: Configure a Port-Channel (LAG) on the switch.
###    3.4.5 LACP Mode: Set the Port-Channel to use LACP (mode active).
###    3.4.6 Hashing: Ensure the switch's load-balancing hash matches OVS (ideally L3 and L4).

#===============================================================================
#
# edit /etc/NetworkManager/NetworkManager.conf and add change with you interfaces name:
# [keyfile]
# unmanaged-devices=interface-name:eno1;interface-name:eno2
# then
# systemctl restart NetworkManager
#-------------------------------------------------------------------------------
#===============================================================================

set -o errexit    # Exit the script immediately if any command returns a non-zero exit status (an error).
set -o pipefail   # Return a failure if any command fails, not just the last one.
set -o nounset    # Treat unset variables as an error and exit immediately.

# ================================
# Environment Variables br1
# ================================
BR1_NAME="br1"
BR1_BOND1_NAME="br1bond1"

BR1_BOND1_MODE="LACP"            # LACP (802.3ad), Balance-TCP
# BR1_BOND1_MODE="BALANCE_SLB"       # Load balancing (Balance-SLB)
# BR1_BOND1_MODE="ACTIVE_BACKUP"   # Active-backup failover


BR1_MAC_IFACE3="90:b1:1c:3a:16:1a"
BR1_MAC_IFACE4="90:b1:1c:3a:16:1c"

VLAN151=$BR1_NAME-"vlan151"
VLAN152=$BR1_NAME-"vlan152"
VLAN153=$BR1_NAME-"vlan153"

VLANID151=151
VLANID152=152
VLANID153=153

IPADDR_VLAN151="172.28.151.15/24"
IPADDR_VLAN152="172.28.152.15/24"
IPADDR_VLAN153="172.28.153.15/24"

BR1_MTU="9000"

#BR1_IP_ADDRESS="192.168.56.15"
BR1_IP_ADDRESS="192.168.150.15"
BR1_SUBNET_MASK="24"
BR1_GATEWAY=""
BR1_DNS1=""
BR1_DNS2=""

# Optional remote ping targets (e.g., BR1_GATEWAYs or peers)
PING_VLAN151="172.28.151.16"
PING_VLAN152="172.28.152.16"
PING_VLAN153="172.28.153.16"

# ================================
# Logging
# ================================
LOG_DIR="/var/log/ovs-scripts"
LOG_FILE="${LOG_DIR}/ovs-br1-network.log"
mkdir -p "$LOG_DIR"

# Rotate log >5MB
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 5242880 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
fi

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') :: $0 $* ====="

log() { echo ">>> $(date '+%Y-%m-%d %H:%M:%S') | $*"; }

# ================================
# Prevent concurrent execution
# ================================
LOCK_FILE="/tmp/ovs-br1-network.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "[ERROR] Another instance of this script is running."; exit 1; }

# ================================
# Help Function
# ================================
print_help_br1() {
    echo "=============================================="
    echo " $0 - Open vSwitch bridge tool "
    echo "=============================================="
    echo "Usage: $0 {create|delete|recreate|start|stop|status|help}"
    echo
    echo "  create    - Create OVS bridge, bond, and VLANs (run once)"
    echo "  delete    - Remove OVS bridge br1 completely"
    echo "  recreate  - Delete then re-create br1"
    echo "  start     - Configure IP, VLANs, route, and DNS"
    echo "  stop      - Remove IPs & routes, bring interfaces down"
    echo "  status    - Show bridge, VLAN, and routing info"
    echo "  help      - Show this help message"
	echo "=============================================="
}
# ================================
# Function: find_iface
# ================================
find_iface() {
    local mac="$1"
    iface=$(ip -o link show | awk -v mac="$mac" '$0 ~ mac {print $2}' | sed 's/://' |grep -v "$BR1_NAME")
    echo "$iface"
}


IFACE3=$(find_iface "$BR1_MAC_IFACE3")
IFACE4=$(find_iface "$BR1_MAC_IFACE4")

if [[ -z "$IFACE3" || -z "$IFACE4" ]]; then
    log "[ERROR] Could not find network interfaces for provided MACs."
    exit 1
fi

# ================================
# Function: create_bridge_br1 (run once)
# ================================
create_bridge_br1() {
    log "Checking if OVS bridge '${BR1_NAME}' exists..."
    if ovs-vsctl br-exists "${BR1_NAME}"; then
        log "Bridge '${BR1_NAME}' already exists. Skipping creation."
        return 0
    fi

    # Creating OVS bridge
    log "Creating OVS bridge: ${BR1_NAME}"
    ovs-vsctl add-br "${BR1_NAME}"
    
	# Creating OVS bond port
    log "Creating OVS bond port: ${BR1_BOND1_NAME} (${IFACE3}, ${IFACE4})"
    ovs-vsctl add-bond "${BR1_NAME}" "${BR1_BOND1_NAME}" "${IFACE3}" "${IFACE4}"

    # Configuring bond monitoring and mode 
    log "Configuring bond monitoring and mode: $BR1_BOND1_MODE"

	case "$BR1_BOND1_MODE" in

		ACTIVE_BACKUP)
			# ---------- Active-Backup Mode ----------
			# Linux/OVS: Only one NIC is active at a time. If the active NIC fails,
			#            traffic automatically fails over to the standby NIC.
			ovs-vsctl set port "${BR1_BOND1_NAME}" bond_mode=active-backup
			# Set link monitoring
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-detect-mode=miimon
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-miimon-interval=100
			# Set the preferred active interface
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-primary=${IFACE3}

			log "Configured Active-Backup bond on ${BR1_BOND1_NAME} with primary NIC ${IFACE3}"
			;;

		BALANCE_SLB)
			# ---------- Balance-SLB (Load Balancing) ----------
			# Linux/OVS: All NICs in the bond are active. Outgoing traffic is distributed
			#            across all active interfaces using adaptive load balancing.
			ovs-vsctl set port "${BR1_BOND1_NAME}" bond_mode=balance-slb
			# Set link monitoring
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-detect-mode=miimon
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-miimon-interval=100

			log "Configured Balance-SLB bond on ${BR1_BOND1_NAME} (multi-link active)"
			;;

		LACP)
			# ---------- LACP (802.3ad) ----------
			# Linux/OVS: Uses 802.3ad protocol to negotiate link aggregation with the switch.
			#            Multiple NICs are active, and traffic is load-balanced according to
			#            hash algorithms (typically TCP/UDP).
            ovs-vsctl set port "${BR1_BOND1_NAME}" lacp=active
			ovs-vsctl set port "${BR1_BOND1_NAME}" bond_mode=balance-tcp
			ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:lacp-time=fast
			#Transmit hash policy: layer3+4
            ovs-vsctl set port "${BR1_BOND1_NAME}" other_config:bond-hash-policy=layer3+4

			log "Configured LACP bond on ${BR1_BOND1_NAME} (negotiated multi-link aggregation)"
			;;

		*)
			log "ERROR: Unknown BR1_BOND1_MODE value: $BR1_BOND1_MODE. Supported: ACTIVE_BACKUP, BALANCE_TCP, LACP"
			exit 1
			;;
	esac
    
	ovs-vsctl set Interface ${IFACE3} type=system
	ovs-vsctl set Interface ${IFACE4} type=system
	
    # Show current bond status
    ovs-appctl bond/show "${BR1_BOND1_NAME}"

    log "Define VLAN trunking on the bond: allow VLANs 151, 152, 153"
    ovs-vsctl set port "${BR1_BOND1_NAME}" trunks=0,"${VLANID151}","${VLANID152}","${VLANID153}"

    # Create VLAN interfaces
    log "Create VLAN Interfaces"
    log "Create ${VLAN151}"
	if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN151}"; then
        ovs-vsctl add-port "${BR1_NAME}" "${VLAN151}" tag="${VLANID151}" -- set interface "${VLAN151}" type=internal
	fi

    log "Create ${VLAN152}"
	if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN152}"; then
        ovs-vsctl add-port "${BR1_NAME}" "${VLAN152}" tag="${VLANID152}" -- set interface "${VLAN152}" type=internal
	fi

    log "Create ${VLAN153}"
	if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN153}"; then
        ovs-vsctl add-port "${BR1_NAME}" "${VLAN153}" tag="${VLANID153}" -- set interface "${VLAN153}" type=internal
    fi
	
    log "Setting MTU"
    set_mtu

    log "Bringing up interfaces"
    bring_up_interfaces

    log "Bridge ${BR1_NAME} with bond ${BR1_BOND1_NAME} and VLANs created."
    log "Done. Use '$0 start' to set IPs."
}

# ================================
# Function: start (set IP and route only)
# ================================
start_bridge_br1() {
    log "Starting OVS network on ${BR1_NAME}..."

    if ! ovs-vsctl br-exists "${BR1_NAME}"; then
        log "[ERROR] Bridge '${BR1_NAME}' does not exist. Use '$0 create' first."
        exit 1
    fi

    log "Bringing bridge up"
    bring_up_interfaces

    if ! ip addr show dev "${BR1_NAME}" | grep -q "${BR1_IP_ADDRESS}"; then
        log "Assigning IP ${BR1_IP_ADDRESS}/${BR1_SUBNET_MASK} to ${BR1_NAME}"
        ip addr add "${BR1_IP_ADDRESS}/${BR1_SUBNET_MASK}" dev "${BR1_NAME}"
    else
        log "IP ${BR1_IP_ADDRESS} already configured on ${BR1_NAME}"
    fi

    if [[ -n "$BR1_GATEWAY" ]]; then
        if ! ip route show | grep -q "default via ${BR1_GATEWAY}"; then
            log "Adding default route via ${BR1_GATEWAY}"
            ip route add default via "${BR1_GATEWAY}" dev "${BR1_NAME}" 2>/dev/null || true
        else
            log "Default route via ${BR1_GATEWAY} already exists"
        fi
    fi

    log "Restoring DNS configuration"
    echo -e "nameserver $BR1_DNS1\nnameserver $BR1_DNS2" > /etc/resolv.conf

    # VLAN151
    ip addr show dev "${VLAN151}" | grep -q "${IPADDR_VLAN151}" || ip addr add "${IPADDR_VLAN151}" dev "${VLAN151}"
    # VLAN152
    ip addr show dev "${VLAN152}" | grep -q "${IPADDR_VLAN152}" || ip addr add "${IPADDR_VLAN152}" dev "${VLAN152}"
    # VLAN153
    ip addr show dev "${VLAN153}" | grep -q "${IPADDR_VLAN153}" || ip addr add "${IPADDR_VLAN153}" dev "${VLAN153}"

    log "[INFO] Network started successfully on ${BR1_NAME}."
	log "Done. Use '$0 status' to verify"
}

# ================================
# Function: delete_bridge_br1
# ================================
delete_bridge_br1() {
    log "Removing bridge '${BR1_NAME}'..."
    if ovs-vsctl br-exists "${BR1_NAME}"; then
        ip addr flush dev "${BR1_NAME}" || true
        ovs-vsctl del-br "${BR1_NAME}"
        log "Bridge '${BR1_NAME}' deleted successfully."
    else
        log "Bridge '${BR1_NAME}' does not exist."
    fi
}

# ================================
# Function: stop (remove IP and route, bring down)
# ================================
stop_bridge_br1() {
    log "Stopping network for ${BR1_NAME}..."

    ip addr flush dev "${VLAN151}" || true
    ip addr flush dev "${VLAN152}" || true
    ip addr flush dev "${VLAN153}" || true
    ip addr flush dev "${BR1_NAME}" || true

    ip link set "${VLAN151}" down || true
    ip link set "${VLAN152}" down || true
    ip link set "${VLAN153}" down || true
    ip link set "${BR1_NAME}" down || true
    ip link set "${IFACE3}" down || true
    ip link set "${IFACE4}" down || true

    log "Network stopped for ${BR1_NAME}."
}

# ================================
# Utility Functions
# ================================
bring_up_interfaces() {
    ip link set "${IFACE3}" up
    ip link set "${IFACE4}" up
    ip link set "${BR1_NAME}" up

    ip link set "${VLAN151}" up
    ip link set "${VLAN152}" up
    ip link set "${VLAN153}" up
}

set_mtu() {
    
	# Change MTU on the physical NICs and others
    ip link set "$IFACE3" mtu "$BR1_MTU" || true
    ip link set "$IFACE4" mtu "$BR1_MTU" || true
	ovs-vsctl set interface "${IFACE3}" mtu_request="${BR1_MTU}"
    ovs-vsctl set interface "${IFACE4}" mtu_request="${BR1_MTU}"
    
	ovs-vsctl set interface "${BR1_NAME}" mtu_request="${BR1_MTU}"
    ovs-vsctl set interface "${VLAN151}" mtu_request="${BR1_MTU}"
    ovs-vsctl set interface "${VLAN152}" mtu_request="${BR1_MTU}"
    ovs-vsctl set interface "${VLAN153}" mtu_request="${BR1_MTU}"
}

status_bridge_br1() {
    echo "=== ovs-vsctl show ==="
    ovs-vsctl show
    echo

	echo "=== ovs-appctl bond/show "${BR1_BOND1_NAME}" ==="
    ovs-appctl bond/show "${BR1_BOND1_NAME}"
    echo
	echo "=== ovs-vsctl list port "${BR1_BOND1_NAME}" ==="
	ovs-vsctl list port "${BR1_BOND1_NAME}"
	echo
	echo "=== ovs-appctl lacp/show "${BR1_BOND1_NAME}" ==="
	ovs-appctl lacp/show "${BR1_BOND1_NAME}"
	echo

    echo "=== ip addr (bridge + VLANs) ==="
    ip addr show dev "${BR1_NAME}"
    ip addr show dev "${VLAN151}"
    ip addr show dev "${VLAN152}"
    ip addr show dev "${VLAN153}"
    echo

    echo "===== Routing Table ====="
    ip route
    echo

    echo "=== LLDP Neighbors ==="
    lldpcli show neighbors ports "${IFACE3}" || echo "No LLDP neighbor on ${IFACE3}"
    lldpcli show neighbors ports "${IFACE4}" || echo "No LLDP neighbor on ${IFACE4}"
    echo

    echo ">>> Testing VLAN Connectivity..."
    ping -c 3 -I "$VLAN151" "$PING_VLAN151" && echo "VLAN151 OK" || echo "VLAN151 FAIL"
    ping -c 3 -I "$VLAN152" "$PING_VLAN152" && echo "VLAN152 OK" || echo "VLAN152 FAIL"
    ping -c 3 -I "$VLAN153" "$PING_VLAN153" && echo "VLAN153 OK" || echo "VLAN153 FAIL"
    echo
    echo ">>> Post-creation tests done."
}

# ================================
# Main control logic
# ================================
ACTION="${1:-help}"  # create | delete | recreate | start | stop | status | help, default to 'help' if no argument
case "$ACTION" in
  create)
    create_bridge_br1
    ;;
  delete)
    delete_bridge_br1
    ;;
  recreate)
    delete_bridge_br1
    create_bridge_br1
    ;;
  start)
    start_bridge_br1
    ;;
  stop)
    stop_bridge_br1
    ;;
  status)
    status_bridge_br1
    ;;
  help|"")
    print_help_br1
    ;;
    *)
    echo "Invalid option: $ACTION"
    print_help_br1
    exit 1
    ;;
esac
