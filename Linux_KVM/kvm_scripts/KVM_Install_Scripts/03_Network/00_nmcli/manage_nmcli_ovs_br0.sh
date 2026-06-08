#!/bin/bash
#===============================================================================
# Script Name: manage_nmcli_ovs_br0.sh
# Description: Create, Remove, Show Status of Open vSwitch Bridge with Bonding
# Author: Mahdi Bahmani
# Date: 2025-11-21
# Usage: ./manage_nmcli_ovs_br0.sh {create|delete|recreate|status|help}
# Version: 2.2
#===============================================================================
# Target Network Topology
#
# Bridge: br0             (With static IP: x.x.x.x/x) Management, CIFS Access, untagged VLAN 150
#  ├── Port: br0bond0     (Bonded: IFACE1 + IFACE2)
#  └── Port: br0          
#
# Topology
#
# ens160 ----\
#             \__ br0bond0 (OVS Port / bond)
#             /     |
# ens193 ----/      |
#                   |
#                   |
#            ovs-bridge (br0)
#             └─ ovs-port
#                 └─ ovs-interface
#                          |
#                      Management IP
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
# Environment Variables br0 
# ================================
BR0_NAME="br0"
BR0_BOND0_NAME="br0bond0"

# BR0_BOND0_MODE="LACP"            # LACP (802.3ad)
# BR0_BOND0_MODE="BALANCE_SLB"       # Load balancing (balance-slb)
BR0_BOND0_MODE="ACTIVE_BACKUP"   # Active-backup failover

BR0_MAC_IFACE1="00:0c:29:0a:c5:9f"
BR0_MAC_IFACE2="00:0c:29:0a:c5:bd"
BR0_IP_ADDRESS="10.0.2.141"
BR0_SUBNET_MASK="24"
BR0_GATEWAY="10.0.2.2"
BR0_DNS1="4.2.2.4"
BR0_DNS2="8.8.8.8"
BR0_MTU="1500"

RCLOCAL="/etc/rc.local"
# ================================
# Logging
# ================================
LOG_DIR="/var/log/ovs-scripts"
LOG_FILE="${LOG_DIR}/manage_nmcli_ovs_br0.log"
mkdir -p "$LOG_DIR"

# Rotate log >5MB
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 5242880 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
fi

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') :: $0 $* ====="

log() { echo ">>> $(date '+%Y-%m-%d %H:%M:%S') | $*"; }

# ================================
# Functions
# ================================
# ---- Function to find interface name by MAC ----
find_iface() {
    local mac="$1"
    iface=$(ip -o link show | awk -v mac="$mac" '$0 ~ mac {print $2}' | sed 's/://')
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
LOCK_FILE="/tmp/manage_nmcli_ovs_br0.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "[ERROR] Another instance of this script is running."; exit 1; }


# ================================
# Help Function
# ================================
print_help_br0() {
    echo "=============================================="
    echo " manage_nmcli_ovs_br0.sh - Open vSwitch bridge tool "
    echo "=============================================="
    echo "Usage: $0 {create|delete|status|help}"
    echo
    echo "  create   : Create OVS bridge br0 with bond and IP config"
    echo "  delete   : Remove OVS bridge br0 and all related configs"
    echo "  status   : Show current OVS/NMCLI bridge and bond status"
    echo "  help     : Show this help message"
    echo
    echo "Examples:"
    echo "  $0 create"
    echo "  $0 delete"
    echo "  $0 status"
    echo "=============================================="
}

# ================================
#  Ensure rc.local Exists & Is Enabled
# ================================
RCLOCAL="/etc/rc.local"

# Create file if missing
if [ ! -f "$RCLOCAL" ]; then
    echo "#!/bin/bash" > "$RCLOCAL"
    chmod +x "$RCLOCAL"
fi

# Enable rc-local compatibility service (EL8/EL9 use this unit)
if systemctl list-unit-files | grep -q rc-local.service; then
    chmod +x "$RCLOCAL"
    systemctl enable rc-local.service >/dev/null 2>&1
fi

# Helper: Add line only if not already present
add_rc_local_line() {
    local line="$1"

    # Remove existing exit 0
    sed -i '/^exit 0$/d' "$RCLOCAL"

    # Add line only if not present
    grep -Fxq "$line" "$RCLOCAL" || echo "$line" >> "$RCLOCAL"

    # Ensure exit 0 at the very end
    echo "exit 0" >> "$RCLOCAL"
	
}

# Helper: Remove a specific line from rc.local
remove_rc_local_line() {
    local line="$1"

    # Remove exact match of the line (full line match)
    sed -i "\|^${line}\$|d" "$RCLOCAL"

    # Ensure only one exit 0 exists and it is at the end
    sed -i '/^exit 0$/d' "$RCLOCAL"
    echo "exit 0" >> "$RCLOCAL"
}
# ================================
# Function: create_bridge_br0 (run once)
# ================================
create_bridge_br0() {

	log ">>> Checking for NetworkManager-ovs..."

	if ! rpm -q NetworkManager-ovs >/dev/null 2>&1; then
		echo ">>> Installing NetworkManager OVS plugin..."
		yum install -y NetworkManager-ovs
		systemctl restart NetworkManager
	else
		echo ">>> NetworkManager-ovs is already installed. Skipping installation."
    fi

	log "Checking if OVS bridge '${BR0_NAME}' exists..."
    if ovs-vsctl br-exists "${BR0_NAME}"; then
        log "Bridge '${BR0_NAME}' already exists. Skipping creation."
        return 0
    fi

    log ">>> Creating OVS bridge: ${BR0_NAME}"
    nmcli connection add type ovs-bridge conn.interface "${BR0_NAME}" con-name "${BR0_NAME}"

    log ">>> Adding bridge port for ${BR0_NAME}"
    nmcli connection add type ovs-port conn.interface "${BR0_NAME}" master "${BR0_NAME}" con-name "ovs-port-${BR0_NAME}"

    log ">>> Adding internal IFACE with static IP ${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK}"
    nmcli connection add type ovs-interface slave-type ovs-port conn.interface "${BR0_NAME}" master "ovs-port-${BR0_NAME}" \
      con-name "ovs-if-${BR0_NAME}" \
      ipv4.method manual \
      ipv4.addresses "${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK}" \
      ipv4.gateway "${BR0_GATEWAY}" \
      ipv4.dns "${BR0_DNS1},${BR0_DNS2}" \
      mtu "${BR0_MTU}"

    log ">>> Creating OVS bond port: ${BR0_BOND0_NAME}"
    nmcli connection add type ovs-port conn.interface "${BR0_BOND0_NAME}" master "${BR0_NAME}" con-name "ovs-port-${BR0_BOND0_NAME}"
    #nmcli connection modify "ovs-port-${BR0_BOND0_NAME}" ovs-port.bond-mode active-backup

    log ">>> Attaching ${IFACE1} and ${IFACE2} to ${BR0_BOND0_NAME}"
    nmcli connection add type ethernet conn.interface "${IFACE1}" master "ovs-port-${BR0_BOND0_NAME}" con-name "ovs-${BR0_NAME}-if-${IFACE1}" mtu "${BR0_MTU}"
    nmcli connection add type ethernet conn.interface "${IFACE2}" master "ovs-port-${BR0_BOND0_NAME}" con-name "ovs-${BR0_NAME}-if-${IFACE2}" mtu "${BR0_MTU}"

    # Configuring bond monitoring and mode 
    log "Configuring bond monitoring and mode: $BR0_BOND0_MODE"
		case "$BR0_BOND0_MODE" in

		ACTIVE_BACKUP)
			# ---------- Active-Backup Mode ----------
			# Linux/OVS: Only one NIC is active at a time. If the active NIC fails,
			#            traffic automatically fails over to the standby NIC.
			nmcli con modify "ovs-port-$BR0_BOND0_NAME" ovs-port.bond-mode active-backup
			log "Configured Active-Backup bond on ${BR0_BOND0_NAME}"
			;;

		BALANCE_SLB)
			# ---------- Balance-SLB (Load Balancing) ----------
			# Linux/OVS: All NICs in the bond are active. Outgoing traffic is distributed
			#            across all active interfaces using adaptive load balancing.
			nmcli con modify "ovs-port-$BR0_BOND0_NAME" ovs-port.bond-mode balance-slb
			log "Configured Balance-SLB bond on ${BR0_BOND0_NAME} (multi-link active)"
			;;

		LACP)
			# ---------- LACP (802.3ad) ----------
			# Linux/OVS: Uses 802.3ad protocol to negotiate link aggregation with the switch.
			#            Multiple NICs are active, and traffic is load-balanced according to
			#            hash algorithms (typically TCP/UDP).
			nmcli con modify "ovs-port-$BR0_BOND0_NAME" ovs-port.bond-mode balance-tcp
            nmcli con modify "ovs-port-$BR0_BOND0_NAME" ovs-port.lacp active
			log "Configured LACP bond on ${BR0_BOND0_NAME} (802.3ad active, negotiated multi-link aggregation)"
			#nmcli connection down "ovs-port-$BR0_BOND0_NAME" && nmcli connection up "ovs-port-$BR0_BOND0_NAME" 
			;;

		*)
			log "[ERROR] Unsupported BR0_BOND0_MODE: $BR0_BOND0_MODE"
			exit 1
			;;
	esac

    log ">>> Reloading and activating connections..."
	# Bring up bridge and bonds
	nmcli con reload
    nmcli con up "ovs-port-$BR0_BOND0_NAME"
    nmcli con up "ovs-$BR0_NAME-if-$IFACE1"
    nmcli con up "ovs-$BR0_NAME-if-$IFACE2"
    nmcli con up "ovs-port-$BR0_NAME"
    nmcli con up "ovs-if-$BR0_NAME"
	
    # ----------------------------------
    #   Apply OVS Bond Settings
    # ----------------------------------
    log "Set link monitoring for BALANCE_SLB or ACTIVE_BACKUP"
	if [ "$BR0_BOND0_MODE" = "ACTIVE_BACKUP" ] || [ "$BR0_BOND0_MODE" = "BALANCE_SLB" ]; then
	
	    # Set bond-detect-mode to miimon: monitors link status of each slave interface, ensures failover works correctly in active-backup mode
		ovs-vsctl set port "$BR0_BOND0_NAME" other_config:bond-detect-mode=miimon
		ovs-vsctl set port "$BR0_BOND0_NAME" other_config:bond-miimon-interval=100

		add_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-detect-mode=miimon"
		add_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR0_BOND0_MODE" = "ACTIVE_BACKUP" ]; then
	
		ovs-vsctl set port "$BR0_BOND0_NAME" other_config:bond-primary=$IFACE1

		add_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-primary=$IFACE1"
	fi


	if [ "$BR0_BOND0_MODE" = "LACP" ]; then
		log "Configure bond for LACP and Transmit hash policy: layer3+4"
		# Configure options that NMCLI CANNOT handle natively
		ovs-vsctl set port "${BR0_BOND0_NAME}" other_config:lacp-time=fast	
		# Transmit hash policy: layer3+4
        ovs-vsctl set port "$BR0_BOND0_NAME" other_config:bond-hash-policy=layer3+4
		
		add_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:lacp-time=fast"
		add_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-hash-policy=layer3+4"
	fi
	
	# Configure the port with VLAN ID 0, tag=0: for untagged (native) VLAN traffic
	#ovs-vsctl set port "$BR0_BOND0_NAME" vlan_mode=access tag=0	
	

    log ">>> Deleting invalid connections..."
    nmcli -t -f NAME,DEVICE connection show | awk -F: '$2==""{print $1}' | while read CONN; do
        echo "Deleting invalid connection: $CONN"
        nmcli connection delete "$CONN"
    done
    
	log "Ensuring SSH and Cockpit firewall rules and services are configured..."

	# --- Firewall: ensure cockpit service is added ---
	if ! firewall-cmd --zone=public --list-services | grep -qw cockpit; then
		echo ">>> Adding Cockpit to firewall..."
		firewall-cmd --zone=public --add-service=cockpit --permanent
		firewall-cmd --reload
	else
		echo ">>> Cockpit already allowed in firewall."
	fi

	# --- Firewall: ensure SSH service is added ---
	if ! firewall-cmd --zone=public --list-services | grep -qw ssh; then
		echo ">>> Adding SSH to firewall..."
		firewall-cmd --zone=public --add-service=ssh --permanent
		firewall-cmd --reload
	else
		echo ">>> SSH already allowed in firewall."
	fi

	# --- Ensure cockpit service is enabled and running ---
	if ! systemctl is-enabled --quiet cockpit.socket; then
		echo ">>> Enabling Cockpit..."
		systemctl enable --now cockpit.socket
	else
		echo ">>> Cockpit already enabled."
	fi

	if ! systemctl is-active --quiet cockpit.socket; then
		echo ">>> Starting Cockpit..."
		systemctl start cockpit.socket
	else
		echo ">>> Cockpit already running."
	fi


    # --- Summary ---
    echo
    echo "Bridge: $BR0_NAME"
    echo "Bond: $BR0_BOND0_NAME"
    echo "Interfaces: $IFACE1, $IFACE2"
    echo "MTU: $BR0_MTU"
    echo
	
    ovs-vsctl show
    nmcli con show
    ip a
	# Show current bond status
    ovs-appctl bond/show "${BR0_BOND0_NAME}"

    echo ">>> OVS bridge setup completed successfully!"
	echo ">>> Done. Use '$0 status' to verify."
}

# ================================
# Function: delete_bridge_br0()
# ================================
# ---- DELETE MODE ----
delete_bridge_br0() {
    echo ">>> Deleting OVS configuration..."

    for CONN in \
        "ovs-${BR0_NAME}-if-${IFACE1}" \
        "ovs-${BR0_NAME}-if-${IFACE2}" \
        "ovs-if-${BR0_NAME}" \
        "ovs-port-${BR0_BOND0_NAME}" \
        "ovs-port-${BR0_NAME}" \
        "${BR0_BOND0_NAME}" \
        "${BR0_NAME}"; do
        if nmcli connection show "$CONN" &>/dev/null; then
            echo "Deleting $CONN..."
            nmcli connection delete "$CONN"
        fi
    done

    echo ">>> Removing OVS bridge manually (if still exists)..."
    ovs-vsctl --if-exists del-br "${BR0_NAME}"
	
	# clean related lines in rc.local
    log "clean related lines in rc.local"
	if [ "$BR0_BOND0_MODE" = "ACTIVE_BACKUP" ] || [ "$BR0_BOND0_MODE" = "BALANCE_SLB" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-detect-mode=miimon"
		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-miimon-interval=100"
		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-primary=$IFACE1"
	fi


	if [ "$BR0_BOND0_MODE" = "ACTIVE_BACKUP" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-primary=$IFACE1"
	fi


	if [ "$BR0_BOND0_MODE" = "LACP" ]; then
		
		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:lacp-time=fast"
		remove_rc_local_line "ovs-vsctl set port $BR0_BOND0_NAME other_config:bond-hash-policy=layer3+4"
	fi

    echo ">>> Restoring IP ${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK} to ${IFACE1}"
    # Deletes old connection if present
    if nmcli connection show "restore-${IFACE1}" &>/dev/null; then
        nmcli connection delete "restore-${IFACE1}"
    fi
	
	# Check if "Wired connection 1" exists and delete it
    if nmcli -t -f NAME connection show | grep -Fxq "Wired connection 1"; then
        echo ">>> Deleting 'Wired connection 1'"
        nmcli connection delete "Wired connection 1"
    else
        echo ">>> 'Wired connection 1' not found, nothing to delete"
    fi

    nmcli connection add type ethernet ifname "${IFACE1}" con-name "restore-${IFACE1}" \
        ipv4.method manual \
        ipv4.addresses "${BR0_IP_ADDRESS}/${BR0_SUBNET_MASK}" \
        ipv4.gateway "${BR0_GATEWAY}" \
        ipv4.dns "${BR0_DNS1},${BR0_DNS2}" \
        mtu "${BR0_MTU}"

    nmcli connection up "restore-${IFACE1}"

    echo ">>> OVS bridge removed and IP restored to ${IFACE1}!"
}

# ================================
# Function: status_bridge_br0()
# ================================
# ---- STATUS MODE ----
status_bridge_br0() {
    echo ">>> Current OVS Status:"
    echo "--------------------------------------------------"
    echo "NetworkManager Connections:"
    nmcli -f NAME,TYPE,DEVICE connection show | grep -E "ovs|${IFACE1}|${IFACE2}|${BR0_NAME}" || echo "No relevant NMCLI connections found."

    echo
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
    echo "Ping Test:"
    if ip addr show "${BR0_NAME}" &>/dev/null; then
        ping -c 3 8.8.8.8 || echo "Ping test failed!"
    else
        echo "Bridge ${BR0_NAME} has no IP configured."
    fi
    echo "--------------------------------------------------"
}
# --------------------------------
# ================================
# Main
# ================================
ACTION="${1:-help}"  # create | delete | recreate | status | help, default to 'help' if no argument
case "$ACTION" in
    create)
        create_bridge_br0
        ;;
    delete)
        delete_bridge_br0
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
# --------------------------------

