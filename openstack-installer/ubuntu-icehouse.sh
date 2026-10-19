#!/bin/bash

CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER_HOSTNAME="silvosc001"
CONTROLLER_EXT_IP_LAST="10"
ICEHOUSE_ARCHIVE_REPO="cloud-archive:icehouse"
RELEASE_LABEL_5="Icehouse Cloud Archive"
RELEASE_LABEL_6="Icehouse Trunk Testing"
RELEASE_DEFAULT="5"
PAUSE_BETWEEN_STEPS="1"
source "${CWD}/../lib/installer-common.sh"
openstack_main
