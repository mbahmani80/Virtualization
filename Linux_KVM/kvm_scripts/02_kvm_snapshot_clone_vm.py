#!/usr/bin/env python3

"""
KVM Snapshot and Clone Manager
==============================

Author: Mahdi Bahmani
Version: 1.1
Date: 2025-10-26
License: GPL

Description:
------------
This script provides a command-line interface for safely managing KVM virtual
machines (VMs) using libvirt and the `virsh` toolset. It supports creating,
listing, deleting, and reverting VM snapshots, as well as cloning VMs from
templates or existing instances.

The script ensures safe operation by checking VM states before performing
actions such as snapshot creation or reversion, automatically shutting down
running VMs when necessary, and showing live progress indicators during
snapshot merges.

A full logging system records all operations, warnings, and errors in
`/var/log/kvm_snapshot_clone_manager.log` for audit and troubleshooting purposes.

Key Features:
--------------
- Dynamic VM state detection using `virsh dominfo`
- Safe snapshot operations (create, list, delete, revert)
- Snapshot deletion with merge progress spinner
- VM cloning with automatic target directory creation
- Storage pool detection and path suggestions
- Optional system cleanup via `virt-sysprep` post-clone
- Comprehensive operation logging and audit trail
- Interactive menu-based user interface

Dependencies:
-------------
- Python 3.x
- libvirt + virsh
- virt-clone (from `virt-manager` or `virt-install` package)
- virt-sysprep (from `guestfs-tools`)

Usage:
------
Run the script as root or with a user that has libvirt access permissions:

    sudo python3 kvm_snapshot_clone_vm.py


Log File:
---------
All operations are recorded in:
    /var/log/kvm_snapshot_clone_manager.log

Note:
-----
Snapshot and clone operations involving disk merges or large images may take
several minutes to complete. The script provides spinners and progress indicators
to show real-time feedback during these processes.
"""



import subprocess
import sys
import time
from datetime import datetime
import logging
import os
import shutil

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

# =======================
# KVM Snapshot Manager
# =======================
class KVMSnapshotManager:
    def __init__(self):
        self.refresh_vms()

    def refresh_vms(self):
        """Retrieve all VMs with their states."""
        result = subprocess.run(['virsh', 'list', '--all', '--name'], capture_output=True, text=True)
        vm_names = result.stdout.splitlines()
        self.vms = {}
        for vm in vm_names:
            if vm.strip():
                state_result = subprocess.run(['virsh', 'dominfo', vm], capture_output=True, text=True)
                state_line = [line for line in state_result.stdout.splitlines() if "State:" in line]
                state = state_line[0].split(":")[1].strip() if state_line else "unknown"
                self.vms[vm] = state

    def list_vms(self):
        """Print available VMs with their state and numbers."""
        print("\nAvailable VMs:")
        for i, (vm, state) in enumerate(self.vms.items(), start=1):
            print(f"{i}) {vm} (State: {state})")

    # -----------------------
    # Snapshot Creation
    # -----------------------
    def create_snapshot(self, vm_name):
        """Create a disk-only snapshot for a VM."""
        self.refresh_vms()
        state = self.vms.get(vm_name)
        if not state:
            print(f"VM {vm_name} not found.")
            logging.error(f"Attempted to create snapshot for unknown VM '{vm_name}'")
            return

        # Auto-shutdown if running
        if "running" in state or "idle" in state:
            print(f"VM {vm_name} is currently running.")
            choice = input("Do you want me to shut it down before creating the snapshot? [y/N]: ").strip().lower()
            if choice == "y":
                logging.info(f"User chose to shut down VM '{vm_name}' for snapshot creation")
                print(f"Shutting down {vm_name}...")
                subprocess.run(['virsh', 'shutdown', vm_name])
                print("Waiting for VM to power off...", end='', flush=True)
                for i in range(30):
                    time.sleep(2)
                    self.refresh_vms()
                    state = self.vms.get(vm_name)
                    sys.stdout.write(".")
                    sys.stdout.flush()
                    if "shut" in state or "off" in state:
                        break
                print()
                self.refresh_vms()
                state = self.vms.get(vm_name)

        if not ("shut" in state or "off" in state):
            print(f"VM {vm_name} is still not shut off. Current state: {state}")
            logging.warning(f"Cannot create snapshot. VM '{vm_name}' not shut off.")
            return

        snapshot_name = f"{vm_name}_snapshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        print(f"Creating snapshot for {vm_name} -> {snapshot_name}")
        logging.info(f"Creating snapshot '{snapshot_name}' for VM '{vm_name}'")
        subprocess.run([
            'virsh', 'snapshot-create-as',
            vm_name,
            snapshot_name,
            f"Snapshot of {vm_name} created on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            '--disk-only', '--atomic'
        ])
        print("✅ Snapshot created successfully.")
        logging.info(f"Snapshot '{snapshot_name}' for VM '{vm_name}' created successfully")

    # -----------------------
    # List Snapshots
    # -----------------------
    def list_snapshots(self, vm_name):
        """List all snapshots for a VM. Return True if snapshots exist, else False."""
        result = subprocess.run(['virsh', 'snapshot-list', vm_name], capture_output=True, text=True)
        output = result.stdout.strip()
        lines = output.splitlines()
        if len(lines) <= 2:
            print(f"\nNo snapshots exist for {vm_name}. Press Enter to return to main menu.")
            input()
            return False
        else:
            print(f"\nSnapshots for {vm_name}:")
            print(output)
            return True

    # -----------------------
    # Delete Snapshot
    # -----------------------
    def delete_snapshot(self, vm_name, snapshot_name):
        """Delete a specific snapshot of a VM and confirm completion."""
        self.refresh_vms()
        state = self.vms.get(vm_name, "unknown")

        if "running" in state or "idle" in state:
            print(f"VM {vm_name} is currently running.")
            choice = input("Do you want to shut it down before deleting the snapshot? [y/N]: ").strip().lower()
            if choice == "y":
                logging.info(f"User chose to shut down VM '{vm_name}' for snapshot deletion")
                print(f"Shutting down {vm_name}...")
                subprocess.run(['virsh', 'shutdown', vm_name])
                print("Waiting for VM to power off...", end='', flush=True)
                for i in range(30):
                    time.sleep(2)
                    self.refresh_vms()
                    state = self.vms.get(vm_name)
                    sys.stdout.write(".")
                    sys.stdout.flush()
                    if "shut" in state or "off" in state:
                        break
                print()
                self.refresh_vms()
                state = self.vms.get(vm_name)

        if not ("shut" in state or "off" in state):
            print(f"VM {vm_name} is still not shut off. Current state: {state}")
            logging.warning(f"Cannot delete snapshot. VM '{vm_name}' not shut off.")
            return

        confirm = input(f"Are you sure you want to delete snapshot '{snapshot_name}' from {vm_name}? [y/N]: ").strip().lower()
        if confirm != 'y':
            print("Deletion cancelled.")
            logging.info(f"Snapshot deletion cancelled by user: {snapshot_name} on VM {vm_name}")
            return

        print(f"\nDeleting snapshot '{snapshot_name}' from {vm_name} (this may take a while)...")
        logging.info(f"Deleting snapshot '{snapshot_name}' from VM '{vm_name}'")

        spinner = ['|', '/', '-', '\\']
        process = subprocess.Popen(['virsh', 'snapshot-delete', vm_name, snapshot_name],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        i = 0
        while process.poll() is None:
            sys.stdout.write(f"\rMerging disk data... {spinner[i % len(spinner)]}")
            sys.stdout.flush()
            i += 1
            time.sleep(0.2)
        sys.stdout.write("\r")
        stdout, stderr = process.communicate()

        if process.returncode == 0:
            print("✅ Snapshot deletion completed. Confirming cleanup...")
            result = subprocess.run(['virsh', 'snapshot-list', vm_name],
                                    capture_output=True, text=True)
            if snapshot_name not in result.stdout:
                print(f"✅ Snapshot '{snapshot_name}' has been fully removed and merged.")
                logging.info(f"Snapshot '{snapshot_name}' for VM '{vm_name}' successfully deleted and merged")
            else:
                print(f"Snapshot '{snapshot_name}' may still appear in the list. Check manually:")
                print(f"   virsh snapshot-list {vm_name}")
                logging.warning(f"Snapshot '{snapshot_name}' for VM '{vm_name}' may still exist after deletion")
        else:
            print(f"Error deleting snapshot: {stderr.strip()}")
            logging.error(f"Error deleting snapshot '{snapshot_name}' for VM '{vm_name}': {stderr.strip()}")

    # -----------------------
    # Revert Snapshot
    # -----------------------
    def revert_snapshot(self, vm_name, snapshot_name):
        """Revert a VM to a specific snapshot safely (auto-shutdown if running)."""
        self.refresh_vms()
        state = self.vms.get(vm_name, "unknown")

        confirm = input(f"Are you sure you want to revert {vm_name} to snapshot '{snapshot_name}'? "
                        "All unsaved changes since that snapshot will be lost. [y/N]: ").strip().lower()
        if confirm != 'y':
            print("Revert cancelled.")
            logging.info(f"Snapshot revert cancelled by user for VM '{vm_name}', snapshot '{snapshot_name}'")
            return

        # Step 1: Shut down VM if running
        if "running" in state or "idle" in state:
            print(f"VM {vm_name} is currently running. Shutting it down before revert...")
            logging.info(f"Shutting down VM '{vm_name}' for revert to snapshot '{snapshot_name}'")
            subprocess.run(['virsh', 'shutdown', vm_name])
            print("Waiting for VM to power off...", end='', flush=True)
            for i in range(30):
                time.sleep(2)
                self.refresh_vms()
                state = self.vms.get(vm_name)
                sys.stdout.write(".")
                sys.stdout.flush()
                if "shut" in state or "off" in state:
                    break
            print()
            self.refresh_vms()
            state = self.vms.get(vm_name)

        if not ("shut" in state or "off" in state):
            print(f"VM {vm_name} is still not shut off. Current state: {state}")
            logging.warning(f"Cannot revert snapshot. VM '{vm_name}' not shut off.")
            return

        # Step 2: Perform revert
        print(f"Reverting {vm_name} to snapshot {snapshot_name}...")
        logging.info(f"Reverting VM '{vm_name}' to snapshot '{snapshot_name}'")
        revert = subprocess.run(['virsh', 'snapshot-revert', vm_name, snapshot_name],
                                capture_output=True, text=True)

        if revert.returncode == 0:
            print(f"✅ VM {vm_name} has been successfully reverted to snapshot {snapshot_name}.")
            logging.info(f"VM '{vm_name}' successfully reverted to snapshot '{snapshot_name}'")
        else:
            print(f"Revert failed:\n{revert.stderr.strip()}")
            logging.error(f"Failed to revert VM '{vm_name}' to snapshot '{snapshot_name}': {revert.stderr.strip()}")
            return

        # Step 3: Optionally restart VM
        restart = input(f"Do you want to start {vm_name} after revert? [y/N]: ").strip().lower()
        if restart == 'y':
            print(f"Starting {vm_name}...")
            subprocess.run(['virsh', 'start', vm_name])
            print(f"VM {vm_name} started successfully.")
            logging.info(f"VM '{vm_name}' started after revert")
        else:
            print(f"VM {vm_name} remains shut off.")
        self.refresh_vms()

    # -----------------------
    # Clone VM (with virt-sysprep option)
    # -----------------------
    def clone_vm(self, source_vm):
        """Clone an existing VM to a new name and optionally run virt-sysprep."""
        import shutil
        import os

        self.refresh_vms()

        # Check for virt-clone availability
        if not shutil.which("virt-clone"):
            print("'virt-clone' not found. Please install 'virt-manager' or 'virt-install'.")
            logging.error("virt-clone not installed.")
            return

        print(f"\nPreparing to clone VM: {source_vm}")
        logging.info(f"Starting clone operation for '{source_vm}'")

        # ---------------------------
        # List available storage pools
        # ---------------------------
        pools_result = subprocess.run(['virsh', 'pool-list', '--all'], capture_output=True, text=True)
        pools = [line.split()[0] for line in pools_result.stdout.splitlines()[2:] if line.strip()]

        if not pools:
            print("No storage pools found. Please configure one with 'virsh pool-define'.")
            logging.error("No KVM pools found.")
            return

        print("\nAvailable Storage Pools:")
        for i, pool in enumerate(pools, start=1):
            print(f"{i}) {pool}")

        pool_choice = input("Select storage pool number (default=1): ").strip()
        try:
            pool_index = int(pool_choice) - 1 if pool_choice else 0
            selected_pool = pools[pool_index]
        except (ValueError, IndexError):
            selected_pool = pools[0]

        # ---------------------------
        # Get path of the selected pool
        # ---------------------------
        pool_xml = subprocess.run(['virsh', 'pool-dumpxml', selected_pool],
                                  capture_output=True, text=True)
        pool_path_line = [line for line in pool_xml.stdout.splitlines() if "<path>" in line]
        pool_path = pool_path_line[0].replace("<path>", "").replace("</path>", "").strip() if pool_path_line else "/var/lib/libvirt/images"

        print(f"\nSuggested storage path: {pool_path}")
        target_path = input(f"Enter target directory for clone (default={pool_path}): ").strip() or pool_path

        # ---------------------------
        # Ask for clone name
        # ---------------------------
        clone_name = input("Enter new VM clone name: ").strip()
        if not clone_name:
            print("Clone name cannot be empty.")
            logging.warning("Clone name not provided.")
            return

        # ---------------------------
        # Ensure the target directory exists
        # ---------------------------
        if not os.path.exists(target_path):
            try:
                os.makedirs(target_path, exist_ok=True)
                print(f"📁 Created directory: {target_path}")
                logging.info(f"Created missing directory for clone target: {target_path}")
            except Exception as e:
                print(f"Failed to create target directory: {e}")
                logging.error(f"Failed to create target directory {target_path}: {e}")
                return

        # ---------------------------
        # Perform clone
        # ---------------------------
        print(f"\nCloning VM '{source_vm}' to '{clone_name}'...")
        logging.info(f"Cloning '{source_vm}' to '{clone_name}' at '{target_path}'")

        process = subprocess.Popen([
            'virt-clone',
            '--original', source_vm,
            '--name', clone_name,
            '--file', f"{target_path}/{clone_name}.qcow2"
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        spinner = ['|', '/', '-', '\\']
        i = 0
        while process.poll() is None:
            sys.stdout.write(f"\rCloning in progress... {spinner[i % len(spinner)]}")
            sys.stdout.flush()
            i += 1
            time.sleep(0.2)
        sys.stdout.write("\r")

        stdout, stderr = process.communicate()

        if process.returncode != 0:
            print(f"Clone failed:\n{stderr.strip()}")
            logging.error(f"Clone failed for '{clone_name}': {stderr.strip()}")
            return

        print(f"✅ Clone '{clone_name}' created successfully at {target_path}")
        logging.info(f"Clone '{clone_name}' created successfully at {target_path}")

        # ---------------------------
        # Optionally run virt-sysprep
        # ---------------------------
        if shutil.which("virt-sysprep"):
            choice = input(f"\nDo you want to run 'virt-sysprep' on {clone_name} to prepare it for reuse? [y/N]: ").strip().lower()
            if choice == 'y':
                print(f"Running virt-sysprep on '{clone_name}' (this may take a while)...")
                logging.info(f"Running virt-sysprep on '{clone_name}'")

                sysprep = subprocess.Popen(['virt-sysprep', '-d', clone_name],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                i = 0
                while sysprep.poll() is None:
                    sys.stdout.write(f"\rCleaning system... {spinner[i % len(spinner)]}")
                    sys.stdout.flush()
                    i += 1
                    time.sleep(0.2)
                sys.stdout.write("\r")

                sysprep_out, sysprep_err = sysprep.communicate()

                if sysprep.returncode == 0:
                    print(f"✅ virt-sysprep completed successfully for '{clone_name}'.")
                    logging.info(f"virt-sysprep completed for '{clone_name}'")
                else:
                    print(f"virt-sysprep failed: {sysprep_err.strip()}")
                    logging.error(f"virt-sysprep failed for '{clone_name}': {sysprep_err.strip()}")
            else:
                print("virt-sysprep skipped by user.")
                logging.info(f"virt-sysprep skipped for '{clone_name}'")
        else:
            print("'virt-sysprep' not installed, skipping system preparation.")
            logging.warning("virt-sysprep command missing on system.")

        print(f"Clone process completed for '{clone_name}'.")
        logging.info(f"Clone process completed for '{clone_name}'.")

# =======================
# Helper: Select VM
# =======================
def select_vm(manager):
    manager.list_vms()
    vm_number = input("Enter VM number: ").strip()
    try:
        vm_index = int(vm_number) - 1
        vm_name = list(manager.vms.keys())[vm_index]
        return vm_name
    except (ValueError, IndexError):
        print("Invalid VM selection.")
        return None

# =======================
# Main Menu
# =======================
def main_menu():
    manager = KVMSnapshotManager()

    while True:
        print("\n--- KVM Snapshot Manager ---")
        print("1) List VMs")
        print("2) Create snapshot")
        print("3) List snapshots")
        print("4) Delete snapshot")
        print("5) Revert to snapshot")
        print("6) Refresh VM list")
        print("7) Clone VM")
        print("0) Exit")
        choice = input("Enter your choice: ").strip()

        if choice == "1":
            manager.list_vms()
        elif choice == "2":
            vm_name = select_vm(manager)
            if vm_name:
                manager.create_snapshot(vm_name)
        elif choice == "3":
            vm_name = select_vm(manager)
            if vm_name:
                manager.list_snapshots(vm_name)
        elif choice == "4":
            vm_name = select_vm(manager)
            if vm_name:
                has_snapshots = manager.list_snapshots(vm_name)
                if not has_snapshots:
                    continue
                snapshot_name = input("Enter snapshot name to delete: ").strip()
                if snapshot_name:
                    manager.delete_snapshot(vm_name, snapshot_name)
        elif choice == "5":
            vm_name = select_vm(manager)
            if vm_name:
                has_snapshots = manager.list_snapshots(vm_name)
                if not has_snapshots:
                    continue
                snapshot_name = input("Enter snapshot name to revert to: ").strip()
                if snapshot_name:
                    manager.revert_snapshot(vm_name, snapshot_name)
        elif choice == "6":
            print("Refreshing VM list...")
            manager.refresh_vms()
        elif choice == "7":
            vm_name = select_vm(manager)
            if vm_name:
                manager.clone_vm(vm_name)
        elif choice == "0":
            print("Exiting.")
            break
        else:
            print("Invalid choice. Please select again.")

if __name__ == "__main__":
    main_menu()


