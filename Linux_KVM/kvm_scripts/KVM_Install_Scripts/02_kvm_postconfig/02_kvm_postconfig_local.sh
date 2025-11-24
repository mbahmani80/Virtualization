#!/bin/bash
#===============================================================================
# Rocky Linux 9.x
# Script Name: 02_kvm_postconfig_local.sh
# Description: Post-install configuration script for KVM, libvirt, Open vSwitch,
#              and Cockpit on Rocky Linux.
# Author: Mahdi Bahmani
# Date:   2025-08-28
#===============================================================================
#
# nmcli con show
# nmcli con modify ens37 connection.interface-name ens37
# nmcli con modify ens37 ipv4.method auto
# systemctl restart NetworkManager
# nmcli con up ens37
# nmcli con show

# sudo nmcli c modify ens224 ipv4.addresses 10.1.1.220/24
# sudo nmcli c modify ens224 ipv4.gateway 10.1.1.1
# sudo nmcli c modify ens224 ipv4.dns "127.0.0.1  8.8.8.8 "
# sudo nmcli c modify ens224 ipv4.method manual
# sudo nmcli c modify ens224 connection.autoconnect yes
# sudo nmcli c modify ens224 +ipv4.dns-search "l.itstorage.co, mbctux.net"
# sudo nmcli c down ens224; sudo nmcli c up ens224
#
# Run as root
#set -euo pipefail

LOGFILE="/tmp/02_kvm_postconfig_local.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run_cmd() {
    log "Running: $*"
    if eval "$@"; then
        log "SUCCESS: $*"
    else
        log "ERROR: $* (exit code $?)"
        # Uncomment if you want script to stop on failure
        # exit 1
    fi
}

log "=== Script started ==="

run_cmd "sudo find /root/bin/ -type f \( -name '*.sh' -o -name '*.cfg' \) -exec dos2unix {} \;"

log "=== Enabling EPEL and CRB repositories ==="
run_cmd "dnf -y localinstall --disablerepo=* /root/bin/RPM/01_dnf_pkgs_repo/*.rpm"
run_cmd "/usr/bin/crb enable"


log "=== Creating local repository for RPM packages ==="
LOCAL_REPO_DIR="/root/bin/RPM/02_dnf_pkgs"
LOCAL_REPO_CONF="/etc/yum.repos.d/local.repo"

# Create repo metadata
run_cmd "createrepo -v $LOCAL_REPO_DIR"

# Create a local repo config
cat <<EOF | sudo tee $LOCAL_REPO_CONF
[localrepo]
name=Local RPM Repository
baseurl=file://$LOCAL_REPO_DIR
enabled=1
gpgcheck=0
EOF

log "=== Installing base utilities and virtualization packages from local repo ==="
run_cmd "dnf -y --disablerepo='*' --enablerepo='localrepo' install '*'"
run_cmd "dnf -y localinstall --skip-broken --disablerepo=* /root/bin/RPM/02_dnf_pkgs/*.rpm"

log '=== Enabling libvirt, Open vSwitch, and lldpd services ==='
run_cmd "systemctl enable --now libvirtd"
run_cmd "systemctl enable --now openvswitch"
run_cmd "systemctl enable --now lldpd"

log "=== Enabling Cockpit service ==="
run_cmd "systemctl enable --now cockpit.socket"
run_cmd "firewall-cmd --permanent --zone=public --add-service=cockpit"
run_cmd "firewall-cmd --reload"

log "=== Kernel network sysctl tuning ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
run_cmd "sysctl -w net.ipv4.ip_forward=1"
echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf
run_cmd "sysctl -w net.ipv4.conf.all.rp_filter=2"

log "=== Enabling IOMMU for virtualization passthrough ==="
run_cmd "grubby --update-kernel=ALL --args='intel_iommu=on iommu=pt'"
run_cmd "dracut -f"

log "=== Adding user sysadmin to kvm and libvirt groups ==="
run_cmd "usermod -aG kvm,libvirt sysadmin"

log "=== Configuring KVM bridge and permissions ==="
echo "allow all" > /etc/qemu-kvm/bridge.conf
run_cmd "systemctl restart libvirtd"
run_cmd "systemctl restart NetworkManager"

log "=== Turing on rc-local.service ==="
run_cmd "chmod 755 /etc/rc.d/rc.local"
run_cmd "systemctl enable rc-local.service"

#log "=== For additional safety, set passwords to expire immediately after first boot: chage -d 0 root"
#run_cmd "chage -d 0 root"

log "===  Enable gpm service ==="
run_cmd "systemctl enable gpm"
run_cmd "systemctl start gpm"

log "===  disable a local repo permanently ==="
run_cmd "sudo sed -i 's/enabled=1/enabled=0/' /etc/yum.repos.d/local.repo"

log "=== Cleaning runonce.service ==="
run_cmd "systemctl stop runonce.service"
run_cmd "systemctl disable runonce.service"
run_cmd "mv /etc/systemd/system/runonce.service /root/bin/"


# Disable SELinux
log "===  Disable SELinux ==="
run_cmd "setenforce 0"
run_cmd "sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"

log "=== Setup completed successfully ==="
