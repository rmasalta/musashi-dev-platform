#!/bin/bash

# Global variables
HOSTNAME="mc"
EMAIL="email.com"
MYSQL_PASSWD="password"
RABBIT_PASS="password"
KEYSTONE_DBPASS="password"
ADMIN_TOKEN="password"
ADMIN_PASS="password"
GLANCE_DBPASS="password"
GLANCE_PASS="password"
NOVA_DBPASS="password"
NOVA_PASS="password"

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
address 10.10.10.10
netmask 255.255.255.0

# External network
auto eth1 
iface eth1 inet static
address 192.168.50.10
netmask 255.255.255.0
gateway 192.168.50.1
dns-nameservers 8.8.8.8
EOF
}

# To configure this host name to be available when the system reboots, you must specify it in the /etc/hostname file
cat <<EOF >> /etc/hosts
10.10.10.10     mc
10.10.10.11     cn
EOF

# Install the ntp package on each system running OpenStack services.
apt-get -y install ntp

# Configure the NTP server to follow the controller node
sed -i 's/server ntp.ubuntu.com/server 10.10.10.10/g' /etc/ntp.conf

# Restart NTP
service ntp restart

# Install the MySQL client and server packages, and the Python library
echo "mysql-server mysql-server/root_password select $MYSQL_PASSWD" | debconf-set-selections
echo "mysql-server mysql-server/root_password_again select $MYSQL_PASSWD" | debconf-set-selections
apt-get -y install python-mysqldb mysql-server

# Backup my.cnf
cp /etc/mysql/my.cnf /etc/mysql/my.cnf.orig

# Modify bind-address
awk '/bind-address/ {print $3}' /etc/mysql/my.cnf | while read bindadd 
do
	sed -i "s/$bindadd/0.0.0.0/g" /etc/mysql/my.cnf
done

# Restart mysql server
service mysql restart

sleep 3

# Allow root access from remote connection
mysql -u root -p$MYSQL_PASSWD -e "GRANT ALL PRIVILEGES ON *.* to root@'localhost' IDENTIFIED BY '$MYSQL_PASSWD';"
mysql -u root -p$MYSQL_PASSWD -e "GRANT ALL PRIVILEGES ON *.* to root@'$HOSTNAME' IDENTIFIED BY '$MYSQL_PASSWD';"
mysql -u root -p$MYSQL_PASSWD -e "GRANT ALL PRIVILEGES ON *.* to root@'%' IDENTIFIED BY '$MYSQL_PASSWD';FLUSH PRIVILEGES;"

# Drop anonymous users
mysql -u root -p$MYSQL_PASSWD -e "DROP USER ''@'localhost';" 

# Drop database "test"
mysql -u root -p$MYSQL_PASSWD -e "DROP DATABASE test;"

# Ubuntu Cloud Archive for Havana
apt-get -y install python-software-properties
add-apt-repository -y cloud-archive:havana

# Update the package database, upgrade your system, and reboot for all changes to take effect
apt-get -y update && apt-get -y dist-upgrade

# Install the messaging queue server and change guest password
apt-get -y install rabbitmq-server
rabbitmqctl change_password guest $RABBIT_PASS

# Install the OpenStack Identity Service
apt-get -y install keystone

# Backup /etc/keystone/keystone.conf
cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig

# Specify the location of the database in the configuration file
sed -i "/\[sql\]/ {
n
n
c\connection = mysql://keystone:$KEYSTONE_DBPASS@$HOSTNAME/keystone
}" /etc/keystone/keystone.conf

# Delete the keystone.db file created in the /var/lib/keystone/
rm -rf /var/lib/keystone/keystone.db

# Create a keystone database/user
mysql -u root -p$MYSQL_PASSWD <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$KEYSTONE_DBPASS';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$KEYSTONE_DBPASS';
EOF

# Create the database tables for the Identity Service
keystone-manage db_sync

# Edit /etc/keystone/keystone.conf and change the [DEFAULT] section, 
# replacing ADMIN_TOKEN with the results of the command
sed -i "/\[DEFAULT\]/ {
n
n
c\admin_token = $ADMIN_TOKEN
}" /etc/keystone/keystone.conf

# Restart the Identity Service
service keystone restart

sleep 3

# Export token and endpoint
export OS_SERVICE_TOKEN=$ADMIN_TOKEN
export OS_SERVICE_ENDPOINT=http://$HOSTNAME:35357/v2.0

# Create a tenant for an administrative user and a tenant for other OpenStack services to use
keystone tenant-create --name=admin --description="Admin Tenant"
keystone tenant-create --name=service --description="Service Tenant"

# Create an administrative user called admin
keystone user-create --name=admin --pass=$ADMIN_PASS --email=admin@$EMAIL

# Create a role for administrative tasks called admin. 
# Any roles you create should map to roles specified in the policy.json files of the various OpenStack services. 
# The default policy files use the admin role to allow access to most services.
keystone role-create --name=admin

# Finally, you have to add roles to users. Users always log in with a tenant, and roles are assigned to users within tenants.
# Add the admin role to the admin user when logging in with the admin tenant.
keystone user-role-add --user=admin --tenant=admin --role=admin

# Create a service entry for the Identity Service
keystone service-create --name=keystone --type=identity --description="Keystone Identity Service"
get_id=$(mysql -u root -p$MYSQL_PASSWD -D keystone -e "SELECT id FROM service WHERE type='identity';" | awk '{print $1}' | tail -n1)
keystone endpoint-create --service-id=$get_id --publicurl=http://$HOSTNAME:5000/v2.0 --internalurl=http://$HOSTNAME:5000/v2.0 --adminurl=http://$HOSTNAME:35357/v2.0

# Unset the OS_SERVICE_TOKEN and OS_SERVICE_ENDPOINT environment variables. These were only used to bootstrap the administrative user and register the Identity Service
unset OS_SERVICE_TOKEN 
unset OS_SERVICE_ENDPOINT

# Request an authentication token using the admin user and the password you chose during the earlier administrative user-creation 
keystone --os-username=admin --os-password=$ADMIN_PASS --os-auth-url=http://$HOSTNAME:35357/v2.0 token-get

# Verify that authorization is behaving as expected by requesting authorization on a tenant
keystone --os-username=admin --os-password=$ADMIN_PASS --os-tenant-name=admin --os-auth-url=http://$HOSTNAME:35357/v2.0 token-get

# Set up a keystonerc file with the admin credentials and admin endpoint
cat <<EOF > /root/keystonerc
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://$HOSTNAME:35357/v2.0
EOF

# Source keystone credentials
source /root/keystonerc

# Verify that your keystonerc is configured correctly by performing the same command as above, but without the --os-* arguments
keystone token-get

# Finally, verify that your admin account has authorization to perform administrative commands
keystone user-list

# Install the Image Service on the controller node
apt-get -y install glance python-glanceclient

# Configure the location of the database. The Image Service provides the glance-api and glance-registry services, each with its own configuration file
sed -i "/sql_connection/c\
sql_connection = mysql://glance:$GLANCE_DBPASS@$HOSTNAME/glance" /etc/glance/glance-api.conf

sed -i "/sql_connection/c\
sql_connection = mysql://glance:$GLANCE_DBPASS@$HOSTNAME/glance" /etc/glance/glance-registry.conf

# Delete the glance.sqlite file created in the /var/lib/glance/ directory so that it does not get used by mistake
rm -rf /var/lib/glance/glance.sqlite

# Use the password you created to log in as root and create a glance database user
mysql -u root -p$MYSQL_PASSWD <<EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$GLANCE_DBPASS';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$GLANCE_DBPASS';
EOF

# Create the database tables for the Image Service
glance-manage db_sync

# Create a glance user that the Image Service can use to authenticate with the Identity Service
keystone user-create --name=glance --pass=$GLANCE_PASS --email=glance@$EMAIL
keystone user-role-add --user=glance --tenant=service --role=admin

# Edit the /etc/glance/glance-api.conf and /etc/glance/glance-registry.conf files
sed -i "/\[keystone_authtoken\]/ {n;i\auth_uri = http://$HOSTNAME:5000
}" /etc/glance/glance-api.conf
sed -i "/auth_host/c auth_host = $HOSTNAME" /etc/glance/glance-api.conf
sed -i "/auth_port/c auth_port = 35357" /etc/glance/glance-api.conf
sed -i "/auth_protocol/c auth_protocol = http" /etc/glance/glance-api.conf
sed -i "/admin_tenant_name/c admin_tenant_name = service" /etc/glance/glance-api.conf
sed -i "/admin_user/c admin_user = glance" /etc/glance/glance-api.conf
sed -i "/admin_password/c admin_password = $GLANCE_PASS" /etc/glance/glance-api.conf

sed -i "/\[keystone_authtoken\]/ {n;i\auth_uri = http://$HOSTNAME:5000
}" /etc/glance/glance-registry.conf
sed -i "/auth_host/c auth_host = $HOSTNAME" /etc/glance/glance-registry.conf
sed -i "/auth_port/c auth_port = 35357" /etc/glance/glance-registry.conf
sed -i "/auth_protocol/c auth_protocol = http" /etc/glance/glance-registry.conf
sed -i "/admin_tenant_name/c admin_tenant_name = service" /etc/glance/glance-registry.conf
sed -i "/admin_user/c admin_user = glance" /etc/glance/glance-registry.conf
sed -i "/admin_password/c admin_password = $GLANCE_PASS" /etc/glance/glance-registry.conf

# Add the following key under the [paste_deploy] section
sed -i "/\[paste_deploy\]/ {n;i\flavor = keystone
}" /etc/glance/glance-api.conf

sed -i "/\[paste_deploy\]/ {n;i\flavor = keystone
}" /etc/glance/glance-registry.conf

# Add the credentials to the /etc/glance/glance-api-paste.ini and /etc/glance/glance-registry-paste.ini files
sed -i "/\[filter:authtoken\]/ {n;n;n;i\auth_host = $HOSTNAME
i\admin_user = glance
i\admin_tenant_name = service
i\admin_password = $GLANCE_PASS
}" /etc/glance/glance-api-paste.ini

#sed -i "/\[filter:authtoken\]/ {n;i\auth_host = $HOSTNAME
#i\admin_user = glance
#i\admin_tenant_name = service
#i\admin_password = $GLANCE_PASS
#}" /etc/glance/glance-registry-paste.ini

cat <<EOF >> /etc/glance/glance-registry-paste.ini
auth_host = $HOSTNAME
admin_user = glance
admin_tenant_name = service
admin_password = $GLANCE_PASS
EOF

# Register the service and create the endpoint
keystone service-create --name=glance --type=image --description="Glance Image Service"
get_id=$(mysql -u root -p$MYSQL_PASSWD -D keystone -e "SELECT id FROM service WHERE type='image';" | awk '{print $1}' | tail -n1)
keystone endpoint-create --service-id=$get_id --publicurl=http://$HOSTNAME:9292 --internalurl=http://$HOSTNAME:9292 --adminurl=http://$HOSTNAME:9292

# Restart the glance service with its new settings
service glance-registry restart && service glance-api restart

sleep 3

# Download the image into a dedicated directory using wget or curl
mkdir /root/images && wget -P /root/images wget http://cdn.download.cirros-cloud.net/0.3.1/cirros-0.3.1-x86_64-disk.img

# Upload the image to the Image Service
glance image-create --name="CirrOS 0.3.1" --disk-format=qcow2  --container-format=bare --is-public=true < /root/images/cirros-0.3.1-x86_64-disk.img

# Install these Compute packages, which provide the Compute services that run on the controller node
apt-get -y install nova-novncproxy novnc nova-api nova-ajax-console-proxy nova-cert nova-conductor nova-consoleauth nova-doc nova-scheduler python-novaclient

# Configure the location of the database. Configure the Compute Service to use the RabbitMQ
cat <<EOF >> /etc/nova/nova.conf 
rpc_backend=nova.rpc.impl_kombu
rabbit_host=$HOSTNAME
rabbit_password=$RABBIT_PASS
my_ip=10.10.10.10
vncserver_listen=0.0.0.0
vncserver_proxyclient_address=10.10.10.10
auth_strategy=keystone

[database]
connection = mysql://nova:$NOVA_DBPASS@$HOSTNAME/nova

[keystone_authtoken]
auth_host=$HOSTNAME
auth_port=35357
auth_protocol=http
admin_tenant_name=service
admin_user=nova
admin_password=$NOVA_PASS
EOF

#  Delete packages create an SQLite database
rm -rf /var/lib/nova/nova.sqlite

# Create a nova database user
mysql -u root -p$MYSQL_PASSWD <<EOF
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$NOVA_DBPASS';
EOF

# Create the Compute service tables
nova-manage db sync

sleep 3

# Create a nova user that Compute uses to authenticate with the Identity Service
keystone user-create --name=nova --pass=$NOVA_PASS --email=nova@$EMAIL
keystone user-role-add --user=nova --tenant=service --role=admin

# Add the credentials to the /etc/nova/api-paste.ini file
sed -i "/\[filter:authtoken\]/ {n;n;i\auth_uri = http://$HOSTNAME:5000/v2.0
}" /etc/nova/api-paste.ini
sed -i "/auth_host/c auth_host = $HOSTNAME" /etc/nova/api-paste.ini
sed -i "/auth_port/c auth_port = 35357" /etc/nova/api-paste.ini
sed -i "/auth_protocol/c auth_protocol = http" /etc/nova/api-paste.ini
sed -i "/admin_tenant_name/c admin_tenant_name = service" /etc/nova/api-paste.ini
sed -i "/admin_user/c admin_user = nova" /etc/nova/api-paste.ini
sed -i "/admin_password/c admin_password = $NOVA_PASS" /etc/nova/api-paste.ini

# Register the service and specify the endpoint
keystone service-create --name=nova --type=compute --description="Nova Compute service"
get_id=$(mysql -u root -p$MYSQL_PASSWD -D keystone -e "SELECT id FROM service WHERE type='compute';" | awk '{print $1}' | tail -n1)
keystone endpoint-create --service-id=$get_id --publicurl=http://$HOSTNAME:8774/v2/%\(tenant_id\)s --internalurl=http://$HOSTNAME:8774/v2/%\(tenant_id\)s --adminurl=http://$HOSTNAME:8774/v2/%\(tenant_id\)s

# Create a network that virtual machines can use
nova network-create vmnet --fixed-range-v4=10.10.10.0/24 --bridge=br100 --multi-host=T

# Generate a keypair that consists of a private and public key to be able to launch instances on OpenStack
ssh-keygen -N "" -f /root/.ssh/id_rsa
nova keypair-add --pub_key /root/.ssh/id_rsa.pub rootkey

# Install the dashboard on the node that can contact the Identity Service as root
apt-get -y install memcached libapache2-mod-wsgi openstack-dashboard

# Remove the openstack-dashboard-ubuntu-theme package
apt-get remove --purge openstack-dashboard-ubuntu-theme


## END
