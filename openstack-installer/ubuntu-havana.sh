#!/bin/bash

####################################################################################################
# Config
####################################################################################################

GRUBMD5=`md5sum /boot/grub/grub.cfg`
CWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OPENSTACK_RELEASE=0
UPDATE_MYSQL=0

LOG="/root/openstack.log"
TOKEN=$(openssl rand -hex 10)
PASSWORD="tester"
EMAIL="david.m.oneill@intel.com"

NETSTART="10.237.216"

CONTROLLER_HOSTNAME="controller"
CONTROLLER_EXT_NW="$NETSTART.0"
CONTROLLER_EXT_IP="$NETSTART.15"
CONTROLLER_EXT_BC="$NETSTART.255"
CONTROLLER_EXT_NM="255.255.255.0"
CONTROLLER_EXT_GW="$NETSTART.1"
CONTROLLER_EXT_DS="ir.intel.com"
CONTROLLER_EXT_DR="10.248.2.1 10.237.217.251"
CONTROLLER_INT_IP="192.168.0.11"
CONTROLLER_INT_NM="255.255.255.0"
CONTROLLER_SERVICE_FQDN="$CONTROLLER_HOSTNAME.$CONTROLLER_EXT_DS"

COMPUTE_HOSTNAME="compute1"
COMPUTE_EXT_NW="$NETSTART.0"
COMPUTE_EXT_IP="$NETSTART.16"
COMPUTE_EXT_BC="$NETSTART.255"
COMPUTE_EXT_NM="255.255.255.0"
COMPUTE_EXT_GW="$NETSTART.1"
COMPUTE_EXT_DS="ir.intel.com"
COMPUTE_EXT_DR="10.248.2.1 10.237.217.251"
COMPUTE_INT_IP="192.168.0.12"
COMPUTE_INT_NM="255.255.255.0"
COMPUTE_SERVICE_FQDN="$COMPUTE_HOSTNAME.$CONTROLLER_EXT_DS"

TENANT_NW="$CONTROLLER_EXT_NW"
TENANT_NM="$CONTROLLER_EXT_NM"
TENANT_GW="$CONTROLLER_EXT_GW"
TENANT_DS="ir.intel.com"
TENANT_FIPS="$NETSTART.5"
TENANT_FIPE="$NETSTART.9"
TENANT_CIDR="24"

ISCOMPUTE=0
ISCONTROLLER=0
ISNETWORK=0
NETWORK=0
ISNEUTRON=0
USEPROXY=0
USEPROXYHOSTS=0
PROXY="cache"
PROXYFQDN="$PROXY.$CONTROLLER_EXT_DS"
PROXYIP=$(nslookup $PROXYFQDN | tail -n 2 | grep Addr | awk '{print $2}')
PROXYPORT="911"

HOSTNAME=""
INT_IP=""
INT_NM=""
EXT_NW=""
EXT_IP=""
EXT_BC=""
EXT_NM=""
EXT_GW=""
EXT_DS=""
EXT_DR=""


####################################################################################################
# Networking
####################################################################################################

function ConfigureNetworking
{
	LogSection "Configuring network"

	WriteConfig "/etc/hostname" "$HOSTNAME"
	BackupConfig "/etc/network/interfaces"
	
	CONFIG=$(ReadConfig "$CWD/ocf/interfaces")
	WriteConfig "/etc/network/interfaces" "$CONFIG"
	
	sed -i 's/sleep 20/sleep 2/g' /etc/init/failsafe.conf
	sed -i 's/sleep 40/sleep 2/g' /etc/init/failsafe.conf
	sed -i 's/sleep 59/sleep 2/g' /etc/init/failsafe.conf

	BackupConfig "/etc/hosts"
	CONFIG=$(ReadConfig "$CWD/ocf/hosts")
	WriteConfig "/etc/hosts" "$CONFIG"

	RestartService "networking"
	hostname "$HOSTNAME"
}

####################################################################################################
# Configure grub
####################################################################################################

function ConfigureGrub
{
	LogSection "Configuring grub"
	
	BackupConfig "/etc/default/grub"
	CONFIG=$(ReadConfig "/etc/default/grub")
	CONFIG=$(ReplaceInConfig "$CONFIG" 'GRUB_CMDLINE_LINUX_DEFAULT=\".*?\"' 'GRUB_CMDLINE_LINUX_DEFAULT=\"kvm-intel.nested=1 text\"')
	WriteConfig "/etc/default/grub" "$CONFIG" 
	update-grub >> $LOG 2>&1 
}

####################################################################################################
# System Settings,,,, Update first
####################################################################################################

function PrepareSystem
{
	LogSection "Configuring system"

	UpdatePackages
	RemovePackage "ufw"
	InstallPackage "debconf-utils firefox dnsmasq iptables sysfsutils"
	StopService "iptables"
	
	BackupConfig "/etc/sysctl.conf"
	CONFIG=$(ReadConfig "/etc/sysctl.conf")
	CONFIG=$(ReplaceInConfig "$CONFIG" "#net.ipv4.ip_forward" "net.ipv4.ip_forward")
	CONFIG=$(ReplaceInConfig "$CONFIG" "#net.ipv4.conf.all.rp_filter=1" "net.ipv4.conf.all.rp_filter = 0")
	CONFIG=$(ReplaceInConfig "$CONFIG" "#net.ipv4.conf.default.rp_filter=1" "net.ipv4.conf.default.rp_filter = 0")
	CONFIG=$(ReplaceInConfig "$CONFIG" "#kernel" "kernel")
	WriteConfig "/etc/sysctl.conf" "$CONFIG" 
	
	sysctl -e -p /etc/sysctl.conf >> $LOG 2>&1  

	BackupConfig "/etc/rsyslog.d/50-default.conf"
	CONFIG=$(ReadConfig "/etc/rsyslog.d/50-default.conf")
	CONFIG=$(ReplaceInConfig "$CONFIG" '\*.\*;auth,authpriv.none.*?\/var\/log\/syslog' '*.*;auth,authpriv.none,kern.none -\/var\/log\/syslog')
	WriteConfig "/etc/rsyslog.d/50-default.conf" "$CONFIG"
}

####################################################################################################
# Ntp
####################################################################################################

function ConfigureNtp
{
	LogSection "Installing ntp"
	
	InstallPackage "ntp"

	BackupConfig "/etc/ntp.conf"
	CONFIG=$(ReadConfig "/etc/ntp.conf")
	CONFIG=$(ReplaceInConfig "$CONFIG" "server 0.*?.org" "server ntp-host1.$CONTROLLER_EXT_DS")
	CONFIG=$(ReplaceInConfig "$CONFIG" "server 1.*?.org" "server ntp-host2.$CONTROLLER_EXT_DS")
	CONFIG=$(ReplaceInConfig "$CONFIG" "server 2.*?.org" "server ntp-host3.$CONTROLLER_EXT_DS")
	CONFIG=$(ReplaceInConfig "$CONFIG" "server 3.*?.org" '')
	WriteConfig "/etc/ntp.conf" "$CONFIG" 

	RestartService "ntp"
}

####################################################################################################
# Mysql
####################################################################################################

function ConfigureMysql
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing mysql"
		InstallPackage "python-mysqldb mysql-server python-sqlalchemy"

		BackupConfig "/etc/mysql/my.cnf"
		CONFIG=$(ReadConfig "/etc/mysql/my.cnf")
		CONFIG=$(ReplaceInConfig "$CONFIG" 'bind-address.*?$' 'bind-address = 0.0.0.0')
		WriteConfig "/etc/mysql/my.cnf" "$CONFIG" 
		
		if [[ $UPDATE_MYSQL -eq 1 ]]; then
			DownloadFile "https://dev.mysql.com/get/Downloads/MySQL-5.6/mysql-5.6.15-debian6.0-x86_64.deb"
			DpkgInstallPackage "mysql-5.6.15-debian6.0-x86_64.deb"
			InstallPackage "libaio1"
			RemovePackage "mysql-common mysql-server-5.5 mysql-server-core-5.5 mysql-client-5.5 mysql-client-core-5.5"
			AutoRemovePackages

			Copy "/opt/mysql/server-5.6/support-files/mysql.server" "/etc/init.d/mysql.server"
			RemoveService "mysql"

			sed -i 's/PATH="\(.*\)"/PATH="\1:\/opt\/mysql\/server-5.6\/bin"/g' /etc/environment
			source /etc/environment
			
			BackupConfig "/etc/mysql/my.cnf"
			CONFIG=$(ReadConfig "$CWD/ocf/my_cnf")
			WriteConfig "/etc/mysql/my.cnf" "$CONFIG" 
			
			RestartService "mysql.server"
		else
			RestartService "mysql"
		fi

		mysqladmin -u root password $PASSWORD >> $LOG 2>&1
	fi
}


####################################################################################################
# Stack repo
####################################################################################################

function ConfigureRepos
{
	LogSection "Configuring repositories"

	InstallPackage "python-software-properties ubuntu-cloud-keyring"

	if [[ $USEPROXY -eq 1 ]]; then
		export http_proxy=http://$PROXYFQDN:$PROXYPORT
		export https_proxy=$http_proxy
	fi

	# monogo db
	apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 7F0CEB10 >> $LOG 2>&1
	echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' | tee /etc/apt/sources.list.d/mongodb.list >> $LOG 2>&1
	
	# docker
	wget -qO- https://get.docker.io/gpg | apt-key add - >> $LOG 2>&1
	echo 'deb http://get.docker.io/ubuntu docker main' | tee /etc/apt/sources.list.d/docker.list >> $LOG 2>&1
	
	if [[ $OPENSTACK_RELEASE -eq 1 ]]; then
		add-apt-repository -y cloud-archive:grizzley >> $LOG 2>&1
	elif [[ $OPENSTACK_RELEASE -eq 2 ]]; then
		add-apt-repository -y ppa:openstack-ubuntu-testing/grizzly >> $LOG 2>&1
	elif [[ $OPENSTACK_RELEASE -eq 3 ]]; then
		add-apt-repository -y cloud-archive:havana >> $LOG 2>&1
	elif [[ $OPENSTACK_RELEASE -eq 4 ]]; then
		add-apt-repository -y ppa:openstack-ubuntu-testing/havana >> $LOG 2>&1
	elif [[ $OPENSTACK_RELEASE -eq 5 ]]; then
		add-apt-repository -y ppa:ubuntu-cloud-archive/icehouse-staging >> $LOG 2>&1
	elif [[ $OPENSTACK_RELEASE -eq 6 ]]; then
		add-apt-repository -y ppa:openstack-ubuntu-testing/icehouse >> $LOG 2>&1
	else
		echo "Somehow you got here.. exiting"
		exit
	fi	
	
	if [[ $USEPROXY -eq 1 ]]; then
		export http_proxy=""
		export https_proxy=""
	fi
	
	#InstallPackage "gplhost-archive-keyring"
}


####################################################################################################
# Rabbit
####################################################################################################

function ConfigureRabbit
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing rabbit"
		InstallPackage "rabbitmq-server"
		
		mkdir -vp /etc/rabbitmq/rabbitmq.conf.d/  >> $LOG 2>&1
		BackupConfig "/etc/rabbitmq/rabbitmq.conf.d/default"
		CONFIG=$(ReadConfig "$CWD/ocf/rabbitdefault")
		WriteConfig "/etc/rabbitmq/rabbitmq.conf.d/default" "$CONFIG" 
		
		RestartService "rabbitmq-server"
		rabbitmqctl change_password guest $PASSWORD >> $LOG 2>&1
	fi
}

####################################################################################################
# Keystone
####################################################################################################

function ConfigureKeystone
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing keystone"
		InstallPackage "keystone"

		BackupConfig "/etc/keystone/keystone.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/keystone_conf")
		WriteConfig "/etc/keystone/keystone.conf" "$CONFIG" 
		
		CONFIG=$(ReadConfig "$CWD/ocf/keystonerc")
		WriteConfig "/root/keystonerc" "$CONFIG" 
		source /root/keystonerc

		rm -rvf /var/lib/keystone/keystone.sqlite >> $LOG 2>&1
		SqlExec "CREATE DATABASE keystone;"
		SqlExec "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$PASSWORD'; FLUSH PRIVILEGES;"
		SqlExec "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$PASSWORD'; FLUSH PRIVILEGES;"
		
		mkdir -pv /usr/etc >> $LOG 2>&1
		ln -s /etc/keystone/keystone.conf /usr/etc/keystone.conf >> $LOG 2>&1
		chown -R keystone:keystone /etc/keystone/* /var/log/keystone/keystone.log >> $LOG 2>&1
		sudo keystone-manage db_sync >> $LOG 2>&1
		RestartService "keystone"

		keystone tenant-create --name=admin --description="Admin Tenant" >> $LOG 2>&1
		keystone tenant-create --name=service --description="Service Tenant" >> $LOG 2>&1
		keystone user-create --name=admin --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone role-create --name=admin >> $LOG 2>&1
		keystone role-create --name=Member >> $LOG 2>&1
		keystone user-role-add --user=admin --tenant=admin --role=admin >> $LOG 2>&1
		keystone user-role-add --user=admin --tenant=admin --role=Member >> $LOG 2>&1
		ID=$(keystone service-create --name=keystone --type=identity --description='Keystone Identity Service' | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:5000/v2.0 \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:5000/v2.0 \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:35357/v2.0  >> $LOG 2>&1	
	fi
}

####################################################################################################
# Glance
####################################################################################################

function ConfigureGlance
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing glance"
		InstallPackage "glance"

		BackupConfig "/etc/glance/glance-api.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/glance_api_conf")
		WriteConfig "/etc/glance/glance-api.conf" "$CONFIG"
	
		BackupConfig "/etc/glance/glance-registry-paste.ini"
		CONFIG=$(ReadConfig "$CWD/ocf/glance_registry_paste_ini")
		WriteConfig "/etc/glance/glance-registry-paste.ini" "$CONFIG" 

		rm -rvf /var/lib/keystone/keystone.sqlite >> $LOG 2>&1
		SqlExec "CREATE DATABASE glance;"
		SqlExec "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$PASSWORD';"

		sudo glance-manage db_sync >> $LOG 2>&1
		keystone user-create --name=glance --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=glance --tenant=service --role=admin >> $LOG 2>&1
		ID=$(keystone service-create --name=glance --type=image --description="Glance Image Service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:9292 \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:9292 \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:9292 >> $LOG 2>&1

		chown -R glance:glance /etc/glance/* /var/log/glance/* >> $LOG 2>&1
		RestartService "glance-registry"
		RestartService "glance-api"
	
		mkdir -pv images >> $LOG 2>&1
		cd images/
		DownloadFile "http://cdn.download.cirros-cloud.net/0.3.1/cirros-0.3.1-x86_64-disk.img"
		glance image-create --name="CirrOS 0.3.1" --disk-format=qcow2 --container-format=bare \
			--is-public=true < cirros-0.3.1-x86_64-disk.img >> $LOG 2>&1
			
		DownloadFile "http://cloud-images.ubuntu.com/precise/current/precise-server-cloudimg-amd64-disk1.img"
		glance image-create --name="Ubuntu Server 12.04" --disk-format=qcow2 --container-format=bare \
			--is-public=true < precise-server-cloudimg-amd64-disk1.img >> $LOG 2>&1
		glance image-create --name="Trove" --container-format=ovf --disk-format=qcow2 --owner trove \
			--is-public=true < precise-server-cloudimg-amd64-disk1.img >> $LOG 2>&1
			
		DownloadFile "http://download.fedoraproject.org/pub/fedora/linux/releases/20/Images/x86_64/Fedora-x86_64-20-20131211.1-sda.qcow2"
		glance image-create --name="Fedora 20" --disk-format=qcow2 --container-format=bare \
			--is-public=true < Fedora-x86_64-20-20131211.1-sda.qcow2 >> $LOG 2>&1
			
		DownloadFile "http://dev.centos.org/centos/hvm/CentOS-6.4-x86_64-Minimal-OpenStack.image.qcow2"
		glance image-create --name="Centos 6.4" --disk-format=qcow2 --container-format=bare \
			--is-public=true < CentOS-6.4-x86_64-Minimal-OpenStack.image.qcow2 >> $LOG 2>&1
			
	fi
}

####################################################################################################
# Docker
####################################################################################################

function ConfigureDocker
{
	LogSection "Installing docker"
	InstallPackage "lxc-docker"
	
	if [[ $USEPROXY -eq 1 ]]; then
		sed -i "s/\"\$DOCKER\"/HTTP_PROXY=http:\/\/$PROXYFQDN:$PROXYPORT \"\$DOCKER\"/g" /etc/init/docker.conf
	fi
	
	RestartService "docker"
	docker pull ubuntu >> $LOG 2>&1
	RestartService "docker"
}

####################################################################################################
# Nova
####################################################################################################

function ConfigureNova
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing nova"
		DownloadFile "http://archive.ubuntu.com/ubuntu/pool/universe/libj/libjs-swfobject/libjs-swfobject_2.2+dfsg-1_all.deb"
		DpkgInstallPackage "libjs-swfobject_2.2+dfsg-1_all.deb"
		InstallPackage "nova-novncproxy novnc nova-api nova-ajax-console-proxy nova-cert nova-conductor nova-consoleauth nova-doc nova-scheduler python-novaclient"
		sed -i 's/nova_token.*token/\/\//g' /usr/share/novnc/include/rfb.js
	fi

	if [[ $ISCOMPUTE -eq 1 ]]; then
		LogSection "Installing nova compute"
		echo "libguestfs0     libguestfs/update-appliance     boolean true" > supermin.seed
		debconf-set-selections ./supermin.seed
		InstallPackage "nova-compute-kvm python-guestfs qemu-kvm libvirt-bin ubuntu-vm-builder bridge-utils"
		InstallPackage "kvm qemu"
		chmod 0644 /boot/vmlinuz* >> $LOG 2>&1
		rm /var/lib/nova/nova.sqlite >> $LOG 2>&1
	fi

	if [[ $NETWORK -eq 1 ]]; then
		if [[ $ISNEUTRON -eq 0 ]]; then
			NETCONFIG=$(ReadConfig "$CWD/ocf/nova_network")
		else
			NETCONFIG=$(ReadConfig "$CWD/ocf/neutron_network")
		fi
	else
		NETCONFIG=""	
	fi

	BackupConfig "/etc/nova/nova.conf"
	CONFIG=$(ReadConfig "$CWD/ocf/nova_conf")
	WriteConfig "/etc/nova/nova.conf" "$CONFIG"
	rm -rvf /var/lib/nova/nova.sqlite >> $LOG 2>&1

	if [[ $ISCONTROLLER -eq 1 ]]; then
		SqlExec "CREATE DATABASE nova;"
		SqlExec "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$PASSWORD';"
		
		mkdir -pv /usr/etc >> $LOG 2>&1
		ln -s /etc/nova/nova.conf /usr/etc/nova.conf >> $LOG 2>&1
		
		sudo nova-manage db sync >> $LOG 2>&1
		keystone user-create --name=nova --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=nova --tenant=service --role=admin >> $LOG 2>&1
	fi	

	BackupConfig "/etc/nova/api-paste.ini"
	CONFIG=$(ReadConfig "$CWD/ocf/api_paste_ini")
	WriteConfig "/etc/nova/api-paste.ini" "$CONFIG"

	if [[ $ISCONTROLLER -eq 1 ]]; then
		ID=$(keystone service-create --name=nova --type=compute --description="Nova Compute service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8774/v2/%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8774/v2/%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8774/v2/%\(tenant_id\)s >> $LOG 2>&1

		RestartService "nova-api"
		RestartService "nova-cert"
		RestartService "nova-consoleauth"
		RestartService "nova-scheduler"
		RestartService "nova-conductor"
		RestartService "nova-novncproxy"

		rm -rvf /root/.ssh/id_rsa >> $LOG 2>&1
		rm -rvf /root/.ssh/id_rsa.pub >> $LOG 2>&1
		mkdir -p /root/.ssh >> $LOG 2>&1
		chmod -v 700 /root/.ssh >> $LOG 2>&1
		cd /root/.ssh
		ssh-keygen -t rsa -N "" -f id_rsa >> $LOG 2>&1
		nova keypair-add --pub_key id_rsa.pub mykey >> $LOG 2>&1
		nova secgroup-add-rule default tcp 22 22 0.0.0.0/0 >> $LOG 2>&1
		nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0 >> $LOG 2>&1
	fi
	
	chown -R nova:nova /etc/nova/* /var/log/nova/* >> $LOG 2>&1
}

####################################################################################################
# horizon
####################################################################################################

function ConfigureHorizon
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing horizon"
		InstallPackage "apache2 memcached libapache2-mod-wsgi openstack-dashboard"
		RemovePackage "openstack-dashboard-ubuntu-theme"
		
		echo "ServerName $CONTROLLER_SERVICE_FQDN" >> /etc/apache2/apache2.conf
		
		BackupConfig "/etc/apache2/sites-enabled/000-default"
		CONFIG=$(ReadConfig "/etc/apache2/sites-enabled/000-default")
		CONFIG=$(ReplaceInConfig "$CONFIG" '^ServerAdmin.*?$' "ServerAdmin $EMAIL\nServerName $CONTROLLER_SERVICE_FQDN")
		WriteConfig "/etc/apache2/sites-enabled/000-default" "$CONFIG" 

		#BackupConfig "/etc/openstack-dashboard/local_settings.py"
		#CONFIG=$(ReadConfig "/etc/openstack-dashboard/local_settings.py")
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^OPENSTACK_HOST.*?$' "OPENSTACK_HOST = \\\"$CONTROLLER_SERVICE_FQDN\\\"")
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^ALLOWED_HOSTS.*?$' "ALLOWED_HOSTS = \['*'\]")
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^OPENSTACK_KEYSTONE_URL.*?$' 'OPENSTACK_KEYSTONE_URL = \"http:\/\/'$CONTROLLER_SERVICE_FQDN':5000\/V2.0\"')
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^try.*?$' '')
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^from ubuntu.*?$' '')
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^except.*?$' '')
		#CONFIG=$(ReplaceInConfig "$CONFIG" '^pass.*?$' '')
		#WriteConfig "/etc/openstack-dashboard/local_settings.py" "$CONFIG" 

		Copy "$CWD/ocf/favicon_ico" "/var/www/favicon.ico"
		chown www-data:www-data /var/www/favicon.ico >> $LOG 2>&1
		
		RestartService "apache2"
		RestartService "memcached"
	fi
}

####################################################################################################
# Cinder
####################################################################################################

function ConfigureCinder
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing cinder"
		InstallPackage "cinder-api cinder-scheduler"

		BackupConfig "/etc/cinder/cinder.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/cinder_conf")
		WriteConfig "/etc/cinder/cinder.conf" "$CONFIG" 

		SqlExec "CREATE DATABASE cinder;"
		SqlExec "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$PASSWORD';"

		sudo cinder-manage db sync >> $LOG 2>&1
		keystone user-create --name=cinder --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=cinder --tenant=service --role=admin >> $LOG 2>&1
	
		BackupConfig "/etc/cinder/api-paste.ini"
		CONFIG=$(ReadConfig "$CWD/ocf/cinder_api_paste_ini")
		WriteConfig "/etc/cinder/api-paste.ini" "$CONFIG" 

		ID=$(keystone service-create --name=cinder --type=volume --description="Cinder Volume Service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8776/v1/%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8776/v1/%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8776/v1/%\(tenant_id\)s >> $LOG 2>&1

		ID=$(keystone service-create --name=cinder --type=volumev2 --description="Cinder Volume Service V2" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8776/v2/%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8776/v2/%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8776/v2/%\(tenant_id\)s >> $LOG 2>&1

		RestartService "cinder-scheduler"
		RestartService "cinder-api"

		InstallPackage "cinder-volume lvm2"
		pvcreate /dev/sdb >> $LOG 2>&1
		vgcreate cinder-volumes /dev/sdb >> $LOG 2>&1
	
		BackupConfig "/etc/lvm/lvm.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/lvm_conf")
		WriteConfig "/etc/lvm/lvm.conf" "$CONFIG" 

		RestartService "cinder-volume"
		RestartService "tgt"
		
		cinder type-create lvm >> $LOG 2>&1
	
		chown -R cinder:cinder /etc/cinder/* /var/log/cinder/* >> $LOG 2>&1
	fi
}

####################################################################################################
# Heat
####################################################################################################

function ConfigureHeat
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing heat"
		InstallPackage "heat-api heat-api-cfn heat-engine"

		BackupConfig "/etc/heat/heat.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/heat_conf")
		WriteConfig "/etc/heat/heat.conf" "$CONFIG" 
	
		SqlExec "CREATE DATABASE heat;"
		SqlExec "GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$PASSWORD';"

		sudo heat-manage db_sync >> $LOG 2>&1

		keystone user-create --name=heat --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=heat --tenant=service --role=admin >> $LOG 2>&1
		ID=$(keystone service-create --name=heat --type=orchestration --description="Heat Orchestration API" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8004/v1/%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8004/v1/%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8004/v1/%\(tenant_id\)s >> $LOG 2>&1

		ID=$(keystone service-create --name=heat-cfn --type=cloudformation --description="Heat CloudFormation API" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8000/v1 \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8000/v1 \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8000/v1 >> $LOG 2>&1
			
		chown -R heat:heat /etc/heat/* /var/log/heat/* >> $LOG 2>&1

		RestartService "heat-api"
		RestartService "heat-api-cfn"
		RestartService "heat-engine restart"
		
		#heat stack-create mystack --template-file=$CWD/ocf/WordPress_Single_Instance_template \
		#	--parameters="InstanceType=m1.small;DBUsername=root;DBPassword=$PASSWORD;KeyName=mykey;LinuxDistribution=Fedora20" >> $LOG 2>&1
	fi
}

####################################################################################################
# Ceilometer
####################################################################################################

function ConfigureCeilometer
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing ceilometer"
		
		InstallPackage "mongodb-10gen"
		InstallPackage "ceilometer-api ceilometer-collector ceilometer-agent-central python-ceilometerclient"
		
		BackupConfig "/etc/mongodb.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/mongodb_conf")
		WriteConfig "/etc/mongodb.conf" "$CONFIG" 
		
		RestartService "mongodb"
		
		mongo --eval "db.getSiblingDB('ceilometer').addUser('ceilometer', '$PASSWORD');" >> $LOG 2>&1
		
		BackupConfig "/etc/ceilometer/ceilometer.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/ceilometer_conf")
		WriteConfig "/etc/ceilometer/ceilometer.conf" "$CONFIG" 
		
		keystone user-create --name=ceilometer --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=ceilometer --tenant=service --role=admin >> $LOG 2>&1
		ID=$(keystone service-create --name=ceilometer --type=metering --description="Ceilometer Telemetry Service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8777 \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8777 \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8777 >> $LOG 2>&1
			
		RestartService "ceilometer-agent-central"
		RestartService "ceilometer-api restart" 
		RestartService "ceilometer-collector restart"
	fi
	
	if [[ $ISCOMPUTE -eq 1 ]]; then
		InstallPackage "ceilometer-agent-compute"
	fi
	
	chown -R ceilometer:ceilometer /etc/ceilometer/* /var/log/ceilometer/* >> $LOG 2>&1
}

####################################################################################################
# Trove
####################################################################################################

function ConfigureTrove
{
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing trove"
		
		useradd -p "'"$PASSWORD"'" trove >> $LOG 2>&1
		mkdir -vp /etc/trove >> $LOG 2>&1
		touch /var/log/trove/trove.log >> $LOG 2>&1
		touch /var/log/trove/trove-api.log >> $LOG 2>&1
		mkdir -vp /var/log/trove >> $LOG 2>&1
		chown -vR trove:trove /etc/trove /var/log/trove >> $LOG 2>&1
		
		InstallPackage "pbr"
		InstallPackage "python-setuptools git python-pip python-dev python-lxml libxml2 libxml2-dev libxslt-dev python-glanceclient"
	
		if [[ $USEPROXY -eq 1 ]]; then
			export http_proxy=http://$PROXYFQDN:$PROXYPORT
			export https_proxy=$http_proxy
		fi

		pip install pbr --upgrade >> $LOG 2>&1
		export PATH=$PATH:/usr/local:/usr/local/bin >> $LOG 2>&1
		ln -s /usr/local/bin/pip /usr/bin/pip >> $LOG 2>&1
		
		git clone -b stable/havana https://github.com/openstack/trove.git /root/trove >> $LOG 2>&1
		cd /root/trove >> $LOG 2>&1
		pip install --upgrade -r requirements.txt >> $LOG 2>&1
		python setup.py develop >> $LOG 2>&1
		cd /root >> $LOG 2>&1
		
		git clone -b stable/havana https://github.com/openstack/python-troveclient.git /root/python-troveclient >> $LOG 2>&1
		cd /root/python-troveclient >> $LOG 2>&1
		python setup.py develop >> $LOG 2>&1
		cd /root >> $LOG 2>&1
		
		if [[ $USEPROXY -eq 1 ]]; then
			export http_proxy=""
			export https_proxy=""
		fi
		
		keystone --os-tenant-name=service tenant-create --name=trove --description="Trove tenant" >> $LOG 2>&1
		keystone --os-tenant-name=service user-create --name=trove --pass=$PASSWORD --email=$EMAIL --tenant=trove >> $LOG 2>&1
		keystone --os-tenant-name=service user-role-add --user=trove --tenant=trove --role=admin >> $LOG 2>&1
		
		ID=$(keystone --os-tenant-name=service service-create --name=trove --type=database --description="Trove Database Service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone --os-tenant-name=service endpoint-create --service-id=$ID --service=trove --region=regionOne \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8779/v1.0/%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8779/v1.0/%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8779/v1.0/%\(tenant_id\)s >> $LOG 2>&1
		
		BackupConfig "/etc/trove/trove.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/trove_conf")
		WriteConfig "/etc/trove/trove.conf" "$CONFIG" 
		
		BackupConfig "/etc/trove/api-paste.ini"
		CONFIG=$(ReadConfig "$CWD/ocf/trove_api_paste_ini")
		WriteConfig "/etc/trove/api-paste.ini" "$CONFIG" 
		
		BackupConfig "/etc/trove/trove-conductor.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/trove_conductor_conf")
		WriteConfig "/etc/trove/trove-conductor.conf" "$CONFIG" 
		
		BackupConfig "/etc/trove/trove-guestagent.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/trove_guestagent_conf")
		WriteConfig "/etc/trove/trove-guestagent.conf" "$CONFIG" 
		
		BackupConfig "/etc/trove/trove-taskmanager.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/trove_taskmanager_conf")
		WriteConfig "/etc/trove/trove-taskmanager.conf" "$CONFIG" 
		
		Copy "$CWD/ocf/trove_taskmanager_conf_init" "/etc/init/trove-taskmanager.conf"
		ln -vs /lib/init/upstart-job /etc/init.d/trove-taskmanager >> $LOG 2>&1
		
		Copy "$CWD/ocf/trove_api_conf_init" "/etc/init/trove-api.conf"
		ln -vs /lib/init/upstart-job /etc/init.d/trove-api >> $LOG 2>&1
		
		chown -vR trove:trove /etc/trove >> $LOG 2>&1
		
		SqlExec "CREATE DATABASE trove;"
		SqlExec "GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'%' IDENTIFIED BY '$PASSWORD';"

		trove-manage db_sync >> $LOG 2>&1
		echo "trove-api --config-file=/etc/trove/trove.conf &" >> /etc/rc.local
		echo "trove-taskmanager --config-file=/etc/trove/trove.conf &" >> /etc/rc.local
		echo "trove-server --config-file=/etc/trove/trove.conf &" >> /etc/rc.local
		
		trove-api --config-file=/etc/trove/trove.conf >> $LOG 2>&1 &
		trove-taskmanager --config-file=/etc/trove/trove.conf >> $LOG 2>&1  &
		trove-server --config-file=/etc/trove/trove.conf >> $LOG 2>&1  &
		
		ID=$(nova image-list | grep Trove | awk '{print $2}')
		trove-manage --config-file=/etc/trove/trove.conf image_update mysql $ID >> $LOG 2>&1
	fi
}

####################################################################################################
# Swift
####################################################################################################

function ConfigureSwift
{
	LogSection "Installing swift"

	if [[ $ISCONTROLLER -eq 1 ]]; then
		InstallPackage "curl gcc memcached python-memcache rsync sqlite3 xfsprogs git-core libffi-dev python-setuptools"
		InstallPackage "python-coverage python-dev python-nose python-simplejson python-xattr python-eventlet"
        InstallPackage "python-greenlet python-pastedeploy python-netifaces python-pip python-dnspython python-mock"
		InstallPackage "swift swift-account swift-container swift-object swift-proxy"
		InstallPackage "python-keystoneclient python-swiftclient python-webob"
	fi
	
	if [[ $ISCOMPUTE -eq 1 ]]; then
		InstallPackage "swift-account swift-container swift-object xfsprogs"
	fi
	
	useradd swift >> $LOG 2>&1
	groupadd swift >> $LOG 2>&1
	mkdir -vp /etc/swift >> $LOG 2>&1
	chown -vR swift:swift /etc/swift/ /srv/node >> $LOG 2>&1
		
	BackupConfig "/etc/rsyncd.conf"
	CONFIG=$(ReadConfig "$CWD/ocf/rsyncd_conf")
	WriteConfig "/etc/rsyncd.conf" "$CONFIG" 
		
	BackupConfig "/etc/default/rsync"
	CONFIG=$(ReadConfig "/etc/default/rsync")
	CONFIG=$(ReplaceInConfig "$CONFIG" '^RSYNC_ENABLE.*?$' 'RSYNC_ENABLE = true')
	WriteConfig "/etc/default/rsync" "$CONFIG" 
		
	RestartService "rsync"
		
	mkdir -p /var/swift/recon >> $LOG 2>&1
	chown -R swift:swift /var/swift/recon >> $LOG 2>&1
	
	BackupConfig "/etc/swift/swift.conf"
	CONFIG=$(ReadConfig "$CWD/ocf/swift_conf")
	WriteConfig "/etc/swift/swift.conf" "$CONFIG" 
		
	echo -e "n\np\n1\n\n\nw" | fdisk /dev/sdc >> $LOG 2>&1
	mkfs.xfs /dev/sdc1 >> $LOG 2>&1
	echo "/dev/sdc1 /srv/node/sdc1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 0" >> /etc/fstab
	mkdir -pv /srv/node/sdc1 >> $LOG 2>&1
	mount /srv/node/sdc1 >> $LOG 2>&1
	chown -vR swift:swift /srv/node >> $LOG 2>&1
	
	if [[ $ISCONTROLLER -eq 1 ]]; then
		keystone user-create --name=swift --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
		keystone user-role-add --user=swift --tenant=service --role=admin >> $LOG 2>&1
		ID=$(keystone service-create --name=swift --type=object-store --description="Object Storage Service" | tee -a $LOG)
		ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id=$ID \
			--publicurl=http://$CONTROLLER_SERVICE_FQDN:8888/v1/AUTH_%\(tenant_id\)s \
			--internalurl=http://$CONTROLLER_SERVICE_FQDN:8888/v1/AUTH_%\(tenant_id\)s \
			--adminurl=http://$CONTROLLER_SERVICE_FQDN:8888/v1 >> $LOG 2>&1
	
		cd /etc/swift >> $LOG 2>&1
		openssl req -new -x509 -nodes -days 3650 -subj '/C=CA/ST=QC/L=Montreal/O=Company Name/CN=server.name.com' \
			-out cert.crt -keyout cert.key >> $LOG 2>&1
		
		BackupConfig "/etc/memcached.conf"
		CONFIG=$(ReadConfig "/etc/memcached.conf")
		CONFIG=$(ReplaceInConfig "$CONFIG" '-l 127.0.0.1' "-l $INT_IP")
		WriteConfig "/etc/memcached.conf" "$CONFIG" 
		
		RestartService "memcached"
		
		git clone https://github.com/openstack/swift.git >> $LOG 2>&1
		cd swift >> $LOG 2>&1
		python setup.py install >> $LOG 2>&1
		swift-init proxy start >> $LOG 2>&1
		
		BackupConfig "/etc/swift/proxy-server.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/proxy_server_conf")
		WriteConfig "/etc/swift/proxy-server.conf" "$CONFIG" 
		
		mkdir -pv /home/swift/keystone-signing >> $LOG 2>&1
		chown -Rv swift:swift /home/swift/keystone-signing >> $LOG 2>&1
		cd /etc/swift >> $LOG 2>&1
		
		swift-ring-builder account.builder create 18 3 1 >> $LOG 2>&1
		swift-ring-builder container.builder create 18 3 1 >> $LOG 2>&1
		swift-ring-builder object.builder create 18 3 1 >> $LOG 2>&1
		
		swift-ring-builder account.builder add z1-$CONTROLLER_INT_IP:6002/sdc1 100 >> $LOG 2>&1
		swift-ring-builder container.builder add z1-$CONTROLLER_INT_IP:6001/sdc1 100 >> $LOG 2>&1
		swift-ring-builder object.builder add z1-$CONTROLLER_INT_IP:6000/sdc1 100 >> $LOG 2>&1
		
		swift-ring-builder account.builder >> $LOG 2>&1
		swift-ring-builder container.builder >> $LOG 2>&1
		swift-ring-builder object.builder >> $LOG 2>&1
		
		swift-ring-builder account.builder rebalance >> $LOG 2>&1
		swift-ring-builder container.builder rebalance >> $LOG 2>&1
		swift-ring-builder object.builder rebalance >> $LOG 2>&1
		
		chown -R swift:swift /etc/swift >> $LOG 2>&1
		
		RestartService "swift-proxy"
		RestartService "swift-object"
		RestartService "swift-object-replicator"
		RestartService "swift-object-updater"
		RestartService "swift-object-auditor"
		RestartService "swift-container"
		RestartService "swift-container-replicator"
		RestartService "swift-container-updater"
		RestartService "swift-container-auditor"
		RestartService "swift-account"
		RestartService "swift-account-replicator"
		RestartService "swift-account-reaper"
		RestartService "swift-account-auditor"
		RestartService "rsyslog "
		RestartService "memcached"
	fi
}

####################################################################################################
# Nova-network / neutron
####################################################################################################

function ConfigureNetwork
{
	if [[ $NETWORK -eq 1 ]]; then
		if [[ $ISNEUTRON -eq 0 ]]; then
			LogSection "Installing nova-network"
			InstallPackage "nova-network"

			if [[ $ISCONTROLLER -eq 1 ]]; then
				nova network-create vmnet --fixed-range-v4=$TENANT_NW/$TENANT_CIDR \
					--bridge-interface=br100 --multi-host=T >> $LOG 2>&1
			fi
		else
			LogSection "Installing neutron"
			
			if [[ $ISCONTROLLER -eq 1 ]]; then
				SqlExec "CREATE DATABASE neutron;"
				SqlExec "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$PASSWORD';"
				SqlExec "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$PASSWORD';"
				
				keystone user-create --name=neutron --pass=$PASSWORD --email=$EMAIL >> $LOG 2>&1
				keystone user-role-add --user=neutron --tenant=service --role=admin >> $LOG 2>&1
				
				ID=$(keystone service-create --name=neutron --type=network --description="OpenStack Networking Service" | tee -a $LOG)
				ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
				
				keystone endpoint-create --service-id=$ID \
					--publicurl=http://$CONTROLLER_SERVICE_FQDN:9696 \
					--internalurl=http://$CONTROLLER_SERVICE_FQDN:9696 \
					--adminurl=http://$CONTROLLER_SERVICE_FQDN:9696 >> $LOG 2>&1
			
				InstallPackage "neutron-server python-neutron python-neutronclient neutron-plugin-openvswitch-agent"
				InstallPackage "neutron-dhcp-agent neutron-l3-agent"
			fi
			
			if [[ $ISCOMPUTE -eq 1 ]]; then
				InstallPackage "neutron-plugin-openvswitch-agent openvswitch-switch openvswitch-datapath-dkms"
				RestartService "openvswitch-switch"
				ovs-vsctl add-br br-int >> $LOG 2>&1
			fi
			
			if [[ $ISCONTROLLER -eq 1 || $ISCOMPUTE -eq 1 ]]; then
				BackupConfig "/etc/neutron/neutron.conf"
				CONFIG=$(ReadConfig "$CWD/ocf/neutron_conf")
				CONFIG=$(ReplaceInConfig "$CONFIG" '^lock_path.*?$' 'lock_path = \$state_path\/lock')
				CONFIG=$(ReplaceInConfig "$CONFIG" '^signing_dir.*?$' 'signing_dir = \$state_path\/keystone-signing')
				WriteConfig "/etc/neutron/neutron.conf" "$CONFIG" 
				
				CONFIG=$(ReadConfig "$CWD/ocf/dnsmasq_conf")
				WriteConfig "/etc/neutron/dnsmasq.conf" "$CONFIG" 

				BackupConfig "/etc/neutron/api-paste.ini"
				CONFIG=$(ReadConfig "$CWD/ocf/neutron_api_paste_ini")
				WriteConfig "/etc/neutron/api-paste.ini" "$CONFIG" 

				BackupConfig "/etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini"
				CONFIG=$(ReadConfig "$CWD/ocf/ovs_neutron_plugin_ini")
				WriteConfig "/etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini" "$CONFIG" 
			fi
			
			if [[ $ISCONTROLLER -eq 1 ]]; then
				BackupConfig "/etc/neutron/l3_agent.ini"
				CONFIG=$(ReadConfig "$CWD/ocf/l3_agent_ini")
				WriteConfig "/etc/neutron/l3_agent.ini" "$CONFIG" 	
				
				BackupConfig "/etc/neutron/dhcp_agent.ini"
				CONFIG=$(ReadConfig "$CWD/ocf/dhcp_agent_ini")
				WriteConfig "/etc/neutron/dhcp_agent.ini" "$CONFIG" 	
				
				BackupConfig "/etc/neutron/metadata_agent.ini"
				CONFIG=$(ReadConfig "$CWD/ocf/metadata_agent_ini")
				WriteConfig "/etc/neutron/metadata_agent.ini" "$CONFIG" 
			fi
			
			if [[ $ISCONTROLLER -eq 1 ]]; then
				RestartService "nova-api"
				RestartService "neutron-server"
				RestartService "neutron-dhcp-agent"
				RestartService "neutron-l3-agent"
				RestartService "neutron-metadata-agent"

				BackupConfig "/etc/network/interfaces"
				CONFIG=$(ReadConfig "$CWD/ocf/interfaces1")
				WriteConfig "/etc/network/interfaces" "$CONFIG"
			
				ovs-vsctl add-br br-ex >> $LOG 2>&1
				
				RestartService "networking"
				hostname "$HOSTNAME"
				
				ovs-vsctl add-port br-ex eth0 >> $LOG 2>&1
				RestartService "neutron-plugin-openvswitch-agent"
			fi		
			
			if [[ $ISCONTROLLER -eq 1 ]]; then
				ID=$(keystone tenant-list | grep service)
				ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')				
					
				ID=$(neutron net-create --tenant-id $ID ext --router:external=True --provider:network_type gre --provider:segmentation_id 2)
				ID=$(echo $ID | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
				
				neutron subnet-create --tenant-id $ID ext $TENANT_NW/$TENANT_CIDR --enable_dhcp=False --allocation-pool \
					start=$TENANT_FIPS,end=$TENANT_FIPE --gateway-ip $TENANT_GW >> $LOG 2>&1
				
				neutron router-create router1 >> $LOG 2>&1
				neutron router-gateway-set router1 ext >> $LOG 2>&1
				neutron net-create int >> $LOG 2>&1
				
				ID=$(neutron subnet-create int 30.0.0.0/24 --dns_nameservers list=true 30.0.0.1 | grep id | head -n 2 | tail -n 1 | awk '{print $4}')
				neutron router-interface-add router1 $ID >> $LOG 2>&1 
			fi	
		fi
	
		# remove libvirt unused interface
		virsh net-autostart default --disable >> $LOG 2>&1
		virsh net-destroy default >> $LOG 2>&1
	fi
}

####################################################################################################
# Configure User Prompts
####################################################################################################

function Configure
{
	echo ""
	echo "#######################################################"
	echo "                   Open Stack Setup                    "
	echo "#######################################################"
	echo ""

	read -p "Configure host as a controller node (Y/n)?" choice
	choice=${choice:="y"} 
	case "$choice" in 
		y|Y ) ISCONTROLLER=1;;
		n|N ) ISCONTROLLER=0;;
		* ) echo "invalid option... exiting"; exit;;
	esac
	
	read -p "Configure host as a compute node (Y/n)?" choice
	choice=${choice:="y"} 
	case "$choice" in 
		y|Y ) ISCOMPUTE=1;;
		n|N ) ISCOMPUTE=0;;
		* ) echo "invalid option... exiting"; exit;;
	esac

	read -p "Configure network (Y/n)?" choice
	choice=${choice:="y"} 
	case "$choice" in 
		y|Y ) NETWORK=1;;
		n|N ) NETWORK=0;;
		* ) echo "invalid option... exiting"; exit;;
	esac
	
	if [[ $NETWORK -eq 1 ]]; then
		read -p "Choose yes for quantum/neutron, Choose no for nova-network (Y/n)?" choice
		choice=${choice:="y"} 
		case "$choice" in 
			y|Y ) ISNEUTRON=1;;
			n|N ) ISNEUTRON=0;;
			* ) echo "invalid option... exiting"; exit;;
		esac
	fi

	read -p "Configure proxy? (Y/n)?" choice
	choice=${choice:="y"} 
	case "$choice" in 
		y|Y ) USEPROXY=1;;
		n|N ) USEPROXY=0;;
		* ) echo "invalid option... exiting"; exit;;
	esac
	
	if [[ $USEPROXY -eq 1 ]]; then
		RESP=""
		echo -n "Proxy host [$PROXYFQDN] > "
		read RESP
		if [[ "$PROXYFQDN" != "$RESP$PROXYFQDN" ]]; then
			PROXYFQDN=$RESP
		fi

		RESP=""
		echo -n "Proxy host port [$PROXYPORT] > "
		read RESP
		if [[ "$PROXYPORT" != "$RESP$PROXYPORT" ]]; then
			PROXYPORT=$RESP
		fi
	fi

	read -p "Write proxy hosts file? (Y/n)?" choice
	choice=${choice:="y"} 
	case "$choice" in 
		y|Y ) USEPROXYHOSTS=1;;
		n|N ) USEPROXYHOSTS=0;;
		* ) echo "invalid option... exiting"; exit;;
	esac

	echo ""
	echo "#######################################################"
	echo "           Open Stack Networking Setup                 "
	echo "#######################################################"
	echo ""

	if [[ $ISCONTROLLER -eq 1 ]]; then
		RESP=""
		echo -n "Controller's unqualified hostname [$CONTROLLER_HOSTNAME] > "
		read RESP
		if [[ "$CONTROLLER_HOSTNAME" != "$RESP$CONTROLLER_HOSTNAME" ]]; then
			CONTROLLER_HOSTNAME=$RESP
		fi
	
		RESP=""
		echo -n "Controller's network address [$CONTROLLER_EXT_NW] > "
		read RESP
		if [[ "$CONTROLLER_EXT_NW" != "$RESP$CONTROLLER_EXT_NW" ]]; then
			CONTROLLER_EXT_NW=$RESP
		fi
	
		RESP=""
		echo -n "Controller's external IP address [$CONTROLLER_EXT_IP] > "
		read RESP
		if [[ "$CONTROLLER_EXT_IP" != "$RESP$CONTROLLER_EXT_IP" ]]; then
			CONTROLLER_EXT_IP=$RESP
		fi
	
		RESP=""
		echo -n "Controller's broadcast address [$CONTROLLER_EXT_BC] > "
		read RESP
		if [[ "$CONTROLLER_EXT_BC" != "$RESP$CONTROLLER_EXT_BC" ]]; then
			CONTROLLER_EXT_BC=$RESP
		fi
		
		RESP=""
		echo -n "Controller's netmask [$CONTROLLER_EXT_NM] > "
		read RESP
		if [[ "$CONTROLLER_EXT_NM" != "$RESP$CONTROLLER_EXT_NM" ]]; then
			CONTROLLER_EXT_NM=$RESP
		fi
	
		RESP=""
		echo -n "Controller's gateway address [$CONTROLLER_EXT_GW] > "
		read RESP
		if [[ "$CONTROLLER_EXT_GW" != "$RESP$CONTROLLER_EXT_GW" ]]; then
			CONTROLLER_EXT_GW=$RESP
		fi
	
		RESP=""
		echo -n "Controller's DNS suffix [$CONTROLLER_EXT_DS] > "
		read RESP
		if [[ "$CONTROLLER_EXT_DS" != "$RESP$CONTROLLER_EXT_DS" ]]; then
			CONTROLLER_EXT_DS=$RESP
		fi
	
		RESP=""
		echo -n "Controller's DNS nameservers [$CONTROLLER_EXT_DR] > "
		read RESP
		if [[ "$CONTROLLER_EXT_DR" != "$RESP$CONTROLLER_EXT_DR" ]]; then
			CONTROLLER_EXT_DR=$RESP
		fi	
	
		RESP=""
		echo -n "Controller's internal IP address [$CONTROLLER_INT_IP] > "
		read RESP
		if [[ "$CONTROLLER_INT_IP" != "$RESP$CONTROLLER_INT_IP" ]]; then
			CONTROLLER_INT_IP=$RESP
		fi	
	
		RESP=""
		echo -n "Controller's internal netmask [$CONTROLLER_INT_NM] > "
		read RESP
		if [[ "$CONTROLLER_INT_NM" != "$RESP$CONTROLLER_INT_NM" ]]; then
			CONTROLLER_INT_NM=$RESP
		fi	
	fi

	if [[ $ISCOMPUTE -eq 1 ]]; then
		modprobe kvm_intel > /dev/null 2>&1
        lsmod | grep kvm > /dev/null 2>&1
	
		if [[ $? -eq 1 ]]; then
			echo "Kvm support is not enable, does your CPU support virtualisation?"
			exit;
		fi

		if [[ $ISCONTROLLER -eq 0 ]]; then
			RESP=""
			echo -n "Controller's unqualified hostname [$CONTROLLER_HOSTNAME] > "
			read RESP
			if [[ "$CONTROLLER_HOSTNAME" != "$RESP$CONTROLLER_HOSTNAME" ]]; then
				CONTROLLER_HOSTNAME=$RESP
			fi
	
			RESP=""
			echo -n "Controller's DNS suffix [$CONTROLLER_EXT_DS] > "
			read RESP
			if [[ "$CONTROLLER_EXT_DS" != "$RESP$CONTROLLER_EXT_DS" ]]; then
				CONTROLLER_EXT_DS=$RESP
			fi
	
			RESP=""
			echo -n "Controller's internal IP address [$CONTROLLER_INT_IP] > "
			read RESP
			if [[ "$CONTROLLER_INT_IP" != "$RESP$CONTROLLER_INT_IP" ]]; then
				CONTROLLER_INT_IP=$RESP
			fi	

			RESP=""
			echo -n "Compute's unqualified hostname [$COMPUTE_HOSTNAME] > "
			read RESP
			if [[ "$COMPUTE_HOSTNAME" != "$RESP$COMPUTE_HOSTNAME" ]]; then
				COMPUTE_HOSTNAME=$RESP
			fi
		
			RESP=""
			echo -n "Compute's network address [$COMPUTE_EXT_NW] > "
			read RESP
			if [[ "$COMPUTE_EXT_NW" != "$RESP$COMPUTE_EXT_NW" ]]; then
				COMPUTE_EXT_NW=$RESP
			fi
		
			RESP=""
			echo -n "Compute's external IP address [$COMPUTE_EXT_IP] > "
			read RESP
			if [[ "$COMPUTE_EXT_IP" != "$RESP$COMPUTE_EXT_IP" ]]; then
				COMPUTE_EXT_IP=$RESP
			fi
		
			RESP=""
			echo -n "Compute's broadcast address [$COMPUTE_EXT_BC] > "
			read RESP
			if [[ "$COMPUTE_EXT_BC" != "$RESP$COMPUTE_EXT_BC" ]]; then
				COMPUTE_EXT_BC=$RESP
			fi
			
			RESP=""
			echo -n "Compute's netmask [$COMPUTE_EXT_NM] > "
			read RESP
			if [[ "$COMPUTE_EXT_NM" != "$RESP$COMPUTE_EXT_NM" ]]; then
				COMPUTE_EXT_NM=$RESP
			fi
		
			RESP=""
			echo -n "Compute's gateway address [$COMPUTE_EXT_GW] > "
			read RESP
			if [[ "$COMPUTE_EXT_GW" != "$RESP$COMPUTE_EXT_GW" ]]; then
				COMPUTE_EXT_GW=$RESP
			fi
		
			RESP=""
			echo -n "Compute's DNS suffix [$COMPUTE_EXT_DS] > "
			read RESP
			if [[ "$COMPUTE_EXT_DS" != "$RESP$COMPUTE_EXT_DS" ]]; then
				COMPUTE_EXT_DS=$RESP
			fi
		
			RESP=""
			echo -n "Compute's DNS nameservers [$COMPUTE_EXT_DR] > "
			read RESP
			if [[ "$COMPUTE_EXT_DR" != "$RESP$COMPUTE_EXT_DR" ]]; then
				COMPUTE_EXT_DR=$RESP
			fi	
		
			RESP=""
			echo -n "Compute's internal IP address [$COMPUTE_INT_IP] > "
			read RESP
			if [[ "$COMPUTE_INT_IP" != "$RESP$COMPUTE_INT_IP" ]]; then
				COMPUTE_INT_IP=$RESP
			fi	
		
			RESP=""
			echo -n "Compute's internal netmask [$COMPUTE_INT_NM] > "
			read RESP
			if [[ "$COMPUTE_INT_NM" != "$RESP$COMPUTE_INT_NM" ]]; then
				COMPUTE_INT_NM=$RESP
			fi	
		fi	
	fi

	echo ""
	echo "#######################################################"
	echo "      Which Open stack would you like to deploy        "
	echo "#######################################################"
	echo ""

	echo "1) Grizzly Cloud Archive"
	echo "2) Grizzly Trunk Testing"
	echo "3) Havana Cloud Archive"
	echo "4) Havana Trunk Testing"
	echo "5) Icehouse Cloud Archive Staging"
	echo "6) Icehouse Testing"
	echo ""

	read -p "Please enter choice 1-6 [4] > " choice
	choice=${choice:=4} 
	case "$choice" in 
		1 ) OPENSTACK_RELEASE=1;;
		2 ) OPENSTACK_RELEASE=2;;
		3 ) OPENSTACK_RELEASE=3;;
		4 ) OPENSTACK_RELEASE=4;;
		5 ) OPENSTACK_RELEASE=5;;
		6 ) OPENSTACK_RELEASE=6;;
		* ) echo "invalid option... exiting"; exit;;
	esac

	echo ""
	echo "#######################################################"
	echo "                    Final stages                       "
	echo "#######################################################"
	echo ""

	RESP=""
	echo -n "Administrators/Mysql .. password [$PASSWORD] > "
	read RESP
	if [[ "$PASSWORD" != "$RESP$PASSWORD" ]]; then
		PASSWORD=$RESP
	fi	
	
	#if [[ $ISCONTROLLER -eq 1 ]]; then
	#	read -p "Update Mysql to 5.6 (Y/n)?" choice
	#	choice=${choice:="y"} 
	#	case "$choice" in 
	#		y|Y ) UPDATE_MYSQL=1;;
	#		n|N ) UPDATE_MYSQL=0;;
	#		* ) echo "invalid option... exiting"; exit;;
	#	esac
	#fi

	RESP=""
	echo -n "Administrator email address [$EMAIL] > "
	read RESP
	if [[ "$EMAIL" != "$RESP$EMAIL" ]]; then
		EMAIL=$RESP
	fi

	echo ""
	echo "#######################################################"
	echo "    Configuration done, sit back and wait for reboot   "
	echo "#######################################################"
	echo ""

	((($ISCONTROLLER)==1)) && HOSTNAME="$CONTROLLER_HOSTNAME" || HOSTNAME="$COMPUTE_HOSTNAME"
	((($ISCONTROLLER)==1)) && EXT_NW="$CONTROLLER_EXT_NW" || EXT_NW="$COMPUTE_EXT_NW"
	((($ISCONTROLLER)==1)) && EXT_IP="$CONTROLLER_EXT_IP" || EXT_IP="$COMPUTE_EXT_IP"
	((($ISCONTROLLER)==1)) && EXT_BC="$CONTROLLER_EXT_BC" || EXT_BC="$COMPUTE_EXT_BC"
	((($ISCONTROLLER)==1)) && EXT_NM="$CONTROLLER_EXT_NM" || EXT_NM="$COMPUTE_EXT_NM"
	((($ISCONTROLLER)==1)) && EXT_GW="$CONTROLLER_EXT_GW" || EXT_GW="$COMPUTE_EXT_GW"
	((($ISCONTROLLER)==1)) && EXT_DS="$CONTROLLER_EXT_DS" || EXT_DS="$COMPUTE_EXT_DS"
	((($ISCONTROLLER)==1)) && EXT_DR="$CONTROLLER_EXT_DR" || EXT_DR="$COMPUTE_EXT_DR"
	((($ISCONTROLLER)==1)) && INT_IP="$CONTROLLER_INT_IP" || INT_IP="$COMPUTE_INT_IP"
	((($ISCONTROLLER)==1)) && INT_NM="$CONTROLLER_INT_NM" || INT_NM="$COMPUTE_INT_NM"
}

####################################################################################################
# Enable Services on boot
####################################################################################################

function EnableServices
{
	LogSection "Enabling services on boot"

	EnableService "ntp"
	EnableService "mysql"
	EnableService "mysql.server"
	EnableService "rabbitmq-server"
	EnableService "keystone"
	EnableService "glance-registry"
	EnableService "glance-api"
	EnableService "heat-api"
	EnableService "heat-api-cfn"
	EnableService "heat-engine"
	EnableService "nova-api"
	EnableService "nova-cert"
	EnableService "nova-conductor"
	EnableService "nova-consoleauth"
	EnableService "nova-novncproxy"
	EnableService "nova-scheduler"
	EnableService "nova-network"
	EnableService "dnsmasq"
	EnableService "iptables"
	EnableService "cinder-volume"
	EnableService "tgt"
	EnableService "docker"
	EnableService "cinder-scheduler"
	EnableService "cinder-api"
	EnableService "apache2"
	EnableService "memcached"
	EnableService "openvswitch-switch"
	EnableService "neutron-server"
	EnableService "neutron-dhcp-agent"
	EnableService "neutron-plugin-openvswitch-agent"
	EnableService "neutron-l3-agent"
	EnableService "neutron-metadata-agent"
	EnableService "ceilometer-agent-central"
	EnableService "ceilometer-agent-compute"
	EnableService "ceilometer-api restart" 
	EnableService "ceilometer-collector restart"
	EnableService "swift-proxy"
	EnableService "swift-object"
	EnableService "swift-object-replicator"
	EnableService "swift-object-updater"
	EnableService "swift-object-auditor"
	EnableService "swift-container"
	EnableService "swift-container-replicator"
	EnableService "swift-container-updater"
	EnableService "swift-container-auditor"
	EnableService "swift-account"
	EnableService "swift-account-replicator"
	EnableService "swift-account-reaper"
	EnableService "swift-account-auditor"
	EnableService "trove-api"
	EnableService "trove-taskmanager"
}

####################################################################################################
# Reboot
####################################################################################################

function Reboot
{
	LogSection "Reboot"
	LogLine "Rebooting"
	reboot
}

####################################################################################################
# Log line
####################################################################################################

function LogLine
{
	echo "$1..." >> $LOG 2>&1
}

####################################################################################################
# Logsection header
####################################################################################################

function LogSection
{
	echo "$1..."
	LogLine "$1"
	LogLine "######################################################################################"
}

####################################################################################################
# Enable Service 
####################################################################################################

function EnableService
{
	LogLine "> ENABLESERVICE: $1"
	update-rc.d $1 defaults >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Remove Service 
####################################################################################################

function RemoveService
{
	LogLine "> REMOVESERVICE: $1"
	update-rc.d -f $1 remove >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Restart Service 
####################################################################################################

function RestartService
{
	LogLine "> RESTARTSERVICE: $1"
	echo "restart $1" >> $LOG 2>&1
	service $1 restart > /dev/null 2>&1
	/etc/init.d/$1 restart > /dev/null 2>&1
	sleep 3
}

####################################################################################################
# Stop Service 
####################################################################################################

function StopService
{
	LogLine "> STOPSERVICE: $1"
	service $1 status > /dev/null 2>&1
	
	if [[ $? -eq 0 ]]; then
		service $1 stop >> $LOG 2>&1
		sleep 2
	else
		if [ -f /etc/init.d/$1 ]; then
			/etc/init.d/$1 stop >> $LOG 2>&1
			sleep 2
		fi
	fi
}

####################################################################################################
# Install package
####################################################################################################

function InstallPackage
{
	LogLine "> INSTALLPACKAGE: $1"
	DEBIAN_FRONTEND=noninteractive apt-get -y --allow-unauthenticated --force-yes install $1 >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Dpkg Install package
####################################################################################################

function DpkgInstallPackage
{
	LogLine "> DPKGINSTALLPACKAGE: $1"
	dpkg -i $1 >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# ReInstall package
####################################################################################################

function ReinstallPackage
{
	LogLine "> REINSTALLPACKAGE: $1"
	DEBIAN_FRONTEND=noninteractive apt-get -y --allow-unauthenticated --force-yes install --reinstall $1 >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Remove package
####################################################################################################

function RemovePackage
{
	LogLine "> REMOVEPACKAGE: $1"
	apt-get -y remove $1 >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Remove package
####################################################################################################

function AutoRemovePackages
{
	LogLine "> REMOVEPACKAGE: $1"
	apt-get -y autoremove >> $LOG 2>&1
	sleep 1
}

####################################################################################################
# Update packages
####################################################################################################

function UpdatePackages
{
	LogLine "> UPDATEPACKAGES"
	apt-get clean all >> $LOG 2>&1
	apt-get -y update >> $LOG 2>&1
	apt-get -y upgrade >> $LOG 2>&1
	apt-get -y dist-upgrade >> $LOG 2>&1
	
	GRUBMD5NOW=`md5sum /boot/grub/grub.cfg`
	
	if [[ "$GRUBMD5" != "$GRUBMD5NOW" ]]; then
		echo "Kernel update requires reboot... rebooting in 5 seconds"
		LogLine "Kernel update requires reboot... rebooting in 5 seconds"
		sleep 5
		reboot
	fi

	sleep 1
}

####################################################################################################
# Configure Proxy
####################################################################################################

function EnableProxy
{
	if [[ $USEPROXY -eq 1 ]]; then
		WriteConfig "/root/.wgetrc" "http_proxy=http://$PROXYFQDN:$PROXYPORT\nhttps_proxy=http://$PROXYFQDN:$PROXYPORT"
		WriteConfig "/etc/apt/apt.conf" "Acquire::http::Proxy \"http://$PROXYFQDN:$PROXYPORT/\";\nAcquire::https::Proxy \"http://$PROXYFQDN:$PROXYPORT/\";"
		BackupConfig "/root/.gitconfig"
		CONFIG=$(ReadConfig "$CWD/ocf/gitconfig")
		WriteConfig "/root/.gitconfig" "$CONFIG" 		
	fi

	proxyhost=""

	if [[ $USEPROXYHOSTS -eq 1 ]]; then
		proxyhost="$PROXYIP $PROXYFQDN $PROXY"
	fi
}

####################################################################################################
# Read Config Template
####################################################################################################

function ReadConfig
{
	LogLine "> READCONFIG: $1"
	IN=""

	while read LINE; do
		if [[ "$LINE" =~ ^\# || ! "$LINE" =~ \$ ]]; then
			CONTENT="$LINE"
		else
			CONTENT=$(eval echo "$LINE")
		fi
		IN=$(printf "%s%s" "$IN" "$CONTENT\n")
	done < $1

	echo "$IN"
}

####################################################################################################
# Write Config Template
####################################################################################################

function WriteConfig
{
	LogLine "> WRITECONFIG: $1"
	if [ ! -f "$1" ]; then
		touch "$1"
	fi

	echo -e "$2" > $1
}

####################################################################################################
# backup Config Template
####################################################################################################

function BackupConfig
{
	LogLine "> BACKUPCONFIG: $1"
	if [ ! -f "$1" ]; then
		touch "$1"
	else
		cp -v $1 $1.bak >> $LOG 2>&1
	fi
}

####################################################################################################
# Copy File
####################################################################################################

function Copy
{
	cp -rv $1 $2 >> $LOG 2>&1
}

####################################################################################################
# Sql Exec
####################################################################################################

function SqlExec
{
	LogLine "> EXECSQL: $1"
	echo "$1" | mysql -u root -p$PASSWORD
}

####################################################################################################
# Sql Import
####################################################################################################

function SqlImport
{
	LogLine "> IMPORTSQL: $1"
	mysql -u root -p$PASSWORD < $1
}

####################################################################################################
# Replace in config
####################################################################################################

function ReplaceInConfig
{
	LogLine "> REPLACEINCONFIG: $2 $3"
	echo -e "$1" | perl -lpe "s/$2/$3/g"
}

####################################################################################################
# Download file
####################################################################################################

function DownloadFile
{
	LogLine "> DOWNLOADFILE: $1"
	wget $1 >> $LOG 2>&1	
}

####################################################################################################
# Pause execution
####################################################################################################

function pause()
{
	read -p "Press [Enter] key to continue..."
}

####################################################################################################
# Go
####################################################################################################

Configure
#pause
EnableProxy
#pause
ConfigureRepos
#pause
PrepareSystem
#pause
ConfigureNetworking
#pause
ConfigureGrub
#pause
ConfigureNtp
#pause
ConfigureMysql
#pause
ConfigureRabbit
#pause
ConfigureKeystone
#pause
ConfigureGlance
#pause
#ConfigureDocker
#pause
ConfigureNova
#pause
ConfigureHorizon
#pause
ConfigureCinder
#pause
ConfigureHeat
#pause
ConfigureCeilometer
#pause
ConfigureSwift
#pause
ConfigureTrove
#pause
ConfigureNetwork
#pause
EnableServices
#pause
Reboot
