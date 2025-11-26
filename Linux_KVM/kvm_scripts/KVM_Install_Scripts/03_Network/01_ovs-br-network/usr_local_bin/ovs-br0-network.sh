#!/bin/bash
#===============================================================================
# Script Name: ovs-br0-network.sh
# Description: Manage Open vSwitch bridge (br0) with bonding and static IP setup
# Author: Mahdi Bahmani
# Date: 2025-08-28
# Usage: ./ovs-br0-network.sh {create|delete|recreate|start|stop|status|help}
#===============================================================================
# Target Network Topology
#
# Bridge: br0             (With static IP: x.x.x.x/x) Management, CIFS Access, untagged VLAN 150
#  ├── Port: br0bond0     (Bonded: IFACE1 + IFACE2)
#  └── Port: br0          
#--------------------------------------------------------------------------------
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

set -o errexit    # Exit the script immediately if any command returns a non-zero exit status (an error).
set -o pipefail   # Return a failure if any command fails, not just the last one.
set -o nounset    # Treat unset variables as an error and exit immediately.
# ================================
# Configuration Variables br0
# ================================
BR0_NAME="br0"
BR0_BOND0_NAME="br0bond0"
# BR0_BOND0_MODE="LACP"            # LACP (802.3ad)
# BR0_BOND0_MODE="BALANCE_SLB"       # Load balancing (balance-slb)
BR0_BOND0_MODE="ACTIVE_BACKUP"   # Active-backup failover
BR0_MAC_IFACE1="90:b1:1c:3a:16:1e"
BR0_MAC_IFACE2="90:b1:1c:3a:16:20"
BR0_IP_ADDRESS="172.28.150.15"
BR0_SUBNET_MASK="24"
BR0_GATEWAY="172.28.150.1"
BR0_DNS1="4.2.2.4"
BR0_DNS2="8.8.8.8"
BR0_MTU="1500"

# ================================
# Logging
# ================================
LOG_DIR="/var/log/ovs-scripts"
LOG_FILE="${LOG_DIR}/ovs-br0-network.sh.log"
mkdir -p "$LOG_DIR"

# Rotate log >5MB
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 5242880 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
fi

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') :: $0 $* ====="

log() { echo ">>> $(date '+%Y-%m-%d %H:%M:%S') | $*"; }

# ================================
# Function: find_iface
# ================================
find_iface() {
    local mac="$1"
    iface=$(ip -o link show | awk -v mac="$mac" '$0 ~ mac {print $2}' | sed 's/://' |grep -v "$BR0_NAME")
    echo "$iface"
}

IFACE1=$(find_iface $BR0_MAC_IFACE1)
IFACE2=$(find_iface $BR0_MAC_IFACE2)

if [[ -z "$IFACE1" || -z "$IFACE2" ]]; then
    log "[ERROR] Could not find network interfaces for provided MACs (IFACE1=${IFACE1}, IFACE2=${IFACE2})."
    exit 1
fi

# ================================
# Prevent concurrent execution
# ================================
LOCK_FILE="/tmp/ovs-br0-network.sh.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "[ERROR] Another instance of this script is running."; exit 1; }

# ================================
# Help Function
# ================================
print_help_br0() {
    echo "=============================================="
    echo " $0 - Open vSwitch bridge tool "
    echo "=============================================="
    echo "Usage: $0 {create|delete|recreate|start|stop|status|help}"
    echo
    echo "  create    - Create OVS bridge, bond, and configure IP & routes"
    echo "  delete    - Remove OVS bridge br0 completely"
    echo "  recreate  - Delete then re-create br0"
    echo "  start     - Set IP, route, and DNS only (bridge must exist)"
    echo "  stop      - Remove IP & route, bring interfaces down (keep bridge)"
    echo "  status    - Show bridge, IP, and routing info"
    echo "  help      - Show this help message"
	echo "=============================================="
}
# ================================
# Function: create_bridge_br0
# ================================
create_bridge_br0() {

    log ">>> Checking if OVS bridge '${BR0_NAME}' exists..."
    if ovs-vsctl br-exists "${BR0_NAME}"; then
        echo ">>> Bridge '${BR0_NAME}' already exists. Skipping creation."
        return 0
    fi

    log ">>> Creating OVS bridge: ${BR0_NAME}"
    ovs-vsctl add-br "${BR0_NAME}"

    log ">>> Creating OVS bond port: ${BR0_BOND0_NAME} (${IFACE1}, ${IFACE2})"
    ovs-vsctl add-bond "${BR0_NAME}" "${BR0_BOND0_NAME}" "${IFACE1}" "${IFACE2}"

	case "$BR0_BOND0_MODE" in

		ACTIVE_BACKUP)
			# ---------- Active-Backup Mode ----------
			# Linux/OVS: Only one NIC is active at a time. If the active NIC fails,
			#            traffic automatically fails over to the standby NIC.
			ovs-vsctl set port "${BR0_BOND0_NAME}" bond_mode=active-backup
			# Set link monitoring
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-detect-mode=miimon
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-miimon-interval=100
			# Set the preferred active interface
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-primary=${IFACE1}

			log "Configured Active-Backup bond on ${BR0_BOND0_NAME} with primary NIC ${IFACE1}"
			;;

		BALANCE_SLB)
			# ---------- Balance-SLB (Load Balancing) ----------
			# Linux/OVS: All NICs in the bond are active. Outgoing traffic is distributed
			#            across all active interfaces using adaptive load balancing.
			ovs-vsctl set port "${BR0_BOND0_NAME}" bond_mode=balance-slb
			# Set link monitoring
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-detect-mode=miimon
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-miimon-interval=100

			log "Configured Balance-SLB bond on ${BR0_BOND0_NAME} (multi-link active)"
			;;

		LACP)
			# ---------- LACP (802.3ad) ----------
			# Linux/OVS: Uses 802.3ad protocol to negotiate link aggregation with the switch.
			#            Multiple NICs are active, and traffic is load-balanced according to
			#            hash algorithms (typically TCP/UDP).
            ovs-vsctl set port "${BR0_BOND0_NAME}" lacp=active
			ovs-vsctl set port "${BR0_BOND0_NAME}" bond_mode=balance-tcp
			ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:lacp-time=fast
			#Transmit hash policy: layer3+4
            ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:bond-hash-policy=layer3+4

			log "Configured LACP bond on ${BR0_BOND0_NAME} (negotiated multi-link aggregation)"
			;;

		*)
			log "ERROR: Unknown BR0_BOND0_MODE value: $BR0_BOND0_MODE. Supported: ACTIVE_BACKUP, BALANCE_TCP, LACP"
			exit 1
			;;
	esac
    
	ovs-vsctl set Interface ${IFACE1} type=system
	ovs-vsctl set Interface ${IFACE2} type=system
	
    # Show current bond status
    ovs-appctl bond/show "${BR0_BOND0_NAME}"

	#log "Configure the port with VLAN ID 0, tag=0: for untagged (native) VLAN traffic"
	#ovs-vsctl set port "$BR0_BOND0_NAME" vlan_mode=access tag=0
	
    log ">>> Setting MTU"
    set_mtu

    log ">>> Bringing up interfaces"
    bring_up_interfaces

    log ">>> Configuring IP and routes"
    configure_ip_routes

	log "Ensuring SSH and Cockpit firewall rules and services are configured..."
	# --- Firewall: ensure cockpit service is added ---
	if ! firewall-cmd --zone=public --list-services | grep -qw cockpit; then
		echo ">>> Adding Cockpit to firewall..."
		firewall-cmd --zone=public --add-service=cockpit --permanent
		firewall-cmd --reload
	else
		log ">>> Cockpit already allowed in firewall."
	fi

	# --- Firewall: ensure SSH service is added ---
	if ! firewall-cmd --zone=public --list-services | grep -qw ssh; then
		echo ">>> Adding SSH to firewall..."
		firewall-cmd --zone=public --add-service=ssh --permanent
		firewall-cmd --reload
	else
		echo ">>> SSH already allowed in firewall."
	fi

	log "--- Ensure cockpit service is enabled and running ---"
	if ! systemctl is-enabled --quiet cockpit.socket; then
		echo ">>> Enabling Cockpit..."
		systemctl enable --now cockpit.socket
	else
		echo ">>> Cockpit already enabled."
	fi

	if ! systemctl is-active --quiet cockpit.socket; then
		log ">>> Starting Cockpit..."
		systemctl start cockpit.socket
	else
		log ">>> Cockpit already running."
	fi


    log ">>> OVS bridge setup completed successfully!"
    log ">>> Done. Use '$0 start' to set IPs."
}

# ================================
# Function: delete_bridge_br0
# ================================
delete_bridge_br0() {
    log ">>> Removing bridge '${BR0_NAME}'..."
    if ovs-vsctl br-exists "${BR0_NAME}"; then
        ip addr flush dev "${BR0_NAME}"
        ovs-vsctl del-br "${BR0_NAME}"
        log ">>> Bridge '${BR0_NAME}' deleted successfully."
    else
        log ">>> Bridge '${BR0_NAME}' does not exist."
    fi
}

# ================================
# Function: stop (remove IP and route, bring down)
# ================================
stop_bridge_br0() {
    log ">>> Stopping network on ${BR0_NAME}..."

    if ip addr show dev "$BR0_NAME" | grep -q "$BR0_IP_ADDRESS"; then
        echo ">>> Removing IP ${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK} from ${BR0_NAME}"
        ip addr del "${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK}" dev "${BR0_NAME}"
    else
        echo ">>> No IP ${BR0_IP_ADDRESS} found on ${BR0_NAME}"
    fi

    # Remove default route if it uses br0
    DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}')
    if [ "$DEFAULT_IFACE" == "$BR0_NAME" ]; then
        echo ">>> Removing default route via ${BR0_GATEWAY}"
        ip route del default via "${BR0_GATEWAY}" dev "${BR0_NAME}" 2>/dev/null
    fi

    echo ">>> Bringing interfaces down"
    ip link set "${BR0_NAME}" down
    ip link set "${IFACE1}" down
    ip link set "${IFACE2}" down

    echo ">>> Network stopped for bridge ${BR0_NAME}"
}

# ================================
# Function: start (set IP and route only)
# ================================
start_bridge_br0() {
    log ">>> Starting network on ${BR0_NAME}..."

    if ! ovs-vsctl br-exists "${BR0_NAME}"; then
        echo ">>> Bridge '${BR0_NAME}' does not exist. Use '$0 create' first."
        exit 1
    fi

    echo ">>> Bringing bridge up"
    ip link set "$IFACE1" up
    ip link set "$IFACE2" up
    ip link set "${BR0_NAME}" up

    if ! ip addr show dev "$BR0_NAME" | grep -q "$BR0_IP_ADDRESS"; then
        echo ">>> Assigning IP ${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK} to ${BR0_NAME}"
        ip addr add "${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK}" dev "${BR0_NAME}"
    else
        echo ">>> IP ${BR0_IP_ADDRESS} already configured on ${BR0_NAME}"
    fi

    if ! ip route show | grep -q "default via ${BR0_GATEWAY}"; then
        echo ">>> Adding default route via ${BR0_GATEWAY}"
        ip route add default via "${BR0_GATEWAY}" dev "${BR0_NAME}" 2>/dev/null
    else
        echo ">>> Default route via ${BR0_GATEWAY} already exists"
    fi

    echo ">>> Restoring DNS configuration"
    echo -e "nameserver $BR0_DNS1\nnameserver $BR0_DNS2" > /etc/resolv.conf

    echo ">>> Bridge ${BR0_NAME} started successfully!"
}

# ================================
# Utility Functions
# ================================
bring_up_interfaces() {
    ip link set "$IFACE1" up
    ip link set "$IFACE2" up
    ip link set "$BR0_NAME" up
}

set_mtu() {
    ovs-vsctl set interface "$IFACE1" mtu_request=$BR0_MTU
    ovs-vsctl set interface "$IFACE2" mtu_request=$BR0_MTU
    ovs-vsctl set interface "$BR0_NAME" mtu_request=$BR0_MTU
}

configure_ip_routes() {
    ip addr show dev "$BR0_NAME" | grep -q "$BR0_IP_ADDRESS" || ip addr add "$BR0_IP_ADDRESS/$BR0_SUBNET_MASK" dev "$BR0_NAME"
    ip route add default via "$BR0_GATEWAY" dev "$BR0_NAME" 2>/dev/null
    echo -e "nameserver $BR0_DNS1\nnameserver $BR0_DNS2" > /etc/resolv.conf
}

status_bridge_br0() {

    echo "OVS Topology:"
    ovs-vsctl show || echo "OVS is not running or bridge not present."

	echo "=== ovs-appctl bond/show "${BR0_BOND0_NAME}" ==="
    ovs-appctl bond/show "${BR0_BOND0_NAME}"
    echo
	echo "=== ovs-vsctl list port "${BR0_BOND0_NAME}" ==="
	ovs-vsctl list port "${BR0_BOND0_NAME}"
	echo
	#echo "=== ovs-appctl lacp/show "${BR0_BOND0_NAME}" ==="
	#ovs-appctl lacp/show "${BR0_BOND0_NAME}"
	echo
    
	echo
    echo "IP Address Info:"
    ip addr show "${BR0_NAME}" 2>/dev/null || echo "Bridge ${BR0_NAME} not present."
    echo
    echo "===== Routing Table ====="
    ip route
	
    echo
    echo "Ping Test:"
    if ip addr show "${BR0_NAME}" &>/dev/null; then
        ping -c 3 8.8.8.8 || echo "Ping test failed!"
    else
        echo "Bridge ${BR0_NAME} has no IP configured."
    fi
    echo "--------------------------------------------------"
}

# ================================
# Main control logic
# ================================
ACTION="${1:-help}"  # create | delete | recreate | start | stop | status | help, default to 'help' if no argument
case "$ACTION" in
  create)
    create_bridge_br0
    ;;
  delete)
    delete_bridge_br0
    ;;
  recreate)
    delete_bridge_br0
    create_bridge_br0
    ;;
  start)
    start_bridge_br0
    ;;
  stop)
    stop_bridge_br0
    ;;
  status)
    status_bridge_br0
    ;;
  help|"")
    print_help_br0
    ;;
    *)
    echo "Invalid option: $ACTION"
    print_help_br0
    exit 1
    ;;
esac
