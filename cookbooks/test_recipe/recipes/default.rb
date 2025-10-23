# Test recipe to output Chef version to file

chef_version = Chef::VERSION
output_file = "C:\\shared\\chef-#{chef_version}.txt"

log "Chef version: #{chef_version}" do
  level :info
end

# Execute PowerShell script to output Chef version and diagnostic information
powershell_script 'output_chef_version' do
  code <<-EOH
    $chefVersion = "#{chef_version}"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $computerName = $env:COMPUTERNAME
    
    # Search for Chef.PowerShell.Wrapper.dll
    Write-Host "Searching for Chef.PowerShell.Wrapper.dll during Chef run..."
    $wrapperDlls = Get-ChildItem -Path "C:\\opscode\\chef" -Include "Chef.PowerShell.Wrapper.dll" -Recurse -ErrorAction SilentlyContinue
    
    $wrapperInfo = if ($wrapperDlls) {
        $wrapperDlls | ForEach-Object {
            "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)"
        } | Out-String
    } else {
        "  Chef.PowerShell.Wrapper.dll not found"
    }
    
    $outputFile = "C:\\shared\\chef-$chefVersion.txt"
    
    # Append to existing file or create new one
    $separator = "`n" + "=" * 70 + "`n"
    $additionalOutput = @"
$separator
Chef Recipe Execution:
Timestamp: $timestamp
Computer Name: $computerName

Chef.PowerShell.Wrapper.dll Search Results (During Chef Run):
$wrapperInfo
"@
    
    Write-Host "Appending Chef run results to $outputFile"
    $additionalOutput | Out-File -FilePath $outputFile -Encoding UTF8 -Append
    Write-Host "Successfully appended Chef run information"
    Get-Content $outputFile
  EOH
  action :run
end

log "Chef version information written to #{output_file}" do
  level :info
end
