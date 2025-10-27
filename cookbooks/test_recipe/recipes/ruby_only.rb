# Test recipe to output Chef version to file (Ruby-only version)

chef_version = Chef::VERSION
timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
output_file = "C:\\shared\\chef-#{chef_version}-#{timestamp}.txt"

log "Chef version: #{chef_version}" do
  level :info
end

log "Creating output file: #{output_file}" do
  level :info
end

# Use Ruby file I/O instead of PowerShell to avoid DLL issues
file output_file do
  content <<-EOL
======================================================================
Chef Recipe Execution Report
======================================================================
Chef Version: #{chef_version}
Ruby Timestamp: #{timestamp}
Recipe Status: SUCCESS
Output File: #{output_file}
======================================================================

This file was created by the Chef test recipe to verify:
1. Chef Ruby integration is working
2. File I/O operations are successful  
3. Recipe execution completed without errors
4. Timestamp functionality is operational

Generated at: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}
======================================================================
EOL
  action :create
end

log "Chef recipe completed for version #{chef_version}" do
  level :info
end