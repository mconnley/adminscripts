# Rancher Backup Script(s)
This script backs up my standalone Docker instance of Rancher. It's an extension of https://ubuntu.com/server/docs/basic-backup-shell-script

Requires the following vars to be set (I put them in crontab):

<ul>
<li>CHECKMK_MAINTOPS: b64-encoded creds to CheckMK
<li>CHECKMK_FQDN: FQDN of CheckMK endpoint
<li>CHECKMK_SITE: CheckMK site code
<li>RANCHER_CHECKMK_HOSTNAME: CheckMK hostname for Rancher server to be put into downtime
</ul>


