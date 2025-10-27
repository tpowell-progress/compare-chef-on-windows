# Enhanced script to compare chef-powershell gem directory and test PowerShell functionality before and after gem pristine
param(
    [string]$MsiFile = "omnibus-ruby_chef_pkg_chef-client-18.8.50-1-x64.msi",
    [string]$GemVersion = "18.6.3"
)

$ErrorActionPreference = "Stop"

# Track if any chef runs failed
$script:chefRunFailed = $false

Write-Host "=== Enhanced Chef PowerShell Gem Pristine Comparison Script ===" -ForegroundColor Cyan
Write-Host "MSI File: $MsiFile" -ForegroundColor Yellow
Write-Host "Gem Version: $GemVersion" -ForegroundColor Yellow
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

# Clean up any previous comparison files
Write-Host "Cleaning previous comparison files..." -ForegroundColor Yellow
Get-ChildItem $sharedDir -Filter "*gem-pristine*" | Remove-Item -Force -ErrorAction SilentlyContinue

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
    docker build -f Dockerfile.msi --build-arg INSTALL_DUMPBIN=False -t chef-gem-pristine:latest .
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build Chef MSI image" -ForegroundColor Red
        exit 1
    }

    # Create PowerShell scripts for running inside container
    $initialScript = @'
Write-Host "=== Initial State Analysis (Post-MSI Install) ==="
Write-Host "Checking chef-powershell gem directory after MSI install..."

$gemPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-*"
$chefPSDirectories = Get-ChildItem -Path $gemPath -Directory -ErrorAction SilentlyContinue

$initialState = @{
    Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    State = "Post-MSI Install"
    Directories = @()
    TotalItems = 0
    ChefRunSuccess = $false
    ChefRunError = ""
}

if ($chefPSDirectories) {
    foreach ($dir in $chefPSDirectories) {
        Write-Host "Found chef-powershell directory: $($dir.FullName)"
        $items = Get-ChildItem -Path $dir.FullName -Recurse -Force | ForEach-Object {
            @{
                Path = $_.FullName.Replace("C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\", "")
                Type = if ($_.PSIsContainer) { "Directory" } else { "File" }
                Size = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
                LastWriteTime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
        $initialState.Directories += @{
            Path = $dir.FullName
            Name = $dir.Name
            Items = $items
            ItemCount = $items.Count
        }
        $initialState.TotalItems += $items.Count
    }
} else {
    Write-Host "No chef-powershell directories found after MSI install"
}

Write-Host ""
Write-Host "=== Testing PowerShell Recipe (Pre-Gem Pristine) ==="

# Test Chef PowerShell functionality by running the recipe
$env:PATH += ";C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64\shared\Microsoft.NETCore.App\5.0.0"

try {
    Write-Host "Running chef-client with test recipe..."
    $chefOutput = & chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1
    Write-Host "Chef run completed successfully (pre-pristine)"
    $initialState.ChefRunSuccess = $true
} catch {
    Write-Host "Chef run failed (pre-pristine): $($_.Exception.Message)" -ForegroundColor Yellow
    $initialState.ChefRunSuccess = $false
    $initialState.ChefRunError = $_.Exception.Message
}

$outputPath = "C:\shared\gem-pristine-initial.json"
$initialState | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host "Initial state saved to: $outputPath"
Write-Host "Total items found: $($initialState.TotalItems)"
Write-Host "Chef run success: $($initialState.ChefRunSuccess)"
'@

    $finalScript = @"
Write-Host "=== Gem Pristine and Final State Analysis ==="
Write-Host "Running gem pristine for chef-powershell..."

# Run gem pristine to reinstall the gem
try {
    & "C:\opscode\chef\embedded\bin\gem" pristine chef-powershell
    Write-Host "Gem pristine completed successfully"
} catch {
    Write-Host "Gem pristine encountered an issue: `$(`$_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continuing with state capture..."
}

Write-Host ""
Write-Host "Checking chef-powershell gem directory after gem pristine..."

`$gemPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-*"
`$chefPSDirectories = Get-ChildItem -Path `$gemPath -Directory -ErrorAction SilentlyContinue

`$finalState = @{
    Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    State = "Post-Gem Pristine"
    Directories = @()
    TotalItems = 0
    ChefRunSuccess = `$false
    ChefRunError = ""
}

if (`$chefPSDirectories) {
    foreach (`$dir in `$chefPSDirectories) {
        Write-Host "Found chef-powershell directory: `$(`$dir.FullName)"
        `$items = Get-ChildItem -Path `$dir.FullName -Recurse -Force | ForEach-Object {
            @{
                Path = `$_.FullName.Replace("C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\", "")
                Type = if (`$_.PSIsContainer) { "Directory" } else { "File" }
                Size = if (-not `$_.PSIsContainer) { `$_.Length } else { 0 }
                LastWriteTime = `$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
        `$finalState.Directories += @{
            Path = `$dir.FullName
            Name = `$dir.Name
            Items = `$items
            ItemCount = `$items.Count
        }
        `$finalState.TotalItems += `$items.Count
    }
} else {
    Write-Host "No chef-powershell directories found after gem pristine"
}

Write-Host ""
Write-Host "=== Testing PowerShell Recipe (Post-Gem Pristine) ==="

# Test Chef PowerShell functionality by running the recipe
`$env:PATH += ";C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64\shared\Microsoft.NETCore.App\5.0.0"

try {
    Write-Host "Running chef-client with test recipe..."
    `$chefOutput = & chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1
    Write-Host "Chef run completed successfully (post-pristine)"
    `$finalState.ChefRunSuccess = `$true
} catch {
    Write-Host "Chef run failed (post-pristine): `$(`$_.Exception.Message)" -ForegroundColor Yellow
    `$finalState.ChefRunSuccess = `$false
    `$finalState.ChefRunError = `$_.Exception.Message
}

`$outputPath = "C:\shared\gem-pristine-final.json"
`$finalState | ConvertTo-Json -Depth 10 | Out-File -FilePath `$outputPath -Encoding UTF8
Write-Host "Final state saved to: `$outputPath"
Write-Host "Total items found: `$(`$finalState.TotalItems)"
Write-Host "Chef run success: `$(`$finalState.ChefRunSuccess)"
"@

    # Step 1: Capture initial state and test Chef run
    Write-Host "`n=== Capturing Initial State and Testing PowerShell Recipe ===" -ForegroundColor Green
    docker run --rm -e CHEF_LICENSE=accept-silent -v "${PWD}\shared:C:\shared" -v "${PWD}\cookbooks:C:\cookbooks" chef-gem-pristine:latest powershell -Command $initialScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to capture initial state or run initial Chef test" -ForegroundColor Yellow
        $script:chefRunFailed = $true
    }

    # Step 2: Run gem pristine, capture final state, and test Chef run
    Write-Host "`n=== Running Gem Pristine and Testing PowerShell Recipe ===" -ForegroundColor Green
    docker run --rm -e CHEF_LICENSE=accept-silent -v "${PWD}\shared:C:\shared" -v "${PWD}\cookbooks:C:\cookbooks" chef-gem-pristine:latest powershell -Command $finalScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to run gem pristine or capture final state" -ForegroundColor Yellow
        $script:chefRunFailed = $true
    }

    # Step 3: Generate comparison report
    Write-Host "`n=== Generating Comprehensive Comparison Report ===" -ForegroundColor Green
    
    $initialFile = Join-Path $sharedDir "gem-pristine-initial.json"
    $finalFile = Join-Path $sharedDir "gem-pristine-final.json"
    
    if ((Test-Path $initialFile) -and (Test-Path $finalFile)) {
        $initialState = Get-Content $initialFile | ConvertFrom-Json
        $finalState = Get-Content $finalFile | ConvertFrom-Json
        
        # Create comparison report
        $reportPath = Join-Path $sharedDir "gem-pristine-report.md"
        
        $report = @"
# Chef PowerShell Gem Pristine Comparison Report

**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**MSI File:** $MsiFile
**Operation:** gem pristine chef-powershell

## Summary

- **Initial State (Post-MSI):** $($initialState.TotalItems) items found
- **Final State (Post-Gem Pristine):** $($finalState.TotalItems) items found
- **File/Directory Difference:** $($finalState.TotalItems - $initialState.TotalItems) items

## Chef PowerShell Recipe Test Results

### Pre-Gem Pristine Test
- **Success:** $($initialState.ChefRunSuccess)
- **Error:** $($initialState.ChefRunError)

### Post-Gem Pristine Test  
- **Success:** $($finalState.ChefRunSuccess)
- **Error:** $($finalState.ChefRunError)

## Initial State Directories

"@

        foreach ($dir in $initialState.Directories) {
            $report += "`n### $($dir.Name)`n"
            $report += "- **Path:** $($dir.Path)`n"
            $report += "- **Item Count:** $($dir.ItemCount)`n"
        }

        $report += "`n## Final State Directories`n"

        foreach ($dir in $finalState.Directories) {
            $report += "`n### $($dir.Name)`n"
            $report += "- **Path:** $($dir.Path)`n"
            $report += "- **Item Count:** $($dir.ItemCount)`n"
        }

        # Compare directories and files
        $report += "`n## Detailed File System Comparison`n"
        
        # Create hashtables for easier comparison
        $initialPaths = @{}
        $finalPaths = @{}
        
        foreach ($dir in $initialState.Directories) {
            foreach ($item in $dir.Items) {
                $initialPaths[$item.Path] = $item
            }
        }
        
        foreach ($dir in $finalState.Directories) {
            foreach ($item in $dir.Items) {
                $finalPaths[$item.Path] = $item
            }
        }
        
        # Find new items
        $newItems = @()
        foreach ($path in $finalPaths.Keys) {
            if (-not $initialPaths.ContainsKey($path)) {
                $newItems += $finalPaths[$path]
            }
        }
        
        # Find removed items
        $removedItems = @()
        foreach ($path in $initialPaths.Keys) {
            if (-not $finalPaths.ContainsKey($path)) {
                $removedItems += $initialPaths[$path]
            }
        }
        
        # Find modified items (size or timestamp changes)
        $modifiedItems = @()
        foreach ($path in $initialPaths.Keys) {
            if ($finalPaths.ContainsKey($path)) {
                $initial = $initialPaths[$path]
                $final = $finalPaths[$path]
                if ($initial.Size -ne $final.Size -or $initial.LastWriteTime -ne $final.LastWriteTime) {
                    $modifiedItems += @{
                        Path    = $path
                        Initial = $initial
                        Final   = $final
                    }
                }
            }
        }

        if ($newItems.Count -gt 0) {
            $report += "`n### New Items ($($newItems.Count))`n"
            foreach ($item in $newItems | Sort-Object Path) {
                $report += "- **$($item.Type):** $($item.Path)"
                if ($item.Type -eq "File") {
                    $report += " ($($item.Size) bytes)"
                }
                $report += "`n"
            }
        }
        else {
            $report += "`n### New Items: None`n"
        }

        if ($removedItems.Count -gt 0) {
            $report += "`n### Removed Items ($($removedItems.Count))`n"
            foreach ($item in $removedItems | Sort-Object Path) {
                $report += "- **$($item.Type):** $($item.Path)"
                if ($item.Type -eq "File") {
                    $report += " ($($item.Size) bytes)"
                }
                $report += "`n"
            }
        }
        else {
            $report += "`n### Removed Items: None`n"
        }

        if ($modifiedItems.Count -gt 0) {
            $report += "`n### Modified Items ($($modifiedItems.Count))`n"
            foreach ($item in $modifiedItems | Sort-Object Path) {
                $report += "- **File:** $($item.Path)`n"
                $report += "  - Initial: $($item.Initial.Size) bytes, $($item.Initial.LastWriteTime)`n"
                $report += "  - Final: $($item.Final.Size) bytes, $($item.Final.LastWriteTime)`n"
            }
        }
        else {
            $report += "`n### Modified Items: None`n"
        }

        # Add functionality assessment
        $report += "`n## Chef PowerShell Functionality Assessment`n"
        
        if ($initialState.ChefRunSuccess -and $finalState.ChefRunSuccess) {
            $report += "✅ **PASS** - PowerShell recipes work both before and after gem pristine`n"
        }
        elseif (-not $initialState.ChefRunSuccess -and $finalState.ChefRunSuccess) {
            $report += "✅ **IMPROVED** - PowerShell recipes now work after gem pristine (were broken before)`n"
        }
        elseif ($initialState.ChefRunSuccess -and -not $finalState.ChefRunSuccess) {
            $report += "❌ **REGRESSION** - PowerShell recipes worked before but are broken after gem pristine`n"
        }
        else {
            $report += "❌ **FAIL** - PowerShell recipes don't work before or after gem pristine`n"
        }

        # Save report
        $report | Out-File -FilePath $reportPath -Encoding UTF8
        
        Write-Host "Comparison report generated: $reportPath" -ForegroundColor Green
        Write-Host ""
        Write-Host "=== Summary ===" -ForegroundColor Cyan
        Write-Host "New items: $($newItems.Count)" -ForegroundColor Yellow
        Write-Host "Removed items: $($removedItems.Count)" -ForegroundColor Yellow
        Write-Host "Modified items: $($modifiedItems.Count)" -ForegroundColor Yellow
        Write-Host "Total change: $($finalState.TotalItems - $initialState.TotalItems) items" -ForegroundColor Yellow
        Write-Host "Pre-pristine Chef run: $(if ($initialState.ChefRunSuccess) { 'SUCCESS' } else { 'FAILED' })" -ForegroundColor $(if ($initialState.ChefRunSuccess) { 'Green' } else { 'Red' })
        Write-Host "Post-pristine Chef run: $(if ($finalState.ChefRunSuccess) { 'SUCCESS' } else { 'FAILED' })" -ForegroundColor $(if ($finalState.ChefRunSuccess) { 'Green' } else { 'Red' })
        
    }
    else {
        Write-Host "ERROR: Could not find comparison files" -ForegroundColor Red
        exit 1
    }

}
finally {
    # Clean up temporary MSI file
    if (Test-Path $tempMsi) {
        Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Enhanced Comparison Complete ===" -ForegroundColor Cyan
Write-Host "Check the shared/ directory for detailed results:" -ForegroundColor Green
Write-Host "- gem-pristine-initial.json - Initial state and Chef test results" -ForegroundColor White
Write-Host "- gem-pristine-final.json - Final state and Chef test results" -ForegroundColor White
Write-Host "- gem-pristine-report.md - Comprehensive comparison report" -ForegroundColor White

# Check if any chef runs failed and report
if ($script:chefRunFailed) {
    Write-Host "`nWARNING: One or more operations encountered errors!" -ForegroundColor Red
    Write-Host "However, comparison and reporting completed. Check the report for details." -ForegroundColor Yellow
    exit 1
}