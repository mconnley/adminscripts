param (
    [string]$vCenterServer,
    [string]$vCenterUser,
    [string]$vCenterPassword,
    [string]$sshServer,
    [string]$sshUser,
    [string]$sshPassword,
    [string]$outputPath
)

# Load the VMware PowerCLI module
Import-Module VMware.PowerCLI
Import-Module Posh-SSH

# Define vCenter connection details

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
Write-Output "Connecting to vCenter..."
Connect-VIServer -Server $vCenterServer -User $vCenterUser -Password $vCenterPassword -ErrorAction Stop
Write-Output "Connected to vCenter!"
# Get all datastores
$datastores = Get-Datastore
Write-Output "Got Datastores!"

Write-Output "Connecting to SSH server..."
$secureSshPassword = ConvertTo-SecureString $sshPassword -AsPlainText -Force
$session = New-SSHSession -ComputerName $sshServer -Credential (New-Object System.Management.Automation.PSCredential($sshUser, $secureSshPassword)) -AcceptKey -ErrorAction Stop
Write-Output "Connected to SSH server!"

$command = "q"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop
Write-Output "Exiting Menu..."

$command = "y"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop
Write-Output "Confirmed exit from menu..."

$sid = Get-Sid -session $session -username $sshUser -password $sshPassword -ErrorAction Stop
Write-Output "Got SID!"

$command = "qcli_iscsi -l sid=$sid"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command -ErrorAction Stop

$lunTable = Get-LUN-ID-Map -session $session -sid $sid -ErrorAction Stop
Write-Output "Got LUN ID map!"

$exitCode = 0

foreach ($datastore in $datastores | Sort-Object -Property CapacityGB) {
    try {
            Write-Output "Processing datastore $($datastore.Name)..."
            $vms = Get-VM -Datastore $datastore
            
            $fields = @{}
            $datastore.ExtensionData.AvailableField | ForEach-Object{
                $fields.Add($_.Key,$_.Name)
            }
            
            $doBackup = $datastore.ExtensionData.CustomValue.GetEnumerator() |
            Select-Object @{N='Name';E={$fields.Item($_.Key)}},Value |
            Where-Object { $_.Name -eq "backupLun" } |
            Select-Object -ExpandProperty Value
        
            Write-Output "Do backup: $doBackup"
        
            if ($doBackup -eq "true") {
                $lunName = $datastore.ExtensionData.CustomValue.GetEnumerator() |
                Select-Object @{N='Name';E={$fields.Item($_.Key)}},Value |
                Where-Object { $_.Name -eq "lunName" } |
                Select-Object -ExpandProperty Value
            
                Write-Output "LUN Name: $lunName"
                $lunID = ($lunTable | Where-Object { $_.Name -eq $lunName }).LunID
                Write-Output "LUN ID: $lunID"
                $backupTime = $(Get-Date -Format 'yyyyMMdd-HHmmss')
                Write-Output "Backup Time: $backupTime"
                
                try {
                    foreach ($vm in $vms) {
                        # Create a snapshot for each VM
                        Write-Output "Creating snapshot for VM $($vm.Name)..."
                        New-Snapshot -VM $vm -Name "BackupSnapshot-$backupTime" -Description "Snapshot created for backup purposes" -Quiesce
                        # SSH to the server and run commands
                    }

                }
                catch {
                    $errMsg = "Failed to create snapshots for VMs in datastore $($datastore.Name)."
                    Write-Error $errMsg
                    throw $errMsg
                }
        
                $sid = Get-Sid -session $session -username $sshUser -password $sshPassword
                
                Write-Output "Adding backup job for LUN $lunName..."
                $command = "qcli_iscsibackup -A Name=$lunName-$backupTime BackLunImageName=$lunName-$backupTime lunID=$lunID compression=no Protocol=2 path=$outputPath Schedule=1 sid=$sid"
                $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command
                
                if ($result.ExitStatus -gt 0) {
                    $errMsg = "Failed to add backup job for LUN $lunName."
                    Write-Error $errMsg
                    throw $errMsg
                }
                Write-Output "Backup job added for LUN $lunName."
        
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
                                Write-Error $errMsg
                                throw $errMsg
                            }
                            if ($matches[1] -ne "Finished") {
                                $backupComplete = $false
                                break
                            }
                        }
                    }
                    Write-Output "Backup job for LUN $lunName is still processing..."
                }
                $command = "find /share/external/sdwa -type f -mmin +1800 -name *$lunName* -delete"
                $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command

                if ($result.ExitStatus -ne 0) {
                    throw "Failed to delete old backup files for LUN $lunName."
                }                        

                Write-Output "Processed datastore $($datastore.Name)."
            }
            else {
                Write-Output "Skipping datastore $($datastore.Name)..."
            }
    }
    catch {
        $exitCode = 1
    }
    finally {
        foreach ($vm in $vms) {
            # Remove the snapshot for each VM
            Write-Output "Removing snapshot for VM $($vm.Name)..."
            $snapshots = Get-Snapshot -VM $vm
            foreach ($snapshot in $snapshots) {
                Remove-Snapshot -Snapshot $snapshot -Confirm:$false
            }
        }
    }
}

Write-Output "Deleting old backup jobs..."
$command = "qcli_iscsibackup -l sid=$sid"
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command $command
$fiveDaysAgo = (Get-Date).AddDays(-5)

foreach ($line in $result.Output) {
    if ($line -match "^(Job\d+)\s+(\S+)\s+Backup\s+\(Schedule:Now\)\s+Finished\s+\((\d{4}/\d{2}/\d{2})") {
        $jobId = $matches[1]
        $jobDate = [datetime]::ParseExact($matches[3], 'yyyy/MM/dd', $null)

        if ($jobDate -lt $fiveDaysAgo) {
            $deleteCommand = "qcli_iscsibackup -d Job=$jobId sid=$sid"
            $deleteResult = Invoke-SSHCommand -SessionId $session.SessionId -Command $deleteCommand
            Write-Output "Deleted backup job $jobId."

            if ($deleteResult.ExitStatus -ne 0) {
                throw "Failed to delete backup job $jobId."
            }
        }
    }
}

Write-Output "Deleted old backup jobs."
Write-Output "Disconnecting from SSH server..."
Remove-SSHSession -SessionId $session.SessionId




# Disconnect from the vCenter server
Write-Output "Disconnecting from vCenter..."
Disconnect-VIServer -Server $vCenterServer -Confirm:$false

Write-Output "Complete!"

exit $exitCode