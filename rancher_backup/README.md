# Rancher Backup Script(s)
This script backs up my standalone Docker instance of Rancher.

Requires the following vars to be set (I put them in crontab):

CHECKMK_MAINTOPS: b64-encoded creds to CheckMK
CHECKMK_FQDN: FQDN of CheckMK endpoint
CHECKMK_SITE: CheckMK site code
