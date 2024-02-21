#!/bin/bash
####################################
#
# Backup Rancher to NFS mount script. 
# Extends/borrows heavily from https://ubuntu.com/server/docs/basic-backup-shell-script
#
####################################

# Create archive filename and other vars
backup_time=$(date +%Y%m%d)
hostname=$(hostname -s)
archive_file="$hostname-$backup_time.tgz"
rancher_container_name=$(docker container ls -a --no-trunc -f name=^/rancher$ --format '{{.Names}}')
rancher_image=$(docker container ls -a --no-trunc -f name=^/rancher$ --format '{{.Image}}')
start_maint_time=$(date -Iseconds)
end_maint_time=$(date -Iseconds -d '15 minutes')

# Create checkmk downtime
curl --location "http://$CHECKMK_FQDN/$CHECKMK_SITE/check_mk/api/1.0/domain-types/downtime/collections/host" \
--header 'Content-Type: application/json' \
--header "Authorization: Basic $CHECKMK_MAINTOPS" \
--data "{\"start_time\": \"$start_maint_time\",\"end_time\": \"$end_maint_time\",\"comment\": \"Nightly Backup\",\"downtime_type\": \"host\",\"host_name\": \"$RANCHER_CHECKMK_HOSTNAME\"}"

# Stop Rancher
echo "Stopping Rancher..."
docker stop rancher

# Create backup volume
echo "Creating backup volume..."
docker create --volumes-from $rancher_container_name --name rancher-data-$backup_time $rancher_image

# Create backup file
echo "Creating backup file..."
date
echo
docker run --name busybox-backup-$backup_time --volumes-from rancher-data-$backup_time -v $PWD:/backup:z busybox tar pzcf /backup/rancher-data-backup-$backup_time.tar.gz /var/lib/rancher
echo "Backup file created."
date
echo

# Start Rancher
echo "Starting Rancher..."
echo
docker start rancher

# What to backup.
backup_files="./rancher-data-backup-$backup_time.tar.gz /etc/ssl/certs/rancher"

# Where to backup to.
dest="/nas/nfsbackup/rancher"

# Print start status message.
echo "Backing up $backup_files to $dest/$archive_file"
date
echo

# Backup the files using tar.
tar czf $dest/$archive_file $backup_files

# Print status message.
echo
echo "Backup finished"
date

# Print status message.
echo
echo "Removing local tarball"
rm ./rancher-data-backup-$backup_time.tar.gz

# Print status message.
echo
echo "Removing Docker containers"

docker rm rancher-data-$backup_time
docker rm busybox-backup-$backup_time

# Remove old backups
echo
echo "Removing old backups..."
find /nas/nfsbackup/rancher -type f -mtime +2 -delete

#Print finished message
echo
echo "Removed backups older than 2 days. Process complete."