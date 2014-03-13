#!/bin/bash


# Global variables
HOSTNAME="mc"
EMAIL="email.com"
MYSQL_PASSWD="password"
NOVA_DBPASS="password"
NOVA_PASS="password"
RABBIT_PASS="password"


# Add user to sudoers file
#echo "mbingcalan ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Backup interfaces in /etc/network
cp /etc/network/interfaces /etc/network/interfaces.orig

# Import settings to /etc/network/interfaces
edit_interfaces() {
cat <<EOF > /etc/network/interfaces
# The loopback network interface
auto lo
iface lo inet loopback

# Internal network
auto eth0
iface eth0 inet static
address 10.10.10.11
netmask 255.255.255.0

# External network
auto eth1 
iface eth1 inet static
address 192.168.50.11
netmask 255.255.255.0
gateway 192.168.50.1
dns-nameservers 8.8.8.8
EOF
}

# To configure this host name to be available when the system reboots, you must specify it in the /etc/hostname file
cat <<EOF >> /etc/hosts
10.10.10.10	mc
10.10.10.11	cn
EOF

# Install the ntp package on each system running OpenStack services.
apt-get -y install ntp

# Configure the NTP server to follow the controller node
sed -i 's/server ntp.ubuntu.com/server 10.10.10.10/g' /etc/ntp.conf

# Restart NTP
service ntp restart

# Install the MySQL client
apt-get -y install mysql-client

# Ubuntu Cloud Archive for Havana
apt-get -y install python-software-properties
add-apt-repository -y cloud-archive:havana

# Update the package database, upgrade your system, and reboot for all changes to take effect
apt-get -y update && apt-get -y dist-upgrade

# Install packages for the Compute service
apt-get -y install nova-compute-qemu python-guestfs nova-network nova-api-metadata

sleep 3

# Configuration file and add these lines to the appropriate sections
cat <<EOF >> /etc/nova/nova.conf 
auth_strategy=keystone
rpc_backend=nova.rpc.impl_kombu
rabbit_host=$HOSTNAME
rabbit_password=$RABBIT_PASS
my_ip=10.10.10.11
vnc_enabled=True
vncserver_listen=0.0.0.0
vncserver_proxyclient_address=10.10.10.11
novncproxy_base_url=http://$HOSTNAME:6080/vnc_auto.html
glance_host=$HOSTNAME
network_manager=nova.network.manager.FlatDHCPManager
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver
network_size=254
allow_same_net_traffic=False
multi_host=True
send_arp_for_ha=True
share_dhcp_address=True
force_dhcp_release=True
flat_network_bridge=br100
flat_interface=eth0
public_interface=eth1

[database]
connection = mysql://nova:$NOVA_DBPASS@$HOSTNAME/nova
EOF

# Add the credentials to the /etc/nova/api-paste.ini file
sed -i "/auth_host/c auth_host = $HOSTNAME" /etc/nova/api-paste.ini
sed -i "/auth_port/c auth_port = 35357" /etc/nova/api-paste.ini
sed -i "/auth_protocol/c auth_protocol = http" /etc/nova/api-paste.ini
sed -i "/admin_tenant_name/c admin_tenant_name = service" /etc/nova/api-paste.ini
sed -i "/admin_user/c admin_user = nova" /etc/nova/api-paste.ini
sed -i "/admin_password/c admin_password = $NOVA_PASS" /etc/nova/api-paste.ini

# Restart the Compute service
service nova-compute restart

# Remove the SQLite database created by the packages
rm -rf /var/lib/nova/nova.sqlite

## END
