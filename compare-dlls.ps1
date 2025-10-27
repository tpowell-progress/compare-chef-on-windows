# Script to compare DLL state before and after dumpbin installation
# This script installs Chef from MSI, captures DLL checksums pre/post dumpbin installation

param(
    [Parameter(Mandatory=$true)]
    [string]$MsiFile
)

$ErrorActionPreference = "Stop"

Write-Host "=== Chef DLL Comparison Script ===" -ForegroundColor Cyan
Write-Host ""

# Validate MSI file exists
if (-not (Test-Path $MsiFile)) {
    Write-Host "ERROR: MSI file not found: $MsiFile" -ForegroundColor Red
    exit 1
}

$MsiFile = Resolve-Path $MsiFile
Write-Host "Using MSI file: $MsiFile" -ForegroundColor Green

# Extract version from MSI filename
if ($MsiFile -match 'chef-(\d+\.\d+\.\d+)') {
    $extractedVersion = $matches[1]
    $imageTag = "dll-compare-$extractedVersion"
} else {
    $extractedVersion = "unknown"
    $imageTag = "dll-compare"
}

Write-Host "Image tag: $imageTag" -ForegroundColor Yellow
Write-Host ""

# Create shared directory if it doesn't exist
$sharedDir = Join-Path $PSScriptRoot "shared"
if (-not (Test-Path $sharedDir)) {
    Write-Host "Creating shared directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $sharedDir | Out-Null
}

# Clean up old comparison files
Write-Host "Cleaning old comparison files..." -ForegroundColor Yellow
Get-ChildItem $sharedDir -Filter "*dumpbin.txt" | Remove-Item -Force

# Create Dockerfile for this comparison
$dockerfileContent = @'
# escape=`
FROM mcr.microsoft.com/windows/servercore:ltsc2022

# Set up PowerShell execution policy
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Copy MSI file to container
COPY chef-installer.msi C:\chef-installer.msi

# Install Chef from MSI
RUN Write-Host 'Installing Chef from MSI...'; `
    Start-Process msiexec.exe -ArgumentList '/i', 'C:\chef-installer.msi', '/qn', '/norestart' -Wait; `
    Remove-Item C:\chef-installer.msi -Force

# Accept Chef license
ENV CHEF_LICENSE=accept-silent

# Set working directory
WORKDIR C:\

CMD ["powershell"]
'@

$dockerfilePath = Join-Path $PSScriptRoot "Dockerfile.dll-compare"
Write-Host "Creating temporary Dockerfile: $dockerfilePath" -ForegroundColor Yellow
$dockerfileContent | Out-File -FilePath $dockerfilePath -Encoding ASCII

# Copy MSI to temporary location
$tempMsi = Join-Path $PSScriptRoot "chef-installer.msi"
Write-Host "Copying MSI to temporary location..." -ForegroundColor Yellow
Copy-Item $MsiFile $tempMsi -Force

# Build Docker image
Write-Host "`n=== Building Docker image ===" -ForegroundColor Green
docker build -f $dockerfilePath -t chef-dll-compare:$imageTag .

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build Docker image" -ForegroundColor Red
    Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
    Remove-Item $dockerfilePath -Force -ErrorAction SilentlyContinue
    exit 1
}

# Clean up temporary files
Remove-Item $tempMsi -Force
Remove-Item $dockerfilePath -Force

# Run pre-dumpbin analysis
Write-Host "`n=== Running Pre-Dumpbin Analysis ===" -ForegroundColor Green
docker run --rm `
    -v "${PWD}\shared:C:\shared" `
    chef-dll-compare:$imageTag `
    powershell -Command {
        Write-Host 'Verifying dumpbin is not installed...'
        $dumpbinCheck = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
        if ($dumpbinCheck) {
            Write-Host 'ERROR: dumpbin.exe is already available in PATH!' -ForegroundColor Red
            Write-Host "  Location: $($dumpbinCheck.Source)"
            exit 1
        }
        Write-Host '  Confirmed: dumpbin.exe is NOT in PATH'
        Write-Host ''
        
        Write-Host 'Collecting DLL information before dumpbin installation...'
        Write-Host ''
        
        $dllsToFind = @(
            'KERNEL32.dll',
            'VCRUNTIME140.dll',
            'api-ms-win-crt-runtime-l1-1-0.dll',
            'api-ms-win-crt-heap-l1-1-0.dll',
            'MSVCP140.dll',
            'mscoree.dll'
        )
        
        $output = "=== DLL Information BEFORE Dumpbin Installation ===`n"
        $output += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
        $output += "Computer: $env:COMPUTERNAME`n"
        $output += "Dumpbin Status: NOT INSTALLED (verified)`n`n"
        
        foreach ($dllName in $dllsToFind) {
            Write-Host "Searching for $dllName..."
            $foundDlls = Get-ChildItem -Path 'C:\' -Include $dllName -Recurse -ErrorAction SilentlyContinue
            
            $output += "=== $dllName ===`n"
            
            if ($foundDlls) {
                foreach ($dll in $foundDlls) {
                    Write-Host "  Found: $($dll.FullName)"
                    $output += "Path: $($dll.FullName)`n"
                    $output += "Size: $($dll.Length) bytes`n"
                    $output += "LastWriteTime: $($dll.LastWriteTime)`n"
                    
                    # Calculate checksums
                    try {
                        $md5 = (Get-FileHash -Path $dll.FullName -Algorithm MD5).Hash
                        $sha256 = (Get-FileHash -Path $dll.FullName -Algorithm SHA256).Hash
                        $output += "MD5: $md5`n"
                        $output += "SHA256: $sha256`n"
                        Write-Host "    MD5: $md5"
                        Write-Host "    SHA256: $sha256"
                    } catch {
                        $output += "Error calculating checksums: $($_.Exception.Message)`n"
                        Write-Host "    Error calculating checksums: $($_.Exception.Message)" -ForegroundColor Red
                    }
                    
                    $output += "`n"
                }
            } else {
                Write-Host "  $dllName not found"
                $output += "Not found`n`n"
            }
        }
        
        $outputFile = "C:\shared\predumpbin.txt"
        Write-Host ''
        Write-Host "Writing results to $outputFile"
        $output | Out-File -FilePath $outputFile -Encoding UTF8
        Write-Host "Pre-dumpbin analysis complete!"
    }

if ($LASTEXITCODE -ne 0) {
    Write-Host "Pre-dumpbin analysis failed" -ForegroundColor Red
    exit 1
}

# Install dumpbin and run post-dumpbin analysis
Write-Host "`n=== Installing Dumpbin and Running Post-Dumpbin Analysis ===" -ForegroundColor Green
docker run --rm `
    -v "${PWD}\shared:C:\shared" `
    chef-dll-compare:$imageTag `
    powershell -Command {
        Write-Host 'Installing Visual Studio Build Tools for dumpbin...'
        Write-Host ''
        
        # Download and install VS Build Tools
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile 'vs_buildtools.exe'
        Write-Host 'Running VS Build Tools installer (this will take several minutes)...'
        Start-Process vs_buildtools.exe -ArgumentList '--quiet', '--wait', '--norestart', '--nocache', '--installPath', "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\", '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended' -Wait
        Remove-Item vs_buildtools.exe -Force
        
        # Add dumpbin to PATH
        $vsPath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'
        
        if (-not (Test-Path $vsPath)) {
            Write-Host 'ERROR: Visual Studio MSVC path not found after installation!' -ForegroundColor Red
            Write-Host "  Expected path: $vsPath"
            exit 1
        }
        
        $msvcVersion = (Get-ChildItem $vsPath | Sort-Object Name -Descending | Select-Object -First 1).Name
        $dumpbinPath = Join-Path (Join-Path (Join-Path $vsPath $msvcVersion) 'bin\Hostx64') 'x64'
        $dumpbinExe = Join-Path $dumpbinPath 'dumpbin.exe'
        
        Write-Host "Looking for dumpbin at: $dumpbinExe"
        
        if (-not (Test-Path $dumpbinExe)) {
            Write-Host 'ERROR: dumpbin.exe NOT found at expected location!' -ForegroundColor Red
            Write-Host "  Expected: $dumpbinExe"
            Write-Host "  Checking alternate locations..."
            $allDumpbins = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Microsoft Visual Studio" -Include 'dumpbin.exe' -Recurse -ErrorAction SilentlyContinue
            if ($allDumpbins) {
                Write-Host "  Found dumpbin.exe at:"
                $allDumpbins | ForEach-Object { Write-Host "    $($_.FullName)" }
            }
            exit 1
        }
        
        $env:PATH = $env:PATH + ';' + $dumpbinPath
        Write-Host "  Confirmed: dumpbin.exe exists at $dumpbinExe"
        Write-Host "  Added to PATH: $dumpbinPath"
        Write-Host "  Version: $(& $dumpbinExe 2>&1 | Select-Object -First 1)"
        Write-Host ''
        
        Write-Host 'Collecting DLL information after dumpbin installation...'
        Write-Host ''
        
        $dllsToFind = @(
            'KERNEL32.dll',
            'VCRUNTIME140.dll',
            'api-ms-win-crt-runtime-l1-1-0.dll',
            'api-ms-win-crt-heap-l1-1-0.dll',
            'MSVCP140.dll',
            'mscoree.dll'
        )
        
        $output = "=== DLL Information AFTER Dumpbin Installation ===`n"
        $output += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
        $output += "Computer: $env:COMPUTERNAME`n"
        $dumpbinInfo = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
        if ($dumpbinInfo) {
            $output += "Dumpbin Status: INSTALLED (verified)`n"
            $output += "Dumpbin Location: $($dumpbinInfo.Source)`n"
        } else {
            $output += "Dumpbin Status: NOT FOUND (unexpected!)`n"
        }
        $output += "`n"
        
        foreach ($dllName in $dllsToFind) {
            Write-Host "Searching for $dllName..."
            $foundDlls = Get-ChildItem -Path 'C:\' -Include $dllName -Recurse -ErrorAction SilentlyContinue
            
            $output += "=== $dllName ===`n"
            
            if ($foundDlls) {
                foreach ($dll in $foundDlls) {
                    Write-Host "  Found: $($dll.FullName)"
                    $output += "Path: $($dll.FullName)`n"
                    $output += "Size: $($dll.Length) bytes`n"
                    $output += "LastWriteTime: $($dll.LastWriteTime)`n"
                    
                    # Calculate checksums
                    try {
                        $md5 = (Get-FileHash -Path $dll.FullName -Algorithm MD5).Hash
                        $sha256 = (Get-FileHash -Path $dll.FullName -Algorithm SHA256).Hash
                        $output += "MD5: $md5`n"
                        $output += "SHA256: $sha256`n"
                        Write-Host "    MD5: $md5"
                        Write-Host "    SHA256: $sha256"
                    } catch {
                        $output += "Error calculating checksums: $($_.Exception.Message)`n"
                        Write-Host "    Error calculating checksums: $($_.Exception.Message)" -ForegroundColor Red
                    }
                    
                    $output += "`n"
                }
            } else {
                Write-Host "  $dllName not found"
                $output += "Not found`n`n"
            }
        }
        
        $outputFile = "C:\shared\postdumpbin.txt"
        Write-Host ''
        Write-Host "Writing results to $outputFile"
        $output | Out-File -FilePath $outputFile -Encoding UTF8
        Write-Host "Post-dumpbin analysis complete!"
    }

if ($LASTEXITCODE -ne 0) {
    Write-Host "Post-dumpbin analysis failed" -ForegroundColor Red
    exit 1
}

# Display results
Write-Host "`n=== Comparison Complete ===" -ForegroundColor Cyan
Write-Host ""

$preFile = Join-Path $sharedDir "predumpbin.txt"
$postFile = Join-Path $sharedDir "postdumpbin.txt"

if (Test-Path $preFile) {
    Write-Host "=== Pre-Dumpbin Results ===" -ForegroundColor Yellow
    Get-Content $preFile
    Write-Host ""
}

if (Test-Path $postFile) {
    Write-Host "=== Post-Dumpbin Results ===" -ForegroundColor Yellow
    Get-Content $postFile
    Write-Host ""
}

# Compare files
Write-Host "=== Comparison Summary ===" -ForegroundColor Cyan

if ((Test-Path $preFile) -and (Test-Path $postFile)) {
    $preContent = Get-Content $preFile -Raw
    $postContent = Get-Content $postFile -Raw
    
    if ($preContent -eq $postContent) {
        Write-Host "No differences detected - DLL checksums are identical before and after dumpbin installation" -ForegroundColor Green
    } else {
        Write-Host "Differences detected - comparing files..." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "You can manually compare the files:" -ForegroundColor White
        Write-Host "  Pre-dumpbin:  $preFile" -ForegroundColor White
        Write-Host "  Post-dumpbin: $postFile" -ForegroundColor White
    }
} else {
    Write-Host "Could not perform comparison - one or both output files are missing" -ForegroundColor Red
}

Write-Host "`n=== Script Complete ===" -ForegroundColor Cyan
