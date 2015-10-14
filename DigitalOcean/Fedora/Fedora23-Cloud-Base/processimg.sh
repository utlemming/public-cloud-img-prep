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

docker run -i --rm --privileged -v /tmp/doimg:/tmp/doimg fedora:22 bash << 'EOF'
set -eux
WORKDIR=/workdir
TMPMNT=/workdir/tmp/mnt

# Vars for the image
XZIMGURL='http://dl.fedoraproject.org/pub/alt/stage/23_TC9/Cloud_Images/x86_64/Images/Fedora-Cloud-Base-23_TC9-20151013.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
XZIMGSUM='c2c7be208790b623ee394f73deb3b701d95c6b4aa42fea349ef20737e983ac51'
IMG=${XZIMG:0:-3}           # Pull .xz off of the end

# File location for DO cloud config
export DOCLOUDCFGFILE='/etc/cloud/cloud.cfg.d/01_digitalocean.cfg'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
dnf install -y gdisk wget xz

# Get the xz image, verify, and decompress the contents
wget $XZIMGURL
imgsum=$(sha256sum $XZIMG | cut -d " " -f 1)
if [ "$imgsum" != "$XZIMGSUM" ]; then
    echo "Checksum doesn't match: $imgsum"
    exit 1
fi
unxz $XZIMG

# Find the starting byte and the total bytes in the 1st partition
# NOTE: normally would be able to use partx/kpartx directly to loopmount
#       the disk image and add the partitions, but inside of docker I found
#       that wasn't working quite right so I resorted to this manual approach.
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Discover the next available loopback device
LOOPDEV=$(losetup -f)
LOMAJOR=''

# Make the loopback device if it doesn't exist already
if [ ! -e $LOOPDEV ]; then
    LOMAJOR=${LOOPDEV#/dev/loop} # Get just the number
    mknod -m660 $LOOPDEV b 7 $LOMAJOR
fi

# Loopmount the first partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Add in DOROOT label to the root partition
e2label $LOOPDEV 'DOROOT'

# Mount it on $TMPMNT
mount $LOOPDEV $TMPMNT

# Put in place the config from Digital Ocean
cat << END > ${TMPMNT}/${DOCLOUDCFGFILE}
datasource_list: [ DigitalOcean, None ]
datasource:
 DigitalOcean:
   retries: 5
   timeout: 10
vendor_data:
   enabled: True
END
# Don't know why this one is failing
#chcon system_u:object_r:etc_t:s0 ${TMPMNT}/${DOCLOUDCFGFILE}

# umount and tear down loop device
umount $TMPMNT
losetup -d $LOOPDEV
[ ! -z $LOMAJOR ] && rm -f $LOOPDEV #Only remove if we created it

# finally, cp $IMG into /tmp/doimg/ on the host
cp -a $IMG /tmp/doimg/ 

EOF
