# Script to test Chef PowerShell DLL error and gem pristine remediation
param(
    [string]$MsiFile = "omnibus-ruby_chef_pkg_chef-client-18.8.50-1-x64.msi"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Chef PowerShell DLL Error Detection and Gem Pristine Remediation Test ===" -ForegroundColor Cyan
Write-Host "MSI File: $MsiFile" -ForegroundColor Yellow
Write-Host ""

# Verify MSI file exists
if (-not (Test-Path $MsiFile)) {
    Write-Host "ERROR: MSI file not found: $MsiFile" -ForegroundColor Red
    exit 1
}

# Create shared directory if it doesn't exist
$sharedDir = Join-Path $PSScriptRoot "shared"
if (-not (Test-Path $sharedDir)) {
    Write-Host "Creating shared directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $sharedDir | Out-Null
}

# Clean up any previous test files
Write-Host "Cleaning previous test files..." -ForegroundColor Yellow
Get-ChildItem $sharedDir -Filter "*dll-remediation*" | Remove-Item -Force -ErrorAction SilentlyContinue

# Copy MSI to temporary location for Docker build
Write-Host "Preparing MSI for Docker build..." -ForegroundColor Yellow
$tempMsi = Join-Path $PSScriptRoot "chef-installer.msi"
Copy-Item $MsiFile $tempMsi -Force

try {
    # Clean up Docker environment before building
    Write-Host "`n=== Cleaning Docker Environment ===" -ForegroundColor Green
    Write-Host "Pruning Docker system (removing unused containers, networks, images)..." -ForegroundColor Yellow
    docker system prune -f
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: Docker prune failed, continuing anyway..." -ForegroundColor Yellow
    }
    else {
        Write-Host "Docker environment cleaned successfully" -ForegroundColor Green
    }

    # Build Docker image with MSI install
    Write-Host "`n=== Building Chef MSI Docker Image ===" -ForegroundColor Green
    docker build -f Dockerfile.msi --build-arg INSTALL_DUMPBIN=False -t chef-dll-test:latest .
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build Chef MSI image" -ForegroundColor Red
        exit 1
    }

    # Create comprehensive test script
    $testScript = @'
Write-Host "======================================================================="
Write-Host "Chef PowerShell DLL Error Detection and Remediation Test"
Write-Host "======================================================================="

$testResults = @{
    Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    PrePristineTest = @{
        Success = $false
        Error = ""
        Output = ""
        DllExists = $false
        DllPath = ""
    }
    GemPristineOperation = @{
        Success = $false
        Error = ""
        Output = ""
    }
    PostPristineTest = @{
        Success = $false
        Error = ""
        Output = ""
        DllExists = $false
        DllPath = ""
    }
    FileSystemChanges = @{
        FilesChanged = @()
        FilesAdded = @()
        FilesRemoved = @()
    }
}

Write-Host ""
Write-Host "=== Phase 1: Pre-Pristine DLL and Chef Test ==="

# Check if DLL exists before testing
$dllPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.6.3\bin\ruby_bin_folder\AMD64\Chef.PowerShell.Wrapper.dll"
if (Test-Path $dllPath) {
    Write-Host "✓ Chef.PowerShell.Wrapper.dll found at: $dllPath"
    $testResults.PrePristineTest.DllExists = $true
    $testResults.PrePristineTest.DllPath = $dllPath
    
    # Check DLL properties
    $dllInfo = Get-Item $dllPath
    Write-Host "  Size: $($dllInfo.Length) bytes"
    Write-Host "  LastWriteTime: $($dllInfo.LastWriteTime)"
    
    # Try to get file version info if available
    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath)
        Write-Host "  File Version: $($versionInfo.FileVersion)"
        Write-Host "  Product Version: $($versionInfo.ProductVersion)"
    } catch {
        Write-Host "  Version info not available: $($_.Exception.Message)"
    }
} else {
    Write-Host "✗ Chef.PowerShell.Wrapper.dll NOT found at: $dllPath"
    $testResults.PrePristineTest.DllExists = $false
}

Write-Host ""
Write-Host "Testing Chef PowerShell functionality (Pre-Pristine)..."

# Capture initial gem directory state
$initialFiles = @{}
$gemDir = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.6.3"
if (Test-Path $gemDir) {
    Get-ChildItem -Path $gemDir -Recurse -Force | ForEach-Object {
        $relativePath = $_.FullName.Replace($gemDir, "")
        $initialFiles[$relativePath] = @{
            Size = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
            LastWriteTime = $_.LastWriteTime
            IsDirectory = $_.PSIsContainer
        }
    }
}

# Test Chef with PowerShell recipe
try {
    Write-Host "Executing: chef-client -z -o recipe[test_recipe] --chef-license accept-silent"
    $chefOutput = & chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1 | Out-String
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Chef run completed successfully (Pre-Pristine)" -ForegroundColor Green
        $testResults.PrePristineTest.Success = $true
        $testResults.PrePristineTest.Output = $chefOutput
    } else {
        Write-Host "✗ Chef run failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        $testResults.PrePristineTest.Success = $false
        $testResults.PrePristineTest.Error = "Exit code: $LASTEXITCODE"
        $testResults.PrePristineTest.Output = $chefOutput
        
        # Check for specific DLL error
        if ($chefOutput -match "Could not open library.*Chef\.PowerShell\.Wrapper\.dll.*Failed with error 126") {
            Write-Host "✗ DETECTED: Chef.PowerShell.Wrapper.dll loading error (Error 126 - Module not found)" -ForegroundColor Red
            $testResults.PrePristineTest.Error = "DLL Error 126: Chef.PowerShell.Wrapper.dll could not be loaded"
        }
    }
} catch {
    Write-Host "✗ Chef execution failed with exception: $($_.Exception.Message)" -ForegroundColor Red
    $testResults.PrePristineTest.Success = $false
    $testResults.PrePristineTest.Error = $_.Exception.Message
}

Write-Host ""
Write-Host "=== Phase 2: Gem Pristine Operation ==="

# Run gem pristine chef-powershell
try {
    Write-Host "Executing: gem pristine chef-powershell"
    $pristineOutput = & "C:\opscode\chef\embedded\bin\gem" pristine chef-powershell 2>&1 | Out-String
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Gem pristine completed successfully" -ForegroundColor Green
        $testResults.GemPristineOperation.Success = $true
        $testResults.GemPristineOperation.Output = $pristineOutput
    } else {
        Write-Host "✗ Gem pristine failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        $testResults.GemPristineOperation.Success = $false
        $testResults.GemPristineOperation.Error = "Exit code: $LASTEXITCODE"
        $testResults.GemPristineOperation.Output = $pristineOutput
    }
    
    Write-Host "Gem pristine output:"
    Write-Host $pristineOutput
} catch {
    Write-Host "✗ Gem pristine failed with exception: $($_.Exception.Message)" -ForegroundColor Red
    $testResults.GemPristineOperation.Success = $false
    $testResults.GemPristineOperation.Error = $_.Exception.Message
}

Write-Host ""
Write-Host "=== Phase 3: Post-Pristine DLL and Chef Test ==="

# Check if DLL exists after pristine
if (Test-Path $dllPath) {
    Write-Host "✓ Chef.PowerShell.Wrapper.dll found at: $dllPath (Post-Pristine)"
    $testResults.PostPristineTest.DllExists = $true
    $testResults.PostPristineTest.DllPath = $dllPath
    
    # Check if DLL was modified
    $dllInfoPost = Get-Item $dllPath
    Write-Host "  Size: $($dllInfoPost.Length) bytes"
    Write-Host "  LastWriteTime: $($dllInfoPost.LastWriteTime)"
    
    if ($testResults.PrePristineTest.DllExists) {
        $preTime = [DateTime]::Parse("$($dllInfo.LastWriteTime)")
        $postTime = [DateTime]::Parse("$($dllInfoPost.LastWriteTime)")
        if ($postTime -gt $preTime) {
            Write-Host "  ✓ DLL was updated by gem pristine" -ForegroundColor Green
        } else {
            Write-Host "  ◦ DLL timestamp unchanged" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "✗ Chef.PowerShell.Wrapper.dll NOT found at: $dllPath (Post-Pristine)"
    $testResults.PostPristineTest.DllExists = $false
}

# Capture file system changes
if (Test-Path $gemDir) {
    Get-ChildItem -Path $gemDir -Recurse -Force | ForEach-Object {
        $relativePath = $_.FullName.Replace($gemDir, "")
        $currentFile = @{
            Size = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
            LastWriteTime = $_.LastWriteTime
            IsDirectory = $_.PSIsContainer
        }
        
        if ($initialFiles.ContainsKey($relativePath)) {
            $initialFile = $initialFiles[$relativePath]
            if ($initialFile.LastWriteTime -ne $currentFile.LastWriteTime -or 
                $initialFile.Size -ne $currentFile.Size) {
                $testResults.FileSystemChanges.FilesChanged += $relativePath
            }
        } else {
            $testResults.FileSystemChanges.FilesAdded += $relativePath
        }
    }
}

# Check for removed files
foreach ($initialPath in $initialFiles.Keys) {
    $fullPath = Join-Path $gemDir $initialPath
    if (-not (Test-Path $fullPath)) {
        $testResults.FileSystemChanges.FilesRemoved += $initialPath
    }
}

Write-Host ""
Write-Host "Testing Chef PowerShell functionality (Post-Pristine)..."

# Test Chef with PowerShell recipe again
try {
    Write-Host "Executing: chef-client -z -o recipe[test_recipe] --chef-license accept-silent"
    $chefOutputPost = & chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1 | Out-String
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Chef run completed successfully (Post-Pristine)" -ForegroundColor Green
        $testResults.PostPristineTest.Success = $true
        $testResults.PostPristineTest.Output = $chefOutputPost
    } else {
        Write-Host "✗ Chef run failed with exit code: $LASTEXITCODE (Post-Pristine)" -ForegroundColor Red
        $testResults.PostPristineTest.Success = $false
        $testResults.PostPristineTest.Error = "Exit code: $LASTEXITCODE"
        $testResults.PostPristineTest.Output = $chefOutputPost
        
        # Check for specific DLL error again
        if ($chefOutputPost -match "Could not open library.*Chef\.PowerShell\.Wrapper\.dll.*Failed with error 126") {
            Write-Host "✗ DLL loading error persists after gem pristine" -ForegroundColor Red
            $testResults.PostPristineTest.Error = "DLL Error 126: Chef.PowerShell.Wrapper.dll could not be loaded (persists after pristine)"
        }
    }
} catch {
    Write-Host "✗ Chef execution failed with exception: $($_.Exception.Message)" -ForegroundColor Red
    $testResults.PostPristineTest.Success = $false
    $testResults.PostPristineTest.Error = $_.Exception.Message
}

Write-Host ""
Write-Host "=== Test Results Summary ==="
Write-Host "Pre-Pristine DLL Present: $($testResults.PrePristineTest.DllExists)"
Write-Host "Pre-Pristine Chef Success: $($testResults.PrePristineTest.Success)"
Write-Host "Gem Pristine Success: $($testResults.GemPristineOperation.Success)"
Write-Host "Post-Pristine DLL Present: $($testResults.PostPristineTest.DllExists)"
Write-Host "Post-Pristine Chef Success: $($testResults.PostPristineTest.Success)"
Write-Host "Files Changed: $($testResults.FileSystemChanges.FilesChanged.Count)"
Write-Host "Files Added: $($testResults.FileSystemChanges.FilesAdded.Count)"
Write-Host "Files Removed: $($testResults.FileSystemChanges.FilesRemoved.Count)"

# Save detailed results to JSON
$outputPath = "C:\shared\dll-remediation-test-results.json"
$testResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host ""
Write-Host "Detailed results saved to: $outputPath"

Write-Host ""
Write-Host "======================================================================="
'@

    # Run the comprehensive test
    Write-Host "`n=== Running DLL Error Detection and Remediation Test ===" -ForegroundColor Green
    docker run --rm -e CHEF_LICENSE=accept-silent -v "${PWD}\shared:C:\shared" -v "${PWD}\cookbooks:C:\cookbooks" chef-dll-test:latest powershell -Command $testScript
    
    # Generate summary report
    Write-Host "`n=== Generating Summary Report ===" -ForegroundColor Green
    
    $resultsFile = Join-Path $sharedDir "dll-remediation-test-results.json"
    
    if (Test-Path $resultsFile) {
        $results = Get-Content $resultsFile | ConvertFrom-Json
        
        # Create summary report
        $reportPath = Join-Path $sharedDir "dll-remediation-summary.md"
        
        $report = @"
# Chef PowerShell DLL Error Detection and Gem Pristine Remediation Report

**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Test Timestamp:** $($results.Timestamp)

## Executive Summary

This test was designed to detect Chef PowerShell DLL loading errors and evaluate whether `gem pristine chef-powershell` can remediate packaging issues.

## Test Results Overview

| Phase | DLL Present | Chef Success | Error Details |
|-------|-------------|--------------|---------------|
| **Pre-Pristine** | $($results.PrePristineTest.DllExists) | $($results.PrePristineTest.Success) | $($results.PrePristineTest.Error) |
| **Gem Pristine** | - | $($results.GemPristineOperation.Success) | $($results.GemPristineOperation.Error) |
| **Post-Pristine** | $($results.PostPristineTest.DllExists) | $($results.PostPristineTest.Success) | $($results.PostPristineTest.Error) |

## Detailed Analysis

### Pre-Pristine State
- **DLL Location:** $($results.PrePristineTest.DllPath)
- **DLL Exists:** $($results.PrePristineTest.DllExists)
- **Chef Functionality:** $(if ($results.PrePristineTest.Success) { "✅ Working" } else { "❌ Failed" })
- **Error Type:** $($results.PrePristineTest.Error)

### Gem Pristine Operation
- **Success:** $(if ($results.GemPristineOperation.Success) { "✅ Completed" } else { "❌ Failed" })
- **Error:** $($results.GemPristineOperation.Error)

### Post-Pristine State  
- **DLL Exists:** $($results.PostPristineTest.DllExists)
- **Chef Functionality:** $(if ($results.PostPristineTest.Success) { "✅ Working" } else { "❌ Failed" })
- **Error Type:** $($results.PostPristineTest.Error)

### File System Changes
- **Files Modified:** $($results.FileSystemChanges.FilesChanged.Count)
- **Files Added:** $($results.FileSystemChanges.FilesAdded.Count)  
- **Files Removed:** $($results.FileSystemChanges.FilesRemoved.Count)

"@

        if ($results.FileSystemChanges.FilesChanged.Count -gt 0) {
            $report += "`n#### Files Modified by Gem Pristine`n"
            foreach ($file in $results.FileSystemChanges.FilesChanged) {
                $report += "- $file`n"
            }
        }

        if ($results.FileSystemChanges.FilesAdded.Count -gt 0) {
            $report += "`n#### Files Added by Gem Pristine`n"
            foreach ($file in $results.FileSystemChanges.FilesAdded) {
                $report += "- $file`n"
            }
        }

        if ($results.FileSystemChanges.FilesRemoved.Count -gt 0) {
            $report += "`n#### Files Removed by Gem Pristine`n"
            foreach ($file in $results.FileSystemChanges.FilesRemoved) {
                $report += "- $file`n"
            }
        }

        # Add conclusions
        $report += "`n## Conclusions`n"
        
        if (-not $results.PrePristineTest.Success -and $results.PostPristineTest.Success) {
            $report += "✅ **SUCCESS** - Gem pristine resolved the Chef PowerShell DLL error!`n"
        }
        elseif (-not $results.PrePristineTest.Success -and -not $results.PostPristineTest.Success) {
            $report += "❌ **UNRESOLVED** - Gem pristine did not resolve the Chef PowerShell DLL error`n"
        }
        elseif ($results.PrePristineTest.Success -and $results.PostPristineTest.Success) {
            $report += "✅ **STABLE** - No DLL errors detected before or after gem pristine`n"
        }
        else {
            $report += "❌ **REGRESSION** - Gem pristine introduced new issues`n"
        }
        
        if ($results.FileSystemChanges.FilesChanged.Count -gt 0 -or 
            $results.FileSystemChanges.FilesAdded.Count -gt 0 -or 
            $results.FileSystemChanges.FilesRemoved.Count -gt 0) {
            $report += "`nGem pristine made changes to $($results.FileSystemChanges.FilesChanged.Count + $results.FileSystemChanges.FilesAdded.Count + $results.FileSystemChanges.FilesRemoved.Count) files, indicating it attempted remediation.`n"
        }
        else {
            $report += "`nGem pristine made no file system changes, suggesting the gem was already in pristine condition.`n"
        }

        # Save report
        $report | Out-File -FilePath $reportPath -Encoding UTF8
        
        Write-Host "Summary report generated: $reportPath" -ForegroundColor Green
        Write-Host ""
        Write-Host "=== Key Findings ===" -ForegroundColor Cyan
        Write-Host "Pre-pristine Chef success: $(if ($results.PrePristineTest.Success) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($results.PrePristineTest.Success) { 'Green' } else { 'Red' })
        Write-Host "Post-pristine Chef success: $(if ($results.PostPristineTest.Success) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($results.PostPristineTest.Success) { 'Green' } else { 'Red' })
        Write-Host "Gem pristine success: $(if ($results.GemPristineOperation.Success) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($results.GemPristineOperation.Success) { 'Green' } else { 'Red' })
        Write-Host "Files changed by pristine: $($results.FileSystemChanges.FilesChanged.Count + $results.FileSystemChanges.FilesAdded.Count + $results.FileSystemChanges.FilesRemoved.Count)" -ForegroundColor Yellow
        
    }
    else {
        Write-Host "ERROR: Could not find test results file" -ForegroundColor Red
        exit 1
    }

}
finally {
    # Clean up temporary MSI file
    if (Test-Path $tempMsi) {
        Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== DLL Remediation Test Complete ===" -ForegroundColor Cyan
Write-Host "Check the shared/ directory for detailed results:" -ForegroundColor Green
Write-Host "- dll-remediation-test-results.json - Detailed test data" -ForegroundColor White
Write-Host "- dll-remediation-summary.md - Human-readable analysis" -ForegroundColor White