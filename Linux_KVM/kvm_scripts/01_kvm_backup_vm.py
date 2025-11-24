#!/usr/bin/env python3
import subprocess
import os
import logging
from datetime import datetime
import shlex

# =======================
# Logging Setup
# =======================
LOG_FILE = "/var/log/kvm_snapshot_manager.log"
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)

class KVMManager:
    def __init__(self, backup_dir):
        self.backup_dir = backup_dir
        os.makedirs(self.backup_dir, exist_ok=True)
        self.vms = self.get_all_vms()
        self.backup_metadata = []  # Track metadata for all backups
        logging.info(f"Initialized KVMManager with backup directory: {self.backup_dir}")

    def get_all_vms(self):
        result = subprocess.run(['virsh', 'list', '--all', '--name'],
                                capture_output=True, text=True)
        vms = [vm.strip() for vm in result.stdout.splitlines() if vm.strip()]
        logging.info(f"Found VMs: {', '.join(vms)}")
        return vms

    def get_vm_disks(self, vm_name):
        result = subprocess.run(['virsh', 'domblklist', vm_name],
                                capture_output=True, text=True)
        disks = []
        for line in result.stdout.splitlines()[2:]:
            parts = line.split()
            if len(parts) >= 2:
                source = parts[1].strip()
                # Ignore empty, dash, or cdrom sources
                if source and source != '-' and 'cdrom' not in source.lower():
                    disks.append(source)
        logging.info(f"[{vm_name}] Disks: {', '.join(disks) if disks else 'None'}")
        return disks

    def dump_xml(self, vm_name, disk_paths):
        backup_xml_path = os.path.join(self.backup_dir, f"{vm_name}.xml")
        os.makedirs(os.path.dirname(backup_xml_path), exist_ok=True)
        print(f"[{vm_name}] Dumping XML to backup path: {backup_xml_path}")
        logging.info(f"[{vm_name}] Dumping XML to backup path: {backup_xml_path}")
        with open(backup_xml_path, 'w') as f:
            subprocess.run(['virsh', 'dumpxml', vm_name], stdout=f)

        # Record XML metadata
        self.backup_metadata.append(f"{vm_name},xml,{backup_xml_path},N/A")

        file_based_dirs = {os.path.dirname(d) for d in disk_paths if not d.startswith("/dev/")}
        for directory in file_based_dirs:
            if directory:  # Fix: skip empty directory strings
                os.makedirs(directory, exist_ok=True)
                disk_xml_path = os.path.join(directory, f"{vm_name}.xml")
                print(f"Dumping XML next to disk: {disk_xml_path}")
                logging.info(f"[{vm_name}] Dumping XML to disk directory: {disk_xml_path}")
                with open(disk_xml_path, 'w') as f:
                    subprocess.run(['virsh', 'dumpxml', vm_name], stdout=f)

    def backup_lvm_disk(self, vm_name, disk):
        """Backup LVM or thin LV safely with automatic type detection."""
        import re

        if not disk.startswith("/dev/"):
            return None

        print(f"💾 LVM disk detected: {disk}")
        logging.info(f"[{vm_name}] LVM disk detected: {disk}")

        # Determine VG name, attributes, and pool info
        lv_info = subprocess.run(
            ['lvs', '-a', '--noheadings', '-o', 'vg_name,lv_attr,pool_lv', disk],
            capture_output=True, text=True
        ).stdout.strip().split()
        if len(lv_info) < 2:
            raise RuntimeError(f"Could not determine LV info for {disk}")

        vg_name, lv_attr = lv_info[0], lv_info[1]
        pool_name = lv_info[2] if len(lv_info) > 2 else ''
        is_thin_lv = lv_attr.startswith('V') or lv_attr.startswith('t') and bool(pool_name)
        is_thin_pool = lv_attr.startswith('t') and not pool_name

        lv_size_bytes = int(subprocess.run(
            ['lvs', '--noheadings', '-o', 'lv_size', '--units', 'b', '--nosuffix', disk],
            capture_output=True, text=True
        ).stdout.strip())
        snap_size_bytes = max(lv_size_bytes // 10, 2 * 1024 * 1024 * 1024)

        lv_basename = os.path.basename(disk)
        snap_name = f"backup_{vm_name}_{lv_basename}_snap"
        snap_device = f"/dev/{vg_name}/{snap_name}"
        out_file = os.path.join(self.backup_dir, f"{lv_basename}_{datetime.now().strftime('%Y%m%d')}.img.xz")

        # === Snapshot or direct backup ===
        try:
            if is_thin_pool:
                print(f"⚠️ {disk} appears to be a thin pool, not a thin LV — backing up directly (no snapshot).")
                cmd = f"pv {shlex.quote(disk)} | xz -9 > {shlex.quote(out_file)}"
                subprocess.run(cmd, shell=True, check=True)

            elif is_thin_lv:
                print(f"Creating thin snapshot {snap_name}")
                subprocess.run(['lvcreate', '-s', '-n', snap_name, disk], check=True)
                cmd = f"pv {shlex.quote(snap_device)} | xz -9 > {shlex.quote(out_file)}"
                subprocess.run(cmd, shell=True, check=True)
                subprocess.run(['lvremove', '-f', snap_device], check=True)

            else:
                print(f"Creating standard snapshot {snap_name} size {snap_size_bytes//1024//1024} MB")
                subprocess.run(['lvcreate', '--snapshot', '--size', f"{snap_size_bytes}B",
                                '--name', snap_name, disk], check=True)
                cmd = f"pv {shlex.quote(snap_device)} | xz -9 > {shlex.quote(out_file)}"
                subprocess.run(cmd, shell=True, check=True)
                subprocess.run(['lvremove', '-f', snap_device], check=True)

            print(f"✅ Backup completed for {disk} → {out_file}")
            self.backup_metadata.append(f"{vm_name},lvm,{disk},{lv_size_bytes}")

        except subprocess.CalledProcessError as e:
            print(f"❌ Backup failed for {disk}: {e}")
            logging.error(f"[{vm_name}] LVM backup failed: {e}")


    def backup_file_disks(self, vm_name, disks):
        file_disks = [d for d in disks if not d.startswith("/dev/")]
        if not file_disks:
            return

        tar_file_path = os.path.join(self.backup_dir, f"{vm_name}.tar.gz")
        os.makedirs(os.path.dirname(tar_file_path), exist_ok=True)

        disk_paths_str = " ".join([shlex.quote(d) for d in file_disks])
        cmd = f"tar cf - {disk_paths_str} | pv | gzip > {shlex.quote(tar_file_path)}"
        print(f"[{vm_name}] Creating tar.gz archive with progress for {len(file_disks)} disks")
        logging.info(f"[{vm_name}] Creating tar.gz archive for file-based disks")
        subprocess.run(cmd, shell=True, check=True)
        print(f"[{vm_name}] Completed tar.gz archive: {tar_file_path}")
        logging.info(f"[{vm_name}] Completed tar.gz archive: {tar_file_path}")

        # Record file-based disk metadata
        for d in file_disks:
            self.backup_metadata.append(f"{vm_name},file,{d},N/A")

    def backup_vm(self, vm_name, backup_disks=True):
        disks = self.get_vm_disks(vm_name)
        self.dump_xml(vm_name, disks)

        if backup_disks:
            for disk in disks:
                if disk.startswith("/dev/"):
                    self.backup_lvm_disk(vm_name, disk)

            self.backup_file_disks(vm_name, disks)
        else:
            print(f"✅ XML-only backup completed for VM: {vm_name}")
            logging.info(f"[{vm_name}] XML-only backup completed")

    def process_vms(self, selected_vms=None, backup_disks=True):
        if selected_vms is None:
            vms_to_process = self.vms
        else:
            vms_to_process = [vm for vm in selected_vms if vm in self.vms]
            missing = set(selected_vms) - set(vms_to_process)
            if missing:
                print(f"Warning: These VMs were not found and will be skipped: {', '.join(missing)}")
                logging.warning(f"VMs not found and skipped: {', '.join(missing)}")

        total_vms = len(vms_to_process)
        for idx, vm in enumerate(vms_to_process, start=1):
            print(f"\n[{idx}/{total_vms}] Processing VM: {vm}")
            logging.info(f"[{idx}/{total_vms}] Processing VM: {vm}")
            self.backup_vm(vm, backup_disks=backup_disks)
            print(f"[{idx}/{total_vms}] Completed VM: {vm}")
            logging.info(f"[{idx}/{total_vms}] Completed VM: {vm}")
            print("------------------------")

        # Write metadata file at the end
        self.write_metadata_file()

    def write_metadata_file(self):
        metadata_file = os.path.join(self.backup_dir, "backup_metadata.txt")
        with open(metadata_file, 'w') as f:
            for line in self.backup_metadata:
                f.write(line + "\n")
        print(f"✅ Backup metadata written to {metadata_file}")
        logging.info(f"Backup metadata written to {metadata_file}")


if __name__ == "__main__":
    default_backup_dir = f"/mnt/kvm_pool/fspool1/VM_backups/{datetime.now().strftime('%Y-%m-%d')}"
    user_input = input(f"Enter the backup path for XML/files [default: {default_backup_dir}]: ").strip()
    backup_path = user_input if user_input else default_backup_dir

    manager = KVMManager(backup_dir=backup_path)

    # Backup mode selection
    mode = input("Backup mode: [1] XML only, [2] XML + disks (default 2): ").strip()
    backup_disks = True if mode != '1' else False

    # Select VMs
    choice = 'select'
    if choice == 'select':
        sorted_vms = sorted(manager.vms)
        print("Available VMs:")
        for idx, vm in enumerate(sorted_vms, start=1):
            print(f"[{idx}] {vm}")

        selected_input = input("Enter the numbers of the VMs to backup (comma-separated): ").strip()
        selected_nums = [int(n.strip()) for n in selected_input.split(',') if n.strip().isdigit()]
        selected_vms = [sorted_vms[n - 1] for n in selected_nums if 1 <= n <= len(sorted_vms)]

        if not selected_vms:
            print("No valid VMs selected. Exiting.")
        else:
            manager.process_vms(selected_vms, backup_disks=backup_disks)
    else:
        manager.process_vms(backup_disks=backup_disks)

