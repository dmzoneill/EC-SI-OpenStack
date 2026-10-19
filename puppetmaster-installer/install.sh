#!/bin/bash

CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/root/puppet.log"
PASSWORD="tester"
EMAIL="david.m.oneill@intel.com"
USEPROXY=1
PROXY="cache"
SEARCH="ir.intel.com"
PROXYFQDN="$PROXY.$SEARCH"
PROXYPORT="911"

source "${CWD}/../lib/installer-common.sh"

####################################################################################################
# Puppet Server
####################################################################################################

function ConfigurePuppetMaster {
	LogSection "Installing puppet master"

	InstallPackage "postgresql"
	run_logged su - postgres -c "psql -U postgres -d postgres -c \"alter user postgres with password '$PASSWORD';\""
	run_logged su - postgres -c "createdb puppetdb"

	InstallPackage "puppetmaster puppetmaster-passenger hiera facter puppetdb puppetdb-terminus pgadmin3"
	InstallPackage "git build-essential git-core curl ruby"
	#update-alternatives --set ruby /usr/bin/ruby1.9.1 >>"$LOG" 2>&1

	WriteConfig "/etc/puppetdb/conf.d/database.ini" "[database]"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "classname = org.postgresql.Driver"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "subprotocol = postgresql"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "subname = //localhost:5432/puppetdb"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "log-slow-statements = 10"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "username = postgres"
	AppendToConfig "/etc/puppetdb/conf.d/database.ini" "password = $PASSWORD"

	run_logged mkdir -vp /var/lib/puppet/log
	run_logged touch /var/lib/puppet/log/http.log
	run_logged touch /var/lib/puppet/log/masterhttp.log
	run_logged touch /var/lib/puppet/log/puppetmaster.log
	run_logged touch /var/lib/puppet/log/puppetd.log
	run_logged touch /var/lib/puppet/log/rails.log

	run_logged mkdir -pv /etc/puppet
	run_logged rm -rvf /etc/puppet/*

	run_logged chown -v puppet:puppet /var/lib/puppet
	run_logged chown -vR puppet:puppet /var/lib/puppet/log
	run_logged chown -vR puppet:puppet /etc/puppet

	run_logged mkdir -vp /root/.ssh/
	run_logged chmod -v 700 /root/.ssh/
	BackupConfig "/root/.ssh/config"
	WriteConfig "/root/.ssh/config" "Host github.intel.com\n    StrictHostKeyChecking no"

	#git clone https://github.intel.com/EC/iLab-Puppet-Config-Global.git /etc/puppet >>"$LOG" 2>&1
	#git clone https://github.intel.com/EC/iLab-Puppet-Config-GER-SIE-EC.git /etc/puppet/environments/ger/ger_sie_ec >>"$LOG" 2>&1

	mkdir -p /etc/puppet/ssl/{ca/{private,requests,signed},certificate_requests,certs,private_keys,public_keys}
	chown puppet:puppet -R /etc/puppet/

	EnableService "puppetmaster"
	EnableService "puppetdb"
	EnableService "postgresql"
	RemoveService "apache2"
}

####################################################################################################
# Puppet Plugins
####################################################################################################

function ConfigurePuppetPlugins {
	LogSection "Installing puppet plugins"

	InstallPackage "ruby-fog"

	if [[ $USEPROXY -eq 1 ]]; then
		run_logged git config --global http.proxy http://$PROXYFQDN:$PROXYPORT
		run_logged git config --global https.proxy http://$PROXYFQDN:$PROXYPORT
		export http_proxy=http://$PROXYFQDN:$PROXYPORT
		export https_proxy=$http_proxy
	fi

	run_logged puppet module install puppetlabs/apt
	run_logged puppet module install puppetlabs/stdlib
	run_logged gem install guid
	run_logged gem install r10k

	if [[ $USEPROXY -eq 1 ]]; then
		run_logged git config --global http.proxy ""
		run_logged git config --global https.proxy ""
		export http_proxy=""
		export https_proxy=""
	fi
}

####################################################################################################
# Main
####################################################################################################

function Main {
	LogSection "System Preparation and Repository Configuration"
	RemovePackage "ufw"
	EnableProxy
	DownloadFile "http://apt.puppetlabs.com/puppetlabs-release-saucy.deb"
	InstallLocalPackage "puppetlabs-release-saucy.deb"
	UpdatePackages

	ConfigureNtp
	ConfigurePuppetMaster
	ConfigurePuppetPlugins

	reboot
}

Main
