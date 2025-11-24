import libvirt
import subprocess
import xml.etree.ElementTree as ET
import string

class KVMManager:
    def __init__(self, uri='qemu:///system'):
        self.uri = uri
        self.conn = libvirt.open(self.uri)
        if self.conn is None:
            raise Exception(f"Failed to open connection to {self.uri}")

    def list_vms(self):
        vms = []
        for id in self.conn.listDomainsID():
            dom = self.conn.lookupByID(id)
            vms.append(dom.name())
        for name in self.conn.listDefinedDomains():
            vms.append(name)
        return sorted(vms)  # Sort alphabetically

    def get_vm_disks(self, vm_name):
        dom = self.conn.lookupByName(vm_name)
        xml_desc = dom.XMLDesc()
        root = ET.fromstring(xml_desc)
        disks = []
        for disk in root.findall("./devices/disk"):
            if disk.get('device') == 'disk':
                source = disk.find('source')
                if source is not None:
                    disks.append(source.get('file'))
        return disks

    def get_next_disk_letter(self, vm_name):
        dom = self.conn.lookupByName(vm_name)
        xml_desc = dom.XMLDesc()
        root = ET.fromstring(xml_desc)

        used_letters = []
        for disk in root.findall("./devices/disk"):
            if disk.get('device') == 'disk':
                target = disk.find('target')
                if target is not None and target.get('dev', '').startswith('vd'):
                    used_letters.append(target.get('dev')[-1])

        for letter in string.ascii_lowercase[1:]:  # skip vda
            if letter not in used_letters:
                return letter

        raise Exception("No available disk letters.")


    def create_qcow2_disk(self, disk_path, size):
        cmd = ['qemu-img', 'create', '-f', 'qcow2', disk_path, size]
        subprocess.run(cmd, check=True)
        print(f"Created QCOW2 disk: {disk_path}")

    def attach_disk(self, vm_name, disk_path):
        disk_letter = self.get_next_disk_letter(vm_name)
        target_dev = f'vd{disk_letter}'

        xml = f"""
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='{disk_path}'/>
          <target dev='{target_dev}' bus='virtio'/>
        </disk>
        """
        cmd = ['virsh', 'attach-device', vm_name, '/dev/stdin', '--config']
        subprocess.run(cmd, input=xml.encode(), check=True)
        print(f"Attached disk {disk_path} as {target_dev} to VM {vm_name}")

    def close(self):
        self.conn.close()


def main():
    manager = KVMManager()

    while True:
        vms = manager.list_vms()
        if not vms:
            print("No VMs found.")
            break

        print("\nAvailable VMs:")
        for i, vm in enumerate(vms, start=1):
            print(f"{i}. {vm}")
        print("0. Exit")

        choice = input("Select VM number (or 0 to exit): ")
        if not choice.isdigit():
            print("Invalid input, enter a number.")
            continue
        choice = int(choice)
        if choice == 0:
            break
        if choice < 1 or choice > len(vms):
            print("Invalid selection, try again.")
            continue

        vm_name = vms[choice - 1]

        disks = manager.get_vm_disks(vm_name)
        print(f"\nExisting disks for {vm_name}:")
        for d in disks:
            print(d)

        new_disk_name = input("Enter new disk filename (e.g., /var/lib/libvirt/images/vm2-disk2.qcow2): ")
        size = input("Enter new disk size (e.g., 10G): ")

        try:
            manager.create_qcow2_disk(new_disk_name, size)
            manager.attach_disk(vm_name, new_disk_name)
        except subprocess.CalledProcessError as e:
            print(f"Error creating or attaching disk: {e}")
            continue

    manager.close()
    print("Exiting. All done.")


if __name__ == "__main__":
    main()


