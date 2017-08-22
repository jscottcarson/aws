#!/bin/bash

# Collect user info
echo "Enter the instance ID of the ec2 who's volumes you'd like to encrypt followed by [ENTER]"
read instanceid

echo "Enter the region that the instance is in followed by [Enter]"
read region

# Get AZ
az=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceid | grep AvailabilityZone | sed 's/"\|,\|:\|//g' | awk '{print $2}' | awk '!seen[$0]++')

# Stop the instance and wait for it to come to a stopped state
echo "Stopping instance $instanceid"
echo " "
aws ec2 stop-instances --instance-ids $instanceid
aws ec2 wait instance-stopped --instance-ids $instanceid

# Returns only volume Id's of non-encrypted volumes
aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceid | sed -n "/Encrypted/,/VolumeId/p" | grep -A 2 false | sed "/Encrypted\|VolumeId/! d" | sed "s/\"\|,\|:\|false//g" | awk '{print $2}' > ids

# Return the mount points for the volumes
aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceid | grep 'Device' | sed 's/"\|,\|:\|false//g' | awk '{print $2}' | sed 's/ //g' | sed '/^\s*$/d' | awk '!seen[$0]++' > mount

# Return the Volume Type
aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceid | sed -n '/Encrypted/,/VolumeId/p' | sed '/.^*Encrypted/ d' | sed '/.^*VolumeId/ d ' | sed 's/.*://' | sed 's/"\|,//g' > voltype

# Read the unencrypted VolumeId's into an array
readarray a <  ids

# Load  mount point into variable by volume order
mount=`cat mount`

az=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instanceid | grep AvailabilityZone | sed 's/"\|,\|:\|//g' | awk '{print $2}' | awk '!seen[$0]++')

# Loop through unencrypted Volumes array and tag with unencrypted tag for failback, detach, make snapshot, copy snapshot to encrypted snapshot, launch encrypted volume from snapshot, attach encrypted volume
for i in ${a[@]}; do
aws ec2 create-tags --region $region --resources $i --tags Key=Name,Value=$instanceid--`cat mount | head -n 1`--unencrypted

echo " "
echo "Deteching unencrypted volume"
echo " "
aws ec2 detach-volume --region $region --volume-id $i --output text

echo Creating snapshot of unecrypted volume
# Create snapshots and wait for the snapshot to complete
snap=$(aws ec2 create-snapshot --region $region --volume-id $i --description "$instanceid--`cat mount | head -n 1`--unencrypted" | grep -o -P 'snap.{0,18}' | grep -o -P 'snap.{0,18}')
aws ec2 wait snapshot-completed --snapshot-ids $snap

# Tag the snapshot with unenencrypted tag
aws ec2 create-tags --region $region --resources $snap --tags Key=Name,Value=$instanceid--`cat mount | head -n 1`--unencrypted

echo Copy unecrypted snapshot to encrypt it
# Encrypt snapshots by copying
encrsnap=$(aws ec2 copy-snapshot --region $region  --source-region $region --source-snapshot-id $snap --encrypted --description "$instanceid--`cat mount | head -n 1`--encrypted" | grep -o -P 'snap.{0,18}')
aws ec2 wait snapshot-completed --snapshot-ids $encrsnap

# Tag the snapshot with unencrypted tag
aws ec2 create-tags --region $region --resources $encrsnap --tags Key=Name,Value=$instanceid--`cat mount | head -n 1`--encrypted

echo Create a new encrypted volume from the encrypted snapshot copy
echo " "
# Create volumes from encryted snapshots
newvol=$(aws ec2 create-volume --region $region --volume-type `cat voltype | head -n 1` --availability-zone $az --snapshot-id $encrsnap | grep -o -P 'vol.{0,18}')
aws ec2 wait volume-available --volume-ids $newvol

# Tag the newly created volume as encrypted
aws ec2 create-tags --region $region --resources $newvol --tags Key=Name,Value=$instanceid--`cat mount | head -n 1`--encrypted

echo Attach the newly created encrypted volume to the original volumes mount point
# Attach the reattached encrypted volume at the original mount point
aws ec2 attach-volume --region $region --volume-id $newvol --instance-id $instanceid --mountice `cat mount | head -n 1` --output text

# Write the instance ID and mount point to a recovery file for failback if needed
echo "$instanceid--`cat mount | head -n 1`--unencrypted + " " + $i" >> $instanceid-encryption-failback
echo " "
sed -i '1d' mount
sed -i '1d' voltype

done
rm -rf ids mount

echo Success! The following volumes for instance $instanceid have been encrypted.
echo `cat $instanceid-encryption-failback` | sed 's/--unencrypted//g'
