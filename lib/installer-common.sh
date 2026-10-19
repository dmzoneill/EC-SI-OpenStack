#!/bin/bash

# Shared shell functions for the OpenStack, Jenkins, and Puppet installers.
# Callers set configuration overrides, source this file, and then run their main.

run_logged() {
	"$@" >>"$LOG" 2>&1
}

run_as_root() {
	sudo "$@"
}

# Read a KEY=VALUE file such as /etc/environment and export each valid name.
# Surrounding single or double quotes are removed. An optional export prefix is
# accepted so OpenStack keystonerc files load the same variables.
LoadEnvironmentFile() {
	local key value
	while IFS='=' read -r key value; do
		key="${key#"${key%%[![:space:]]*}"}"
		key="${key%"${key##*[![:space:]]}"}"
		[[ -z "$key" || "$key" == \#* ]] && continue
		if [[ "$key" == "export "* ]]; then
			key="${key#export }"
			key="${key#"${key%%[![:space:]]*}"}"
			key="${key%"${key##*[![:space:]]}"}"
		fi
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
		if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
			value="${value:1:$((${#value} - 2))}"
		elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
			value="${value:1:$((${#value} - 2))}"
		fi
		export "$key=$value"
	done <"$1"
}

####################################################################################################
# Networking
####################################################################################################

function ConfigureNetworking {
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

function ConfigureGrub {
	LogSection "Configuring grub"

	BackupConfig "/etc/default/grub"
	CONFIG=$(ReadConfig "/etc/default/grub")
	CONFIG=$(ReplaceInConfig "$CONFIG" 'GRUB_CMDLINE_LINUX_DEFAULT=\".*?\"' 'GRUB_CMDLINE_LINUX_DEFAULT=\"kvm-intel.nested=1 text\"')
	WriteConfig "/etc/default/grub" "$CONFIG"
	run_logged update-grub
}

####################################################################################################
# System Settings,,,, Update first
####################################################################################################

function PrepareSystem {
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

	run_logged sysctl -e -p /etc/sysctl.conf

	BackupConfig "/etc/rsyslog.d/50-default.conf"
	CONFIG=$(ReadConfig "/etc/rsyslog.d/50-default.conf")
	CONFIG=$(ReplaceInConfig "$CONFIG" '\*.\*;auth,authpriv.none.*?\/var\/log\/syslog' '*.*;auth,authpriv.none,kern.none -\/var\/log\/syslog')
	WriteConfig "/etc/rsyslog.d/50-default.conf" "$CONFIG"
}

####################################################################################################
# Ntp
####################################################################################################

function ConfigureNtp {
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

function ConfigureMysql {
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
			AutoRemovePackages ""

			Copy "/opt/mysql/server-5.6/support-files/mysql.server" "/etc/init.d/mysql.server"
			RemoveService "mysql"

			sed -i 's/PATH="\(.*\)"/PATH="\1:\/opt\/mysql\/server-5.6\/bin"/g' /etc/environment
			LoadEnvironmentFile /etc/environment

			BackupConfig "/etc/mysql/my.cnf"
			CONFIG=$(ReadConfig "$CWD/ocf/my_cnf")
			WriteConfig "/etc/mysql/my.cnf" "$CONFIG"

			RestartService "mysql.server"
		else
			RestartService "mysql"
		fi

		run_logged mysqladmin -u root password "$PASSWORD"
	fi
}

####################################################################################################
# Stack repo
####################################################################################################

function ConfigureRepos {
	LogSection "Configuring repositories"

	InstallPackage "python-software-properties ubuntu-cloud-keyring"

	if [[ $USEPROXY -eq 1 ]]; then
		export http_proxy=http://$PROXYFQDN:$PROXYPORT
		export https_proxy=$http_proxy
	fi

	# monogo db
	run_logged apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 7F0CEB10
	echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' | run_logged tee /etc/apt/sources.list.d/mongodb.list

	# docker
	wget -qO- https://get.docker.io/gpg | run_logged apt-key add -
	echo 'deb http://get.docker.io/ubuntu docker main' | run_logged tee /etc/apt/sources.list.d/docker.list

	if [[ $OPENSTACK_RELEASE -eq 1 ]]; then
		run_logged add-apt-repository -y cloud-archive:grizzley
	elif [[ $OPENSTACK_RELEASE -eq 2 ]]; then
		run_logged add-apt-repository -y ppa:openstack-ubuntu-testing/grizzly
	elif [[ $OPENSTACK_RELEASE -eq 3 ]]; then
		run_logged add-apt-repository -y cloud-archive:havana
	elif [[ $OPENSTACK_RELEASE -eq 4 ]]; then
		run_logged add-apt-repository -y ppa:openstack-ubuntu-testing/havana
	elif [[ $OPENSTACK_RELEASE -eq 5 ]]; then
		run_logged add-apt-repository -y "$ICEHOUSE_ARCHIVE_REPO"
	elif [[ $OPENSTACK_RELEASE -eq 6 ]]; then
		run_logged add-apt-repository -y ppa:openstack-ubuntu-testing/icehouse
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

function ConfigureRabbit {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing rabbit"
		InstallPackage "rabbitmq-server"

		run_logged mkdir -vp /etc/rabbitmq/rabbitmq.conf.d/
		BackupConfig "/etc/rabbitmq/rabbitmq.conf.d/default"
		CONFIG=$(ReadConfig "$CWD/ocf/rabbitdefault")
		WriteConfig "/etc/rabbitmq/rabbitmq.conf.d/default" "$CONFIG"

		RestartService "rabbitmq-server"
		run_logged rabbitmqctl change_password guest "$PASSWORD"
	fi
}

####################################################################################################
# Keystone
####################################################################################################

function ConfigureKeystone {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing keystone"
		InstallPackage "keystone"

		BackupConfig "/etc/keystone/keystone.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/keystone_conf")
		WriteConfig "/etc/keystone/keystone.conf" "$CONFIG"

		CONFIG=$(ReadConfig "$CWD/ocf/keystonerc")
		WriteConfig "/root/keystonerc" "$CONFIG"
		LoadEnvironmentFile /root/keystonerc

		run_logged rm -rvf /var/lib/keystone/keystone.sqlite
		SqlExec "CREATE DATABASE keystone;"
		SqlExec "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$PASSWORD'; FLUSH PRIVILEGES;"
		SqlExec "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$PASSWORD'; FLUSH PRIVILEGES;"

		run_logged mkdir -pv /usr/etc
		run_logged ln -s /etc/keystone/keystone.conf /usr/etc/keystone.conf
		run_logged chown -R keystone:keystone /etc/keystone/* /var/log/keystone/keystone.log
		run_logged run_as_root keystone-manage db_sync
		RestartService "keystone"

		run_logged keystone tenant-create --name=admin --description="Admin Tenant"
		run_logged keystone tenant-create --name=service --description="Service Tenant"
		run_logged keystone user-create --name=admin --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone role-create --name=admin
		run_logged keystone role-create --name=Member
		run_logged keystone user-role-add --user=admin --tenant=admin --role=admin
		run_logged keystone user-role-add --user=admin --tenant=admin --role=Member
		ID=$(keystone service-create --name=keystone --type=identity --description='Keystone Identity Service' | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":5000/v2.0 \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":5000/v2.0 \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":35357/v2.0 >>"$LOG" 2>&1
	fi
}

####################################################################################################
# Glance
####################################################################################################

function ConfigureGlance {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing glance"
		InstallPackage "glance"

		BackupConfig "/etc/glance/glance-api.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/glance_api_conf")
		WriteConfig "/etc/glance/glance-api.conf" "$CONFIG"

		BackupConfig "/etc/glance/glance-registry-paste.ini"
		CONFIG=$(ReadConfig "$CWD/ocf/glance_registry_paste_ini")
		WriteConfig "/etc/glance/glance-registry-paste.ini" "$CONFIG"

		run_logged rm -rvf /var/lib/keystone/keystone.sqlite
		SqlExec "CREATE DATABASE glance;"
		SqlExec "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$PASSWORD';"

		run_logged run_as_root glance-manage db_sync
		run_logged keystone user-create --name=glance --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=glance --tenant=service --role=admin
		ID=$(keystone service-create --name=glance --type=image --description="Glance Image Service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":9292 \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":9292 \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":9292 >>"$LOG" 2>&1

		run_logged chown -R glance:glance /etc/glance/* /var/log/glance/*
		RestartService "glance-registry"
		RestartService "glance-api"

		run_logged mkdir -pv images
		cd images/ || exit
		DownloadFile "http://cdn.download.cirros-cloud.net/0.3.1/cirros-0.3.1-x86_64-disk.img"
		glance image-create --name="CirrOS 0.3.1" --disk-format=qcow2 --container-format=bare \
			--is-public=true <cirros-0.3.1-x86_64-disk.img >>"$LOG" 2>&1

		DownloadFile "http://cloud-images.ubuntu.com/precise/current/precise-server-cloudimg-amd64-disk1.img"
		glance image-create --name="Ubuntu Server 12.04" --disk-format=qcow2 --container-format=bare \
			--is-public=true <precise-server-cloudimg-amd64-disk1.img >>"$LOG" 2>&1
		glance image-create --name="Trove" --container-format=ovf --disk-format=qcow2 --owner trove \
			--is-public=true <precise-server-cloudimg-amd64-disk1.img >>"$LOG" 2>&1

		DownloadFile "http://download.fedoraproject.org/pub/fedora/linux/releases/20/Images/x86_64/Fedora-x86_64-20-20131211.1-sda.qcow2"
		glance image-create --name="Fedora 20" --disk-format=qcow2 --container-format=bare \
			--is-public=true <Fedora-x86_64-20-20131211.1-sda.qcow2 >>"$LOG" 2>&1

		DownloadFile "http://dev.centos.org/centos/hvm/CentOS-6.4-x86_64-Minimal-OpenStack.image.qcow2"
		glance image-create --name="Centos 6.4" --disk-format=qcow2 --container-format=bare \
			--is-public=true <CentOS-6.4-x86_64-Minimal-OpenStack.image.qcow2 >>"$LOG" 2>&1

	fi
}

####################################################################################################
# Docker
####################################################################################################

function ConfigureDocker {
	LogSection "Installing docker"
	InstallPackage "lxc-docker"

	if [[ $USEPROXY -eq 1 ]]; then
		sed -i "s/\"\$DOCKER\"/HTTP_PROXY=http:\/\/$PROXYFQDN:$PROXYPORT \"\$DOCKER\"/g" /etc/init/docker.conf
	fi

	RestartService "docker"
	run_logged docker pull ubuntu
	RestartService "docker"
}

####################################################################################################
# Nova
####################################################################################################

function ConfigureNova {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing nova"
		DownloadFile "http://archive.ubuntu.com/ubuntu/pool/universe/libj/libjs-swfobject/libjs-swfobject_2.2+dfsg-1_all.deb"
		DpkgInstallPackage "libjs-swfobject_2.2+dfsg-1_all.deb"
		InstallPackage "nova-novncproxy novnc nova-api nova-ajax-console-proxy nova-cert nova-conductor nova-consoleauth nova-doc nova-scheduler python-novaclient"
		sed -i 's/nova_token.*token/\/\//g' /usr/share/novnc/include/rfb.js
	fi

	if [[ $ISCOMPUTE -eq 1 ]]; then
		LogSection "Installing nova compute"
		echo "libguestfs0     libguestfs/update-appliance     boolean true" >supermin.seed
		debconf-set-selections ./supermin.seed
		InstallPackage "nova-compute-kvm python-guestfs qemu-kvm libvirt-bin ubuntu-vm-builder bridge-utils"
		InstallPackage "kvm qemu"
		run_logged chmod 0644 /boot/vmlinuz*
		run_logged rm /var/lib/nova/nova.sqlite
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
	run_logged rm -rvf /var/lib/nova/nova.sqlite

	if [[ $ISCONTROLLER -eq 1 ]]; then
		SqlExec "CREATE DATABASE nova;"
		SqlExec "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$PASSWORD';"

		run_logged mkdir -pv /usr/etc
		run_logged ln -s /etc/nova/nova.conf /usr/etc/nova.conf

		run_logged run_as_root nova-manage db sync
		run_logged keystone user-create --name=nova --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=nova --tenant=service --role=admin
	fi

	BackupConfig "/etc/nova/api-paste.ini"
	CONFIG=$(ReadConfig "$CWD/ocf/api_paste_ini")
	WriteConfig "/etc/nova/api-paste.ini" "$CONFIG"

	if [[ $ISCONTROLLER -eq 1 ]]; then
		ID=$(keystone service-create --name=nova --type=compute --description="Nova Compute service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8774/v2/%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8774/v2/%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8774/v2/%\(tenant_id\)s >>"$LOG" 2>&1

		RestartService "nova-api"
		RestartService "nova-cert"
		RestartService "nova-consoleauth"
		RestartService "nova-scheduler"
		RestartService "nova-conductor"
		RestartService "nova-novncproxy"

		run_logged rm -rvf /root/.ssh/id_rsa
		run_logged rm -rvf /root/.ssh/id_rsa.pub
		run_logged mkdir -p /root/.ssh
		run_logged chmod -v 700 /root/.ssh
		cd /root/.ssh || exit
		run_logged ssh-keygen -t rsa -N "" -f id_rsa
		run_logged nova keypair-add --pub_key id_rsa.pub mykey
		run_logged nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
		run_logged nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
	fi

	run_logged chown -R nova:nova /etc/nova/* /var/log/nova/*
}

####################################################################################################
# horizon
####################################################################################################

function ConfigureHorizon {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing horizon"
		InstallPackage "apache2 memcached libapache2-mod-wsgi openstack-dashboard"
		RemovePackage "openstack-dashboard-ubuntu-theme"

		echo "ServerName $CONTROLLER_SERVICE_FQDN" >>/etc/apache2/apache2.conf

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
		run_logged chown www-data:www-data /var/www/favicon.ico

		RestartService "apache2"
		RestartService "memcached"
	fi
}

####################################################################################################
# Cinder
####################################################################################################

function ConfigureCinder {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing cinder"
		InstallPackage "cinder-api cinder-scheduler"

		BackupConfig "/etc/cinder/cinder.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/cinder_conf")
		WriteConfig "/etc/cinder/cinder.conf" "$CONFIG"

		SqlExec "CREATE DATABASE cinder;"
		SqlExec "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$PASSWORD';"

		run_logged run_as_root cinder-manage db sync
		run_logged keystone user-create --name=cinder --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=cinder --tenant=service --role=admin

		BackupConfig "/etc/cinder/api-paste.ini"
		CONFIG=$(ReadConfig "$CWD/ocf/cinder_api_paste_ini")
		WriteConfig "/etc/cinder/api-paste.ini" "$CONFIG"

		ID=$(keystone service-create --name=cinder --type=volume --description="Cinder Volume Service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v1/%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v1/%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v1/%\(tenant_id\)s >>"$LOG" 2>&1

		ID=$(keystone service-create --name=cinder --type=volumev2 --description="Cinder Volume Service V2" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v2/%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v2/%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8776/v2/%\(tenant_id\)s >>"$LOG" 2>&1

		RestartService "cinder-scheduler"
		RestartService "cinder-api"

		InstallPackage "cinder-volume lvm2"
		run_logged pvcreate /dev/sdb
		run_logged vgcreate cinder-volumes /dev/sdb

		BackupConfig "/etc/lvm/lvm.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/lvm_conf")
		WriteConfig "/etc/lvm/lvm.conf" "$CONFIG"

		RestartService "cinder-volume"
		RestartService "tgt"

		run_logged cinder type-create lvm

		run_logged chown -R cinder:cinder /etc/cinder/* /var/log/cinder/*
	fi
}

####################################################################################################
# Heat
####################################################################################################

function ConfigureHeat {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing heat"
		InstallPackage "heat-api heat-api-cfn heat-engine"

		BackupConfig "/etc/heat/heat.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/heat_conf")
		WriteConfig "/etc/heat/heat.conf" "$CONFIG"

		SqlExec "CREATE DATABASE heat;"
		SqlExec "GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$PASSWORD';"

		run_logged run_as_root heat-manage db_sync

		run_logged keystone user-create --name=heat --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=heat --tenant=service --role=admin
		ID=$(keystone service-create --name=heat --type=orchestration --description="Heat Orchestration API" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8004/v1/%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8004/v1/%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8004/v1/%\(tenant_id\)s >>"$LOG" 2>&1

		ID=$(keystone service-create --name=heat-cfn --type=cloudformation --description="Heat CloudFormation API" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8000/v1 \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8000/v1 \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8000/v1 >>"$LOG" 2>&1

		run_logged chown -R heat:heat /etc/heat/* /var/log/heat/*

		RestartService "heat-api"
		RestartService "heat-api-cfn"
		RestartService "heat-engine restart"

		#heat stack-create mystack --template-file=$CWD/ocf/WordPress_Single_Instance_template \
		#	--parameters="InstanceType=m1.small;DBUsername=root;DBPassword=$PASSWORD;KeyName=mykey;LinuxDistribution=Fedora20" >>"$LOG" 2>&1
	fi
}

####################################################################################################
# Ceilometer
####################################################################################################

function ConfigureCeilometer {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing ceilometer"

		InstallPackage "mongodb-10gen"
		InstallPackage "ceilometer-api ceilometer-collector ceilometer-agent-central python-ceilometerclient"

		BackupConfig "/etc/mongodb.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/mongodb_conf")
		WriteConfig "/etc/mongodb.conf" "$CONFIG"

		RestartService "mongodb"

		run_logged mongo --eval "db.getSiblingDB('ceilometer').addUser('ceilometer', '$PASSWORD');"

		BackupConfig "/etc/ceilometer/ceilometer.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/ceilometer_conf")
		WriteConfig "/etc/ceilometer/ceilometer.conf" "$CONFIG"

		run_logged keystone user-create --name=ceilometer --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=ceilometer --tenant=service --role=admin
		ID=$(keystone service-create --name=ceilometer --type=metering --description="Ceilometer Telemetry Service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8777 \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8777 \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8777 >>"$LOG" 2>&1

		RestartService "ceilometer-agent-central"
		RestartService "ceilometer-api restart"
		RestartService "ceilometer-collector restart"
	fi

	if [[ $ISCOMPUTE -eq 1 ]]; then
		InstallPackage "ceilometer-agent-compute"
	fi

	run_logged chown -R ceilometer:ceilometer /etc/ceilometer/* /var/log/ceilometer/*
}

####################################################################################################
# Trove
####################################################################################################

function ConfigureTrove {
	if [[ $ISCONTROLLER -eq 1 ]]; then
		LogSection "Installing trove"

		run_logged useradd -p "'""$PASSWORD""'" trove
		run_logged mkdir -vp /etc/trove
		run_logged touch /var/log/trove/trove.log
		run_logged touch /var/log/trove/trove-api.log
		run_logged mkdir -vp /var/log/trove
		run_logged chown -vR trove:trove /etc/trove /var/log/trove

		InstallPackage "pbr"
		InstallPackage "python-setuptools git python-pip python-dev python-lxml libxml2 libxml2-dev libxslt-dev python-glanceclient"

		if [[ $USEPROXY -eq 1 ]]; then
			export http_proxy=http://$PROXYFQDN:$PROXYPORT
			export https_proxy=$http_proxy
		fi

		run_logged pip install pbr --upgrade
		run_logged export PATH="$PATH:/usr/local:/usr/local/bin"
		run_logged ln -s /usr/local/bin/pip /usr/bin/pip

		run_logged git clone -b stable/havana https://github.com/openstack/trove.git /root/trove
		run_logged cd /root/trove || exit
		run_logged pip install --upgrade -r requirements.txt
		run_logged python setup.py develop
		run_logged cd /root || exit

		run_logged git clone -b stable/havana https://github.com/openstack/python-troveclient.git /root/python-troveclient
		run_logged cd /root/python-troveclient || exit
		run_logged python setup.py develop
		run_logged cd /root || exit

		if [[ $USEPROXY -eq 1 ]]; then
			export http_proxy=""
			export https_proxy=""
		fi

		run_logged keystone --os-tenant-name=service tenant-create --name=trove --description="Trove tenant"
		run_logged keystone --os-tenant-name=service user-create --name=trove --pass="$PASSWORD" --email="$EMAIL" --tenant=trove
		run_logged keystone --os-tenant-name=service user-role-add --user=trove --tenant=trove --role=admin

		ID=$(keystone --os-tenant-name=service service-create --name=trove --type=database --description="Trove Database Service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone --os-tenant-name=service endpoint-create --service-id="$ID" --service=trove --region=regionOne \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8779/v1.0/%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8779/v1.0/%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8779/v1.0/%\(tenant_id\)s >>"$LOG" 2>&1

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
		run_logged ln -vs /lib/init/upstart-job /etc/init.d/trove-taskmanager

		Copy "$CWD/ocf/trove_api_conf_init" "/etc/init/trove-api.conf"
		run_logged ln -vs /lib/init/upstart-job /etc/init.d/trove-api

		run_logged chown -vR trove:trove /etc/trove

		SqlExec "CREATE DATABASE trove;"
		SqlExec "GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'localhost' IDENTIFIED BY '$PASSWORD';"
		SqlExec "GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'%' IDENTIFIED BY '$PASSWORD';"

		run_logged trove-manage db_sync
		{
			echo "trove-api --config-file=/etc/trove/trove.conf &"
			echo "trove-taskmanager --config-file=/etc/trove/trove.conf &"
			echo "trove-server --config-file=/etc/trove/trove.conf &"
		} >>/etc/rc.local

		run_logged trove-api --config-file=/etc/trove/trove.conf &
		run_logged trove-taskmanager --config-file=/etc/trove/trove.conf &
		run_logged trove-server --config-file=/etc/trove/trove.conf &

		ID=$(nova image-list | grep Trove | awk '{print $2}')
		run_logged trove-manage --config-file=/etc/trove/trove.conf image_update mysql "$ID"
	fi
}

####################################################################################################
# Swift
####################################################################################################

function ConfigureSwift {
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

	run_logged useradd swift
	run_logged groupadd swift
	run_logged mkdir -vp /etc/swift
	run_logged chown -vR swift:swift /etc/swift/ /srv/node

	BackupConfig "/etc/rsyncd.conf"
	CONFIG=$(ReadConfig "$CWD/ocf/rsyncd_conf")
	WriteConfig "/etc/rsyncd.conf" "$CONFIG"

	BackupConfig "/etc/default/rsync"
	CONFIG=$(ReadConfig "/etc/default/rsync")
	CONFIG=$(ReplaceInConfig "$CONFIG" '^RSYNC_ENABLE.*?$' 'RSYNC_ENABLE = true')
	WriteConfig "/etc/default/rsync" "$CONFIG"

	RestartService "rsync"

	run_logged mkdir -p /var/swift/recon
	run_logged chown -R swift:swift /var/swift/recon

	BackupConfig "/etc/swift/swift.conf"
	CONFIG=$(ReadConfig "$CWD/ocf/swift_conf")
	WriteConfig "/etc/swift/swift.conf" "$CONFIG"

	echo -e "n\np\n1\n\n\nw" | fdisk /dev/sdc >>"$LOG" 2>&1
	run_logged mkfs.xfs /dev/sdc1
	echo "/dev/sdc1 /srv/node/sdc1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 0" >>/etc/fstab
	run_logged mkdir -pv /srv/node/sdc1
	run_logged mount /srv/node/sdc1
	run_logged chown -vR swift:swift /srv/node

	if [[ $ISCONTROLLER -eq 1 ]]; then
		run_logged keystone user-create --name=swift --pass="$PASSWORD" --email="$EMAIL"
		run_logged keystone user-role-add --user=swift --tenant=service --role=admin
		ID=$(keystone service-create --name=swift --type=object-store --description="Object Storage Service" | tee -a "$LOG")
		ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')
		keystone endpoint-create --service-id="$ID" \
			--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":8888/v1/AUTH_%\(tenant_id\)s \
			--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":8888/v1/AUTH_%\(tenant_id\)s \
			--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":8888/v1 >>"$LOG" 2>&1

		run_logged cd /etc/swift || exit
		openssl req -new -x509 -nodes -days 3650 -subj '/C=CA/ST=QC/L=Montreal/O=Company Name/CN=server.name.com' \
			-out cert.crt -keyout cert.key >>"$LOG" 2>&1

		BackupConfig "/etc/memcached.conf"
		CONFIG=$(ReadConfig "/etc/memcached.conf")
		CONFIG=$(ReplaceInConfig "$CONFIG" '-l 127.0.0.1' "-l $INT_IP")
		WriteConfig "/etc/memcached.conf" "$CONFIG"

		RestartService "memcached"

		run_logged git clone https://github.com/openstack/swift.git
		run_logged cd swift || exit
		run_logged python setup.py install
		run_logged swift-init proxy start

		BackupConfig "/etc/swift/proxy-server.conf"
		CONFIG=$(ReadConfig "$CWD/ocf/proxy_server_conf")
		WriteConfig "/etc/swift/proxy-server.conf" "$CONFIG"

		run_logged mkdir -pv /home/swift/keystone-signing
		run_logged chown -Rv swift:swift /home/swift/keystone-signing
		run_logged cd /etc/swift || exit

		run_logged swift-ring-builder account.builder create 18 3 1
		run_logged swift-ring-builder container.builder create 18 3 1
		run_logged swift-ring-builder object.builder create 18 3 1

		run_logged swift-ring-builder account.builder add z1-"$CONTROLLER_INT_IP":6002/sdc1 100
		run_logged swift-ring-builder container.builder add z1-"$CONTROLLER_INT_IP":6001/sdc1 100
		run_logged swift-ring-builder object.builder add z1-"$CONTROLLER_INT_IP":6000/sdc1 100

		run_logged swift-ring-builder account.builder
		run_logged swift-ring-builder container.builder
		run_logged swift-ring-builder object.builder

		run_logged swift-ring-builder account.builder rebalance
		run_logged swift-ring-builder container.builder rebalance
		run_logged swift-ring-builder object.builder rebalance

		run_logged chown -R swift:swift /etc/swift

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

function ConfigureNetwork {
	if [[ $NETWORK -eq 1 ]]; then
		if [[ $ISNEUTRON -eq 0 ]]; then
			LogSection "Installing nova-network"
			InstallPackage "nova-network"

			if [[ $ISCONTROLLER -eq 1 ]]; then
				nova network-create vmnet --fixed-range-v4="${TENANT_NW}/${TENANT_CIDR}" \
					--bridge-interface=br100 --multi-host=T >>"$LOG" 2>&1
			fi
		else
			LogSection "Installing neutron"

			if [[ $ISCONTROLLER -eq 1 ]]; then
				SqlExec "CREATE DATABASE neutron;"
				SqlExec "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$PASSWORD';"
				SqlExec "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$PASSWORD';"

				run_logged keystone user-create --name=neutron --pass="$PASSWORD" --email="$EMAIL"
				run_logged keystone user-role-add --user=neutron --tenant=service --role=admin

				ID=$(keystone service-create --name=neutron --type=network --description="OpenStack Networking Service" | tee -a "$LOG")
				ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')

				keystone endpoint-create --service-id="$ID" \
					--publicurl=http://"${CONTROLLER_SERVICE_FQDN}":9696 \
					--internalurl=http://"${CONTROLLER_SERVICE_FQDN}":9696 \
					--adminurl=http://"${CONTROLLER_SERVICE_FQDN}":9696 >>"$LOG" 2>&1

				InstallPackage "neutron-server python-neutron python-neutronclient neutron-plugin-openvswitch-agent"
				InstallPackage "neutron-dhcp-agent neutron-l3-agent"
			fi

			if [[ $ISCOMPUTE -eq 1 ]]; then
				InstallPackage "neutron-plugin-openvswitch-agent openvswitch-switch openvswitch-datapath-dkms"
				RestartService "openvswitch-switch"
				run_logged ovs-vsctl add-br br-int
			fi

			if [[ $ISCONTROLLER -eq 1 || $ISCOMPUTE -eq 1 ]]; then
				BackupConfig "/etc/neutron/neutron.conf"
				CONFIG=$(ReadConfig "$CWD/ocf/neutron_conf")
				CONFIG=$(ReplaceInConfig "$CONFIG" '^lock_path.*?$' "lock_path = \\\$state_path\\/lock")
				CONFIG=$(ReplaceInConfig "$CONFIG" '^signing_dir.*?$' "signing_dir = \\\$state_path\\/keystone-signing")
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

				run_logged ovs-vsctl add-br br-ex

				RestartService "networking"
				hostname "$HOSTNAME"

				run_logged ovs-vsctl add-port br-ex eth0
				RestartService "neutron-plugin-openvswitch-agent"
			fi

			if [[ $ISCONTROLLER -eq 1 ]]; then
				ID=$(keystone tenant-list | grep service)
				ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')

				ID=$(neutron net-create --tenant-id "$ID" ext --router:external=True --provider:network_type gre --provider:segmentation_id 2)
				ID=$(echo "$ID" | sed -n -e 's/^.*\([0-9a-z]\{32\}\).*$/\1/p')

				neutron subnet-create --tenant-id "$ID" ext "${TENANT_NW}/${TENANT_CIDR}" --enable_dhcp=False --allocation-pool \
					start="${TENANT_FIPS}",end="${TENANT_FIPE}" --gateway-ip "$TENANT_GW" >>"$LOG" 2>&1

				run_logged neutron router-create router1
				run_logged neutron router-gateway-set router1 ext
				run_logged neutron net-create int

				ID=$(neutron subnet-create int 30.0.0.0/24 --dns_nameservers list=true 30.0.0.1 | grep id | head -n 2 | tail -n 1 | awk '{print $4}')
				run_logged neutron router-interface-add router1 "$ID"
			fi
		fi

		# remove libvirt unused interface
		run_logged virsh net-autostart default --disable
		run_logged virsh net-destroy default
	fi
}

####################################################################################################
# Configure User Prompts
####################################################################################################

function Configure {
	echo ""
	echo "#######################################################"
	echo "                   Open Stack Setup                    "
	echo "#######################################################"
	echo ""

	read -r -p "Configure host as a controller node (Y/n)?" choice
	choice=${choice:="y"}
	case "$choice" in
	y | Y) ISCONTROLLER=1 ;;
	n | N) ISCONTROLLER=0 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	read -r -p "Configure host as a compute node (Y/n)?" choice
	choice=${choice:="y"}
	case "$choice" in
	y | Y) ISCOMPUTE=1 ;;
	n | N) ISCOMPUTE=0 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	read -r -p "Configure network (Y/n)?" choice
	choice=${choice:="y"}
	case "$choice" in
	y | Y) NETWORK=1 ;;
	n | N) NETWORK=0 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	if [[ $NETWORK -eq 1 ]]; then
		read -r -p "Choose yes for quantum/neutron, Choose no for nova-network (Y/n)?" choice
		choice=${choice:="y"}
		case "$choice" in
		y | Y) ISNEUTRON=1 ;;
		n | N) ISNEUTRON=0 ;;
		*)
			echo "invalid option... exiting"
			exit
			;;
		esac
	fi

	read -r -p "Configure proxy? (Y/n)?" choice
	choice=${choice:="y"}
	case "$choice" in
	y | Y) USEPROXY=1 ;;
	n | N) USEPROXY=0 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	if [[ $USEPROXY -eq 1 ]]; then
		RESP=""
		echo -n "Proxy host [$PROXYFQDN] > "
		read -r RESP
		if [[ "$PROXYFQDN" != "$RESP$PROXYFQDN" ]]; then
			PROXYFQDN=$RESP
		fi

		RESP=""
		echo -n "Proxy host port [$PROXYPORT] > "
		read -r RESP
		if [[ "$PROXYPORT" != "$RESP$PROXYPORT" ]]; then
			PROXYPORT=$RESP
		fi
	fi

	read -r -p "Write proxy hosts file? (Y/n)?" choice
	choice=${choice:="y"}
	case "$choice" in
	y | Y) USEPROXYHOSTS=1 ;;
	n | N) USEPROXYHOSTS=0 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	echo ""
	echo "#######################################################"
	echo "           Open Stack Networking Setup                 "
	echo "#######################################################"
	echo ""

	if [[ $ISCONTROLLER -eq 1 ]]; then
		RESP=""
		echo -n "Controller's unqualified hostname [$CONTROLLER_HOSTNAME] > "
		read -r RESP
		if [[ "$CONTROLLER_HOSTNAME" != "$RESP$CONTROLLER_HOSTNAME" ]]; then
			CONTROLLER_HOSTNAME=$RESP
		fi

		RESP=""
		echo -n "Controller's network address [$CONTROLLER_EXT_NW] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_NW" != "$RESP$CONTROLLER_EXT_NW" ]]; then
			CONTROLLER_EXT_NW=$RESP
		fi

		RESP=""
		echo -n "Controller's external IP address [$CONTROLLER_EXT_IP] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_IP" != "$RESP$CONTROLLER_EXT_IP" ]]; then
			CONTROLLER_EXT_IP=$RESP
		fi

		RESP=""
		echo -n "Controller's broadcast address [$CONTROLLER_EXT_BC] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_BC" != "$RESP$CONTROLLER_EXT_BC" ]]; then
			CONTROLLER_EXT_BC=$RESP
		fi

		RESP=""
		echo -n "Controller's netmask [$CONTROLLER_EXT_NM] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_NM" != "$RESP$CONTROLLER_EXT_NM" ]]; then
			CONTROLLER_EXT_NM=$RESP
		fi

		RESP=""
		echo -n "Controller's gateway address [$CONTROLLER_EXT_GW] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_GW" != "$RESP$CONTROLLER_EXT_GW" ]]; then
			CONTROLLER_EXT_GW=$RESP
		fi

		RESP=""
		echo -n "Controller's DNS suffix [$CONTROLLER_EXT_DS] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_DS" != "$RESP$CONTROLLER_EXT_DS" ]]; then
			CONTROLLER_EXT_DS=$RESP
		fi

		RESP=""
		echo -n "Controller's DNS nameservers [$CONTROLLER_EXT_DR] > "
		read -r RESP
		if [[ "$CONTROLLER_EXT_DR" != "$RESP$CONTROLLER_EXT_DR" ]]; then
			CONTROLLER_EXT_DR=$RESP
		fi

		RESP=""
		echo -n "Controller's internal IP address [$CONTROLLER_INT_IP] > "
		read -r RESP
		if [[ "$CONTROLLER_INT_IP" != "$RESP$CONTROLLER_INT_IP" ]]; then
			CONTROLLER_INT_IP=$RESP
		fi

		RESP=""
		echo -n "Controller's internal netmask [$CONTROLLER_INT_NM] > "
		read -r RESP
		if [[ "$CONTROLLER_INT_NM" != "$RESP$CONTROLLER_INT_NM" ]]; then
			CONTROLLER_INT_NM=$RESP
		fi
	fi

	if [[ $ISCOMPUTE -eq 1 ]]; then
		modprobe kvm_intel >/dev/null 2>&1
		lsmod | grep kvm >/dev/null 2>&1

		if [[ $? -eq 1 ]]; then
			echo "Kvm support is not enable, does your CPU support virtualisation?"
			exit
		fi

		if [[ $ISCONTROLLER -eq 0 ]]; then
			RESP=""
			echo -n "Controller's unqualified hostname [$CONTROLLER_HOSTNAME] > "
			read -r RESP
			if [[ "$CONTROLLER_HOSTNAME" != "$RESP$CONTROLLER_HOSTNAME" ]]; then
				CONTROLLER_HOSTNAME=$RESP
			fi

			RESP=""
			echo -n "Controller's DNS suffix [$CONTROLLER_EXT_DS] > "
			read -r RESP
			if [[ "$CONTROLLER_EXT_DS" != "$RESP$CONTROLLER_EXT_DS" ]]; then
				CONTROLLER_EXT_DS=$RESP
			fi

			RESP=""
			echo -n "Controller's internal IP address [$CONTROLLER_INT_IP] > "
			read -r RESP
			if [[ "$CONTROLLER_INT_IP" != "$RESP$CONTROLLER_INT_IP" ]]; then
				CONTROLLER_INT_IP=$RESP
			fi

			RESP=""
			echo -n "Compute's unqualified hostname [$COMPUTE_HOSTNAME] > "
			read -r RESP
			if [[ "$COMPUTE_HOSTNAME" != "$RESP$COMPUTE_HOSTNAME" ]]; then
				COMPUTE_HOSTNAME=$RESP
			fi

			RESP=""
			echo -n "Compute's network address [$COMPUTE_EXT_NW] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_NW" != "$RESP$COMPUTE_EXT_NW" ]]; then
				COMPUTE_EXT_NW=$RESP
			fi

			RESP=""
			echo -n "Compute's external IP address [$COMPUTE_EXT_IP] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_IP" != "$RESP$COMPUTE_EXT_IP" ]]; then
				COMPUTE_EXT_IP=$RESP
			fi

			RESP=""
			echo -n "Compute's broadcast address [$COMPUTE_EXT_BC] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_BC" != "$RESP$COMPUTE_EXT_BC" ]]; then
				COMPUTE_EXT_BC=$RESP
			fi

			RESP=""
			echo -n "Compute's netmask [$COMPUTE_EXT_NM] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_NM" != "$RESP$COMPUTE_EXT_NM" ]]; then
				COMPUTE_EXT_NM=$RESP
			fi

			RESP=""
			echo -n "Compute's gateway address [$COMPUTE_EXT_GW] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_GW" != "$RESP$COMPUTE_EXT_GW" ]]; then
				COMPUTE_EXT_GW=$RESP
			fi

			RESP=""
			echo -n "Compute's DNS suffix [$COMPUTE_EXT_DS] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_DS" != "$RESP$COMPUTE_EXT_DS" ]]; then
				COMPUTE_EXT_DS=$RESP
			fi

			RESP=""
			echo -n "Compute's DNS nameservers [$COMPUTE_EXT_DR] > "
			read -r RESP
			if [[ "$COMPUTE_EXT_DR" != "$RESP$COMPUTE_EXT_DR" ]]; then
				COMPUTE_EXT_DR=$RESP
			fi

			RESP=""
			echo -n "Compute's internal IP address [$COMPUTE_INT_IP] > "
			read -r RESP
			if [[ "$COMPUTE_INT_IP" != "$RESP$COMPUTE_INT_IP" ]]; then
				COMPUTE_INT_IP=$RESP
			fi

			RESP=""
			echo -n "Compute's internal netmask [$COMPUTE_INT_NM] > "
			read -r RESP
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
	echo "5) ${RELEASE_LABEL_5}"
	echo "6) ${RELEASE_LABEL_6}"
	echo ""

	read -r -p "Please enter choice 1-6 [${RELEASE_DEFAULT}] > " choice
	choice="${choice:=${RELEASE_DEFAULT}}"
	case "$choice" in
	1) OPENSTACK_RELEASE=1 ;;
	2) OPENSTACK_RELEASE=2 ;;
	3) OPENSTACK_RELEASE=3 ;;
	4) OPENSTACK_RELEASE=4 ;;
	5) OPENSTACK_RELEASE=5 ;;
	6) OPENSTACK_RELEASE=6 ;;
	*)
		echo "invalid option... exiting"
		exit
		;;
	esac

	echo ""
	echo "#######################################################"
	echo "                    Final stages                       "
	echo "#######################################################"
	echo ""

	RESP=""
	echo -n "Administrators/Mysql .. password [$PASSWORD] > "
	read -r RESP
	if [[ "$PASSWORD" != "$RESP$PASSWORD" ]]; then
		PASSWORD=$RESP
	fi

	#if [[ $ISCONTROLLER -eq 1 ]]; then
	#	read -r -p "Update Mysql to 5.6 (Y/n)?" choice
	#	choice=${choice:="y"}
	#	case "$choice" in
	#		y|Y ) UPDATE_MYSQL=1;;
	#		n|N ) UPDATE_MYSQL=0;;
	#		* ) echo "invalid option... exiting"; exit;;
	#	esac
	#fi

	RESP=""
	echo -n "Administrator email address [$EMAIL] > "
	read -r RESP
	if [[ "$EMAIL" != "$RESP$EMAIL" ]]; then
		EMAIL=$RESP
	fi

	echo ""
	echo "#######################################################"
	echo "    Configuration done, sit back and wait for reboot   "
	echo "#######################################################"
	echo ""

	(((ISCONTROLLER) == 1)) && HOSTNAME="$CONTROLLER_HOSTNAME" || HOSTNAME="$COMPUTE_HOSTNAME"
	(((ISCONTROLLER) == 1)) && EXT_NW="$CONTROLLER_EXT_NW" || EXT_NW="$COMPUTE_EXT_NW"
	(((ISCONTROLLER) == 1)) && EXT_IP="$CONTROLLER_EXT_IP" || EXT_IP="$COMPUTE_EXT_IP"
	(((ISCONTROLLER) == 1)) && EXT_BC="$CONTROLLER_EXT_BC" || EXT_BC="$COMPUTE_EXT_BC"
	(((ISCONTROLLER) == 1)) && EXT_NM="$CONTROLLER_EXT_NM" || EXT_NM="$COMPUTE_EXT_NM"
	(((ISCONTROLLER) == 1)) && EXT_GW="$CONTROLLER_EXT_GW" || EXT_GW="$COMPUTE_EXT_GW"
	(((ISCONTROLLER) == 1)) && EXT_DS="$CONTROLLER_EXT_DS" || EXT_DS="$COMPUTE_EXT_DS"
	(((ISCONTROLLER) == 1)) && EXT_DR="$CONTROLLER_EXT_DR" || EXT_DR="$COMPUTE_EXT_DR"
	(((ISCONTROLLER) == 1)) && INT_IP="$CONTROLLER_INT_IP" || INT_IP="$COMPUTE_INT_IP"
	(((ISCONTROLLER) == 1)) && INT_NM="$CONTROLLER_INT_NM" || INT_NM="$COMPUTE_INT_NM"
}

####################################################################################################
# Enable Services on boot
####################################################################################################

function EnableServices {
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

function Reboot {
	LogSection "Reboot"
	LogLine "Rebooting"
	reboot
}

####################################################################################################
# Log line
####################################################################################################

function LogLine {
	run_logged echo "$1..."
}

####################################################################################################
# Logsection header
####################################################################################################

function LogSection {
	echo "$1..."
	LogLine "$1"
	LogLine "######################################################################################"
}

####################################################################################################
# Enable Service
####################################################################################################

function EnableService {
	LogLine "> ENABLESERVICE: $1"
	run_logged update-rc.d "$1" defaults
	sleep 1
}

####################################################################################################
# Remove Service
####################################################################################################

function RemoveService {
	LogLine "> REMOVESERVICE: $1"
	run_logged update-rc.d -f "$1" remove
	sleep 1
}

####################################################################################################
# Restart Service
####################################################################################################

function RestartService {
	LogLine "> RESTARTSERVICE: $1"
	run_logged echo "restart $1"
	service "$1" restart >/dev/null 2>&1
	/etc/init.d/"$1" restart >/dev/null 2>&1
	sleep 3
}

####################################################################################################
# Stop Service
####################################################################################################

function StopService {
	LogLine "> STOPSERVICE: $1"
	if service "$1" status >/dev/null 2>&1; then
		run_logged service "$1" stop
		sleep 2
	else
		if [ -f "/etc/init.d/$1" ]; then
			run_logged /etc/init.d/"$1" stop
			sleep 2
		fi
	fi
}

####################################################################################################
# Install package
####################################################################################################

function InstallPackage {
	LogLine "> INSTALLPACKAGE: $1"
	local -a packages
	if [[ -n "$1" ]]; then
		read -r -a packages <<<"$1"
		DEBIAN_FRONTEND=noninteractive run_logged apt-get -y --allow-unauthenticated --force-yes install "${packages[@]}"
	else
		DEBIAN_FRONTEND=noninteractive run_logged apt-get -y --allow-unauthenticated --force-yes install
	fi
	sleep 1
}

####################################################################################################
# Dpkg Install package
####################################################################################################

function DpkgInstallPackage {
	LogLine "> DPKGINSTALLPACKAGE: $1"
	run_logged dpkg -i "$1"
	sleep 1
}

function InstallLocalPackage {
	LogLine "> INSTALLLOCALPACKAGE: $1"
	run_logged dpkg -i "$1"
	sleep 1
}

####################################################################################################
# ReInstall package
####################################################################################################

function ReinstallPackage {
	LogLine "> REINSTALLPACKAGE: $1"
	local -a packages
	if [[ -n "$1" ]]; then
		read -r -a packages <<<"$1"
		DEBIAN_FRONTEND=noninteractive run_logged apt-get -y --allow-unauthenticated --force-yes install --reinstall "${packages[@]}"
	else
		DEBIAN_FRONTEND=noninteractive run_logged apt-get -y --allow-unauthenticated --force-yes install --reinstall
	fi
	sleep 1
}

####################################################################################################
# Remove package
####################################################################################################

function RemovePackage {
	LogLine "> REMOVEPACKAGE: $1"
	local -a packages
	if [[ -n "$1" ]]; then
		read -r -a packages <<<"$1"
		run_logged apt-get -y remove "${packages[@]}"
	else
		run_logged apt-get -y remove
	fi
	sleep 1
}

####################################################################################################
# Remove package
####################################################################################################

function AutoRemovePackages {
	LogLine "> REMOVEPACKAGE: ${1-}"
	run_logged apt-get -y autoremove
	sleep 1
}

####################################################################################################
# Update packages
####################################################################################################

function UpdatePackages {
	LogLine "> UPDATEPACKAGES"
	{
		apt-get clean all
		apt-get -y update
		apt-get -y upgrade
		apt-get -y dist-upgrade
	} >>"$LOG" 2>&1

	if [[ "${CHECK_GRUB_REBOOT:-0}" -eq 1 ]]; then
		GRUBMD5NOW=$(md5sum /boot/grub/grub.cfg)
		if [[ "$GRUBMD5" != "$GRUBMD5NOW" ]]; then
			echo "Kernel update requires reboot... rebooting in 5 seconds"
			LogLine "Kernel update requires reboot... rebooting in 5 seconds"
			sleep 5
			reboot
		fi
	fi

	sleep 1
}

####################################################################################################
# Configure Proxy
####################################################################################################

function EnableProxy {
	if [[ $USEPROXY -eq 1 ]]; then
		WriteConfig "/root/.wgetrc" "http_proxy=http://$PROXYFQDN:$PROXYPORT\nhttps_proxy=http://$PROXYFQDN:$PROXYPORT"
		WriteConfig "/etc/apt/apt.conf" "Acquire::http::Proxy \"http://$PROXYFQDN:$PROXYPORT/\";\nAcquire::https::Proxy \"http://$PROXYFQDN:$PROXYPORT/\";"
		if [[ "${PROXY_WRITE_GITCONFIG:-0}" -eq 1 ]]; then
			BackupConfig "/root/.gitconfig"
			CONFIG=$(ReadConfig "$CWD/ocf/gitconfig")
			WriteConfig "/root/.gitconfig" "$CONFIG"
		fi
	fi

	proxyhost=""

	if [[ $USEPROXYHOSTS -eq 1 ]]; then
		proxyhost="$PROXYIP $PROXYFQDN $PROXY"
	fi
}

####################################################################################################
# Read Config Template
####################################################################################################

function ReadConfig {
	LogLine "> READCONFIG: $1"
	IN=""

	while read -r LINE; do
		if [[ "$LINE" =~ ^\# || ! "$LINE" =~ \$ ]]; then
			CONTENT="$LINE"
		else
			CONTENT=$(eval echo "$LINE")
		fi
		IN=$(printf "%s%s" "$IN" "$CONTENT\n")
	done <"$1"

	echo "$IN"
}

####################################################################################################
# Write Config Template
####################################################################################################

function WriteConfig {
	LogLine "> WRITECONFIG: $1"
	if [ ! -f "$1" ]; then
		touch "$1"
	fi

	echo -e "$2" >"$1"
}

function AppendToConfig {
	LogLine "> APPENDTOCONFIG: $1 $2"
	echo -e "$2" >>"$1"
}

####################################################################################################
# backup Config Template
####################################################################################################

function BackupConfig {
	LogLine "> BACKUPCONFIG: $1"
	if [ ! -f "$1" ]; then
		touch "$1"
	else
		run_logged cp -v "$1" "$1".bak
	fi
}

####################################################################################################
# Copy File
####################################################################################################

function Copy {
	run_logged cp -rv "$1" "$2"
}

####################################################################################################
# Sql Exec
####################################################################################################

function SqlExec {
	LogLine "> EXECSQL: $1"
	echo "$1" | mysql -u root -p"$PASSWORD"
}

####################################################################################################
# Sql Import
####################################################################################################

function SqlImport {
	LogLine "> IMPORTSQL: $1"
	mysql -u root -p"$PASSWORD" <"$1"
}

####################################################################################################
# Replace in config
####################################################################################################

function ReplaceInConfig {
	LogLine "> REPLACEINCONFIG: $2 $3"
	echo -e "$1" | perl -lpe "s/$2/$3/g"
}

####################################################################################################
# Download file
####################################################################################################

function DownloadFile {
	LogLine "> DOWNLOADFILE: $1"
	run_logged wget "$1"
}

####################################################################################################
# Pause execution
####################################################################################################

function pause() {
	read -r -p "Press [Enter] key to continue..."
}

# Names expanded by ReadConfig from the ocf templates. Referencing them keeps
# those assignments part of the installer contract.
reference_config_templates() {
	: "$TOKEN" "$COMPUTE_SERVICE_FQDN" "$TENANT_NM" "$TENANT_DS" "$ISNETWORK" \
		"$NETCONFIG" "$EXT_NW" "$EXT_IP" "$EXT_BC" "$EXT_NM" "$EXT_GW" \
		"$EXT_DS" "$EXT_DR" "$INT_NM" "$proxyhost"
}

openstack_init() {
	GRUBMD5=$(md5sum /boot/grub/grub.cfg)
	: "${OPENSTACK_RELEASE:=0}"
	: "${UPDATE_MYSQL:=0}"
	: "${LOG:=/root/openstack.log}"
	TOKEN=$(openssl rand -hex 10)
	: "${PASSWORD:=tester}"
	: "${EMAIL:=david.m.oneill@intel.com}"
	: "${NETSTART:=10.237.216}"
	: "${CONTROLLER_HOSTNAME:=controller}"
	: "${CONTROLLER_EXT_IP_LAST:=15}"
	CONTROLLER_EXT_NW="$NETSTART.0"
	CONTROLLER_EXT_IP="$NETSTART.$CONTROLLER_EXT_IP_LAST"
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
	PROXYIP=$(nslookup "$PROXYFQDN" | tail -n 2 | grep Addr | awk '{print $2}')
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

	CHECK_GRUB_REBOOT=1
	PROXY_WRITE_GITCONFIG=1
	: "${ICEHOUSE_ARCHIVE_REPO:=ppa:ubuntu-cloud-archive/icehouse-staging}"
	: "${RELEASE_LABEL_5:=Icehouse Cloud Archive Staging}"
	: "${RELEASE_LABEL_6:=Icehouse Testing}"
	: "${RELEASE_DEFAULT:=4}"
	: "${PAUSE_BETWEEN_STEPS:=0}"
}

maybe_pause() {
	if [[ "${PAUSE_BETWEEN_STEPS}" -eq 1 ]]; then
		pause
	fi
}

openstack_main() {
	openstack_init
	Configure
	maybe_pause
	EnableProxy
	maybe_pause
	ConfigureRepos
	maybe_pause
	PrepareSystem
	maybe_pause
	ConfigureNetworking
	maybe_pause
	ConfigureGrub
	maybe_pause
	ConfigureNtp
	maybe_pause
	ConfigureMysql
	maybe_pause
	ConfigureRabbit
	maybe_pause
	ConfigureKeystone
	maybe_pause
	ConfigureGlance
	maybe_pause
	# ConfigureDocker is defined above and is not invoked.
	maybe_pause
	ConfigureNova
	maybe_pause
	ConfigureHorizon
	maybe_pause
	ConfigureCinder
	maybe_pause
	ConfigureHeat
	maybe_pause
	ConfigureCeilometer
	maybe_pause
	ConfigureSwift
	maybe_pause
	ConfigureTrove
	maybe_pause
	ConfigureNetwork
	maybe_pause
	EnableServices
	maybe_pause
	Reboot
}
