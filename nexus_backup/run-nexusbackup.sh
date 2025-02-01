#!/bin/bash
####################################
#
# Backup to NFS mount script.
#
####################################

# What to backup.
backup_files="/opt/sonatype-work/nexus3/blobs"

# Where to backup to.
dest="/nas/nfsbackup/nexus"

# Create archive filename.
backupTime=$(date +%Y%m%d)
hostname=$(hostname -s)
archive_file="$hostname-$backupTime.tgz"

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

# Remove old backups
echo
echo "Removing old backups..."
find /nas/nfsbackup/nexus -type f -mtime +2 -delete

#Print finished message
echo
echo "Removed backups older than 2 days. Process complete."
