#!/bin/bash
write-mime-multipart --output=combined-userdata.txt \
   rc.sh:text/cloud-boothook \
   inc.url:text/x-include-url \
   upstart.conf:text/upstart-job \
   rc.pl:text/x-shellscript \
   cloud.txt

#gzip combined-userdata.txt

