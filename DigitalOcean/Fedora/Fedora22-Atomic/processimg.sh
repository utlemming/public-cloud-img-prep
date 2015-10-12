#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free  Software Foundation; either version 2 of the License, or
# (at your option)  any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
#
# purpose: This script will download a fedora image and then modify it 
#          to prepare it for Digital Ocean's infrastructure. It uses 
#          Docker to hopefully guarantee the behavior is consistent across 
#          different machines.
#  author: Dusty Mabe (dusty@dustymabe.com)

set -eux 
mkdir -p /tmp/doimg/

docker run -i --rm --privileged -v /tmp/doimg:/tmp/doimg fedora:21 bash << 'EOF'
set -eux
WORKDIR=/workdir
TMPMNT=/workdir/tmp/mnt

# Vars for the image
XZIMGURL='http://fedora.mirror.lstn.net/releases/22/Cloud/x86_64/Images/Fedora-Cloud-Atomic-22-20150521.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
IMG=${XZIMG:0:-3}           # Pull .xz off of the end

# URL/File location for upstream DO data source file.
DODATASOURCEURL='http://bazaar.launchpad.net/~cloud-init-dev/cloud-init/trunk/download/head:/datasourcedigitaloce-20141016153006-gm8n01q6la3stalt-1/DataSourceDigitalOcean.py'
# The file location for atomic is complicated basically we need to put 
# it into Atomic's version of /usr/local/
DODATASOURCEFILE='/ostree/deploy/fedora-atomic/var/usrlocal/lib/python2.7/site-packages/cloudinit/sources/DataSourceDigitalOcean.py'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
yum install -y gdisk wget lvm2

# Get the xz image and decompress it
wget $XZIMGURL && unxz $XZIMG

# Discover the next available loopback device
LOOPDEV=$(losetup -f)
LOMAJOR=''

# Make the loopback device if it doesn't exist already
if [ ! -e $LOOPDEV ]; then
    LOMAJOR=${LOOPDEV#/dev/loop} # Get just the number
    mknod -m660 $LOOPDEV b 7 $LOMAJOR
fi

# Find the starting byte and the total bytes in the 1st partition
# NOTE: normally would be able to use partx/kpartx directly to loopmount
#       the disk image and add the partitions, but inside of docker I found
#       that wasn't working quite right so I resorted to this manual approach.
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Loopmount the 1st partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Add in DOROOT label to the boot partition
e2label $LOOPDEV 'DOROOT'

# Disassociate 1st partition from loopmount device
losetup -d $LOOPDEV

# Find the starting byte and the total bytes in the 2nd partition
# (only 2 partitions)
eval `echo "$PAIRS" | tail -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Loopmount the 2nd partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Tell lvm to not depend on udev and create device nodes itself.
sed -i 's/udev_sync = 1/udev_sync = 0/' /etc/lvm/lvm.conf
sed -i 's/udev_rules = 1/udev_rules = 0/' /etc/lvm/lvm.conf

# Enable volume group
pvscan
vgchange -a y atomicos

# Mount it on $TMPMNT
mount /dev/mapper/atomicos-root $TMPMNT

# Copy the cloud-init python files over because we need to add the 
# DODATASOURCE and you can't just have 1 file from the package over
# there. We have to have them all over there.
mkdir -p ${TMPMNT}/ostree/deploy/fedora-atomic/var/usrlocal/lib/python2.7/site-packages/
pushd ${TMPMNT}/ostree/deploy/fedora-atomic/deploy/*.0/
cp -ar ./usr/lib/python2.7/site-packages/cloudinit \
    ${TMPMNT}/ostree/deploy/fedora-atomic/var/usrlocal/lib/python2.7/site-packages/
popd

# Get the DO datasource and store in the right place
curl $DODATASOURCEURL > ${TMPMNT}/${DODATASOURCEFILE}
chcon system_u:object_r:lib_t:s0 ${TMPMNT}/${DODATASOURCEFILE}

# Since we just effectively wrote a file to /usr/local/lib we need
# to update the unit file for cloud-init to set a PYTHONPATH to
# include /usr/local/lib. Do this by placing a file in /etc/ that masks
# the one in /usr/ for the service.
pushd ${TMPMNT}/ostree/deploy/fedora-atomic/deploy/*.0/
cp usr/lib/systemd/system/cloud-init.service etc/systemd/system/cloud-init.service
sed -i "s|\[Service\]|\[Service\]\nEnvironment=PYTHONPATH=/usr/local/lib/python2.7/site-packages/|" \
    etc/systemd/system/cloud-init.service
chcon system_u:object_r:systemd_unit_file_t:s0 etc/systemd/system/cloud-init.service
popd

# Put in place the config from Digital Ocean
DOCLOUDCFGFILE='etc/cloud/cloud.cfg.d/01_digitalocean.cfg'
pushd ${TMPMNT}/ostree/deploy/fedora-atomic/deploy/*.0/
cat << END > ${DOCLOUDCFGFILE}
datasource_list: [ DigitalOcean, None ]
datasource:
 DigitalOcean:
   retries: 5
   timeout: 10
vendor_data:
   enabled: True
END
chcon system_u:object_r:etc_t:s0 ${DOCLOUDCFGFILE}
popd

# umount and tear down loop device
umount $TMPMNT
vgchange -a n atomicos
losetup -d $LOOPDEV
[ ! -z $LOMAJOR ] && rm $LOOPDEV #Only remove if we created it

# finally, cp $IMG into /tmp/doimg/ on the host
cp -a $IMG /tmp/doimg/ 

EOF
