#!/bin/bash

CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CWD}/../lib/installer-common.sh"
openstack_main
