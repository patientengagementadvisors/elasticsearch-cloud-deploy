#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


# == Vars
#
VOLUME_NAME="${volume_name}"
MOUNT_POINT="${mount_point}"
FS="${file_system}"


# == Main
#
echo "===> UserData Script: Start"

echo "---> Waiting for $${VOLUME_NAME} (. = 5s)"
while [[ ! -e $${VOLUME_NAME} ]]; do
  sleep 5s;
  echo -n "."
done
echo ''

echo '---> Creating File System'
mkfs -t $${FS} $${VOLUME_NAME}

echo '---> Creating Mount point'
mkdir -p $${MOUNT_POINT}

echo '---> Retrieve UUID EBS'
VOLUME_UUID=$(blkid -s UUID -o value $${VOLUME_NAME})

echo '---> Mount EBS'
mount UUID="$${VOLUME_UUID}" $${MOUNT_POINT}

echo '---> Saving Mount point'
echo "UUID="$${VOLUME_UUID}" $${MOUNT_POINT} $${FS} defaults,nofail 0 2" | sudo tee -a /etc/fstab

echo "===> UserData Script: Done"