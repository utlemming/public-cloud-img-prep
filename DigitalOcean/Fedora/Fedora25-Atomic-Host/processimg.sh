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

set -eu 
mkdir -p /tmp/doimg/
cd /tmp/doimg

# need wget/sha256sum/unxz for this script
for exe in wget sha256sum unxz; do
    if ! which $exe >/dev/null; then
        echo "You need $exe to run this program"
        exit 1
    fi
done

# Vars for the image
XZIMGURL='https://kojipkgs.fedoraproject.org//work/tasks/7833/16177833/Fedora-Atomic-25-20161023.n.0.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
XZIMGSUM='a9dde4ae13291bebaf4647007ebef5b48c837848f02a61be267a68199a30f803'
IMG=${XZIMG:0:-3}           # Pull .xz off of the end

# Get the xz image, verify, and decompress the contents
wget $XZIMGURL
imgsum=$(sha256sum $XZIMG | cut -d " " -f 1)
if [ "$imgsum" != "$XZIMGSUM" ]; then
    echo "Checksum doesn't match: $imgsum"
    exit 1
fi
unxz $XZIMG

echo "The following image has been downloaded verified and uncompressed:"
echo "   $(pwd)/$XZIMG"
