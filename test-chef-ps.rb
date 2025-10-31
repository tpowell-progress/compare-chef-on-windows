#!/usr/bin/env ruby
# test-chef-ps.rb - Chef PowerShell gem test suite

puts "=== Chef PowerShell Gem Test Suite ==="
puts "Ruby version: #{RUBY_VERSION}"
puts "Platform: #{RUBY_PLATFORM}"
puts ""

# List all powershell-related gems
puts "Installed gems matching 'powershell':"
begin
  require 'rubygems'
  Gem::Specification.find_all.select { |spec| spec.name.downcase.include?('powershell') }.each do |spec|
    puts "  #{spec.name} (#{spec.version})"
  end
rescue => e
  puts "  Error listing gems: #{e.message}"
end
puts ""

# Get chef-powershell gem specification
puts "Chef-PowerShell gem specification:"
begin
  spec = Gem::Specification.find_by_name('chef-powershell')
  puts "  Name: #{spec.name}"
  puts "  Version: #{spec.version}"
  puts "  Authors: #{spec.authors.join(', ')}"
  puts "  Summary: #{spec.summary}"
  puts "  Homepage: #{spec.homepage}"
  puts "  Installed at: #{spec.gem_dir}"
rescue Gem::MissingSpecError => e
  puts "  ✗ chef-powershell gem not found: #{e.message}"
rescue => e
  puts "  ✗ Error getting gem spec: #{e.message}"
end
puts ""

# Test 1: Basic gem loading
puts "Test 1: Loading chef-powershell gem..."
begin
  require 'chef-powershell'
  puts "✓ chef-powershell loaded successfully"
rescue LoadError => e
  puts "✗ Failed to load chef-powershell: #{e.message}"
  exit 1
rescue => e
  puts "✗ Error loading chef-powershell: #{e.message}"
  exit 1
end

include ChefPowerShell::ChefPowerShellModule::PowerShellExec
puts powershell_exec('Get-Date').inspect[0..100]
puts powershell_exec('Get-Process').inspect[0..100]
puts powershell_exec('Get-ChildItem C:\\').inspect[0..100]