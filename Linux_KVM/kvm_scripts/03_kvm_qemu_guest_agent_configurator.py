#!/usr/bin/env python3
import subprocess
import sys
import os
import logging
from logging.handlers import RotatingFileHandler
import argparse

class QemuGuestAgentConfigurator:
    def __init__(self, vm_name, guest_agent_path="/mnt/nfs/qemu.guest_agent/", live=False, log_file="/var/log/qemu_guest_agent.log"):
        self.vm_name = vm_name
        self.guest_agent_path = guest_agent_path.rstrip("/")
        self.live_flag = "--live" if live else ""
        self.controller_xml = f"Virtio-Serial_Controller_{vm_name}.xml"
        self.channel_xml = f"qemuga_{vm_name}.xml"
        self.log_file = log_file

        self._setup_logging()
        self.logger.info("Initialized configurator for VM: %s", vm_name)
        os.makedirs(self.guest_agent_path, exist_ok=True)

    def _setup_logging(self):
        """Set up logging to both console and file."""
        logger = logging.getLogger(self.vm_name)
        logger.setLevel(logging.INFO)
        formatter = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s")

        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)

        file_handler = RotatingFileHandler(self.log_file, maxBytes=5*1024*1024, backupCount=3)
        file_handler.setFormatter(formatter)

        logger.addHandler(console_handler)
        logger.addHandler(file_handler)

        self.logger = logger

    def _run_cmd(self, cmd):
        """Run shell command safely and log output."""
        self.logger.info("Executing command: %s", cmd)
        try:
            result = subprocess.run(cmd, shell=True, text=True, capture_output=True, check=True)
            if result.stdout.strip():
                self.logger.info(result.stdout.strip())
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            self.logger.error("Command failed: %s", cmd)
            self.logger.error(e.stderr)
            sys.exit(1)

    def _create_controller_xml(self):
        """Generate VirtIO Serial Controller XML."""
        xml_content = """<controller type='virtio-serial' index='0'>
  <address type='pci' domain='0' bus='0' slot='4' function='0'/>
</controller>
"""
        with open(self.controller_xml, "w") as f:
            f.write(xml_content)
        self.logger.info("Created controller XML: %s", self.controller_xml)

    def _create_channel_xml(self):
        """Generate QEMU Guest Agent Channel XML."""
        socket_path = os.path.join(self.guest_agent_path, f"{self.vm_name}.agent")
        xml_content = f"""<channel type='unix'>
  <source mode='bind' path='{socket_path}'/>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
"""
        with open(self.channel_xml, "w") as f:
            f.write(xml_content)
        self.logger.info("Created channel XML: %s", self.channel_xml)

    def attach_controller(self):
        """Attach VirtIO Serial Controller if not already present."""
        check = self._run_cmd(f"virsh dumpxml {self.vm_name} | grep \"<controller type='virtio-serial'\"")
        if check:
            self.logger.info("VirtIO Serial Controller already exists, skipping attachment.")
            return
        self._create_controller_xml()
        cmd = f"virsh attach-device {self.vm_name} {self.controller_xml} --config {self.live_flag}"
        self._run_cmd(cmd)
        self.logger.info("VirtIO Serial Controller attached successfully.")

    def attach_channel(self):
        """Attach QEMU Guest Agent Channel if not already present."""
        check = self._run_cmd(f"virsh dumpxml {self.vm_name} | grep \"org.qemu.guest_agent.0\"")
        if check:
            self.logger.info("QEMU Guest Agent Channel already exists, skipping attachment.")
            return
        self._create_channel_xml()
        cmd = f"virsh attach-device {self.vm_name} {self.channel_xml} --config {self.live_flag}"
        self._run_cmd(cmd)
        self.logger.info("QEMU Guest Agent Channel attached successfully.")

    def reboot_vm(self):
        """Reboot the VM if running, otherwise start it."""
        state = self._run_cmd(f"virsh domstate {self.vm_name}").lower()
        if "running" in state:
            self.logger.info("VM is running. Rebooting VM: %s", self.vm_name)
            self._run_cmd(f"virsh reboot {self.vm_name}")
            self.logger.info("VM reboot command sent.")
        elif "shut off" in state or "shutoff" in state:
            self.logger.info("VM is shut down. Starting VM: %s", self.vm_name)
            self._run_cmd(f"virsh start {self.vm_name}")
            self.logger.info("VM start command sent.")
        else:
            self.logger.warning("VM is in unexpected state: '%s'. Skipping reboot/start.", state)

    def verify_setup(self):
        """Verify if Guest Agent is active and channel exists."""
        self.logger.info("Verifying Guest Agent setup for VM: %s", self.vm_name)

        # Check if channel exists
        xml_output = self._run_cmd(f"virsh dumpxml {self.vm_name} | grep -A 5 '<channel'")
        if "org.qemu.guest_agent.0" in xml_output:
            self.logger.info("Guest Agent channel already exists in VM XML.")
        else:
            self.logger.warning("Guest Agent channel not found in VM XML.")

        # Check if guest agent is responding (Linux/Windows)
        try:
            ping_output = self._run_cmd(f"virsh qemu-agent-command {self.vm_name} '{{\"execute\":\"guest-ping\"}}'")
            if "return" in ping_output:
                self.logger.info("Guest Agent is already active inside the VM. No need to start again.")
            else:
                self.logger.warning("Guest Agent channel exists but no response. It may start after VM reboot.")
        except SystemExit:
            self.logger.warning("Guest Agent not active or not responding yet.")

    def configure(self):
        """Perform full configuration."""
        self.logger.info("=== Starting QEMU Guest Agent Configuration ===")
        self.attach_controller()
        self.attach_channel()
        self.reboot_vm()
        self.verify_setup()
        self.logger.info("=== QEMU Guest Agent Configuration Completed Successfully ===")


# ---- Menu and helper functions ----

def list_vms():
    """Return a list of all VMs (running and shut off)."""
    try:
        result = subprocess.run("virsh list --all --name", shell=True, text=True, capture_output=True, check=True)
        vms = [vm.strip() for vm in result.stdout.strip().splitlines() if vm.strip()]
        return vms
    except subprocess.CalledProcessError as e:
        print("[ERROR] Failed to list VMs:", e.stderr)
        sys.exit(1)


def select_vm_menu(vms):
    """Present a menu for the user to choose a VM."""
    print("\nAvailable VMs:")
    for idx, vm in enumerate(vms, 1):
        print(f"{idx}. {vm}")
    while True:
        try:
            choice = int(input("\nEnter the number of the VM to configure: "))
            if 1 <= choice <= len(vms):
                return vms[choice - 1]
            else:
                print(f"[!] Please enter a number between 1 and {len(vms)}")
        except ValueError:
            print("[!] Invalid input. Please enter a number.")


# ---- Main script ----
def main():
    parser = argparse.ArgumentParser(description="Enable QEMU Guest Agent on Linux & Windows VMs in KVM.")
    parser.add_argument("--path", default="/mnt/nfs/qemu.guest_agent/", help="Guest agent socket path")
    parser.add_argument("--live", action="store_true", help="Apply changes live without reboot")
    parser.add_argument("--log", default="/var/log/qemu_guest_agent.log", help="Path to log file")
    args = parser.parse_args()

    vms = list_vms()
    if not vms:
        print("[!] No VMs found on this host.")
        sys.exit(0)

    selected_vm = select_vm_menu(vms)
    print(f"\n[*] You selected VM: {selected_vm}")

    configurator = QemuGuestAgentConfigurator(
        vm_name=selected_vm,
        guest_agent_path=args.path,
        live=args.live,
        log_file=args.log
    )
    configurator.configure()


if __name__ == "__main__":
    main()


