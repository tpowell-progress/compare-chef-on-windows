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
    chef-powershell gem version (default: latest)

.PARAMETER ChefPowerShellGemPath
    Path to local chef-powershell*.gem file to install instead of downloading from RubyGems

.PARAMETER ContainerName
    Name for the Docker container (default: ruby-chef-ps-test)

.PARAMETER KeepContainer
    Keep the container after exit (don't auto-remove)

.EXAMPLE
    .\run-ruby-test.ps1
    .\run-ruby-test.ps1 -RubyVersion "3.1.6" -ChefPowerShellVersion "3.1.6"
    .\run-ruby-test.ps1 -ChefPowerShellVersion "latest"
    .\run-ruby-test.ps1 -ChefPowerShellGemPath "C:\path\to\chef-powershell-3.2.0.gem"
    .\run-ruby-test.ps1 -ContainerName "my-ruby-test" -KeepContainer
#>

param(
    [string]$RubyVersion = "3.1.7",
    [string]$ChefPowerShellVersion = "latest",
    [string]$ChefPowerShellGemPath,
    [string]$ContainerName = "ruby-chef-ps-test",
    [switch]$KeepContainer
)

$ErrorActionPreference = "Stop"

# Configuration
$BaseImage = "mcr.microsoft.com/windows/servercore:ltsc2022"
$RubyImageTag = "ruby-devkit:$RubyVersion-windows"
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

function Test-RubyImageExists {
    param([string]$ImageTag)
    
    try {
        $images = docker images --format "table {{.Repository}}:{{.Tag}}" | Select-String -Pattern "^$ImageTag$"
        if ($images) {
            Write-Host "Found existing Ruby image: $ImageTag" -ForegroundColor Green
            return $true
        }
        Write-Host "Ruby image $ImageTag not found, will build new image" -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "Error checking for Ruby image: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Build-RubyImage {
    param([string]$ImageTag)
    
    Write-Status "Building Ruby $RubyVersion Docker image using commit approach"
    
    try {
        # Create a temporary container name for building
        $buildContainerName = "ruby-build-temp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        
        # Create installation script
        $buildScript = Create-RubyInstallationScript
        $scriptDir = Join-Path $env:TEMP "ruby-build-setup"
        if (-not (Test-Path $scriptDir)) {
            New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        }
        
        $scriptPath = Join-Path $scriptDir "install-ruby.ps1"
        $buildScript | Out-File -FilePath $scriptPath -Encoding UTF8
        
        Write-Host "Created Ruby installation script at: $scriptPath"
        Write-Host "Starting build container: $buildContainerName"
        
        # Run container to install Ruby
        $dockerArgs = @(
            "run"
            "--name", $buildContainerName
            "-v", "${scriptDir}:C:\setup"
            $BaseImage
            "powershell", "-ExecutionPolicy", "Bypass", "-File", "C:\setup\install-ruby.ps1"
        )
        
        Write-Host "Running: docker $($dockerArgs -join ' ')"
        & docker @dockerArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Ruby installation in build container failed with exit code: $LASTEXITCODE"
        }
        
        Write-Host "Ruby installation completed, committing container as image..."
        
        # Commit the container as a new image
        & docker commit $buildContainerName $ImageTag
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit container as image with exit code: $LASTEXITCODE"
        }
        
        Write-Status "Ruby image $ImageTag created successfully" "Green"
        return $true
        
    }
    catch {
        Write-Error-Status "Failed to build Ruby image: $($_.Exception.Message)"
        throw
    }
    finally {
        # Cleanup build container and temp files
        if ($buildContainerName) {
            docker rm -f $buildContainerName 2>$null | Out-Null
        }
        if (Test-Path $scriptDir) {
            Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Create-RubyInstallationScript {
    Write-Status "Creating Ruby installation script for image building"
    
    $installScript = @"
# Ruby installation script for image building
Write-Host "=== Starting Ruby $RubyVersion installation for image ==="

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
[Environment]::SetEnvironmentVariable("PATH", [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";`$rubyBinPath", "Machine")

# Verify Ruby installation
try {
    if (Test-Path "`$rubyBinPath\ruby.exe") {
        Write-Host "Ruby executable verified at: `$rubyBinPath\ruby.exe" -ForegroundColor Green
    } else {
        throw "Ruby executable not found at expected location"
    }
} catch {
    Write-Host "Warning: Could not verify Ruby installation" -ForegroundColor Yellow
    exit 1
}

# Cleanup installer
Remove-Item `$installerPath -Force -ErrorAction SilentlyContinue

Write-Host "=== Ruby $RubyVersion installation for image completed successfully ==="
"@

    return $installScript
}

function Create-InstallationScript {
    Write-Status "Creating chef-powershell installation script"
    
    $installScript = @"
# chef-powershell installation script for container
Write-Host "=== Starting chef-powershell $ChefPowerShellVersion installation ==="

# Set Ruby path
`$rubyBinPath = "$RubyInstallPath\bin"
`$env:PATH = "`$rubyBinPath;`$env:PATH"

# Verify Ruby installation
Write-Host "Verifying Ruby installation..."
try {
    `$rubyVersion = & "`$rubyBinPath\ruby.exe" --version
    Write-Host "Ruby verification: `$rubyVersion" -ForegroundColor Green
} catch {
    Write-Host "Error: Ruby not found in image" -ForegroundColor Red
    exit 1
}

# Install chef-powershell gem
if ("$ChefPowerShellGemPath" -ne "") {
    Write-Host "Installing chef-powershell from local gem file: $ChefPowerShellGemPath..."
    if (Test-Path "C:\setup\chef-powershell.gem") {
        try {
            & "`$rubyBinPath\gem.cmd" install "C:\setup\chef-powershell.gem" --no-document --quiet --no-verbose --force
            Write-Host "chef-powershell gem installed from local file successfully!" -ForegroundColor Green
        } catch {
            Write-Host "Failed to install chef-powershell gem from local file: `$(`$_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "Error: Local gem file not found at C:\setup\chef-powershell.gem" -ForegroundColor Red
        exit 1
    }
} elseif ("$ChefPowerShellVersion" -eq "latest") {
    Write-Host "Installing latest chef-powershell gem..."
    try {
        & "`$rubyBinPath\gem.cmd" install chef-powershell --no-document --quiet --no-verbose
        Write-Host "chef-powershell gem (latest) installed successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to install chef-powershell gem: `$(`$_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Installing chef-powershell gem $ChefPowerShellVersion..."
    try {
        & "`$rubyBinPath\gem.cmd" install chef-powershell -v $ChefPowerShellVersion --no-document --quiet --no-verbose
        Write-Host "chef-powershell gem $ChefPowerShellVersion installed successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to install chef-powershell gem: `$(`$_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Test installation using external test file
Write-Host "Running chef-powershell test suite..."
try {
    `$gemList = & "`$rubyBinPath\gem.cmd" list chef-powershell
    Write-Host "Installed gems: `$gemList" -ForegroundColor Cyan
    
    # Run external test file
    Write-Host "Executing test-chef-ps.rb test suite..."
    if (Test-Path "C:\setup\test-chef-ps.rb") {
        `$testResult = & "`$rubyBinPath\ruby.exe" "C:\setup\test-chef-ps.rb"
        Write-Host "Test suite completed" -ForegroundColor Green
    } else {
        Write-Host "Warning: test-chef-ps.rb not found, running basic test..." -ForegroundColor Yellow
        `$basicTest = & "`$rubyBinPath\ruby.exe" -e "require 'chef/powershell'; puts 'chef-powershell loaded successfully'"
        Write-Host "Basic test result: `$basicTest" -ForegroundColor Green
    }
} catch {
    Write-Host "chef-powershell test failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow
}

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
    Write-Status "Setting up Ruby $RubyVersion container"
    
    try {
        # Check if Ruby image exists, build if needed
        if (-not (Test-RubyImageExists -ImageTag $RubyImageTag)) {
            Build-RubyImage -ImageTag $RubyImageTag
        }
        
        # Check if container already exists and remove it
        $existingContainer = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
        if ($existingContainer -eq $ContainerName) {
            Write-Host "Removing existing container: $ContainerName"
            docker rm -f $ContainerName 2>$null | Out-Null
        }
        
        # Create chef-powershell installation script in a dedicated directory
        $scriptDir = Join-Path $env:TEMP "ruby-container-setup"
        if (-not (Test-Path $scriptDir)) {
            New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        }
        
        # Copy the test file to the shared directory
        $scriptLocation = $PSScriptRoot
        if (-not $scriptLocation) {
            $scriptLocation = Split-Path -Parent $MyInvocation.MyCommand.Definition
        }
        if (-not $scriptLocation) {
            $scriptLocation = Get-Location
        }
        
        $testFilePath = Join-Path $scriptLocation "test-chef-ps.rb"
        $targetTestPath = Join-Path $scriptDir "test-chef-ps.rb"
        
        if (Test-Path $testFilePath) {
            Copy-Item $testFilePath $targetTestPath -Force
            Write-Host "Copied test-chef-ps.rb to shared volume"
        } else {
            Write-Host "Warning: test-chef-ps.rb not found at $testFilePath" -ForegroundColor Yellow
            Write-Host "Searched in: $scriptLocation" -ForegroundColor Yellow
        }
        
        # Copy local gem file if specified
        if ($ChefPowerShellGemPath) {
            if (Test-Path $ChefPowerShellGemPath) {
                $targetGemPath = Join-Path $scriptDir "chef-powershell.gem"
                Copy-Item $ChefPowerShellGemPath $targetGemPath -Force
                Write-Host "Copied local gem file to shared volume: $ChefPowerShellGemPath"
            } else {
                Write-Error-Status "Local gem file not found: $ChefPowerShellGemPath"
                throw "Gem file path specified but file does not exist"
            }
        }
        
        $installScript = Create-InstallationScript
        $scriptPath = Join-Path $scriptDir "install-script.ps1"
        $installScript | Out-File -FilePath $scriptPath -Encoding UTF8
        
        Write-Host "Created chef-powershell installation script at: $scriptPath"
        
        # Determine removal flag
        $removeFlag = if ($KeepContainer) { "" } else { "--rm" }
        
        # Run container with installation script using pre-built Ruby image
        Write-Host "Starting container: $ContainerName"
        Write-Host "Ruby image: $RubyImageTag"
        
        $dockerArgs = @(
            "run"
            "-it"
            if ($removeFlag) { $removeFlag }
            "--name", $ContainerName
            "-v", "${scriptDir}:C:\setup"
            $RubyImageTag
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
    $gemSource = if ($ChefPowerShellGemPath) { 
        "local gem file: $ChefPowerShellGemPath" 
    } else { 
        "version $ChefPowerShellVersion from RubyGems" 
    }
    
    Write-Host @"
=== Ruby $RubyVersion & chef-powershell Container Test ===

This script will:
1. Check for existing Ruby $RubyVersion Docker image (builds if needed)
2. Run container with pre-installed Ruby $RubyVersion + Devkit
3. Install chef-powershell gem from $gemSource
4. Run comprehensive test suite (test-chef-ps.rb)
5. Drop you into an interactive PowerShell session in the container

Available commands in the container:
  ruby --version                    # Check Ruby version
  gem list chef-powershell         # List chef-powershell gems
  ruby test-chef-ps.rb             # Run comprehensive test suite
  ruby -e "require 'chef/powershell'; puts 'OK'"  # Quick test
  
Ruby image: $RubyImageTag
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