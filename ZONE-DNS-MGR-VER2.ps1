# Route53 DNS Backup & Restore Utility (BOM-free, single JSON, import-safe)

# ========== SSL WARNING SUPPRESSION ==========
# Completely disable Python warnings for AWS CLI
$env:PYTHONWARNINGS = "ignore"
# Alternative method that might work better
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
# ============================================

function Show-Menu {
    Write-Host "`nRoute53 DNS Backup and Restore Utility"
    Write-Host "1. Export all Route53 zones to JSON"
    Write-Host "2. Zip the JSON file"
    Write-Host "3. Upload ZIP to S3"
    Write-Host "4. Restore zones & records from JSON"
    Write-Host "5. Exit"
}

function Export-ZonesToJson {
    $global:folder = "route53-backups"
    $global:date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $global:workingDir = "$env:TEMP\Route53Backup_$date"
    $global:zipFile = "$workingDir\route53-dns-$date.zip"
    $global:jsonFile = "$workingDir\route53-all-zones-$date.json"

    New-Item -ItemType Directory -Path $workingDir -Force | Out-Null

    Write-Host "`nExporting all hosted zones..."

    # Explicitly suppress warnings for this command
    $zones = (aws route53 list-hosted-zones --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }) | ConvertFrom-Json
    if (-not $zones) {
        Write-Host "Error: Failed to retrieve hosted zones. Check your AWS credentials and permissions."
        return
    }

    $fullExport = @()

    foreach ($zone in $zones.HostedZones) {
        $zoneId = $zone.Id -replace '^/hostedzone/', ''
        $zoneName = $zone.Name.TrimEnd('.')

        Write-Host " -> $zoneName ($zoneId)"

        $records = (aws route53 list-resource-record-sets --hosted-zone-id $zoneId --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }) | ConvertFrom-Json
        $changeList = @()

        foreach ($record in $records.ResourceRecordSets) {
            if ($record.Type -eq "NS" -and $record.Name -eq "$zoneName.") { continue }
            if ($record.Type -eq "SOA") { continue }

            $entry = @{
                Action = "UPSERT"
                ResourceRecordSet = @{
                    Name = $record.Name
                    Type = $record.Type
                }
            }

            if ($record.TTL) {
                $entry.ResourceRecordSet.TTL = $record.TTL
            }

            if ($record.ResourceRecords) {
                $entry.ResourceRecordSet.ResourceRecords = @()
                foreach ($rr in $record.ResourceRecords) {
                    $entry.ResourceRecordSet.ResourceRecords += @{ Value = $rr.Value }
                }
            }

            if ($record.AliasTarget) {
                $entry.ResourceRecordSet.AliasTarget = $record.AliasTarget
            }

            $changeList += $entry
        }

        $zoneExport = @{
            ZoneName = $zoneName
            ZoneId   = $zoneId
            Comment  = "Backup of $zoneName on $date"
            Changes  = $changeList
        }

        $fullExport += $zoneExport
    }

    $jsonRaw = $fullExport | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($jsonFile, $jsonRaw, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "`nExport complete: $jsonFile"
}

function Zip-JsonFile {
    if (!(Test-Path $jsonFile)) {
        Write-Host "JSON file not found. Please run export first."
        return
    }

    Compress-Archive -Path $jsonFile -DestinationPath $zipFile -Force
    Write-Host "Zipped JSON to: $zipFile"
}

function Upload-ToS3 {
    if (!(Test-Path $zipFile)) {
        Write-Host "Zip file not found. Run export and zip steps first."
        return
    }

    # Always prompt for bucket name
    $bucket = Read-Host "Enter your S3 bucket name (required)"
    
    if ([string]::IsNullOrWhiteSpace($bucket)) {
        Write-Host "Bucket name cannot be empty. Upload canceled."
        return
    }

    # Verify bucket exists before attempting upload
    try {
        Write-Host "Checking if bucket '$bucket' exists..."
        $bucketCheck = (aws s3api head-bucket --bucket $bucket --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" })
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Bucket '$bucket' does not exist or you don't have permissions."
            Write-Host "Please create the bucket first or check your permissions."
            return
        }
    }
    catch {
        Write-Host "Error verifying bucket: $_"
        return
    }

    $s3Key = "$folder/route53-dns-$date.zip"
    try {
        Write-Host "Attempting upload to s3://$bucket/$s3Key..."
        aws s3 cp $zipFile "s3://$bucket/$s3Key" --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Upload successful."
        } else {
            Write-Host "Upload failed."
        }
    }
    catch {
        Write-Host "Upload failed with error: $_"
    }
}

function Restore-ZonesFromJson {
    $jsonPath = Read-Host "Enter path to the JSON file (e.g., C:\path\to\route53-all-zones.json)"

    if (!(Test-Path $jsonPath)) {
        Write-Host "File not found: $jsonPath"
        return
    }

    $zonesData = Get-Content -Raw $jsonPath | ConvertFrom-Json

    Write-Host "`nAvailable zones in backup:"
    $zonesData | ForEach-Object { Write-Host " - $($_.ZoneName)" }

    Write-Host "`nSelect restore mode:"
    Write-Host "1. Restore all zones"
    Write-Host "2. Restore specific zones"
    $mode = Read-Host "Enter option (1 or 2)"

    $zonesToRestore = @()

    if ($mode -eq "1") {
        $zonesToRestore = $zonesData
    }
    elseif ($mode -eq "2") {
        $selectedNames = Read-Host "Enter comma-separated zone names to restore (e.g., example.com,myzone.com)"
        $selectedList = $selectedNames.Split(",") | ForEach-Object { $_.Trim().ToLower() }
        $zonesToRestore = $zonesData | Where-Object { $selectedList -contains $_.ZoneName.ToLower() }

        if ($zonesToRestore.Count -eq 0) {
            Write-Host "No matching zones found for the input."
            return
        }
    }
    else {
        Write-Host "Invalid option selected. Aborting."
        return
    }

    foreach ($zone in $zonesToRestore) {
        $zoneName = $zone.ZoneName
        $originalZoneId = $zone.ZoneId

        Write-Host "`nProcessing zone: $zoneName"

        $existingZones = (aws route53 list-hosted-zones --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }) | ConvertFrom-Json
        $targetZone = $existingZones.HostedZones | Where-Object { $_.Name -eq "$zoneName." }

        if ($targetZone) {
            $zoneId = $targetZone.Id -replace '^/hostedzone/', ''
            Write-Host "Found existing hosted zone with ID: $zoneId"
        }
        else {
            Write-Host "Creating new hosted zone for $zoneName"
            $newZone = (aws route53 create-hosted-zone --name $zoneName --caller-reference "restore-$(Get-Date -Format 'yyyyMMddHHmmss')" --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }) | ConvertFrom-Json
            $zoneId = $newZone.HostedZone.Id -replace '^/hostedzone/', ''
            Write-Host "Created new hosted zone with ID: $zoneId"
        }

        $changeBatch = @{
            Comment = $zone.Comment
            Changes = $zone.Changes
        }

        $tempJson = "$env:TEMP\restore-$zoneName.json"
        $json = $changeBatch | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tempJson, $json, (New-Object System.Text.UTF8Encoding($false)))

        try {
            aws route53 change-resource-record-sets --hosted-zone-id $zoneId --change-batch file://$tempJson --no-verify-ssl 2>&1 | Where-Object { $_ -notmatch "InsecureRequestWarning" }
            Write-Host "Records restored successfully for $zoneName"
        }
        catch {
            Write-Host "Error restoring ${zoneName}: $_"
        }

        Remove-Item $tempJson -ErrorAction SilentlyContinue
    }
}

# === MAIN LOOP ===
$exitScript = $false
do {
    Show-Menu
    $choice = Read-Host "Select an option (1-5)"
    switch ($choice) {
        "1" { Export-ZonesToJson }
        "2" { Zip-JsonFile }
        "3" { Upload-ToS3 }
        "4" { Restore-ZonesFromJson }
        "5" { $exitScript = $true }
        default { Write-Host "Invalid choice. Try again." }
    }
} while (-not $exitScript)
Write-Host "Exiting script..."