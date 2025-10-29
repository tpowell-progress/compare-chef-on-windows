#!/usr/bin/env powershell
<#
.SYNOPSIS
    Runs Ruby 3.1.7 and chef-powershell 3.1.7 test in Windows Server Core 2022 Docker container

.DESCRIPTION
    This script creates and runs a Windows Server Core 2022 Docker container,
    installs Ruby 3.1.7 using OneClickInstaller2, installs chef-powershell 3.1.7,
    and then drops you into the container for interactive testing.

.PARAMETER RubyVersion
    Ruby version to install (default: 3.1.7)

.PARAMETER ChefPowerShellVersion
    chef-powershell gem version (default: 3.1.7)

.PARAMETER ContainerName
    Name for the Docker container (default: ruby-chef-ps-test)

.PARAMETER KeepContainer
    Keep the container after exit (don't auto-remove)

.EXAMPLE
    .\run-ruby-test.ps1
    .\run-ruby-test.ps1 -RubyVersion "3.1.6" -ChefPowerShellVersion "3.1.6"
    .\run-ruby-test.ps1 -ContainerName "my-ruby-test" -KeepContainer
#>

param(
    [string]$RubyVersion = "3.1.7",
    [string]$ChefPowerShellVersion = "3.1.7",
    [string]$ContainerName = "ruby-chef-ps-test",
    [switch]$KeepContainer
)

$ErrorActionPreference = "Stop"

# Configuration
$BaseImage = "mcr.microsoft.com/windows/servercore:ltsc2022"
$RubyInstallerUrl = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$RubyVersion-1/rubyinstaller-devkit-$RubyVersion-1-x64.exe"
$RubyInstallPath = "C:\Ruby$($RubyVersion.Replace('.', ''))"

function Write-Status {
    param([string]$Message, [string]$Color = "Green")
    Write-Host "=== $Message ===" -ForegroundColor $Color
}

function Write-Error-Status {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Test-DockerAvailable {
    try {
        $dockerVersion = docker --version 2>$null
        if ($dockerVersion) {
            Write-Host "Docker available: $dockerVersion" -ForegroundColor Green
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Create-InstallationScript {
    Write-Status "Creating Ruby and chef-powershell installation script"
    
    $installScript = @"
# Ruby and chef-powershell installation script for container
Write-Host "=== Starting Ruby $RubyVersion and chef-powershell $ChefPowerShellVersion installation ==="

# Download Ruby installer
Write-Host "Downloading Ruby installer..."
`$rubyUrl = "$RubyInstallerUrl"
`$installerPath = "C:\rubyinstaller.exe"

try {
    Invoke-WebRequest -Uri `$rubyUrl -OutFile `$installerPath -UseBasicParsing
    Write-Host "Downloaded Ruby installer successfully"
} catch {
    Write-Host "Failed to download Ruby installer: `$(`$_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Install Ruby with Devkit silently
Write-Host "Installing Ruby $RubyVersion with Devkit..."
`$installArgs = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NOCLOSEAPPLICATIONS",
    "/NORESTART", 
    "/NOCANCEL",
    "/SP-",
    "/DIR=$RubyInstallPath",
    "/TASKS=assocfiles,modpath,devkit"
)

try {
    Write-Host "Running installer with args: `$(`$installArgs -join ' ')"
    `$process = Start-Process -FilePath `$installerPath -ArgumentList `$installArgs -Wait -PassThru -NoNewWindow
    Write-Host "Installer process completed with exit code: `$(`$process.ExitCode)"
    if (`$process.ExitCode -ne 0) {
        throw "Ruby installer failed with exit code: `$(`$process.ExitCode)"
    }
    Write-Host "Ruby installed successfully!" -ForegroundColor Green
} catch {
    Write-Host "Ruby installation failed: `$(`$_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Update PATH and refresh environment
`$rubyBinPath = "$RubyInstallPath\bin"
`$env:PATH = "`$rubyBinPath;`$env:PATH"
Write-Host "Updated PATH to include: `$rubyBinPath"

# Initialize devkit if needed
Write-Host "Initializing Ruby devkit..."
try {
    & "`$rubyBinPath\ridk.exe" enable
    Write-Host "Devkit initialized successfully" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not initialize devkit" -ForegroundColor Yellow
}

# Verify Ruby installation
try {
    `$rubyVersion = & "`$rubyBinPath\ruby.exe" --version
    Write-Host "Ruby verification: `$rubyVersion" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not verify Ruby installation" -ForegroundColor Yellow
}

# Install chef-powershell gem
Write-Host "Installing chef-powershell gem $ChefPowerShellVersion..."
try {
    & "`$rubyBinPath\gem.cmd" install chef-powershell -v $ChefPowerShellVersion --no-document --quiet --no-verbose
    Write-Host "chef-powershell gem installed successfully!" -ForegroundColor Green
} catch {
    Write-Host "Failed to install chef-powershell gem: `$(`$_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test installation
Write-Host "Testing chef-powershell installation..."
try {
    `$gemList = & "`$rubyBinPath\gem.cmd" list chef-powershell
    Write-Host "Installed gems: `$gemList" -ForegroundColor Cyan
    
    # Test requiring the gem
    `$testScript = @'
begin
  require \"chef/powershell\"
  puts \"chef-powershell loaded successfully\"
  puts \"Chef::PowerShell::VERSION = #{Chef::PowerShell::VERSION}\" if defined?(Chef::PowerShell::VERSION)
rescue LoadError => e
  puts \"Failed to load chef-powershell: #{e.message}\"
  exit 1
rescue => e
  puts \"Error testing chef-powershell: #{e.message}\"
  exit 1
end
'@
    
    `$testResult = & "`$rubyBinPath\ruby.exe" -e `$testScript
    Write-Host "Test result: `$testResult" -ForegroundColor Green
} catch {
    Write-Host "chef-powershell test failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

# Cleanup installer
Remove-Item `$installerPath -Force -ErrorAction SilentlyContinue

Write-Host "=== Installation completed! ==="
Write-Host "Ruby $RubyVersion and chef-powershell $ChefPowerShellVersion are ready for testing"
Write-Host "Ruby is installed at: $RubyInstallPath"
Write-Host "Use 'ruby --version' and 'gem list chef-powershell' to verify"
Write-Host ""
Write-Host "=== Entering interactive session ==="
Write-Host "You can now test Ruby and chef-powershell interactively"
Write-Host "Type 'exit' to leave the container"
Write-Host ""

# Start interactive PowerShell session
& powershell -NoLogo
"@

    return $installScript
}

function Run-DockerContainer {
    Write-Status "Creating and running Windows Server Core 2022 container"
    
    try {
        # Check if container already exists and remove it
        $existingContainer = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
        if ($existingContainer -eq $ContainerName) {
            Write-Host "Removing existing container: $ContainerName"
            docker rm -f $ContainerName 2>$null | Out-Null
        }
        
        # Create installation script in a dedicated directory
        $scriptDir = Join-Path $env:TEMP "ruby-container-setup"
        if (-not (Test-Path $scriptDir)) {
            New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        }
        
        $installScript = Create-InstallationScript
        $scriptPath = Join-Path $scriptDir "install-script.ps1"
        $installScript | Out-File -FilePath $scriptPath -Encoding UTF8
        
        Write-Host "Created installation script at: $scriptPath"
        
        # Determine removal flag
        $removeFlag = if ($KeepContainer) { "" } else { "--rm" }
        
        # Run container with installation script
        Write-Host "Starting container: $ContainerName"
        Write-Host "Base image: $BaseImage"
        
        $dockerArgs = @(
            "run"
            "-it"
            if ($removeFlag) { $removeFlag }
            "--name", $ContainerName
            "-v", "${scriptDir}:C:\setup"
            $BaseImage
            "powershell", "-ExecutionPolicy", "Bypass", "-File", "C:\setup\install-script.ps1"
        ) | Where-Object { $_ -ne $null -and $_ -ne "" }
        
        Write-Host "Running: docker $($dockerArgs -join ' ')"
        
        # Execute the installation in detached mode first
        Write-Host "Running: docker $($dockerArgs -join ' ')"
        & docker @dockerArgs
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Installation completed successfully!" -ForegroundColor Green
            
            # If container was created with --rm, we can't exec into it
            if (-not $KeepContainer) {
                Write-Host "Note: Container was auto-removed after installation completed" -ForegroundColor Yellow
                Write-Host "To keep container for interactive testing, use -KeepContainer switch" -ForegroundColor Yellow
            } else {
                # Now drop into interactive session in the existing container
                Write-Status "Dropping into interactive container session"
                Write-Host "You can now test Ruby and chef-powershell interactively"
                Write-Host "Type 'exit' to leave the container"
                
                $interactiveArgs = @(
                    "exec", "-it", $ContainerName, "powershell"
                )
                
                & docker @interactiveArgs
            }
        } else {
            throw "Container installation failed with exit code: $LASTEXITCODE"
        }
        
    }
    catch {
        Write-Error-Status "Docker container operation failed: $($_.Exception.Message)"
        throw
    }
    finally {
        # Cleanup temp script directory
        if (Test-Path $scriptDir) {
            Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-Usage {
    Write-Host @"
=== Ruby $RubyVersion & chef-powershell $ChefPowerShellVersion Container Test ===

This script will:
1. Create a Windows Server Core 2022 Docker container
2. Install Ruby $RubyVersion using OneClickInstaller2
3. Install chef-powershell gem $ChefPowerShellVersion
4. Drop you into an interactive PowerShell session in the container

Available commands in the container:
  ruby --version                    # Check Ruby version
  gem list chef-powershell         # List chef-powershell gems
  ruby -e "require 'chef/powershell'; puts 'OK'"  # Test gem loading
  
Container name: $ContainerName
Auto-remove: $(-not $KeepContainer)
"@
}

function Main {
    param([string[]]$Arguments)
    
    try {
        Show-Usage
        Write-Status "Starting Ruby $RubyVersion and chef-powershell $ChefPowerShellVersion container test"
        
        # Check Docker availability
        if (-not (Test-DockerAvailable)) {
            throw "Docker is not available. Please ensure Docker Desktop is running."
        }
        
        # Run the Docker container with installation and interactive session
        Run-DockerContainer
        
        Write-Status "Container test completed!" "Green"
    }
    catch {
        Write-Error-Status "Container test failed: $($_.Exception.Message)"
        exit 1
    }
}

# Run main function
Main $args