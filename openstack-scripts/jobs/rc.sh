#!/bin/sh
LOG=/root/log.txt

echo "The time is now $(date -R)!" | tee $LOG
apt-get -y install puppet
sed -i 's/^START=.*$/START=yes/g' /etc/default/puppet
service puppet restart

