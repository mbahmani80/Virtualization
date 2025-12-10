#!/bin/bash
#===============================================================================
# Rocky Linux 9.5
# Script Name: kvm_postconfig.sh
# Description: Post-install configuration script for KVM, libvirt, Open vSwitch,
#              and Cockpit on Rocky Linux.
# Author: Mahdi Bahmani
# Date:   2025-08-28
#===============================================================================
#
# 
# Run as root

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

#set -euo pipefail


LOGFILE="/tmp/01_kvm_postconfig_online.log"
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
        # Uncomment if you want the script to stop on error
        # exit 1
    fi
}

log "=== Script started ==="

run_cmd "sudo find /root/bin/ -type f \( -name '*.sh' -o -name '*.cfg' \) -exec dos2unix {} \;"

log "=== Enabling EPEL and CRB repositories ==="
run_cmd "dnf install -y epel-release"
run_cmd "/usr/bin/crb enable"

log "=== Enabling Open vSwitch NFV SIG repository ==="
run_cmd "dnf install -y centos-release-nfv-openvswitch"

log "=== Updating cache ==="
run_cmd "dnf makecache"

log ">>> Updating system packages..."
run_cmd "dnf update -y"

log "=== Installing base utilities and virtualization packages ==="
run_cmd "dnf install -y \
    fail2ban openssl sshguard tcpdump net-tools lldpd bind-utils lvm2 xfsprogs nfs-utils rsync parted \
    lsscsi vim nano screen curl wget zip unzip lshw pv htop iotop iftop sysstat dstat glances gpm \
    qemu-kvm libvirt virt-install libguestfs-tools virt-top virt-viewer \
    edk2-ovmf swtpm swtpm-tools openvswitch3.3.x86_64 NetworkManager-ovs lsof"

log "=== Enabling libvirt and Open vSwitch services ==="
run_cmd "systemctl enable --now libvirtd"
run_cmd "systemctl enable --now openvswitch"
run_cmd "systemctl enable --now lldpd"

log "=== Installing Cockpit and extensions ==="
run_cmd "dnf install -y cockpit cockpit-*"

log "=== Enabling Cockpit service ==="
run_cmd "systemctl enable --now cockpit.socket"
run_cmd "firewall-cmd --permanent --zone=public --add-service=cockpit"
run_cmd "firewall-cmd --reload"

log "=== Kernel network sysctl tuning ==="
run_cmd "sysctl -w net.ipv4.ip_forward=1"
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
run_cmd "sysctl -w net.ipv4.conf.all.rp_filter=2"
echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf

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


# Disable SELinux
log "===  Disable SELinux ==="
run_cmd "setenforce 0"
run_cmd "sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"

# Placeholder for storage pool config
log "=== Storage Pool configuration (to be added) ==="

log "=== Setup completed successfully ==="

