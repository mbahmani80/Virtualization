#!/usr/bin/env python3
import libvirt
import xml.etree.ElementTree as ET
import os
import shutil
import logging
import sys
import subprocess
import time
import shlex

def shlex_quote(s):
    return shlex.quote(s)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Server management
KVM_NODES = {
    "kvmnode01": {"ip": "172.28.150.15", "uri": "qemu+ssh://root@kvmnode01.lab.local/system"},
    "kvmnode02": {"ip": "172.28.150.16", "uri": "qemu+ssh://root@kvmnode02.lab.local/system"}
}

# Migration network path
MIGRATION_PATHS = {
    "kvmnode01": {"ip": "172.28.153.15", "uri": "qemu+ssh://root@kvmnode01-mig.lab.local/system"},
    "kvmnode02": {"ip": "172.28.153.16", "uri": "qemu+ssh://root@kvmnode02-mig.lab.local/system"}
}


class KVMManager:
    def __init__(self, uri="qemu:///system"):
        self.conn = libvirt.open(uri)
        if not self.conn:
            logger.error("Failed to open connection to KVM hypervisor")
            sys.exit(1)
        logger.info(f"Connected to KVM at {uri}")

    def list_vms(self):
        domains = [self.conn.lookupByID(id) for id in self.conn.listDomainsID()]
        domains += [self.conn.lookupByName(name) for name in self.conn.listDefinedDomains()]
        return domains

    # -----------------------
    # New helper function
    # -----------------------
    def is_vm_running(self, vm):
        """
        Check if the VM is running.
        Returns True if running, False if shut down or paused.
        """
        try:
            state, _ = vm.state()
            return state == libvirt.VIR_DOMAIN_RUNNING
        except libvirt.libvirtError as e:
            logger.error(f"Failed to get VM state: {e}")
            return False

    def get_vm(self, name):
        try:
            return self.conn.lookupByName(name)
        except libvirt.libvirtError:
            logger.error(f"VM '{name}' not found")
            return None

    def show_vm_info(self, vm):
        xml = vm.XMLDesc()
        tree = ET.fromstring(xml)
        disks = tree.findall("./devices/disk[@device='disk']/source")
        print(f"VM Name: {vm.name()}")
        disk_paths = []
        for i, disk in enumerate(disks, 1):
            path = disk.get('file')
            print(f" Disk {i}: {path}")
            disk_paths.append(path)
        return disk_paths

    def get_vm_disks(self, vm):
        """
        Return a list of actual disk files (exclude cdroms and directories)
        """
        disks = []
        for disk in self.show_vm_info(vm):  # assuming show_vm_info returns all disks
            if os.path.isfile(disk) and not disk.lower().endswith('.iso'):
                disks.append(disk)
        return disks

    # -----------------------
    # Helper: check if VM has NVRAM
    # -----------------------
    def has_nvram(self, vm):
        """
        Returns True if the VM XML contains NVRAM (UEFI) configuration.
        """
        try:
            xml = vm.XMLDesc()
            tree = ET.fromstring(xml)
            nvram = tree.find("./os/nvram")
            return nvram is not None
        except libvirt.libvirtError as e:
            logger.error(f"Failed to check NVRAM for VM '{vm.name()}': {e}")
            return False

    # -----------------------
    # Helper: undefine VM safely
    # -----------------------
    def undefine_vm(self, vm):
        """
        Undefine VM from source host.
        If VM has NVRAM, use 'virsh undefine --nvram' to remove XML and NVRAM safely.
        Otherwise, use libvirt's vm.undefine().
        """
        try:
            if self.has_nvram(vm):
                logger.info(f"VM '{vm.name()}' has NVRAM, using 'virsh undefine --nvram'")
                subprocess.run(
                    ["virsh", "undefine", vm.name(), "--nvram"],
                    check=True
                )
                logger.info(f"VM '{vm.name()}' XML and NVRAM removed successfully")
            else:
                vm.undefine()
                logger.info(f"VM '{vm.name()}' XML removed successfully (no NVRAM)")
            return True
        except Exception as e:
            logger.error(f"Failed to undefine VM '{vm.name()}': {e}")
            return False

    # -----------------------
    # List storage pools and volumes
    # -----------------------
    def list_storage_pools_vols(self):
        """
        Returns a dictionary of all storage pools and their volumes.
        Example: {'pool_name': ['/path/to/vol1', '/path/to/vol2']}
        """
        pools_dict = {}
        try:
            pools = self.conn.listAllStoragePools()
            for pool in pools:
                vols = pool.listAllVolumes()
                vol_paths = [vol.path() for vol in vols]
                pools_dict[pool.name()] = vol_paths
            return pools_dict
        except libvirt.libvirtError as e:
            logger.error(f"Failed to list storage pools: {e}")
            return {}

    def list_storage_pools(self):
        """
        List all storage pools on the current host (pool names only, no volumes)
        """
        print("\nAvailable storage pools on current host:")
        # Run virsh pool-list --all
        result = subprocess.run(['virsh', 'pool-list', '--all'], capture_output=True, text=True)
        lines = result.stdout.splitlines()[2:]  # Skip header lines
        pools = []
        for line in lines:
            if line.strip():
                # The pool name is the first column
                pool_name = line.split()[0]
                pools.append(pool_name)

        for idx, pool in enumerate(pools, start=1):
            print(f"{idx}. Pool: {pool}")

        return pools


    def remote_copy(self, src_path, dest_host, dest_path):
        """
        Copy a disk from source KVM node to destination KVM node over SSH.
        """
        print(f"Copying {src_path} → {dest_host}:{dest_path}")

        dest_dir = os.path.dirname(dest_path)

        # Create destination directory
        subprocess.run(["ssh", dest_host, "mkdir", "-p", dest_dir], check=True)

        # Copy disk over SSH using rsync
        cmd = [
            "rsync", "-avh", "--progress",
            src_path,
            f"{dest_host}:{dest_path}"
        ]

        subprocess.run(cmd, check=True)

        print("✓ Copy completed")

    # -----------------------
    # Change compute resource only
    # -----------------------

    def migrate_compute(self, vm, dest_uri):
        """
        Migrate VM to another host without changing storage.
        - Live migration if VM is running.
        - Offline migration if VM is stopped (copies XML only).
        - Removes source VM after migration safely, including NVRAM if present.
        """
        try:
            dest_conn = libvirt.open(dest_uri)
            if not dest_conn:
                logger.error(f"Failed to connect to destination {dest_uri}")
                return False

            if self.is_vm_running(vm):
                # Live migration
                logger.info(f"VM '{vm.name()}' is running. Performing live migration.")
                flags = (
                    libvirt.VIR_MIGRATE_LIVE |
                    libvirt.VIR_MIGRATE_PEER2PEER |
                    libvirt.VIR_MIGRATE_UNDEFINE_SOURCE
                )
                vm.migrate2(dest_conn, dxml=None, flags=flags, dname=None, uri=None, bandwidth=0)
                logger.info("Live compute migration completed successfully")
                # Source VM removed automatically by UNDEFINE_SOURCE
            else:
                # Offline migration: copy XML only
                logger.info(f"VM '{vm.name()}' is not running. Performing offline migration (copy XML only).")
                xml_desc = vm.XMLDesc()
                dest_conn.defineXML(xml_desc)
                logger.info("Offline compute migration completed successfully")
                # Remove source safely
                self.undefine_vm(vm)

            dest_conn.close()
            return True

        except libvirt.libvirtError as e:
            logger.error(f"Compute migration failed: {e}")
            return False

    # -----------------------------
    # 2. Change storage only
    # -----------------------------
    def migrate_storage(self, vm, disk_paths):
        """
        Safely migrate VM disks offline.
        Copies all disks first, verifies, updates XML, then removes source disks.

        Args:
            vm: libvirt VM object
            disk_paths: dict mapping old disk paths -> new disk paths
        """
        vm_name = vm.name()
        logger.info(f"Starting storage migration for VM '{vm_name}'")

        # Step 1: Ensure VM is shut down
        if self.is_vm_running(vm):
            print(f"VM '{vm_name}' is running. Shutting down for offline storage migration...")
            vm.shutdown()
            for _ in range(30):
                time.sleep(2)
                if not self.is_vm_running(vm):
                    break
            if self.is_vm_running(vm):
                print(f"❌ Failed to shut down VM '{vm_name}'. Aborting migration.")
                logger.error(f"VM '{vm_name}' still running after shutdown attempt.")
                return

        # Step 2: Parse VM XML
        xml_desc = vm.XMLDesc()
        root = ET.fromstring(xml_desc)

        # Step 3: Copy all disks safely
        successful_copies = {}
        for old_path, new_path in disk_paths.items():
            if not os.path.isfile(old_path):
                print(f"⚠ Skipping '{old_path}', not a valid file.")
                logger.warning(f"Skipping invalid disk file '{old_path}' for VM '{vm_name}'")
                continue

            # If target is directory, append filename
            if os.path.isdir(new_path) or new_path.endswith("/"):
                new_path = os.path.join(new_path, os.path.basename(old_path))

            os.makedirs(os.path.dirname(new_path), exist_ok=True)

            print(f"Copying {old_path} -> {new_path}")
            logger.info(f"Copying disk '{old_path}' to '{new_path}'")
            try:
                shutil.copy2(old_path, new_path)
            except Exception as e:
                print(f"❌ Failed to copy '{old_path}' to '{new_path}': {e}")
                logger.error(f"Failed to copy '{old_path}': {e}")
                return

            # Verify copy
            if os.path.isfile(new_path) and os.path.getsize(new_path) == os.path.getsize(old_path):
                print(f"✅ Copy verified for {old_path}")
                successful_copies[old_path] = new_path
            else:
                print(f"❌ Verification failed for '{old_path}'. Aborting migration.")
                logger.error(f"Verification failed for '{old_path}'")
                # Remove partially copied file
                if os.path.exists(new_path):
                    os.remove(new_path)
                return

        if not successful_copies:
            print("❌ No disks copied successfully. Aborting migration.")
            return

        # Step 4: Update VM XML with new disk paths
        for old_path, new_path in successful_copies.items():
            for disk in root.findall("./devices/disk"):
                source = disk.find("source")
                if source is not None and source.attrib.get("file") == old_path:
                    source.attrib["file"] = new_path

        new_xml_path = f"/tmp/{vm_name}_storage_migrated.xml"
        ET.ElementTree(root).write(new_xml_path)
        logger.info(f"Updated VM XML saved to {new_xml_path}")

        # Step 5: Remove original disks only after successful copy and XML update
        for old_path in successful_copies.keys():
            try:
                os.remove(old_path)
                logger.info(f"Removed original disk '{old_path}'")
            except Exception as e:
                print(f"⚠ Failed to remove original disk '{old_path}': {e}")
                logger.warning(f"Failed to remove original disk '{old_path}': {e}")

        # Step 6: Undefine and redefine VM
        if self.has_nvram(vm):
            print(f"VM '{vm_name}' has NVRAM. Using virsh undefine --nvram")
            subprocess.run(['virsh', 'undefine', vm_name, '--nvram'])
        else:
            vm.undefine()

        print(f"Defining VM '{vm_name}' with updated disk paths...")
        subprocess.run(['virsh', 'define', new_xml_path])

        print("✅ Storage migration completed successfully.")
        logger.info(f"Storage migration for VM '{vm_name}' completed.")


    # -----------------------------
    # 3. Change both compute and storage
    # -----------------------------
    def migrate_compute_and_storage(self, vm, dest_uri, disk_paths):
        """
        Full offline migration: storage + compute.
        - Copy disks to destination KVM host via SSH (rsync)
        - Update VM XML with new paths
        - Copy XML to destination and define VM there
        - Only after successful define: undefine VM on source and remove local disks
        - Start VM on destination
        """
        vm_name = vm.name()
        logger.info(f"Starting full compute+storage migration for VM '{vm_name}'")

        # 1) Ensure VM is shut down
        if self.is_vm_running(vm):
            print(f"Shutting down VM '{vm_name}' for migration...")
            vm.shutdown()
            for _ in range(30):
                time.sleep(2)
                if not self.is_vm_running(vm):
                    break
            if self.is_vm_running(vm):
                print(f"❌ VM '{vm_name}' did not shut down. Aborting migration.")
                return

        # 2) Parse VM XML (source configuration)
        xml_desc = vm.XMLDesc()
        root = ET.fromstring(xml_desc)

        # 3) Determine destination hostname from dest_uri
        try:
            dest_host = dest_uri.split("@")[1].split("/")[0]
        except Exception:
            logger.error("Could not extract destination hostname from dest_uri")
            return
        print(f"Destination compute host: {dest_host}")

        # 4) Copy disks from source → destination host (rsync)
        updated_disk_map = {}
        for old_path, new_path in disk_paths.items():
            # Normalize new_path: if directory given, append basename
            if new_path.endswith("/") or os.path.isdir(new_path):
                new_path = os.path.join(new_path, os.path.basename(old_path))

            # Ensure destination folder exists (remote)
            dest_dir = os.path.dirname(new_path)
            try:
                subprocess.run(["ssh", dest_host, "mkdir", "-p", dest_dir], check=True)
            except subprocess.CalledProcessError as e:
                logger.error(f"Failed to create remote directory {dest_dir} on {dest_host}: {e}")
                return

            print(f"\n📦 Copying disk:\n  SRC: {old_path}\n  DST: {dest_host}:{new_path}")
            cmd = ["rsync", "-avh", "--progress", old_path, f"{dest_host}:{new_path}"]
            result = subprocess.run(cmd)
            if result.returncode != 0:
                logger.error(f"rsync failed for {old_path} -> {dest_host}:{new_path}")
                return

            # Verify size on remote
            try:
                src_size = os.path.getsize(old_path)
            except OSError as e:
                logger.error(f"Cannot stat source file {old_path}: {e}")
                return

            stat_cmd = ["ssh", dest_host, f"stat -c %s {shlex_quote(new_path)}"]
            res = subprocess.run(stat_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if res.returncode != 0:
                logger.error(f"Failed to stat remote file {new_path} on {dest_host}: {res.stderr.strip()}")
                return

            try:
                dst_size = int(res.stdout.strip())
            except ValueError:
                logger.error(f"Invalid stat output for remote file {new_path}: {res.stdout!r}")
                return

            if src_size != dst_size:
                logger.error(f"Size mismatch for {old_path} (src={src_size} dst={dst_size}). Aborting.")
                return

            print(f"✓ Disk copy verified: {old_path}")
            updated_disk_map[old_path] = new_path

        if not updated_disk_map:
            logger.error("No disks were copied successfully. Aborting migration.")
            return

        # 5) Update VM XML <source file="..."> elements to remote paths
        for disk in root.findall("./devices/disk"):
            source = disk.find("source")
            if source is not None:
                old_file = source.attrib.get("file")
                if old_file in updated_disk_map:
                    source.attrib["file"] = updated_disk_map[old_file]

        # 6) Save updated XML to a local temp file
        new_xml_path = f"/tmp/{vm_name}_full_migrated.xml"
        ET.ElementTree(root).write(new_xml_path)
        logger.info(f"Updated VM XML saved locally to: {new_xml_path}")

        # 7) Copy XML to destination and define there BEFORE touching source
        remote_xml_path = f"/tmp/{vm_name}_full_migrated.xml"
        scp_cmd = ["scp", new_xml_path, f"root@{dest_host}:{remote_xml_path}"]
        scp_result = subprocess.run(scp_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if scp_result.returncode != 0:
            logger.error(f"Failed to copy XML to destination ({dest_host}): {scp_result.stderr.strip()}")
            return
        logger.info("XML copied to destination successfully")

        define_cmd = ["ssh", f"root@{dest_host}", f"virsh define {shlex_quote(remote_xml_path)}"]
        define_result = subprocess.run(define_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if define_result.returncode != 0:
            logger.error(f"Failed to define VM on destination ({dest_host}): {define_result.stderr.strip()}")
            return
        logger.info(f"VM '{vm_name}' defined on destination {dest_host}")

        # 8) Start VM on destination
        #start_cmd = ["ssh", f"root@{dest_host}", f"virsh start {shlex_quote(vm_name)}"]
        #start_result = subprocess.run(start_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        #if start_result.returncode != 0:
        #    logger.error(f"Failed to start VM on destination ({dest_host}): {start_result.stderr.strip()}")
        #    # proceed to undefine source? better to leave source until start success
        #    return
        #logger.info(f"VM '{vm_name}' started on destination {dest_host}")

        # 9) Undefine VM on source (only after success on destination)
        try:
            if self.has_nvram(vm):
                subprocess.run(["virsh", "undefine", vm_name, "--nvram"], check=True)
            else:
                vm.undefine()
            logger.info(f"VM '{vm_name}' undefined on source host")
        except Exception as e:
            logger.error(f"Failed to undefine VM on source: {e}")
            # At this point VM is running on destination; leave source manual cleanup
            return

        # 10) Remove original disks on source (best-effort)
        for old_path in updated_disk_map.keys():
            try:
                if os.path.exists(old_path):
                    os.remove(old_path)
                    logger.info(f"Removed old disk: {old_path}")
            except Exception as e:
                logger.warning(f"Failed to remove old disk {old_path}: {e}")

        # 11) Optionally cleanup local temp xml
        try:
            if os.path.exists(new_xml_path):
                os.remove(new_xml_path)
        except Exception:
            pass

        print("\n✅ FULL MIGRATION (compute + storage) completed successfully.")
        logger.info(f"Full compute+storage migration completed for VM '{vm_name}'")




def main():
    # Select source KVM node
    print("Select source KVM node:")
    for i, node in enumerate(KVM_NODES.keys(), 1):
        print(f"{i}. {node}")
    src_choice = int(input("Enter choice number: "))
    src_node = list(KVM_NODES.keys())[src_choice - 1]

    kvm = KVMManager(uri=KVM_NODES[src_node]['uri'])

    # List VMs
    vms = kvm.list_vms()
    if not vms:
        print("No VMs found.")
        return

    print("\nAvailable VMs:")
    for i, vm in enumerate(vms, 1):
        print(f"{i}. {vm.name()}")
    vm_choice = int(input("Select VM to migrate: "))
    vm = vms[vm_choice - 1]

    # Select migration scenario
    print("\nSelect migration scenario:")
    print("1. Change compute resource only")
    print("2. Change storage only")
    print("3. Change both compute and storage")
    scenario = int(input("Enter choice number: "))

    dest_uri = None
    disk_paths = None

    # Scenario 1 or 3 requires destination KVM node
    if scenario in [1, 3]:
        print("\nSelect destination KVM node for migration:")
        for i, node in enumerate(MIGRATION_PATHS.keys(), 1):
            print(f"{i}. {node}")
        dest_choice = int(input("Enter choice number: "))
        dest_node = list(MIGRATION_PATHS.keys())[dest_choice - 1]
        dest_uri = MIGRATION_PATHS[dest_node]['uri']

    # Scenario 2 or 3 requires storage migration
    if scenario in [2, 3]:
        # Show current VM disks
        vm_disks = kvm.get_vm_disks(vm)
        if not vm_disks:
            print(f"No valid VM disks found for migration.")
            return

        print("\nCurrent VM disks:")
        for i, disk in enumerate(vm_disks, 1):
            print(f"{i}. {disk}")

        # Ask user for new path for each disk
        disk_paths = {}
        for disk in vm_disks:
            default_path = os.path.join("/mnt/kvm_pool/fspool1/VMs", os.path.basename(disk))
            new_disk_path = input(f"Enter new storage path for disk '{disk}' (default: {default_path}): ").strip()
            if not new_disk_path:
                new_disk_path = default_path
            os.makedirs(os.path.dirname(new_disk_path), exist_ok=True)
            disk_paths[disk] = new_disk_path

    # Execute migration based on scenario
    if scenario == 1:
        # Compute-only migration
        disks = kvm.get_vm_disks(vm)
        shared = all(disk.startswith("/mnt/nfs") or disk.startswith("/shared") for disk in disks)
        if shared:
            print("VM appears to be on shared storage. No storage migration needed.")
        else:
            print("Warning: VM is not on shared storage! Compute-only migration may fail if destination cannot access the disk.")
        kvm.migrate_compute(vm, dest_uri)

    elif scenario == 2:
        # Storage-only migration
        kvm.migrate_storage(vm, disk_paths)

    elif scenario == 3:
        # Both compute and storage migration
        kvm.migrate_compute_and_storage(vm, dest_uri, disk_paths)
    else:
        print("Invalid scenario selected.")


if __name__ == "__main__":
    main()

