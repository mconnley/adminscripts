param (
    [string]$vCenterServer,
    [string]$vCenterUser,
    [string]$vCenterPassword,
    [string]$sshServer,
    [string]$sshUser,
    [string]$sshPassword,
    [string]$outputHost,
    [string]$outputPath,
    [string]$deletePath
)

# Load the VMware PowerCLI module
Import-Module VMware.PowerCLI
Import-Module Posh-SSH

Function Write-LogMessage {
    [Alias("LogMsg")]
    Param(
        [Parameter(Position = 0, ValueFromPipeline, Mandatory=$false)]
        $Msg
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$Timestamp - $Msg"
}

function Get-Sid {
    param (
        [Parameter(Mandatory=$true)]
        [object]$session,
        [string]$username,
        [string]$password
    )
    $command = "qcli -l user=$username pw=$password"
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command

    if ($result.Output[1] -match "sid is (\w+)") {
        $sid = $matches[1]
    } else {
        throw "Failed to parse SID from command output."
    }
    return $sid
}

function Get-LUN-ID-Map {
    param (
        [Parameter(Mandatory=$true)]
        [object]$session,
        [Parameter(Mandatory=$true)]
        [string]$sid
    )

    if ($result.ExitStatus -ne 0) {
        throw "Failed to retrieve LUN ID map."
    }
    # Skip the first two lines (headers)
    $result.Output = $result.Output[2..$result.Output.Length]

    # Initialize an empty array to store the parsed results
    $lunTable = @()

    foreach ($line in $result.Output) {
        if ($line -match "(\d+)\s+\d+\s+\w+\s+\w+\s+(\w+)") {
            $lunTable += [PSCustomObject]@{
                Name = $matches[2]
                LunID = $matches[1]
            }
        }
    }

    return $lunTable
}

# Connect to the vCenter server
LogMsg "Connecting to vCenter..."
Connect-VIServer -Server $vCenterServer -User $vCenterUser -Password $vCenterPassword -ErrorAction Stop
LogMsg "Connected to vCenter!"
# Get all datastores
$datastores = Get-Datastore
LogMsg "Got Datastores!"

LogMsg "Connecting to SSH server..."
$secureSshPassword = ConvertTo-SecureString $sshPassword -AsPlainText -Force
$session = New-SSHSession -ComputerName $sshServer -Credential (New-Object System.Management.Automation.PSCredential($sshUser, $secureSshPassword)) -AcceptKey -ErrorAction Stop
LogMsg "Connected to SSH server!"

$command = "q"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop
LogMsg "Exiting Menu..."

$command = "y"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop
LogMsg "Confirmed exit from menu..."

$sid = Get-Sid -session $session -username $sshUser -password $sshPassword -ErrorAction Stop
LogMsg "Got SID!"

LogMsg "Deleting old backup jobs..."
$command = "qcli_iscsibackup -l sid=$sid"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command
$maxBackupJobAge = (Get-Date).AddHours(-12)

foreach ($line in $result.Output) {
    if ($line -match "^(Job\d+)\s+(\S+)\s+Backup\s+\(Schedule:Now\)\s+Finished\s+\((\d{4}/\d{2}/\d{2})") {
        $jobId = $matches[1]
        $jobDate = [datetime]::ParseExact($matches[3], 'yyyy/MM/dd', $null)

        if ($jobDate -lt $maxBackupJobAge) {
            $deleteCommand = "qcli_iscsibackup -d Job=$jobId sid=$sid"
            $deleteResult = Invoke-SSHCommand -SessionId $session.SessionId -Command $deleteCommand
            LogMsg "Deleted backup job $jobId."

            if ($deleteResult.ExitStatus -ne 0) {
                throw "Failed to delete backup job $jobId."
            }
        }
    }
}

LogMsg "Deleted old backup jobs."

$command = "qcli_iscsi -l sid=$sid"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop

$lunTable = Get-LUN-ID-Map -session $session -sid $sid -ErrorAction Stop
LogMsg "Got LUN ID map!"

$exitCode = 0

foreach ($datastore in $datastores | Sort-Object -Property CapacityGB) {
    try {
            LogMsg "Processing datastore $($datastore.Name)..."
            $vms = Get-VM -Datastore $datastore

            $fields = @{}
            $datastore.ExtensionData.AvailableField | ForEach-Object{
                $fields.Add($_.Key,$_.Name)
            }

            $doBackup = $datastore.ExtensionData.CustomValue.GetEnumerator() |
            Select-Object @{N='Name';E={$fields.Item($_.Key)}},Value |
            Where-Object { $_.Name -eq "backupLun" } |
            Select-Object -ExpandProperty Value

            LogMsg "Do backup: $doBackup"

            if ($doBackup -eq "true") {
                $lunName = $datastore.ExtensionData.CustomValue.GetEnumerator() |
                Select-Object @{N='Name';E={$fields.Item($_.Key)}},Value |
                Where-Object { $_.Name -eq "lunName" } |
                Select-Object -ExpandProperty Value

                LogMsg "LUN Name: $lunName"
                $lunID = ($lunTable | Where-Object { $_.Name -eq $lunName }).LunID
                LogMsg "LUN ID: $lunID"
                $backupTime = $(Get-Date -Format 'yyyyMMdd-HHmmss')
                LogMsg "Backup Time: $backupTime"

                try {
                    foreach ($vm in $vms) {
                        # Create a snapshot for each VM
                        LogMsg "Creating snapshot for VM $($vm.Name)..."
                        New-Snapshot -VM $vm -Name "BackupSnapshot-$backupTime" -Description "Snapshot created for backup purposes" -Quiesce
                        # SSH to the server and run commands
                    }

                }
                catch {
                    $errMsg = "Failed to create snapshots for VMs in datastore $($datastore.Name)."
                    LogMsg $errMsg
                    throw $errMsg
                }

                $sid = Get-Sid -session $session -username $sshUser -password $sshPassword

                LogMsg "Adding backup job for LUN $lunName..."
                $command = "qcli_iscsibackup -A Name=$lunName-$backupTime BackLunImageName=$lunName-$backupTime lunID=$lunID compression=no Protocol=0 Server=$outputHost path=$outputPath Schedule=1 sid=$sid"
                $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command

                if ($result.ExitStatus -gt 0) {
                    $errMsg = "Failed to add backup job for LUN $lunName."
                    LogMsg $errMsg
                    throw $errMsg
                }
                LogMsg "Backup job added for LUN $lunName."

                # Wait for the backup job to complete
                $backupComplete = $false
                while (-not $backupComplete) {
                    Start-Sleep -Seconds 10
                    $command = "qcli_iscsibackup -l sid=$sid"
                    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command

                    if ($result.ExitStatus -ne 0) {
                        throw "Failed to retrieve backup job status."
                    }

                    $backupComplete = $true
                    foreach ($line in $result.Output) {
                        if ($line -match "Job\d+\s+$lunName-$backupTime\s+Backup\s+\(Schedule:Now\)\s+(Processing|Finished|Failed)") {
                            if ($matches[1] -eq "Failed") {
                                $errMsg = "Backup job for LUN $lunName failed."
                                LogMsg $errMsg
                                throw $errMsg
                            }
                            if ($matches[1] -ne "Finished") {
                                $backupComplete = $false
                                break
                            }
                        }
                    }
                    LogMsg "Backup job for LUN $lunName is still processing..."
                }
                $command = "find $deletePath -type f -mmin +1800 -name *$lunName* -delete"
                Invoke-Expression $command

                if ($result.ExitStatus -ne 0) {
                    throw "Failed to delete old backup files for LUN $lunName."
                }

                LogMsg "Processed datastore $($datastore.Name)."
            }
            else {
                LogMsg "Skipping datastore $($datastore.Name)..."
            }
    }
    catch {
        $exitCode = 1
    }
    finally {
        foreach ($vm in $vms) {
            # Remove the snapshot for each VM
            LogMsg "Removing snapshot for VM $($vm.Name)..."
            $snapshots = Get-Snapshot -VM $vm
            foreach ($snapshot in $snapshots) {
                Remove-Snapshot -Snapshot $snapshot -Confirm:$false
            }
        }
    }
}

LogMsg "Disconnecting from SSH server..."
Remove-SSHSession -SessionId $session.SessionId




# Disconnect from the vCenter server
LogMsg "Disconnecting from vCenter..."
Disconnect-VIServer -Server $vCenterServer -Confirm:$false

LogMsg "Complete!"

exit $exitCode