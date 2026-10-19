#!/bin/bash

CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/root/puppet.log"
PASSWORD="tester"
EMAIL="david.m.oneill@intel.com"
USEPROXY=1
PROXY="cache"
SEARCH="asus"
PROXYFQDN="$PROXY.$SEARCH"
PROXYPORT="911"

source "${CWD}/../lib/installer-common.sh"

ConfigureJenkins() {
	LogSection "Installing Jenkins"
	wget -q -O - http://pkg.jenkins-ci.org/debian/jenkins-ci.org.key | run_as_root apt-key add - >>"$LOG" 2>&1
	echo "deb http://pkg.jenkins-ci.org/debian binary/" >>/etc/apt/sources.list
	UpdatePackages
	InstallPackage "jenkins"
}

Main() {
	LogSection "System Preparation and Repository Configuration"
	RemovePackage "ufw"
	EnableProxy
	UpdatePackages
	ConfigureNtp
	ConfigureJenkins
}

Main
