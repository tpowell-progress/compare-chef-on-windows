# Script to compare chef-powershell gem directory before and after gem install
param(
    [string]$MsiFile = "omnibus-ruby_chef_pkg_chef-client-18.8.50-1-x64.msi",
    [string]$GemVersion = "18.6.3"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Chef PowerShell Gem Install Comparison Script ===" -ForegroundColor Cyan
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
Get-ChildItem $sharedDir -Filter "*gem-comparison*" | Remove-Item -Force -ErrorAction SilentlyContinue

# Copy MSI to temporary location for Docker build
Write-Host "Preparing MSI for Docker build..." -ForegroundColor Yellow
$tempMsi = Join-Path $PSScriptRoot "chef-installer.msi"
Copy-Item $MsiFile $tempMsi -Force

try {
    # Build Docker image with MSI install
    Write-Host "`n=== Building Chef MSI Docker Image ===" -ForegroundColor Green
    docker build -f Dockerfile.msi --build-arg INSTALL_DUMPBIN=False -t chef-gem-compare:latest .
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build Chef MSI image" -ForegroundColor Red
        exit 1
    }

    # Step 1: Capture initial state after MSI install
    Write-Host "`n=== Capturing Initial State (Post-MSI Install) ===" -ForegroundColor Green
    docker run --rm -v "${PWD}\shared:C:\shared" chef-gem-compare:latest powershell -Command {
        Write-Host "Checking chef-powershell gem directory after MSI install..."
        
        $gemPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-*"
        $chefPSDirectories = Get-ChildItem -Path $gemPath -Directory -ErrorAction SilentlyContinue
        
        $initialState = @{
            Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            State       = "Post-MSI Install"
            Directories = @()
            TotalItems  = 0
        }
        
        if ($chefPSDirectories) {
            foreach ($dir in $chefPSDirectories) {
                Write-Host "Found chef-powershell directory: $($dir.FullName)"
                
                # Get all files and directories recursively
                $items = Get-ChildItem -Path $dir.FullName -Recurse -Force | ForEach-Object {
                    @{
                        Path          = $_.FullName.Replace("C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\", "")
                        Type          = if ($_.PSIsContainer) { "Directory" } else { "File" }
                        Size          = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
                        LastWriteTime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                }
                
                $initialState.Directories += @{
                    Path      = $dir.FullName
                    Name      = $dir.Name
                    Items     = $items
                    ItemCount = $items.Count
                }
                
                $initialState.TotalItems += $items.Count
            }
        }
        else {
            Write-Host "No chef-powershell directories found after MSI install"
        }
        
        # Save initial state to JSON
        $outputPath = "C:\shared\gem-comparison-initial.json"
        $initialState | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding UTF8
        Write-Host "Initial state saved to: $outputPath"
        Write-Host "Total items found: $($initialState.TotalItems)"
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to capture initial state" -ForegroundColor Red
        exit 1
    }

    # Step 2: Install gem and capture final state
    Write-Host "`n=== Installing chef-powershell gem and capturing final state ===" -ForegroundColor Green
    docker run --rm -v "${PWD}\shared:C:\shared" chef-gem-compare:latest powershell -Command {
        param($gemVersion)
        
        Write-Host "Installing chef-powershell gem version $gemVersion..."
        
        # Install the gem
        try {
            & "C:\opscode\chef\embedded\bin\gem" install chef-powershell -v $gemVersion
            Write-Host "Gem installation completed"
        }
        catch {
            Write-Host "Gem installation encountered an issue: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Continuing with state capture..."
        }
        
        Write-Host "Checking chef-powershell gem directory after gem install..."
        
        $gemPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-*"
        $chefPSDirectories = Get-ChildItem -Path $gemPath -Directory -ErrorAction SilentlyContinue
        
        $finalState = @{
            Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            State       = "Post-Gem Install"
            Directories = @()
            TotalItems  = 0
        }
        
        if ($chefPSDirectories) {
            foreach ($dir in $chefPSDirectories) {
                Write-Host "Found chef-powershell directory: $($dir.FullName)"
                
                # Get all files and directories recursively
                $items = Get-ChildItem -Path $dir.FullName -Recurse -Force | ForEach-Object {
                    @{
                        Path          = $_.FullName.Replace("C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\", "")
                        Type          = if ($_.PSIsContainer) { "Directory" } else { "File" }
                        Size          = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
                        LastWriteTime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                }
                
                $finalState.Directories += @{
                    Path      = $dir.FullName
                    Name      = $dir.Name
                    Items     = $items
                    ItemCount = $items.Count
                }
                
                $finalState.TotalItems += $items.Count
            }
        }
        else {
            Write-Host "No chef-powershell directories found after gem install"
        }
        
        # Save final state to JSON
        $outputPath = "C:\shared\gem-comparison-final.json"
        $finalState | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding UTF8
        Write-Host "Final state saved to: $outputPath"
        Write-Host "Total items found: $($finalState.TotalItems)"
        
    } -ArgumentList $GemVersion
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to install gem or capture final state" -ForegroundColor Red
        exit 1
    }

    # Step 3: Generate comparison report
    Write-Host "`n=== Generating Comparison Report ===" -ForegroundColor Green
    
    $initialFile = Join-Path $sharedDir "gem-comparison-initial.json"
    $finalFile = Join-Path $sharedDir "gem-comparison-final.json"
    
    if ((Test-Path $initialFile) -and (Test-Path $finalFile)) {
        $initialState = Get-Content $initialFile | ConvertFrom-Json
        $finalState = Get-Content $finalFile | ConvertFrom-Json
        
        # Create comparison report
        $reportPath = Join-Path $sharedDir "gem-comparison-report.md"
        
        $report = @"
# Chef PowerShell Gem Install Comparison Report

**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**MSI File:** $MsiFile
**Gem Version:** $GemVersion

## Summary

- **Initial State (Post-MSI):** $($initialState.TotalItems) items found
- **Final State (Post-Gem Install):** $($finalState.TotalItems) items found
- **Difference:** $($finalState.TotalItems - $initialState.TotalItems) items

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
        $report += "`n## Detailed Comparison`n"
        
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
            foreach ($item in $newItems) {
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
            foreach ($item in $removedItems) {
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
            foreach ($item in $modifiedItems) {
                $report += "- **File:** $($item.Path)`n"
                $report += "  - Initial: $($item.Initial.Size) bytes, $($item.Initial.LastWriteTime)`n"
                $report += "  - Final: $($item.Final.Size) bytes, $($item.Final.LastWriteTime)`n"
            }
        }
        else {
            $report += "`n### Modified Items: None`n"
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

Write-Host "`n=== Comparison Complete ===" -ForegroundColor Cyan
Write-Host "Check the shared/ directory for detailed results:" -ForegroundColor Green
Write-Host "- gem-comparison-initial.json - Initial state after MSI install" -ForegroundColor White
Write-Host "- gem-comparison-final.json - Final state after gem install" -ForegroundColor White
Write-Host "- gem-comparison-report.md - Human-readable comparison report" -ForegroundColor White