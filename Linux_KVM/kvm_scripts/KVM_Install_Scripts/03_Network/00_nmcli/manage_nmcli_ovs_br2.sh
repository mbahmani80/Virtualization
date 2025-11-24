#!/bin/bash
#===============================================================================
# Script Name: manage_nmcli_ovs_br2.sh
# Description: Create, Remove, Show Status of Open vSwitch Bridge with Bonding
# Author: Mahdi Bahmani
# Date: 2025-11-21
# Usage: ./manage_nmcli_ovs_br2.sh {create|delete|recreate|status|help}
# Version: 2.2
#===============================================================================
# Target Network Topology
#
# Bridge: br2
#  ├── Port:br2bond2 (Bonded: IFACE5 + IFACE6)
#  ├── Port: br2 
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
# Environment Variables br2
# ================================
BR2_NAME="br2"
BR2_BOND2_NAME="br2bond2"

BR2_BOND2_MODE="LACP"            # LACP (802.3ad)
# BR2_BOND2_MODE="BALANCE_SLB"       # Load balancing (balance-slb)
# BR2_BOND2_MODE="ACTIVE_BACKUP"   # Active-backup failover

BR2_MAC_IFACE5="00:0c:29:0a:c5:b3"
BR2_MAC_IFACE6="00:0c:29:0a:c5:d1"
BR2_IP_ADDRESS="192.168.178.140"
BR2_SUBNET_MASK="24"
BR2_GATEWAY=""
BR2_DNS1=""
BR2_DNS2=""
BR2_MTU="9000"

RCLOCAL="/etc/rc.local"
# ================================
# Logging
# ================================
LOG_DIR="/var/log/ovs-scripts"
LOG_FILE="${LOG_DIR}/manage_nmcli_ovs_br2.log"
mkdir -p "$LOG_DIR"

# Rotate log >5MB
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 5242880 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
fi

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') :: $0 $* ====="

log() { echo ">>> $(date '+%Y-%m-%d %H:%M:%S') | $*"; }


# ================================
# Function to find interface name by MAC
# ================================
find_iface() {
    local mac="$1"
    iface=$(ip -o link show | awk -v mac="$mac" '$0 ~ mac {print $2}' | sed 's/://' \
            | grep -v "$BR2_NAME" | grep -v virbr0 | head -n1)
    echo "$iface"
}

IFACE5=$(find_iface $BR2_MAC_IFACE5)
IFACE6=$(find_iface $BR2_MAC_IFACE6)

if [[ -z "$IFACE5" || -z "$IFACE6" ]]; then
    log "[ERROR] Could not find network interfaces for provided MACs (IFACE5=${IFACE5}, IFACE6=${IFACE6})."
    exit 1
fi

# ================================
# Prevent concurrent execution
# ================================
LOCK_FILE="/tmp/manage_nmcli_ovs_br2.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "[ERROR] Another instance of this script is running."; exit 1; }

# ================================
# Help Function
# ================================
print_help_br2() {
    echo "=============================================="
    echo " manage_nmcli_ovs_br2.sh - Open vSwitch bridge tool "
    echo "=============================================="
    echo "Usage: $0 {create|delete|status|help}"
    echo
    echo "  create   : Create OVS bridge br2 with bond and IP config"
    echo "  delete   : Remove OVS bridge br2 and all related configs"
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
# Function: create_bridge_br2 (run once)
# ================================
# ---- CREATE MODE ----
create_bridge_br2() {

    echo ">>> Creating OVS bridge: ${BR2_NAME}"
    nmcli connection add type ovs-bridge conn.interface "${BR2_NAME}" con-name "${BR2_NAME}"

    echo ">>> Adding bridge port for ${BR2_NAME}"
    nmcli connection add type ovs-port conn.interface "${BR2_NAME}" master "${BR2_NAME}" con-name "ovs-port-${BR2_NAME}"

    echo ">>> Add Internal Bridge Port and Interface"
    #nmcli con add type ovs-interface slave-type ovs-port conn.interface "$BR2_NAME" master "ovs-port-$BR2_NAME" \
    #  con-name "ovs-if-$BR2_NAME" ipv4.method disabled mtu "$BR2_MTU"
	nmcli connection add type ovs-interface slave-type ovs-port conn.interface "${BR2_NAME}" master "ovs-port-${BR2_NAME}" \
      con-name "ovs-if-${BR2_NAME}" \
      ipv4.method manual mtu "${BR2_MTU}" \
      ipv4.addresses "${BR2_IP_ADDRESS}/${BR2_SUBNET_MASK}" \
    #  ipv4.gateway "${BR2_GATEWAY}" \
    #  ipv4.dns "${BR2_DNS1},${BR2_DNS2}" \
    #  mtu "${BR2_MTU}"

    echo ">>> Creating OVS bond port: ${BR2_BOND2_NAME}"
    nmcli connection add type ovs-port conn.interface "${BR2_BOND2_NAME}" master "${BR2_NAME}" con-name "ovs-port-${BR2_BOND2_NAME}"

    echo ">>> Attaching ${IFACE5} and ${IFACE6} to ${BR2_BOND2_NAME}"
    nmcli connection add type ethernet conn.interface "${IFACE5}" master "ovs-port-${BR2_BOND2_NAME}" con-name "ovs-${BR2_NAME}-if-${IFACE5}" mtu "${BR2_MTU}"
    nmcli connection add type ethernet conn.interface "${IFACE6}" master "ovs-port-${BR2_BOND2_NAME}" con-name "ovs-${BR2_NAME}-if-${IFACE6}" mtu "${BR2_MTU}"

    # Configuring bond monitoring and mode 
    log "Configuring bond monitoring and mode: $BR2_BOND2_MODE"
	
	case "$BR2_BOND2_MODE" in

		ACTIVE_BACKUP)
			# ---------- Active-Backup Mode ----------
			# Linux/OVS: Only one NIC is active at a time. If the active NIC fails,
			#            traffic automatically fails over to the standby NIC.
			# Switch-side: Standard switch (no LACP or EtherChannel needed)
			# Topology: Single switch with dual NICs
			# VMware Equivalent: NIC Teaming -> Failover Order (Active/Standby uplink)
			#                   Load balancing: "Route based on originating virtual port ID"

			nmcli con modify "ovs-port-$BR2_BOND2_NAME" ovs-port.bond-mode active-backup
			log "Configured Active-Backup bond on ${BR2_BOND2_NAME}"
			;;

		BALANCE_SLB)
			# ---------- Balance-SLB (Load Balancing) ----------
			# Linux/OVS: All NICs in the bond are active. Outgoing traffic is distributed
			#            across all active interfaces using adaptive load balancing.
			# Switch-side: 1x Switch Static EtherChannel (manual aggregation)
			# VMware Equivalent: NIC Teaming -> All uplinks active
			#                   Load balancing: "Route based on IP hash"

			nmcli con modify "ovs-port-$BR2_BOND2_NAME" ovs-port.bond-mode balance-slb
			log "Configured Balance-SLB bond on ${BR2_BOND2_NAME} (multi-link active)"
			;;

		LACP)
			# ---------- LACP (802.3ad) ----------
			# Linux/OVS: Uses 802.3ad protocol to negotiate link aggregation with the switch.
			#            Multiple NICs are active, and traffic is load-balanced according to
			#            hash algorithms (typically TCP/UDP or IP hash).
			# Switch: Two switches (stacked or vPC), LACP enabled
			# Topology: Dual switches with vPC
			# VMware Equivalent: vSphere vDS NIC Teaming, Load balancing: "Route based on IP hash"
			#                   Requires LACP-capable switch	
			nmcli con modify "ovs-port-$BR2_BOND2_NAME" ovs-port.bond-mode balance-tcp
            nmcli con modify "ovs-port-$BR2_BOND2_NAME" ovs-port.lacp active

			log "Configured LACP bond on ${BR2_BOND2_NAME} (802.3ad active, negotiated multi-link aggregation)"
			#nmcli connection down "ovs-port-$BR2_BOND2_NAME" && nmcli connection up "ovs-port-$BR2_BOND2_NAME" 
			;;

		*)
			log "[ERROR] Unsupported BR2_BOND2_MODE: $BR2_BOND2_MODE"
			exit 1
			;;
	esac

	log ">>> Reloading and activating connections..."
	# Bring up bridge and bonds
	nmcli con reload
    nmcli con up "ovs-port-$BR2_BOND2_NAME"
    nmcli con up "ovs-$BR2_NAME-if-$IFACE5"
    nmcli con up "ovs-$BR2_NAME-if-$IFACE6"
    nmcli con up "ovs-port-$BR2_NAME"
    nmcli con up "ovs-if-$BR2_NAME"

	# ----------------------------------
    #   Apply OVS Bond Settings
    # ----------------------------------
    log "Set link monitoring for BALANCE_SLB or ACTIVE_BACKUP"
	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ] || [ "$BR2_BOND2_MODE" = "BALANCE_SLB" ]; then

		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-detect-mode=miimon
		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-miimon-interval=100

		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-detect-mode=miimon"
		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ]; then

		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-primary="$IFACE5"

		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-primary=$IFACE5"
	fi


	if [ "$BR2_BOND2_MODE" = "LACP" ]; then
		log "Configure bond for LACP and Transmit hash policy: layer3+4"
		# Configure bond for LACP
		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:lacp-time=fast
		# Transmit hash policy: layer3+4
		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-hash-policy=layer3+4
		
		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:lacp-time=fast"
		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-hash-policy=layer3+4"
	fi


	# Configure the port with VLAN ID 0, tag=0: for untagged (native) VLAN traffic
	ovs-vsctl set port "$BR2_BOND2_NAME" vlan_mode=access tag=0	
	
    echo ">>> Deleting invalid connections..."
    nmcli -t -f NAME,DEVICE connection show | awk -F: '$2==""{print $1}' | while read CONN; do
        echo "Deleting invalid connection: $CONN"
        nmcli connection delete "$CONN"
    done

    echo ">>> OVS bridge setup completed successfully!"
	
	echo ">>> Done. Use '$0 status' to verify."
}

# ================================
# Function: delete_bridge_br2()
# ================================
# ---- DELETE MODE ----
delete_bridge_br2() {
    echo ">>> Deleting OVS Bridge $BR2_NAME and related connections..."

    # Safely get all connections related to $BR2_NAME, IFACE5 or IFACE6
	PATTERN="$(printf "%s|" "$BR2_NAME" "$IFACE5" "$IFACE6" | sed 's/|$//')"
    CONNS=$(nmcli -t -f NAME connection show | grep -E "$PATTERN")

    if [ -z "$CONNS" ]; then
        echo "No connections related to $BR2_NAME found."
    else
        # Delete each connection safely
        echo "$CONNS" | while IFS= read -r c; do
            echo "Deleting connection: $c"
            nmcli connection delete "$c"
        done
    fi
   
	# Delete invalid connections (DEVICE == --)
    echo ">>> Deleting invalid connections (DEVICE == --)..."
    nmcli -t -f NAME,DEVICE connection show | awk -F: '$2==""{print $1}' | while IFS= read -r c; do
        echo "Deleting invalid connection: $c"
        nmcli connection delete "$c"
    done
	
	# Check if "Wired connection 1" exists and delete it
    if nmcli -t -f NAME connection show | grep "Wired connection 1"; then
        echo ">>> Deleting 'Wired connection 1'"
        nmcli connection delete "Wired connection 1"
    else
        echo ">>> 'Wired connection 1' not found, nothing to delete"
    fi
	
    # Remove OVS bridge manually if it still exists
    ovs-vsctl --if-exists del-br "$BR2_NAME"
	
	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ] || [ "$BR2_BOND2_MODE" = "BALANCE_SLB" ]; then

		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-detect-mode=miimon
		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-miimon-interval=100

		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-detect-mode=miimon"
		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ]; then

		ovs-vsctl set port "$BR2_BOND2_NAME" other_config:bond-primary="$IFACE5"

		add_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-primary=$IFACE5"
	fi

    # clean related lines in rc.local
    log "clean related lines in rc.local"
	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ] || [ "$BR2_BOND2_MODE" = "BALANCE_SLB" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-detect-mode=miimon"
		remove_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR2_BOND2_MODE" = "ACTIVE_BACKUP" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-primary=$IFACE5"
	fi


	if [ "$BR2_BOND2_MODE" = "LACP" ]; then
		
		remove_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:lacp-time=fast"
		remove_rc_local_line "ovs-vsctl set port $BR2_BOND2_NAME other_config:bond-hash-policy=layer3+4"
	fi
  
    echo ">>> Deletion of $BR2_NAME completed."
}

# ================================
# Function: status_bridge_br1()
# ================================
# ---- STATUS MODE ----
status_bridge_br2() {
    echo ">>> Current OVS Status:"
    echo "--------------------------------------------------"
    echo "NetworkManager Connections:"
    nmcli -f NAME,TYPE,DEVICE connection show | grep -E "ovs|${IFACE5}|${IFACE6}|${BR2_NAME}" || echo "No relevant NMCLI connections found."

    echo "IP Address Info and Ping Test:"
    if ip addr show "${BR2_NAME}" &>/dev/null; then
	    echo "IP Address Info:"
		ip addr show "${BR2_NAME}" 2>/dev/null
        ping -c 3 8.8.8.8 || echo "Ping test failed!"
    else
        echo "Bridge ${BR2_NAME} has no IP configured."
    fi
    echo "--------------------------------------------------"
	
    echo "=== ovs-vsctl show ==="
    ovs-vsctl show
    echo

    echo "=== ovs-appctl bond/show "${BR2_BOND2_NAME}" ==="
    ovs-appctl bond/show "${BR2_BOND2_NAME}"
    echo
	echo "=== ovs-vsctl list port "${BR2_BOND2_NAME}" ==="
	ovs-vsctl list port "${BR2_BOND2_NAME}"
	echo
	echo "=== ovs-appctl lacp/show "${BR2_BOND2_NAME}" ==="
	ovs-appctl lacp/show "${BR2_BOND2_NAME}"
	echo


    echo "=== LLDP Neighbors ==="
    lldpcli show neighbors ports "${IFACE5}" || echo "No LLDP neighbor on ${IFACE5}"
    lldpcli show neighbors ports "${IFACE6}" || echo "No LLDP neighbor on ${IFACE6}"
    echo

    echo
    echo ">>> Post-creation tests done."
}
# --------------------------------

# ================================
# Main
# ================================
ACTION="${1:-help}"  # create | delete | recreate | status | help, default to 'help' if no argument
case "$ACTION" in
    create)
        create_bridge_br2
        ;;
    delete)
        delete_bridge_br2
        ;;
    status)
        status_bridge_br2
        ;;
    help|"")
        print_help_br2
        ;;
    *)
        echo "Invalid option: $ACTION"
        print_help_br2
        exit 1
        ;;
esac
# --------------------------------
