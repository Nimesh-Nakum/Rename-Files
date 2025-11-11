<#
.SYNOPSIS
    Safely rename files by adding a prefix (e.g. "finance_"), with logging, optional backup, retries, and ShouldProcess support.

.DESCRIPTION
    Advanced function that renames files matching a filter in a folder.
    Features:
      - CmdletBinding(SupportsShouldProcess=$true) => supports -WhatIf / -Confirm
      - Dry-run mode (separate -DryRun switch)
      - Per-file try/catch with retry
      - Optional backup copy before rename
      - CSV audit log (Timestamp, OriginalPath, TargetPath, Status, Message, Attempts)
      - Idempotent: skips files that already start with the prefix
      - Collision handling: appends timestamp (milliseconds) if target exists
      - Failed files moved to a "Failed" subfolder for manual inspection

.EXAMPLE
    # Preview only:
    Rename-Files -SourcePath 'E:\Files' -Filter '*.txt' -Prefix 'finance_' -WhatIf

.EXAMPLE
    # Dry run (no changes, but logs planned changes)
    Rename-Files -SourcePath 'E:\Files' -Filter '*.txt' -Prefix 'finance_' -DryRun -LogPath 'E:\rename_log.csv'

.EXAMPLE
    # Real run with backup & log
    Rename-Files -SourcePath 'E:\Files' -Filter '*.txt' -Prefix 'finance_' -BackupFolder 'E:\backup' -LogPath 'E:\rename_log.csv'

.PARAMETER SourcePath
    Folder containing files to rename. (Required)

.PARAMETER Filter
    Wildcard filter, e.g. '*.txt'. (Default: '*.txt')

.PARAMETER Prefix
    Prefix to add to filenames. Files already starting with this prefix are skipped.

.PARAMETER BackupFolder
    Optional. If provided, a copy of each file will be saved here before renaming.

.PARAMETER LogPath
    Path to CSV audit log. Created if missing. (Default: RenameTool.csv next to script)

.PARAMETER MaxRetries
    Number of times to retry a failing rename operation. (Default: 3)

.PARAMETER RetryDelaySeconds
    Delay in seconds between retries. (Default: 2)

.PARAMETER DryRun
    If specified, the function prints planned actions but does not perform renames (respects ShouldProcess/WhatIf as well).

.NOTES
    Author: You (edit author line as desired)
    License: MIT (edit if you want another license)
#>

function Rename-Files {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory = $false)]
        [string]$Filter = '*.txt',

        [Parameter(Mandatory = $false)]
        [string]$Prefix = 'finance_',

        [Parameter(Mandatory = $false)]
        [string]$BackupFolder = '',

        [Parameter(Mandatory = $false)]
        [string]$LogPath = "$PSScriptRoot\RenameTool.csv",

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 2,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    # -------------------------
    # Helpers
    # -------------------------
    function Ensure-Dir {
        param([Parameter(Mandatory = $true)][string]$PathToCreate)
        if (-not (Test-Path $PathToCreate)) {
            try {
                New-Item -Path $PathToCreate -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            catch {
                throw "Failed to create directory '$PathToCreate' : $($_.Exception.Message)"
            }
        }
    }

    function Append-LogCsv {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][PSCustomObject]$Record
        )

        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) {
            Ensure-Dir -PathToCreate $dir
        }

        if (-not (Test-Path $Path)) {
            # create file with header
            $Record | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        }
        else {
            $Record | Export-Csv -Path $Path -NoTypeInformation -Append -Encoding UTF8
        }
    }

    # -------------------------
    # Normalize & validate paths
    # -------------------------
    try {
        $SourcePath = (Resolve-Path -Path $SourcePath -ErrorAction Stop).ProviderPath
    }
    catch {
        Write-Error "SourcePath not found or inaccessible: $SourcePath"
        return
    }

    if ($BackupFolder) {
        # Try to resolve if exists; if not, we'll create it later
        try {
            $resolved = Resolve-Path -Path $BackupFolder -ErrorAction SilentlyContinue
            if ($resolved) { $BackupFolder = $resolved.ProviderPath }
        }
        catch {
            # ignore; we'll create folder if needed
        }
    }

    # ensure log directory exists
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir) {
        try { Ensure-Dir -PathToCreate $logDir } catch { Write-Warning $_; return }
    }

    # ensure backup directory if provided
    if ($BackupFolder) {
        try { Ensure-Dir -PathToCreate $BackupFolder } catch { Write-Error $_; return }
    }

    # -------------------------
    # Gather files
    # -------------------------
    $Files = @(Get-ChildItem -Path $SourcePath -Filter $Filter -File -ErrorAction SilentlyContinue)
    if (-not $Files -or $Files.Count -eq 0) {
        Write-Warning "No files found matching '$Filter' in $SourcePath"
        return
    }

    # -------------------------
    # Counters
    # -------------------------
    $total = 0; $succeeded = 0; $failed = 0; $skipped = 0

    foreach ($file in $Files) {
        $total++

        # idempotency: skip files already prefixed
        if ($file.Name -like "$Prefix*") {
            $skipped++
            $record = [PSCustomObject]@{
                Timestamp    = (Get-Date).ToString('s')
                OriginalPath = $file.FullName
                TargetPath   = $file.FullName
                Status       = 'Skipped'
                Message      = 'Already prefixed'
                Attempts     = 0
            }
            Append-LogCsv -Path $LogPath -Record $record
            continue
        }

       
        # compute new name & target path
        $newName = "$Prefix$($file.Name)" 
        $targetPath = Join-Path -Path $file.DirectoryName -ChildPath $newName

        # collision handling: if target exists, create a unique name with milliseconds
        if (Test-Path $targetPath) {
            $timeSuffix = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) # Use original file's name
            $ext = [System.IO.Path]::GetExtension($file.Name)                     # Use original file's extension
    
            # Construct the final, unique, and prefixed name
            $newName = "$Prefix$baseName`_$timeSuffix$ext" # e.g., finance_report_20251109-etc.txt
            $targetPath = Join-Path -Path $file.DirectoryName -ChildPath $newName
        }

        $actionDescription = "Rename '$($file.Name)' -> '$newName'"

        # ShouldProcess check (respects -WhatIf and -Confirm).
        if (-not $PSCmdlet.ShouldProcess($file.FullName, $actionDescription)) {
            $record = [PSCustomObject]@{
                Timestamp    = (Get-Date).ToString('s')
                OriginalPath = $file.FullName
                TargetPath   = $targetPath
                Status       = 'Preview'
                Message      = 'Planned change (WhatIf/declined)'
                Attempts     = 0
            }
            Append-LogCsv -Path $LogPath -Record $record
            continue
        }

        # DryRun (explicit switch) - do not modify disk
        if ($DryRun) {
            Write-Host "[DryRun] Would: $actionDescription"
            $record = [PSCustomObject]@{
                Timestamp    = (Get-Date).ToString('s')
                OriginalPath = $file.FullName
                TargetPath   = $targetPath
                Status       = 'DryRun'
                Message      = 'DryRun: no action'
                Attempts     = 0
            }
            Append-LogCsv -Path $LogPath -Record $record
            continue
        }

        # Optional: backup copy
        if ($BackupFolder) {
            try {
                $backupTarget = Join-Path -Path $BackupFolder -ChildPath $file.Name
                Copy-Item -Path $file.FullName -Destination $backupTarget -ErrorAction Stop
            }
            catch {
                Write-Warning "Failed to backup '$($file.FullName)' : $($_.Exception.Message)"
                # policy: continue even if backup fails
            }
        }

        # Rename with retry loop for transient issues
        $attempts = 0
        $success = $false
        while ($attempts -lt $MaxRetries -and -not $success) {
            $attempts++
            try {
                Rename-Item -Path $file.FullName -NewName $newName -ErrorAction Stop
                $success = $true
                $succeeded++
                $record = [PSCustomObject]@{
                    Timestamp    = (Get-Date).ToString('s')
                    OriginalPath = $file.FullName
                    TargetPath   = $targetPath
                    Status       = 'Success'
                    Message      = ''
                    Attempts     = $attempts
                }
                Append-LogCsv -Path $LogPath -Record $record
            }
            catch {
                if ($attempts -ge $MaxRetries) {
                    $failed++
                    $errMsg = $_.Exception.Message
                    $record = [PSCustomObject]@{
                        Timestamp    = (Get-Date).ToString('s')
                        OriginalPath = $file.FullName
                        TargetPath   = $targetPath
                        Status       = 'Failed'
                        Message      = $errMsg
                        Attempts     = $attempts
                    }
                    Append-LogCsv -Path $LogPath -Record $record

                    # move failed file to a Failed folder for inspection
                    try {
                        $failedFolder = Join-Path -Path $SourcePath -ChildPath 'Failed'
                        Ensure-Dir -PathToCreate $failedFolder
                        Move-Item -Path $file.FullName -Destination (Join-Path $failedFolder $file.Name) -Force -ErrorAction SilentlyContinue
                        Write-Warning "Moved failed file $($file.FullName) to $failedFolder"
                    }
                    catch {
                        Write-Warning "Could not move failed file: $($_.Exception.Message)"
                    }
                }
                else {
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
        }
    } 

    # final summary (outside loop)
    $summary = "Processed: $total, Succeeded: $succeeded, Failed: $failed, Skipped: $skipped"
    Write-Host $summary
    $recordSummary = [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('s')
        OriginalPath = $SourcePath
        TargetPath   = ''
        Status       = 'Summary'
        Message      = $summary
        Attempts     = 0
    }
    Append-LogCsv -Path $LogPath -Record $recordSummary
} 





#-------------------------- Example Usage:
#Rename-Files -SourcePath "E:\scripts\share\Projects\Quick-Cli Tools\Files" -Filter "*.txt" -Prefix "finance_" -BackupFolder "E:\scripts\share\Projects\Quick-Cli Tools\backup" -LogPath "E:\scripts\share\Projects\Quick-Cli Tools\RenameTool.csv"
#--------------------------