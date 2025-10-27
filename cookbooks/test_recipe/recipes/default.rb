# Test recipe to output Chef version to file

chef_version = Chef::VERSION
output_file = "C:\\shared\\chef-#{chef_version}.txt"

log "Chef version: #{chef_version}" do
  level :info
end

# Execute PowerShell script to confirm Chef recipe ran successfully
powershell_script 'confirm_chef_run' do
  code <<-EOH
    $chefVersion = "#{chef_version}"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $computerName = $env:COMPUTERNAME
    
    # Find the most recent chef output file for this version
    $fileTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputFile = Get-ChildItem "C:\\shared\\chef-$chefVersion-*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    
    if (-not $outputFile) {
        # Fallback if file doesn't exist yet (shouldn't happen, but just in case)
        $outputFile = "C:\\shared\\chef-$chefVersion-$fileTimestamp.txt"
    }
    
    # Append to existing file
    $separator = "`n" + "=" * 70 + "`n"
    $additionalOutput = @"
$separator
Chef Recipe Execution Completed:
Timestamp: $timestamp
Computer Name: $computerName
Status: SUCCESS
"@
    
    Write-Host "Appending Chef run completion to $outputFile"
    $additionalOutput | Out-File -FilePath $outputFile -Encoding UTF8 -Append
    Write-Host "Chef recipe completed successfully"
  EOH
  action :run
end

log "Chef recipe completed for version #{chef_version}" do
  level :info
end
