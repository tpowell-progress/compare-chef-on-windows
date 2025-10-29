<#
.SYNOPSIS
    Tests DLL compatibility between Chef Infra Client versions and optionally finds minimal required DLL set.

.DESCRIPTION
    This script performs comprehensive DLL compatibility testing between two Chef versions:
    1. Builds Docker containers for both versions
    2. Extracts DLLs from source version
    3. Tests baseline functionality of target version
    4. Tests target version with source DLLs replaced
    5. Optionally performs bisection analysis to find minimal DLL set
    
    The bisection mode uses a binary search algorithm to iteratively reduce the number
    of DLLs needed from the source to fix a broken target, finding the minimal set
    required for compatibility.

.PARAMETER SourceVersion
    Version of Chef to use as DLL source (donor). Default: "18.8.11"

.PARAMETER TargetVersion
    Version of Chef to use as DLL target (recipient). Default: "18.8.46"

.PARAMETER Bisect
    Enable DLL bisection mode to find minimal required DLL set.
    Only runs when baseline target test fails.

.PARAMETER MaxBisectionIterations
    Maximum number of bisection iterations to perform. Default: 10

.EXAMPLE
    .\test-dll-compatibility.ps1
    Basic compatibility test between default versions

.EXAMPLE
    .\test-dll-compatibility.ps1 -SourceVersion "18.8.11" -TargetVersion "18.8.46" -Bisect
    Find minimal DLL set from 18.8.11 needed to fix broken 18.8.46

.EXAMPLE
    .\test-dll-compatibility.ps1 -Bisect -MaxBisectionIterations 15
    Perform bisection with up to 15 iterations for thorough analysis
#>

param(
    [string]$SourceVersion = "18.8.11",
    [string]$TargetVersion = "18.8.46",
    [switch]$Bisect,
    [int]$MaxBisectionIterations = 10
)

function Play-CompletionSound {
    param([bool]$Success)
    
    if ($Success) {
        # Three ascending beeps for success
        [Console]::Beep(800, 200)
        [Console]::Beep(1000, 200)
        [Console]::Beep(1200, 200)
    } else {
        # Two descending beeps for failure
        [Console]::Beep(400, 300)
        [Console]::Beep(200, 300)
    }
}

function Test-ChefWithDlls {
    param(
        [string[]]$DllPaths,
        [string]$TestName
    )
    
    Write-Host "Testing with $($DllPaths.Count) DLLs: $TestName" -ForegroundColor Cyan
    
    # Create a DLL list file for the container to use
    $dllListPath = "${PWD}\shared\bisect-dll-list.txt"
    $DllPaths | Out-File -FilePath $dllListPath -Encoding ASCII
    
    # Create a PowerShell script file to run inside the container
    $scriptPath = "${PWD}\shared\bisect-test.ps1"
    $scriptContent = @'
try {
    # Restore from backup first
    if (Test-Path 'C:\opscode-backup') {
        Remove-Item 'C:\opscode\chef\embedded' -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item 'C:\opscode-backup\chef\embedded' 'C:\opscode\chef\embedded' -Recurse -Force
    }
    
    # Copy only the specified DLLs
    $dllList = Get-Content 'C:\shared\bisect-dll-list.txt'
    $copiedCount = 0
    foreach ($relativePath in $dllList) {
        $sourceFile = 'C:\shared\extracted-dlls\' + $relativePath
        $targetPath = 'C:\opscode\chef\embedded\' + $relativePath
        
        if (Test-Path $sourceFile) {
            $targetDir = Split-Path $targetPath -Parent
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item $sourceFile $targetPath -Force
            $copiedCount++
        }
    }
    
    Write-Host "Copied $copiedCount DLLs"
    
    # Test chef-client
    $env:PATH="$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64"
    chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'TEST PASSED' -ForegroundColor Green
        Set-Content -Path 'C:\shared\test_result.txt' -Value 'SUCCESS'
        exit 0
    } else {
        Write-Host 'TEST FAILED' -ForegroundColor Red
        Set-Content -Path 'C:\shared\test_result.txt' -Value 'FAILED'
        exit 1
    }
    
} catch {
    Write-Host 'TEST FAILED with exception' -ForegroundColor Red
    Set-Content -Path 'C:\shared\test_result.txt' -Value 'ERROR'
    exit 1
}
'@
    
    Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8
    
    # Test the specified DLLs in target container by running the script file
    $success = docker run --rm `
        -e CHEF_LICENSE=accept-silent `
        -e SOURCE_VERSION=$SourceVersion `
        -e TARGET_VERSION=$TargetVersion `
        -v "${PWD}\shared:C:\shared" `
        -v "${PWD}\cookbooks:C:\cookbooks" `
        chef-dll-test:target `
        powershell -File "C:\shared\bisect-test.ps1"
    
    return $LASTEXITCODE -eq 0
}

function Find-MinimalDllSet {
    param(
        [string[]]$AllDlls,
        [int]$MaxIterations = 10
    )
    
    Write-Host "`n=== Starting DLL Bisection Algorithm ===" -ForegroundColor Magenta
    Write-Host "Total DLLs to analyze: $($AllDlls.Count)" -ForegroundColor Yellow
    Write-Host "Maximum iterations: $MaxIterations" -ForegroundColor Yellow
    
    $minimalSet = @()
    $remainingDlls = $AllDlls.Clone()
    $iteration = 0
    
    # First, create backup in target container
    Write-Host "Creating backup of original target DLLs..." -ForegroundColor Yellow
    docker run --rm `
        -v "${PWD}\shared:C:\shared" `
        chef-dll-test:target `
        powershell -Command {
            if (Test-Path "C:\opscode-backup") {
                Remove-Item "C:\opscode-backup" -Recurse -Force
            }
            Copy-Item "C:\opscode\chef\embedded" "C:\opscode-backup\chef\embedded" -Recurse -Force
            Write-Host "Backup created successfully"
        }
    
    while ($remainingDlls.Count -gt 0 -and $iteration -lt $MaxIterations) {
        $iteration++
        Write-Host "`n--- Bisection Iteration $iteration ---" -ForegroundColor Cyan
        Write-Host "Remaining DLLs to test: $($remainingDlls.Count)" -ForegroundColor Gray
        
        # Try with current minimal set first
        if ($minimalSet.Count -gt 0) {
            Write-Host "Testing current minimal set ($($minimalSet.Count) DLLs)..." -ForegroundColor Gray
            if (Test-ChefWithDlls -DllPaths $minimalSet -TestName "Current Minimal Set") {
                Write-Host "Current minimal set is sufficient!" -ForegroundColor Green
                break
            }
        }
        
        # Binary search: try with half of remaining DLLs
        $halfSize = [Math]::Max(1, [Math]::Floor($remainingDlls.Count / 2))
        $testSet = $minimalSet + $remainingDlls[0..($halfSize - 1)]
        
        Write-Host "Testing with first $halfSize DLLs (total: $($testSet.Count))..." -ForegroundColor Yellow
        
        if (Test-ChefWithDlls -DllPaths $testSet -TestName "Bisection Test") {
            # Success with this half - these DLLs are needed
            $newDlls = $remainingDlls[0..($halfSize - 1)]
            $minimalSet += $newDlls
            $remainingDlls = $remainingDlls[$halfSize..($remainingDlls.Count - 1)]
            
            Write-Host "SUCCESS: Added $($newDlls.Count) DLLs to minimal set" -ForegroundColor Green
            Write-Host "Minimal set now contains: $($minimalSet.Count) DLLs" -ForegroundColor Green
        } else {
            # Failed - try with second half
            if ($remainingDlls.Count -gt $halfSize) {
                $testSet2 = $minimalSet + $remainingDlls[$halfSize..($remainingDlls.Count - 1)]
                Write-Host "First half failed, testing with second half ($($remainingDlls.Count - $halfSize) DLLs)..." -ForegroundColor Yellow
                
                if (Test-ChefWithDlls -DllPaths $testSet2 -TestName "Second Half Test") {
                    # Success with second half
                    $newDlls = $remainingDlls[$halfSize..($remainingDlls.Count - 1)]
                    $minimalSet += $newDlls
                    $remainingDlls = $remainingDlls[0..($halfSize - 1)]
                    
                    Write-Host "SUCCESS: Second half worked - added $($newDlls.Count) DLLs to minimal set" -ForegroundColor Green
                } else {
                    # Neither half works alone - need to test smaller chunks
                    Write-Host "Neither half works independently - testing individual DLLs..." -ForegroundColor Yellow
                    
                    $foundRequired = $false
                    foreach ($dll in $remainingDlls[0..($halfSize - 1)]) {
                        $singleTest = $minimalSet + @($dll)
                        if (Test-ChefWithDlls -DllPaths $singleTest -TestName "Single DLL: $dll") {
                            $minimalSet += @($dll)
                            $remainingDlls = $remainingDlls | Where-Object { $_ -ne $dll }
                            Write-Host "Found critical DLL: $dll" -ForegroundColor Green
                            $foundRequired = $true
                            break
                        }
                    }
                    
                    if (-not $foundRequired) {
                        # Remove first half and continue with second half
                        $remainingDlls = $remainingDlls[$halfSize..($remainingDlls.Count - 1)]
                        Write-Host "No critical DLLs in first half - moving to second half" -ForegroundColor Gray
                    }
                }
            } else {
                # Only one DLL left - test it
                $singleDll = $remainingDlls[0]
                $singleTest = $minimalSet + @($singleDll)
                if (Test-ChefWithDlls -DllPaths $singleTest -TestName "Final DLL: $singleDll") {
                    $minimalSet += @($singleDll)
                    Write-Host "Added final critical DLL: $singleDll" -ForegroundColor Green
                }
                break
            }
        }
        
        Write-Host "Minimal set progress: $($minimalSet -join ', ')" -ForegroundColor Cyan
    }
    
    Write-Host "`n=== Bisection Complete ===" -ForegroundColor Magenta
    Write-Host "Iterations used: $iteration" -ForegroundColor Yellow
    Write-Host "Minimal DLL set contains: $($minimalSet.Count) DLLs" -ForegroundColor Green
    
    return $minimalSet
}

Write-Host "=== Chef DLL Cross-Version Compatibility Test ===" -ForegroundColor Cyan
Write-Host "Source Version: $SourceVersion (DLL donor)" -ForegroundColor Yellow
Write-Host "Target Version: $TargetVersion (recipient)" -ForegroundColor Yellow
Write-Host ""

# Clean shared directory
Write-Host "Cleaning shared directory..." -ForegroundColor Yellow
if (Test-Path ".\shared") {
    Remove-Item ".\shared\*" -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path ".\shared" | Out-Null
}

# Create extraction directory
$extractDir = ".\shared\extracted-dlls"
if (Test-Path $extractDir) {
    Remove-Item $extractDir -Recurse -Force
}
New-Item -ItemType Directory -Path $extractDir | Out-Null

# Build both Chef versions
Write-Host "`n=== Building Chef containers ===" -ForegroundColor Green

Write-Host "Building Chef $SourceVersion (source)..." -ForegroundColor Yellow
docker build --build-arg CHEF_VERSION=$SourceVersion -t chef-dll-test:source .
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build source Chef $SourceVersion image" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

Write-Host "Building Chef $TargetVersion (target)..." -ForegroundColor Yellow
docker build --build-arg CHEF_VERSION=$TargetVersion -t chef-dll-test:target .
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build target Chef $TargetVersion image" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

# Extract DLLs from source version
Write-Host "`n=== Extracting DLLs from Chef $SourceVersion ===" -ForegroundColor Green
docker run --rm `
    -v "${PWD}\shared:C:\shared" `
    chef-dll-test:source `
    powershell -Command {
        Write-Host "=== Extracting DLLs from C:\opscode\chef\embedded\bin ==="
        
        # Create extraction directory in container
        New-Item -ItemType Directory -Path "C:\shared\extracted-dlls" -Force | Out-Null
        
        # Find all DLL files in embedded\bin
        $dllFiles = Get-ChildItem -Path "C:\opscode\chef\embedded\bin" -Include "*.dll" -Recurse -ErrorAction SilentlyContinue
        
        if ($dllFiles) {
            Write-Host "Found $($dllFiles.Count) DLL files in embedded\bin"
            
            $dllList = @()
            foreach ($dll in $dllFiles) {
                $relativePath = $dll.FullName -replace '^C:\\opscode\\chef\\embedded\\bin\\?', ''
                $destPath = "C:\shared\extracted-dlls\$relativePath"
                
                # Create directory structure if needed
                $destDir = Split-Path $destPath -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                
                # Copy the DLL
                Copy-Item $dll.FullName $destPath -Force
                Write-Host "Extracted: $relativePath ($($dll.Length) bytes)"
                
                $dllList += [PSCustomObject]@{
                    RelativePath = $relativePath
                    Size = $dll.Length
                    LastWrite = $dll.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                }
            }
            
            # Save DLL list
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $report = "Chef $env:SOURCE_VERSION DLL Extraction Report`nTimestamp: $timestamp`nTotal DLLs: $($dllList.Count)`n`nDLL Files:`n" + 
                      ($dllList | ForEach-Object { "$($_.RelativePath)`t$($_.Size)`t$($_.LastWrite)" } | Out-String)
            $report | Out-File -FilePath "C:\shared\source-dlls-list.txt" -Encoding UTF8
            
        } else {
            Write-Host "No DLL files found in C:\opscode\chef\embedded\bin"
        }
    }

# Test baseline target version (without DLL replacement)
Write-Host "`n=== Testing baseline Chef $TargetVersion ===" -ForegroundColor Green
$baselineSuccess = $true
docker run --rm `
    -e CHEF_LICENSE=accept-silent `
    -v "${PWD}\shared:C:\shared" `
    -v "${PWD}\cookbooks:C:\cookbooks" `
    chef-dll-test:target `
    powershell -Command {
        Write-Host "=== Baseline Test: Chef $env:TARGET_VERSION ==="
        
        try {
            # Test chef-client command
            $chefVersion = chef-client --version
            Write-Host "Chef version check: $chefVersion"
            
            # Run the test recipe
            Write-Host "Running test recipe..."
            $env:PATH="$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64"
            chef-client -z -o recipe[test_recipe] --chef-license accept-silent
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Baseline test PASSED" -ForegroundColor Green
                "BASELINE_SUCCESS" | Out-File -FilePath "C:\shared\baseline-result.txt" -Encoding UTF8
            } else {
                Write-Host "Baseline test FAILED with exit code $LASTEXITCODE" -ForegroundColor Red
                "BASELINE_FAILED" | Out-File -FilePath "C:\shared\baseline-result.txt" -Encoding UTF8
            }
        } catch {
            Write-Host "Baseline test FAILED with exception: $($_.Exception.Message)" -ForegroundColor Red
            "BASELINE_EXCEPTION: $($_.Exception.Message)" | Out-File -FilePath "C:\shared\baseline-result.txt" -Encoding UTF8
        }
    }

# Check baseline result
$baselineResult = Get-Content ".\shared\baseline-result.txt" -ErrorAction SilentlyContinue
if ($baselineResult -notmatch "BASELINE_SUCCESS") {
    Write-Host "Baseline test failed - this is expected for broken target versions" -ForegroundColor Yellow
    Write-Host "Baseline result: $baselineResult" -ForegroundColor Yellow
    
    if ($Bisect) {
        Write-Host "Bisection mode enabled - finding minimal DLL set to fix the issue..." -ForegroundColor Cyan
        
        # Get list of all extracted DLLs
        $sourceDllsContent = Get-Content ".\shared\source-dlls-list.txt" -ErrorAction SilentlyContinue
        $allDlls = @()
        
        if ($sourceDllsContent) {
            # Parse the DLL list from the source extraction report
            $inDllSection = $false
            foreach ($line in $sourceDllsContent) {
                if ($line -match "^DLL Files:") {
                    $inDllSection = $true
                    continue
                }
                if ($inDllSection -and $line.Trim() -and $line -match "^\S+") {
                    $parts = $line.Split("`t")
                    if ($parts.Count -gt 0) {
                        $dllPath = $parts[0].Trim()
                        if ($dllPath -and $dllPath -ne "DLL Files:") {
                            $allDlls += $dllPath
                        }
                    }
                }
            }
        }
        
        Write-Host "Found $($allDlls.Count) DLLs for bisection analysis" -ForegroundColor Yellow
        
        if ($allDlls.Count -eq 0) {
            Write-Host "No DLLs found for bisection - falling back to standard test" -ForegroundColor Red
        } else {
            # Perform bisection to find minimal set
            $minimalDlls = Find-MinimalDllSet -AllDlls $allDlls -MaxIterations $MaxBisectionIterations
            
            # Generate bisection report
            $bisectionReport = @"
DLL Bisection Analysis Report
============================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Source Version: $SourceVersion (DLL donor)
Target Version: $TargetVersion (recipient)

Total DLLs Available: $($allDlls.Count)
Minimal Set Required: $($minimalDlls.Count)
Reduction: $([Math]::Round((1 - ($minimalDlls.Count / $allDlls.Count)) * 100, 2))%

Minimal DLL Set:
---------------
$($minimalDlls | ForEach-Object { "- $_" } | Out-String)

All Available DLLs:
------------------
$($allDlls | ForEach-Object { "- $_" } | Out-String)
"@
            
            $bisectionReportFile = ".\shared\dll-bisection-$SourceVersion-to-$TargetVersion.txt"
            $bisectionReport | Out-File -FilePath $bisectionReportFile -Encoding UTF8
            
            Write-Host "`nBisection analysis completed!" -ForegroundColor Green
            Write-Host "Minimal DLL set: $($minimalDlls.Count) out of $($allDlls.Count) DLLs required" -ForegroundColor Cyan
            Write-Host "Report saved to: $bisectionReportFile" -ForegroundColor Cyan
            Write-Host "Minimal set: $($minimalDlls -join ', ')" -ForegroundColor Yellow
            
            Play-CompletionSound -Success $true
            return
        }
    } else {
        Write-Host "Proceeding with DLL replacement test to see if source DLLs can fix the issue..." -ForegroundColor Cyan
        Write-Host "(Use -Bisect parameter to find minimal DLL set)" -ForegroundColor Gray
    }
} else {
    Write-Host "Baseline test passed - testing if DLL replacement breaks compatibility..." -ForegroundColor Green
}

# Test with DLL replacement
Write-Host "`n=== Testing Chef $TargetVersion with $SourceVersion DLLs ===" -ForegroundColor Green
docker run --rm `
    -e CHEF_LICENSE=accept-silent `
    -v "${PWD}\shared:C:\shared" `
    -v "${PWD}\cookbooks:C:\cookbooks" `
    chef-dll-test:target `
    powershell -Command {
        Write-Host "=== DLL Replacement Test ==="
        
        try {
            # Backup original DLLs
            Write-Host "Backing up original DLLs..."
            $backupDir = "C:\opscode-backup\chef\embedded\bin"
            if (Test-Path "C:\opscode\chef\embedded\bin") {
                Copy-Item "C:\opscode\chef\embedded\bin" $backupDir -Recurse -Force
                Write-Host "Backup created at $backupDir"
            }
            
            # Replace DLLs with source version
            Write-Host "Replacing DLLs with source version..."
            $sourceFiles = Get-ChildItem "C:\shared\extracted-dlls" -Recurse -File
            $replacedCount = 0
            
            foreach ($sourceFile in $sourceFiles) {
                $relativePath = $sourceFile.FullName -replace '^C:\\shared\\extracted-dlls\\?', ''
                $targetPath = "C:\opscode\chef\embedded\bin\$relativePath"
                
                if (Test-Path $targetPath) {
                    Copy-Item $sourceFile.FullName $targetPath -Force
                    Write-Host "Replaced: $relativePath"
                    $replacedCount++
                } else {
                    Write-Host "Target not found, copying new: $relativePath"
                    $targetDir = Split-Path $targetPath -Parent
                    if (-not (Test-Path $targetDir)) {
                        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                    }
                    Copy-Item $sourceFile.FullName $targetPath -Force
                    $replacedCount++
                }
            }
            
            Write-Host "Replaced/copied $replacedCount DLL files"
            
            # Test chef-client after DLL replacement
            Write-Host "`nTesting chef-client after DLL replacement..."
            $chefVersion = chef-client --version
            Write-Host "Chef version check: $chefVersion"
            
            # Run the test recipe
            Write-Host "Running test recipe with replaced DLLs..."
            $env:PATH="$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64"
            chef-client -z -o recipe[test_recipe] --chef-license accept-silent
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "DLL replacement test PASSED" -ForegroundColor Green
                "REPLACEMENT_SUCCESS" | Out-File -FilePath "C:\shared\replacement-result.txt" -Encoding UTF8
            } else {
                Write-Host "DLL replacement test FAILED with exit code $LASTEXITCODE" -ForegroundColor Red
                "REPLACEMENT_FAILED: Exit code $LASTEXITCODE" | Out-File -FilePath "C:\shared\replacement-result.txt" -Encoding UTF8
            }
            
        } catch {
            Write-Host "DLL replacement test FAILED with exception: $($_.Exception.Message)" -ForegroundColor Red
            "REPLACEMENT_EXCEPTION: $($_.Exception.Message)" | Out-File -FilePath "C:\shared\replacement-result.txt" -Encoding UTF8
        }
    }

# Generate final report
Write-Host "`n=== Generating Compatibility Report ===" -ForegroundColor Green

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$baselineResult = Get-Content ".\shared\baseline-result.txt" -ErrorAction SilentlyContinue
$replacementResult = Get-Content ".\shared\replacement-result.txt" -ErrorAction SilentlyContinue
$sourceDllList = Get-Content ".\shared\source-dlls-list.txt" -ErrorAction SilentlyContinue

$report = @"
Chef DLL Cross-Version Compatibility Test Report
===============================================
Generated: $timestamp
Source Version: $SourceVersion (DLL donor)
Target Version: $TargetVersion (recipient)

Test Results:
------------
Baseline Test ($TargetVersion): $baselineResult
DLL Replacement Test: $replacementResult

Analysis:
---------
"@

if ($baselineResult -match "SUCCESS" -and $replacementResult -match "SUCCESS") {
    $report += "STABLE COMPATIBILITY: Both baseline and replacement tests passed"
    $success = $true
} elseif ($baselineResult -match "SUCCESS" -and $replacementResult -match "FAILED") {
    $report += "REGRESSION: Target works alone but fails with source DLLs (incompatible downgrade)"
    $success = $false
} elseif ($baselineResult -match "FAILED" -and $replacementResult -match "SUCCESS") {
    $report += "FIXED BY SOURCE DLLS: Target was broken but source DLLs repair the functionality!"
    $success = $true
} elseif ($baselineResult -match "FAILED" -and $replacementResult -match "FAILED") {
    $report += "BOTH FAILED: Target is broken and source DLLs do not fix the issue"
    $success = $false
} else {
    $report += "INCONCLUSIVE: Unable to determine compatibility due to test errors"
    $success = $false
}

$report += "`n`nSource DLL Information:`n"
$report += $sourceDllList
$report += "`n`nRecommendation:`n"
$report += "--------------`n"

if ($success) {
    $report += "The DLL files from Chef $SourceVersion embedded\bin are compatible with Chef $TargetVersion.`nThis suggests good backward compatibility for these core components."
} else {
    $report += "The DLL replacement caused failures. Chef $TargetVersion requires its native DLLs.`nVersion-specific dependencies exist that prevent cross-version compatibility."
}

$reportFile = ".\shared\dll-compatibility-$SourceVersion-to-$TargetVersion.txt"
$report | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "`nCompatibility test completed!" -ForegroundColor Green
Write-Host "Report saved to: $reportFile" -ForegroundColor Cyan

if ($success) {
    Write-Host "Result: COMPATIBLE" -ForegroundColor Green
} else {
    Write-Host "Result: INCOMPATIBLE" -ForegroundColor Red
}

Play-CompletionSound -Success $success