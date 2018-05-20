#!/bin/bash

source $(dirname $0)/config

mkdir -p $(dirname $0)/networks
mkdir -p $(dirname $0)/config-drives/$VM1_NAME-config
mkdir -p $(dirname $0)/config-drives/$VM2_NAME-config
mkdir -p $(dirname "$VM1_HDD")
mkdir -p $(dirname "$VM2_HDD")

###NETWORK
#External
VM1_EXT_MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
echo "
<network>
  <name>$EXTERNAL_NET_NAME</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='$EXTERNAL_NET_HOST_IP' netmask='$EXTERNAL_NET_MASK'>
    <dhcp>
      <range start='$EXTERNAL_NET.2' end='$EXTERNAL_NET.254'/>
      <host mac='$VM1_EXT_MAC' name='$VM1_NAME' ip='$VM1_EXTERNAL_IP'/>
    </dhcp>
  </ip>
</network>" > $(dirname $0)/networks/$EXTERNAL_NET_NAME.xml
#
#Internal
echo "
<network>
  <name>$INTERNAL_NET_NAME</name>
</network>" > $(dirname $0)/networks/$INTERNAL_NET_NAME.xml
#
#Management
echo "
<network>
  <name>$MANAGEMENT_NET_NAME</name>
  <ip address='$MANAGEMENT_HOST_IP' netmask='$MANAGEMENT_NET_MASK'/>
</network>" > $(dirname $0)/networks/$MANAGEMENT_NET_NAME.xml
##########

$(dirname $0)/flush_conf.sh

wget -O /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 -nc $VM_BASE_IMAGE

cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 $VM1_HDD
cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 $VM2_HDD

#Create user-data and meta-data
#user-data for VM1
cat << EOF > config-drives/$VM1_NAME-config/user-data
#cloud-config
ssh_authorized_keys:
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
runcmd:
  - echo 1 > /proc/sys/net/ipv4/ip_forward
  - iptables -A INPUT -i lo -j ACCEPT
  - iptables -A FORWARD -i $VM1_EXTERNAL_IF -o $VM1_INTERNAL_IF -j ACCEPT
  - iptables -t nat -A POSTROUTING -o $VM1_EXTERNAL_IF -j MASQUERADE
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM2_INTERNAL_IP local $VM1_INTERNAL_IP dstport 4789
  - ip addr add $VM1_VXLAN_IP/24 dev vxlan0
  - ip link set vxlan0 up
EOF
#
#meta-data for VM1
echo "hostname: $VM1_NAME
local-hostname: $VM1_NAME
network-interfaces: |
  auto $VM1_EXTERNAL_IF
  iface $VM1_EXTERNAL_IF inet dhcp
  dns-nameservers $VM_DNS
  auto $VM1_INTERNAL_IF
  iface $VM1_INTERNAL_IF inet static
  address $VM1_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  auto $VM1_MANAGEMENT_IF
  iface $VM1_MANAGEMENT_IF inet static
  address $VM1_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM1_NAME-config/meta-data
#
#user-data for VM2
cat << EOF > config-drives/$VM2_NAME-config/user-data
#cloud-config
ssh_authorized_keys:
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - software-properties-common.
runcmd:
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM1_INTERNAL_IP local $VM2_INTERNAL_IP dstport 4789
  - ip link set vxlan0 up
  - ip addr add $VM2_VXLAN_IP/24 dev vxlan0
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  - apt update
  - apt install docker-ce docker-compose -y
EOF
#meta-data for VM2
echo "hostname: $VM2_NAME
local-hostname: $VM2_NAME
network-interfaces: |
  auto $VM2_INTERNAL_IF
  iface $VM2_INTERNAL_IF inet static
  address $VM2_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  gateway $VM1_INTERNAL_IP
  dns-nameservers $EXTERNAL_NET_HOST_IP $VM_DNS
  auto $VM2_MANAGEMENT_IF
  iface $VM2_MANAGEMENT_IF inet static
  address $VM2_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM2_NAME-config/meta-data
#

mkisofs -o $VM1_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM1_NAME-config
mkisofs -o $VM2_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM2_NAME-config

###Create XML
#vm1
echo "<domain type='kvm'>
  <name>vm1</name>
  <memory unit='MiB'>$VM1_MB_RAM</memory>
  <vcpu placement='static'>$VM1_NUM_CPU</vcpu>
  <os>
    <type>$VM_TYPE</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$VM1_HDD'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$VM1_CONFIG_ISO'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <mac address='$VM1_EXT_MAC'/>
      <source network='$EXTERNAL_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <interface type='network'>
      <source network='$INTERNAL_NET_NAME'/>
      <model type='virtio'/>
      <protocol family='ipv4'>
      <ip address='192.168.124.101' prefix='24'/>
      <route gateway='192.168.124.1'/>
      </protocol>
    </interface>
    <interface type='network'>
      <source network='$MANAGEMENT_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <source path='/dev/pts/0'/>
      <target port='0'/>
    </serial>
    <console type='pty' tty='/dev/pts/0'>
      <source path='/dev/pts/0'/>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes'/>
  </devices>
  <features>
    <acpi/>
  </features>
</domain>" > $(dirname $0)/vm1.xml
#
#vm2
echo "<domain type='kvm'>
  <name>$VM2_NAME</name>
  <memory unit='MiB'>$VM2_MB_RAM</memory>
  <vcpu placement='static'>$VM2_NUM_CPU</vcpu>
  <os>
    <type>$VM_TYPE</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$VM2_HDD'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$VM2_CONFIG_ISO'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$INTERNAL_NET_NAME'/>
      <model type='virtio'/>
        <protocol family='ipv4'>
        <ip address='192.168.124.102' prefix='24'/>
        <route gateway='192.168.124.1'/>
        </protocol>
    </interface>
    <interface type='network'>
      <source network='$MANAGEMENT_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <source path='/dev/pts/0'/>
      <target port='0'/>
    </serial>
    <console type='pty' tty='/dev/pts/0'>
      <source path='/dev/pts/0'/>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes'/>
  </devices>
</domain>" > $(dirname $0)/vm2.xml
##############
virsh net-define networks/external.xml
virsh net-define networks/internal.xml
virsh net-define networks/management.xml

virsh net-start external
virsh net-start internal
virsh net-start management

virsh define vm1.xml
virsh define vm2.xml

virsh start vm1
virsh start vm2
