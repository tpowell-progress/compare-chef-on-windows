# Test recipe to output Chef version to file

chef_version = Chef::VERSION
output_file = "C:\\shared\\chef-#{chef_version}.txt"

log "Chef version: #{chef_version}" do
  level :info
end

# Execute PowerShell script to output Chef version
powershell_script 'output_chef_version' do
  code <<-EOH
    $chefVersion = "#{chef_version}"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $computerName = $env:COMPUTERNAME
    $output = @"
Chef Version: $chefVersion
Computer Name: $computerName
Timestamp: $timestamp
Chef Client Path: $(Get-Command chef-client | Select-Object -ExpandProperty Source)
"@
    
    $outputFile = "C:\\shared\\chef-$chefVersion.txt"
    Write-Host "Writing Chef version information to $outputFile"
    $output | Out-File -FilePath $outputFile -Encoding UTF8
    Write-Host "Successfully wrote version information"
    Get-Content $outputFile
  EOH
  action :run
end

log "Chef version written to #{output_file}" do
  level :info
end
