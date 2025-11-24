#!/bin/bash
#===============================================================================
# Script Name: manage_nmcli_ovs_br1.sh
# Description: Create, Remove, Show Status of OVS bridge with bonding, VLANs, MTU 9000
# Author: Mahdi Bahmani
# Date: 2025-11-21
# Usage: ./manage_nmcli_ovs_br1.sh {create|delete|recreate|status|help}
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

set -o errexit    # Exit the script immediately if any command returns a non-zero exit status (an error).
set -o pipefail   # Return a failure if any command fails, not just the last one.
set -o nounset    # Treat unset variables as an error and exit immediately.

# ================================
# Environment Variables br1
# ================================
BR1_NAME="br1"
BR1_BOND1_NAME="br1bond1"

BR1_BOND1_MODE="LACP"            # LACP (802.3ad)
# BR1_BOND1_MODE="BALANCE_SLB"       # Load balancing (balance-slb)
# BR1_BOND1_MODE="ACTIVE_BACKUP"   # Active-backup failover

BR1_MAC_IFACE3="90:b1:1c:39:ee:e4"
BR1_MAC_IFACE4="90:b1:1c:39:ee:e6"

VLAN151="br1-vlan151"
VLAN152="br1-vlan152"
VLAN153="br1-vlan153"

VLANID151=151
VLANID152=152
VLANID153=153

IPADDR_VLAN151="172.28.151.16/24"
IPADDR_VLAN152="172.28.152.16/24"
IPADDR_VLAN153="172.28.153.16/24"

BR1_MTU="9000"

# Internal Clustering IP
BR1_IP_ADDRESS="192.168.150.16"
BR1_SUBNET_MASK="24"
BR1_GATEWAY=""
BR1_DNS1=""
BR1_DNS2=""

# Optional remote ping targets (e.g., BR1_GATEWAYs or peers)
PING_VLAN151="172.28.151.15"
PING_VLAN152="172.28.152.15"
PING_VLAN153="172.28.153.15"

RCLOCAL="/etc/rc.local"
# ================================
# Logging
# ================================
LOG_DIR="/var/log/ovs-scripts"
LOG_FILE="${LOG_DIR}/manage_nmcli_ovs_br1.log"
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
            | grep -v "$BR1_NAME" | grep -v virbr0 | head -n1)
    echo "$iface"
}
IFACE3=$(find_iface $BR1_MAC_IFACE3)
IFACE4=$(find_iface $BR1_MAC_IFACE4)

if [[ -z "$IFACE3" || -z "$IFACE4" ]]; then
    log "[ERROR] Could not find network interfaces for provided MACs (IFACE3=${IFACE3}, IFACE4=${IFACE4})."
    exit 1
fi

# ================================
# Prevent concurrent execution
# ================================
LOCK_FILE="/tmp/manage_nmcli_ovs_br1.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log "[ERROR] Another instance of this script is running."; exit 1; }

# ================================
# Help Function
# ================================
help_bridge_br1() {
    echo "Usage: $0 {create|delete|status|start|stop|help}"
    echo
    echo "Commands:"
    echo "  create   - Create OVS bridge ($BR1_NAME), bond ($BR1_BOND1_NAME), VLANs (151,152,153) (no IPs)"
    echo "  delete   - Delete all connections related to $BR1_NAME"
    echo "  status   - Show nmcli and ovs-vsctl status"
    echo "  start    - Assign IPs and bring up bridge + VLANs"
    echo "  stop     - Remove IPs and bring down bridge + VLANs"
    echo "  help     - Show this help message"
    exit 0
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
# Function: create_bridge_br1 (run once)
# ================================
# ---- CREATE MODE ----
create_bridge_br1() {
    
	log "Checking if OVS bridge '${BR1_NAME}' exists..."
    if ovs-vsctl br-exists "${BR1_NAME}"; then
        log "Bridge '${BR1_NAME}' already exists. Skipping creation."
        return 0
    fi

    log ">>> Creating OVS Bridge $BR1_NAME with bond $BR1_BOND1_NAME and VLANs..."
    # Create the OVS Bridge
    nmcli con add type ovs-bridge conn.interface "$BR1_NAME" con-name "$BR1_NAME"

    # Change MTU on the physical NICs
    ip link set "$IFACE3" mtu "$BR1_MTU" || true
    ip link set "$IFACE4" mtu "$BR1_MTU" || true

    # Internal bridge interface
    log ">>> Add Internal Bridge Port and Interface"
    nmcli con add type ovs-port conn.interface "$BR1_NAME" master "$BR1_NAME" con-name "ovs-port-$BR1_NAME"
    nmcli con add type ovs-interface slave-type ovs-port conn.interface "$BR1_NAME" master "ovs-port-$BR1_NAME" \
        con-name "ovs-if-$BR1_NAME" ipv4.method manual ipv4.addresses "${BR1_IP_ADDRESS}/${BR1_SUBNET_MASK}" mtu "$BR1_MTU"

    # Bond
    log ">>> Create the Bond Port"
    nmcli con add type ovs-port conn.interface "$BR1_BOND1_NAME" master "$BR1_NAME" con-name "ovs-port-$BR1_BOND1_NAME"
    nmcli con modify "ovs-port-$BR1_BOND1_NAME" ovs-port.trunks "0,$VLANID151,$VLANID152,$VLANID153" 

	# Physical interfaces as bond slaves
    log ">>> Add Physical Interfaces as Bond Slaves"
    nmcli con add type ethernet conn.interface "$IFACE3" master "ovs-port-$BR1_BOND1_NAME" con-name "ovs-$BR1_NAME-if-$IFACE3" mtu "$BR1_MTU"
    nmcli con add type ethernet conn.interface "$IFACE4" master "ovs-port-$BR1_BOND1_NAME" con-name "ovs-$BR1_NAME-if-$IFACE4" mtu "$BR1_MTU"

    # Configuring bond monitoring and mode 
    log "Configuring bond monitoring and mode: $BR1_BOND1_MODE"
	
	case "$BR1_BOND1_MODE" in

		ACTIVE_BACKUP)
			# ---------- Active-Backup Mode ----------
			# Linux/OVS: Only one NIC is active at a time. If the active NIC fails,
			#            traffic automatically fails over to the standby NIC.
			# Switch-side: Standard switch (no LACP or EtherChannel needed)
			# Topology: Single switch with dual NICs
			# VMware Equivalent: NIC Teaming -> Failover Order (Active/Standby uplink)
			#                   Load balancing: "Route based on originating virtual port ID"

			nmcli con modify "ovs-port-$BR1_BOND1_NAME" ovs-port.bond-mode active-backup
			log "Configured Active-Backup bond on ${BR1_BOND1_NAME}"
			;;

		BALANCE_SLB)
			# ---------- Balance-SLB (Load Balancing) ----------
			# Linux/OVS: All NICs in the bond are active. Outgoing traffic is distributed
			#            across all active interfaces using adaptive load balancing.
			# Switch-side: 1x Switch Static EtherChannel (manual aggregation)
			# VMware Equivalent: NIC Teaming -> All uplinks active
			#                   Load balancing: "Route based on IP hash"

			nmcli con modify "ovs-port-$BR1_BOND1_NAME" ovs-port.bond-mode balance-slb
			log "Configured Balance-SLB bond on ${BR1_BOND1_NAME} (multi-link active)"
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
			nmcli con modify "ovs-port-$BR1_BOND1_NAME" ovs-port.bond-mode balance-tcp
            nmcli con modify "ovs-port-$BR1_BOND1_NAME" ovs-port.lacp active
			log "Configured LACP bond on ${BR1_BOND1_NAME} (802.3ad active, negotiated multi-link aggregation)"
			#nmcli connection down "ovs-port-$BR1_BOND1_NAME" && nmcli connection up "ovs-port-$BR1_BOND1_NAME" 
			;;

		*)
			log "[ERROR] Unsupported BR1_BOND1_MODE: $BR1_BOND1_MODE"
			exit 1
			;;
	esac

    # VLANs
    echo ">>> Create VLAN Interfaces"
    # VLAN 151
    echo ">>> Create $VLAN151"
	if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN151}"; then
        nmcli con add type ovs-port conn.interface "$VLAN151" master "$BR1_NAME" ovs-port.tag 151 con-name "ovs-$BR1_NAME-port-$VLAN151"
        nmcli con add type ovs-interface slave-type ovs-port conn.interface "$VLAN151" master "ovs-$BR1_NAME-port-$VLAN151" \
          con-name "ovs-if-$VLAN151" ipv4.method manual ipv4.addresses "$IPADDR_VLAN151" mtu "$BR1_MTU"
    fi
	
    # VLAN 152
    echo ">>> Create $VLAN152"
    if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN152}"; then
	    nmcli con add type ovs-port conn.interface "$VLAN152" master "$BR1_NAME" ovs-port.tag 152 con-name "ovs-$BR1_NAME-port-$VLAN152"
        nmcli con add type ovs-interface slave-type ovs-port conn.interface "$VLAN152" master "ovs-$BR1_NAME-port-$VLAN152" \
          con-name "ovs-if-$VLAN152" ipv4.method manual ipv4.addresses "$IPADDR_VLAN152" mtu "$BR1_MTU"
    fi
	
    # VLAN 153
    echo ">>> Create $VLAN153"
    if ! ovs-vsctl list-ports "${BR1_NAME}" | grep -q "${VLAN153}"; then
	    nmcli con add type ovs-port conn.interface "$VLAN153" master "$BR1_NAME" ovs-port.tag 153 con-name "ovs-$BR1_NAME-port-$VLAN153"
        nmcli con add type ovs-interface slave-type ovs-port conn.interface "$VLAN153" master "ovs-$BR1_NAME-port-$VLAN153" \
          con-name "ovs-if-$VLAN153" ipv4.method manual ipv4.addresses "$IPADDR_VLAN153" mtu "$BR1_MTU"
    fi
	
    # Bring up bridge and bonds
	nmcli con reload
    nmcli con up "ovs-port-$BR1_BOND1_NAME"
    nmcli con up "ovs-$BR1_NAME-if-$IFACE3"
    nmcli con up "ovs-$BR1_NAME-if-$IFACE4"
    nmcli con up "ovs-port-$BR1_NAME"
    nmcli con up "ovs-if-$BR1_NAME"

    for VLAN in "$VLAN151" "$VLAN152" "$VLAN153"; do
        nmcli con up "ovs-if-$VLAN"
    done
	

	# ----------------------------------
    #   Apply OVS Bond Settings
    # ----------------------------------
    log "Set link monitoring for BALANCE_SLB or ACTIVE_BACKUP"
	if [ "$BR1_BOND1_MODE" = "ACTIVE_BACKUP" ] || [ "$BR1_BOND1_MODE" = "BALANCE_SLB" ]; then

		ovs-vsctl set port "$BR1_BOND1_NAME" other_config:bond-detect-mode=miimon
		ovs-vsctl set port "$BR1_BOND1_NAME" other_config:bond-miimon-interval=100

		add_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-detect-mode=miimon"
		add_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR1_BOND1_MODE" = "ACTIVE_BACKUP" ]; then

		ovs-vsctl set port "$BR1_BOND1_NAME" other_config:bond-primary="$IFACE3"

		add_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-primary=$IFACE3"
	fi


	if [ "$BR1_BOND1_MODE" = "LACP" ]; then
		log "Configure bond for LACP and Transmit hash policy: layer3+4"
		# Configure bond for LACP
		ovs-vsctl set port "$BR1_BOND1_NAME" other_config:lacp-time=fast
		# Transmit hash policy: layer3+4
		ovs-vsctl set port "$BR1_BOND1_NAME" other_config:bond-hash-policy=layer3+4
		
		add_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:lacp-time=fast"
		add_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-hash-policy=layer3+4"
	fi

    # Clean up invalid connections
    nmcli -t -f NAME,DEVICE connection show | awk -F: '$2==""{print $1}' | while IFS= read -r CONN; do
        echo "Deleting invalid connection: $CONN"
        nmcli connection delete "$CONN"
    done

    # --- Summary ---
    echo
    echo "Bridge: $BR1_NAME"
    echo "Bond: $BR1_BOND1_NAME ($BR1_BOND1_MODE)"
    echo "Interfaces: $IFACE3, $IFACE4"
    echo "VLANs: 151, 152, 153"
    echo "MTU: $BR1_MTU"
    echo
	
    ovs-vsctl show
    nmcli con show
    ip a
	# Show current bond status
    ovs-appctl bond/show "${BR1_BOND1_NAME}"
    echo ">>> Create complete. Use '$0 status' to verify."
}

# ================================
# Function: delete_bridge_br1()
# ================================
# ---- DELETE MODE ----
delete_bridge_br1() {
    echo ">>> Deleting OVS Bridge $BR1_NAME and related connections..."

    # Delete all connections related to bridge or physical interfaces
    PATTERN="$(printf "%s|" "$BR1_NAME" "$IFACE3" "$IFACE4" | sed 's/|$//')"
    CONNS=$(nmcli -t -f NAME connection show | grep -E "$PATTERN")
    if [ -n "$CONNS" ]; then
        echo "$CONNS" | while IFS= read -r c; do
            echo "Deleting connection: $c"
            nmcli connection delete "$c"
        done
    fi

    # Delete invalid connections
    nmcli -t -f NAME,DEVICE connection show | awk -F: '$2==""{print $1}' | while IFS= read -r c; do
        echo "Deleting invalid connection: $c"
        nmcli connection delete "$c"
    done

    # Delete default Wired connection if exists
    if nmcli -t -f NAME connection show | grep -q "Wired connection 1"; then
        echo ">>> Deleting 'Wired connection 1'"
        nmcli connection delete "Wired connection 1"
    fi

    # Delete OVS bridge manually if still exists
    ovs-vsctl --if-exists del-br "$BR1_NAME"

    # clean related lines in rc.local
    log "clean related lines in rc.local"
	if [ "$BR1_BOND1_MODE" = "ACTIVE_BACKUP" ] || [ "$BR1_BOND1_MODE" = "BALANCE_SLB" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-detect-mode=miimon"
		remove_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-miimon-interval=100"
	fi


	if [ "$BR1_BOND1_MODE" = "ACTIVE_BACKUP" ]; then

		remove_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-primary=$IFACE3"
	fi


	if [ "$BR1_BOND1_MODE" = "LACP" ]; then
		
		remove_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:lacp-time=fast"
		remove_rc_local_line "ovs-vsctl set port $BR1_BOND1_NAME other_config:bond-hash-policy=layer3+4"
	fi
	
    ovs-vsctl show
    nmcli con show
    ip a
    echo ">>> Deletion complete."
}

# ================================
# Function: status_bridge_br1()
# ================================
# ---- STATUS MODE ----
status_bridge_br1() {
    echo "=== nmcli connections ==="
    nmcli -t -f NAME,DEVICE connection show
    echo

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

# --------------------------------
# ================================
# Main
# ================================
ACTION="${1:-help}"  # create | delete | recreate | status | help, default to 'help' if no argument
case "$ACTION" in
    create) create_bridge_br1 ;;
    delete) delete_bridge_br1 ;;
    status) status_bridge_br1 ;;
    help|--help|-h|"") help_bridge_br1 ;;
    *) echo "Unknown command: $1"; help_bridge_br1 ;;
esac
# --------------------------------
