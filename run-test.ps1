# This script creates Windows containers with different Chef versions and tests them

param(
    # Script to build, run, and test Chef Docker containers
    [string]$ChefVersion1 = "18.8.11",
    [string]$ChefVersion2 = "18.8.46",
    [string]$MsiFile = "",
    [switch]$SingleVersion,
    [switch]$FindDLLs,
    [switch]$UseDumpbin
)

$ErrorActionPreference = "Stop"

# Track if any chef runs failed
$script:chefRunFailed = $false

# Helper function to play sounds
function Play-CompletionSound {
    param([bool]$Success)
    
    if ($Success) {
        # Success sound: Three ascending beeps
        [Console]::Beep(800, 150)
        Start-Sleep -Milliseconds 50
        [Console]::Beep(1000, 150)
        Start-Sleep -Milliseconds 50
        [Console]::Beep(1200, 200)
    }
    else {
        # Failure sound: Two descending beeps
        [Console]::Beep(800, 200)
        Start-Sleep -Milliseconds 100
        [Console]::Beep(400, 300)
    }
}

# Helper function to get DLL list from dumpbin output or use default list
function Get-DllsToFind {
    param([string]$DumpbinOutput)
    
    $defaultDlls = @(
        'KERNEL32.dll',
        'VCRUNTIME140.dll',
        'api-ms-win-crt-runtime-l1-1-0.dll',
        'api-ms-win-crt-heap-l1-1-0.dll',
        'MSVCP140.dll',
        'mscoree.dll'
    )
    
    if ([string]::IsNullOrWhiteSpace($DumpbinOutput)) {
        Write-Host '  Using default DLL list (dumpbin output not available)'
        return $defaultDlls
    }
    
    # Parse dumpbin output to extract DLL dependencies
    Write-Host '  Parsing dumpbin output for DLL dependencies...'
    $dllPattern = '^\s+([a-zA-Z0-9\-\.]+\.dll)'
    $extractedDlls = @()
    
    $DumpbinOutput -split "`n" | ForEach-Object {
        if ($_ -match $dllPattern) {
            $dllName = $matches[1].Trim()
            if ($dllName -and $extractedDlls -notcontains $dllName) {
                $extractedDlls += $dllName
                Write-Host "    Found dependency: $dllName"
            }
        }
    }
    
    if ($extractedDlls.Count -gt 0) {
        Write-Host "  Extracted $($extractedDlls.Count) DLL(s) from dumpbin output"
        return $extractedDlls
    }
    else {
        Write-Host '  No DLLs found in dumpbin output, using default list'
        return $defaultDlls
    }
}

Write-Host "=== Chef Docker Container Test Script ===" -ForegroundColor Cyan

# Determine test mode
$versionsToTest = @()
$useMsi = $false

if ($MsiFile -ne "") {
    # MSI file mode
    if (-not (Test-Path $MsiFile)) {
        Write-Host "ERROR: MSI file not found: $MsiFile" -ForegroundColor Red
        Play-CompletionSound -Success $false
        exit 1
    }
    $useMsi = $true
    $MsiFile = Resolve-Path $MsiFile
    Write-Host "Testing with MSI file: $MsiFile" -ForegroundColor Cyan
    $versionsToTest += @{ Version = "msi"; MsiPath = $MsiFile }
}
elseif ($SingleVersion) {
    # Single version mode
    Write-Host "Testing single Chef version: $ChefVersion1" -ForegroundColor Cyan
    $versionsToTest += @{ Version = $ChefVersion1; MsiPath = "" }
}
else {
    # Two version comparison mode (default)
    Write-Host "Testing Chef versions: $ChefVersion1 vs $ChefVersion2" -ForegroundColor Cyan
    $versionsToTest += @{ Version = $ChefVersion1; MsiPath = "" }
    $versionsToTest += @{ Version = $ChefVersion2; MsiPath = "" }
}

Write-Host ""

# Create shared directory if it doesn't exist
$sharedDir = Join-Path $PSScriptRoot "shared"
if (-not (Test-Path $sharedDir)) {
    Write-Host "Creating shared directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $sharedDir | Out-Null
}

# Clean up shared directory
Write-Host "Cleaning shared directory..." -ForegroundColor Yellow
Get-ChildItem $sharedDir -Filter "chef-*.txt" | Remove-Item -Force

# Clean up Docker environment before testing
Write-Host "`n=== Cleaning Docker Environment ===" -ForegroundColor Green
Write-Host "Pruning Docker system (removing unused containers, networks, images)..." -ForegroundColor Yellow
docker system prune -f

if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: Docker prune failed, continuing anyway..." -ForegroundColor Yellow
}
else {
    Write-Host "Docker environment cleaned successfully" -ForegroundColor Green
}

# Process each version to test
foreach ($versionInfo in $versionsToTest) {
    $version = $versionInfo.Version
    $msiPath = $versionInfo.MsiPath
    
    if ($msiPath -ne "") {
        # MSI installation mode
        Write-Host "`n=== Building Chef MSI container ===" -ForegroundColor Green
        
        # Copy MSI to temporary location
        $tempMsi = Join-Path $PSScriptRoot "chef-installer.msi"
        Copy-Item $msiPath $tempMsi -Force
        
        # Extract version from MSI filename or use "msi" as version
        if ($msiPath -match 'chef-(\d+\.\d+\.\d+)') {
            $extractedVersion = $matches[1]
            $imageTag = "msi-$extractedVersion"
        }
        else {
            $extractedVersion = "msi"
            $imageTag = "msi"
        }

        $installDumpbinArg = if ($UseDumpbin) { "True" } else { "False" }
        Write-Host "INSTALL_DUMPBIN: $installDumpbinArg" 
        docker build -f Dockerfile.msi --build-arg INSTALL_DUMPBIN=$installDumpbinArg -t chef-test:$imageTag .
        Remove-Item $tempMsi -Force
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to build Chef MSI image" -ForegroundColor Red
            Play-CompletionSound -Success $false
            exit 1
        }
        
        # Run pre-check
        Write-Host "`n=== Running Chef MSI container ===" -ForegroundColor Green
        if ($FindDLLs) {
            Write-Host "Verifying Chef installation and searching for DLLs..." -ForegroundColor Yellow
        }
        else {
            Write-Host "Verifying Chef installation..." -ForegroundColor Yellow
        }
        
        $findDllsArg = if ($FindDLLs) { "True" } else { "False" }
        docker run --rm `
            -v "${PWD}\shared:C:\shared" `
            -e FIND_DLLS=$findDllsArg `
            -e INSTALL_DUMPBIN=$installDumpbinArg `
            chef-test:$imageTag `
            powershell -Command {
            Write-Host '=== Chef Installation Verification ==='
            $chefVersion = (chef-client --version) -replace 'Chef Infra Client: ', ''
            Write-Host "Chef Version: $chefVersion"
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $computerName = $env:COMPUTERNAME
                
            $findDlls = $env:FIND_DLLS -eq 'True'
            $useDumpbin = $env:INSTALL_DUMPBIN -eq 'True'
            $dllInfo = ''
                
            if ($findDlls) {
                Write-Host ''
                Write-Host '=== Searching for Chef.PowerShell.Wrapper.dll ==='
                $wrapperDlls = Get-ChildItem -Path 'C:\opscode\chef' -Include 'Chef.PowerShell.Wrapper.dll' -Recurse -ErrorAction SilentlyContinue
                    
                # Initialize dumpbin output variable
                $script:dumpbinOutput = ''
                    
                $wrapperInfo = if ($wrapperDlls) {
                    $wrapperDlls | ForEach-Object {
                        Write-Host "Found: $($_.FullName)"
                        Write-Host "  Size: $($_.Length) bytes"
                        Write-Host "  LastWriteTime: $($_.LastWriteTime)"
                        if ($useDumpbin) {
                            Write-Host ''
                            Write-Host 'Running dumpbin /dependents...'
                            try {
                                $script:dumpbinOutput = & dumpbin.exe /dependents $_.FullName 2>&1 | Out-String
                                Write-Host $script:dumpbinOutput
                                "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)`n`nDumpbin Output:`n$script:dumpbinOutput"
                            }
                            catch {
                                Write-Host "  Error running dumpbin: $($_.Exception.Message)" -ForegroundColor Yellow
                                $script:dumpbinOutput = ''
                                "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)`n`nDumpbin Error: $($_.Exception.Message)"
                            }
                        }
                        else {
                            "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)"
                        }
                        Write-Host ''
                    } | Out-String
                }
                else {
                    Write-Host 'Chef.PowerShell.Wrapper.dll not found'
                    '  Chef.PowerShell.Wrapper.dll not found'
                }
                    
                Write-Host ''
                Write-Host '=== Determining DLLs to search for ==='
                    
                # Define the function inside the script block
                function Get-DllsToFind {
                    param([string]$DumpbinOutput)
                        
                    $defaultDlls = @(
                        'KERNEL32.dll',
                        'VCRUNTIME140.dll',
                        'api-ms-win-crt-runtime-l1-1-0.dll',
                        'api-ms-win-crt-heap-l1-1-0.dll',
                        'MSVCP140.dll',
                        'mscoree.dll'
                    )
                        
                    if ([string]::IsNullOrWhiteSpace($DumpbinOutput)) {
                        Write-Host '  Using default DLL list (dumpbin output not available)'
                        return $defaultDlls
                    }
                        
                    Write-Host '  Parsing dumpbin output for DLL dependencies...'
                    $dllPattern = '^\s+([a-zA-Z0-9\-\.]+\.dll)'
                    $extractedDlls = @()
                        
                    $DumpbinOutput -split "`n" | ForEach-Object {
                        if ($_ -match $dllPattern) {
                            $dllName = $matches[1].Trim()
                            if ($dllName -and $extractedDlls -notcontains $dllName) {
                                $extractedDlls += $dllName
                                Write-Host "    Found dependency: $dllName"
                            }
                        }
                    }
                        
                    if ($extractedDlls.Count -gt 0) {
                        Write-Host "  Extracted $($extractedDlls.Count) DLL(s) from dumpbin output"
                        return $extractedDlls
                    }
                    else {
                        Write-Host '  No DLLs found in dumpbin output, using default list'
                        return $defaultDlls
                    }
                }
                    
                $dllsToFind = Get-DllsToFind -DumpbinOutput $script:dumpbinOutput
                    
                Write-Host ''
                Write-Host '=== Searching for DLLs ==='
                    
                $allDllInfo = ''
                foreach ($dllName in $dllsToFind) {
                    Write-Host "Searching for $dllName..."
                    $foundDlls = Get-ChildItem -Path 'C:\' -Include $dllName -Recurse -ErrorAction SilentlyContinue
                        
                    if ($foundDlls) {
                        $allDllInfo += "$dllName found at:`n"
                        $foundDlls | ForEach-Object {
                            Write-Host "  $($_.FullName)"
                            $allDllInfo += "  $($_.FullName)`n"
                        }
                    }
                    else {
                        Write-Host "  $dllName not found"
                        $allDllInfo += "  $dllName not found`n"
                    }
                }
                    
                $dllInfo = "`n`nChef.PowerShell.Wrapper.dll Search Results (Pre-Chef Run):`n$wrapperInfo`nDLL Search Results:`n$allDllInfo"
            }
                
            $chefClientPath = Get-Command chef-client | Select-Object -ExpandProperty Source
            $output = "Chef Version: $chefVersion`nInstallation Method: MSI`nComputer Name: $computerName`nTimestamp: $timestamp`nChef Client Path: $chefClientPath$dllInfo"
                
            $outputFile = "C:\shared\chef-$chefVersion.txt"
            Write-Host ''
            Write-Host "Writing initial results to $outputFile"
            $output | Out-File -FilePath $outputFile -Encoding UTF8
            Write-Host ''
        }
        
        # Run chef recipe
        Write-Host "Running Chef recipe..." -ForegroundColor Yellow
        docker run --rm `
            -e CHEF_LICENSE=accept-silent `
            -v "${PWD}\shared:C:\shared" `
            -v "${PWD}\cookbooks:C:\cookbooks" `
            chef-test:$imageTag `
            powershell -Command {
            $env:PATH = "$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64\shared\Microsoft.NETCore.App\5.0.0"
            #$env:PATH=$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64
            Write-Host "Path: $env:PATH"
            chef-client -z -o recipe[test_recipe] --chef-license accept-silent
        }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Chef MSI execution failed (will continue to report results)" -ForegroundColor Yellow
            $script:chefRunFailed = $true
        }
        
    }
    else {
        # Omnitruck installation mode
        Write-Host "`n=== Building Chef $version container ===" -ForegroundColor Green
        $installDumpbinArg = if ($UseDumpbin) { "True" } else { "False" }
        docker build --build-arg CHEF_VERSION=$version --build-arg INSTALL_DUMPBIN=$installDumpbinArg -t chef-test:$version .
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to build Chef $version image" -ForegroundColor Red
            Play-CompletionSound -Success $false
            exit 1
        }
        
        Write-Host "`n=== Running Chef $version container ===" -ForegroundColor Green
        
        # First, verify Chef installation and search for DLLs before running chef
        if ($FindDLLs) {
            Write-Host "Verifying Chef installation and searching for DLLs..." -ForegroundColor Yellow
        }
        else {
            Write-Host "Verifying Chef installation..." -ForegroundColor Yellow
        }
        
        $findDllsArg = if ($FindDLLs) { "True" } else { "False" }
        $installDumpbinArg = if ($UseDumpbin) { "True" } else { "False" }
        docker run --rm `
            -v "${PWD}\shared:C:\shared" `
            -e FIND_DLLS=$findDllsArg `
            -e INSTALL_DUMPBIN=$installDumpbinArg `
            chef-test:$version `
            powershell -Command {
            Write-Host '=== Chef Installation Verification ==='
            $chefVersion = (chef-client --version) -replace 'Chef Infra Client: ', ''
            Write-Host "Chef Version: $chefVersion"
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $computerName = $env:COMPUTERNAME
                
            $findDlls = $env:FIND_DLLS -eq 'True'
            $useDumpbin = $env:INSTALL_DUMPBIN -eq 'True'
            $dllInfo = ''
                
            if ($findDlls) {
                Write-Host ''
                Write-Host '=== Searching for Chef.PowerShell.Wrapper.dll ==='
                $wrapperDlls = Get-ChildItem -Path 'C:\opscode\chef' -Include 'Chef.PowerShell.Wrapper.dll' -Recurse -ErrorAction SilentlyContinue
                    
                # Initialize dumpbin output variable
                $script:dumpbinOutput = ''
                    
                $wrapperInfo = if ($wrapperDlls) {
                    $wrapperDlls | ForEach-Object {
                        Write-Host "Found: $($_.FullName)"
                        Write-Host "  Size: $($_.Length) bytes"
                        Write-Host "  LastWriteTime: $($_.LastWriteTime)"
                        if ($useDumpbin) {
                            Write-Host ''
                            Write-Host 'Running dumpbin /dependents...'
                            try {
                                $script:dumpbinOutput = & dumpbin.exe /dependents $_.FullName 2>&1 | Out-String
                                Write-Host $script:dumpbinOutput
                                "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)`n`nDumpbin Output:`n$script:dumpbinOutput"
                            }
                            catch {
                                Write-Host "  Error running dumpbin: $($_.Exception.Message)" -ForegroundColor Yellow
                                $script:dumpbinOutput = ''
                                "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)`n`nDumpbin Error: $($_.Exception.Message)"
                            }
                        }
                        else {
                            "  Path: $($_.FullName)`n  Size: $($_.Length) bytes`n  LastWriteTime: $($_.LastWriteTime)"
                        }
                        Write-Host ''
                    } | Out-String
                }
                else {
                    Write-Host 'Chef.PowerShell.Wrapper.dll not found'
                    '  Chef.PowerShell.Wrapper.dll not found'
                }
                    
                Write-Host ''
                Write-Host '=== Determining DLLs to search for ==='
                    
                # Define the function inside the script block
                function Get-DllsToFind {
                    param([string]$DumpbinOutput)
                        
                    $defaultDlls = @(
                        'KERNEL32.dll',
                        'VCRUNTIME140.dll',
                        'api-ms-win-crt-runtime-l1-1-0.dll',
                        'api-ms-win-crt-heap-l1-1-0.dll',
                        'MSVCP140.dll',
                        'mscoree.dll'
                    )
                        
                    if ([string]::IsNullOrWhiteSpace($DumpbinOutput)) {
                        Write-Host '  Using default DLL list (dumpbin output not available)'
                        return $defaultDlls
                    }
                        
                    Write-Host '  Parsing dumpbin output for DLL dependencies...'
                    $dllPattern = '^\s+([a-zA-Z0-9\-\.]+\.dll)'
                    $extractedDlls = @()
                        
                    $DumpbinOutput -split "`n" | ForEach-Object {
                        if ($_ -match $dllPattern) {
                            $dllName = $matches[1].Trim()
                            if ($dllName -and $extractedDlls -notcontains $dllName) {
                                $extractedDlls += $dllName
                                Write-Host "    Found dependency: $dllName"
                            }
                        }
                    }
                        
                    if ($extractedDlls.Count -gt 0) {
                        Write-Host "  Extracted $($extractedDlls.Count) DLL(s) from dumpbin output"
                        return $extractedDlls
                    }
                    else {
                        Write-Host '  No DLLs found in dumpbin output, using default list'
                        return $defaultDlls
                    }
                }
                    
                $dllsToFind = Get-DllsToFind -DumpbinOutput $script:dumpbinOutput
                    
                Write-Host ''
                Write-Host '=== Searching for DLLs ==='
                    
                $allDllInfo = ''
                foreach ($dllName in $dllsToFind) {
                    Write-Host "Searching for $dllName..."
                    $foundDlls = Get-ChildItem -Path 'C:\' -Include $dllName -Recurse -ErrorAction SilentlyContinue
                        
                    if ($foundDlls) {
                        $allDllInfo += "$dllName found at:`n"
                        $foundDlls | ForEach-Object {
                            Write-Host "  $($_.FullName)"
                            $allDllInfo += "  $($_.FullName)`n"
                        }
                    }
                    else {
                        Write-Host "  $dllName not found"
                        $allDllInfo += "  $dllName not found`n"
                    }
                }
                    
                $dllInfo = "`n`nChef.PowerShell.Wrapper.dll Search Results (Pre-Chef Run):`n$wrapperInfo`nDLL Search Results:`n$allDllInfo"
            }
                
            $chefClientPath = Get-Command chef-client | Select-Object -ExpandProperty Source
            $output = "Chef Version: $chefVersion`nInstallation Method: Omnitruck`nComputer Name: $computerName`nTimestamp: $timestamp`nChef Client Path: $chefClientPath$dllInfo"
                
            $outputFile = "C:\shared\chef-$chefVersion.txt"
            Write-Host ''
            Write-Host "Writing initial results to $outputFile"
            $output | Out-File -FilePath $outputFile -Encoding UTF8
            Write-Host ''
        }
        
        # Now run the actual chef recipe
        Write-Host "Running Chef recipe..." -ForegroundColor Yellow
        docker run --rm `
            -e CHEF_LICENSE=accept-silent `
            -v "${PWD}\shared:C:\shared" `
            -v "${PWD}\cookbooks:C:\cookbooks" `
            chef-test:$version `
            powershell -Command {
            $env:PATH = $env:PATH; C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64; C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64\shared\Microsoft.NETCore.App\5.0.0
            #$env:PATH=$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64
            Write-Host "Path: $env:PATH"
            chef-client -z -o recipe[test_recipe] --chef-license accept-silent
        } 
            
            
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Chef $version execution failed (will continue to report results)" -ForegroundColor Yellow
            $script:chefRunFailed = $true
        }
    }
}

# Check results
Write-Host "`n=== Checking Results on Shared Volume ===" -ForegroundColor Cyan
Write-Host ""

$results = Get-ChildItem $sharedDir -Filter "chef-*.txt"

if ($results.Count -eq 0) {
    Write-Host "ERROR: No output files found in shared directory!" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

Write-Host "Found $($results.Count) output file(s):" -ForegroundColor Green
Write-Host ""

foreach ($file in $results) {
    Write-Host "=== Contents of $($file.Name) ===" -ForegroundColor Yellow
    Get-Content $file.FullName
    Write-Host ""
}

# Summary
Write-Host "=== Test Summary ===" -ForegroundColor Cyan

if ($SingleVersion) {
    Write-Host "Expected Chef version: $ChefVersion1" -ForegroundColor White
}
elseif ($MsiFile -ne "") {
    Write-Host "Tested Chef MSI: $MsiFile" -ForegroundColor White
}
else {
    Write-Host "Expected Chef versions: $ChefVersion1 and $ChefVersion2" -ForegroundColor White
}

$foundVersions = @()
foreach ($file in $results) {
    if ($file.Name -match 'chef-(\d+\.\d+\.\d+)\.txt') {
        $foundVersions += $matches[1]
    }
}

Write-Host "Found Chef versions: $($foundVersions -join ', ')" -ForegroundColor White

# Determine success status
$success = $false

if ($SingleVersion) {
    if ($foundVersions -contains $ChefVersion1) {
        Write-Host "`nSUCCESS: Chef version executed successfully!" -ForegroundColor Green
        $success = $true
    }
    else {
        Write-Host "`nWARNING: Expected version not found" -ForegroundColor Yellow
    }
}
elseif ($MsiFile -ne "") {
    if ($foundVersions.Count -gt 0) {
        Write-Host "`nSUCCESS: Chef MSI executed successfully!" -ForegroundColor Green
        $success = $true
    }
    else {
        Write-Host "`nWARNING: No version output found" -ForegroundColor Yellow
    }
}
else {
    if ($foundVersions -contains $ChefVersion1 -and $foundVersions -contains $ChefVersion2) {
        Write-Host "`nSUCCESS: Both Chef versions executed successfully!" -ForegroundColor Green
        $success = $true
    }
    else {
        Write-Host "`nWARNING: Not all expected versions found" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Test Complete ===" -ForegroundColor Cyan

# Check if any chef runs failed and report
if ($script:chefRunFailed) {
    Write-Host "`nWARNING: One or more Chef runs encountered errors!" -ForegroundColor Red
    Write-Host "However, DLL search and reporting completed successfully." -ForegroundColor Yellow
    $success = $false
}

# Play completion sound
Play-CompletionSound -Success $success

# Exit with error code if chef run failed
if ($script:chefRunFailed) {
    exit 1
}
