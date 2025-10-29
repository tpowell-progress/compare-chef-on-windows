param(
    [string]$Version1 = "18.8.11",
    [string]$Version2 = "18.8.46"
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

Write-Host "=== Chef Version DLL Comparison Tool ===" -ForegroundColor Cyan
Write-Host "Comparing Chef $Version1 vs $Version2" -ForegroundColor Yellow
Write-Host ""

# Clean shared directory
Write-Host "Cleaning shared directory..." -ForegroundColor Yellow
if (Test-Path ".\shared") {
    Remove-Item ".\shared\*" -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path ".\shared" | Out-Null
}

# Function to build Chef image and extract DLL list
function Get-ChefDlls {
    param(
        [string]$Version,
        [string]$OutputFile
    )
    
    Write-Host "`n=== Building Chef $Version container ===" -ForegroundColor Green
    docker build --build-arg CHEF_VERSION=$Version -t chef-dll-compare:$Version .
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build Chef $Version image" -ForegroundColor Red
        return $false
    }
    
    Write-Host "Extracting DLL list for Chef $Version..." -ForegroundColor Yellow
    docker run --rm `
        -v "${PWD}\shared:C:\shared" `
        -e CHEF_VERSION=$Version `
        -e OUTPUT_FILE=$OutputFile `
        chef-dll-compare:$Version `
        powershell -Command {
            $version = $env:CHEF_VERSION
            $outputFile = $env:OUTPUT_FILE
            
            Write-Host "=== Scanning C:\opscode for DLLs in Chef $version ==="
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            
            # Get all DLL files recursively under C:\opscode
            $dlls = Get-ChildItem -Path "C:\opscode" -Include "*.dll" -Recurse -ErrorAction SilentlyContinue | 
                    Sort-Object FullName
            
            $output = @"
Chef Version: $version
Scan Timestamp: $timestamp
Total DLL Count: $($dlls.Count)

DLL List:
========
"@
            
            foreach ($dll in $dlls) {
                $relativePath = $dll.FullName -replace '^C:\\opscode\\', ''
                $size = $dll.Length
                $lastWrite = $dll.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                $output += "`n$relativePath`t$size`t$lastWrite"
            }
            
            $outputPath = "C:\shared\$outputFile"
            $output | Out-File -FilePath $outputPath -Encoding UTF8
            Write-Host "DLL list saved to $outputPath"
            Write-Host "Found $($dlls.Count) DLL files"
        }
    
    return $LASTEXITCODE -eq 0
}

# Extract DLL lists for both versions
$success1 = Get-ChefDlls -Version $Version1 -OutputFile "chef-$Version1-dlls.txt"
if (-not $success1) {
    Write-Host "Failed to extract DLLs for Chef $Version1" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

$success2 = Get-ChefDlls -Version $Version2 -OutputFile "chef-$Version2-dlls.txt"
if (-not $success2) {
    Write-Host "Failed to extract DLLs for Chef $Version2" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

# Compare the DLL lists
Write-Host "`n=== Comparing DLL lists ===" -ForegroundColor Green

$file1 = ".\shared\chef-$Version1-dlls.txt"
$file2 = ".\shared\chef-$Version2-dlls.txt"
$compareFile = ".\shared\chef-dll-comparison-$Version1-vs-$Version2.txt"

if (-not (Test-Path $file1) -or -not (Test-Path $file2)) {
    Write-Host "Error: DLL list files not found" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

# Parse DLL lists
function Parse-DllList {
    param([string]$FilePath)
    
    $content = Get-Content $FilePath -Raw
    $lines = $content -split "`n"
    $dlls = @{}
    
    $inDllSection = $false
    foreach ($line in $lines) {
        if ($line -match "^DLL List:") {
            $inDllSection = $true
            continue
        }
        if ($line -match "^========") {
            continue
        }
        if ($inDllSection -and $line.Trim() -ne "") {
            $parts = $line -split "`t"
            if ($parts.Count -ge 3) {
                $path = $parts[0].Trim()
                $size = $parts[1].Trim()
                $lastWrite = $parts[2].Trim()
                $dlls[$path] = @{
                    Size = $size
                    LastWrite = $lastWrite
                }
            }
        }
    }
    return $dlls
}

$dlls1 = Parse-DllList $file1
$dlls2 = Parse-DllList $file2

$allPaths = ($dlls1.Keys + $dlls2.Keys) | Sort-Object -Unique

$onlyIn1 = @()
$onlyIn2 = @()
$different = @()
$same = @()

foreach ($path in $allPaths) {
    if ($dlls1.ContainsKey($path) -and $dlls2.ContainsKey($path)) {
        if ($dlls1[$path].Size -eq $dlls2[$path].Size -and $dlls1[$path].LastWrite -eq $dlls2[$path].LastWrite) {
            $same += $path
        } else {
            $different += [PSCustomObject]@{
                Path = $path
                Version1_Size = $dlls1[$path].Size
                Version1_LastWrite = $dlls1[$path].LastWrite
                Version2_Size = $dlls2[$path].Size
                Version2_LastWrite = $dlls2[$path].LastWrite
            }
        }
    } elseif ($dlls1.ContainsKey($path)) {
        $onlyIn1 += $path
    } else {
        $onlyIn2 += $path
    }
}

# Generate comparison report
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$report = @"
Chef DLL Comparison Report
==========================
Generated: $timestamp
Version 1: Chef ${Version1} ($($dlls1.Count) DLLs)
Version 2: Chef ${Version2} ($($dlls2.Count) DLLs)

Summary:
--------
- DLLs only in ${Version1}: $($onlyIn1.Count)
- DLLs only in ${Version2}: $($onlyIn2.Count)
- DLLs with differences: $($different.Count)
- Identical DLLs: $($same.Count)

DLLs Only in Chef ${Version1} ($($onlyIn1.Count)):
$('=' * 50)
"@

foreach ($dll in $onlyIn1) {
    $info = $dlls1[$dll]
    $report += "`n$dll`t$($info.Size)`t$($info.LastWrite)"
}

$report += @"

`nDLLs Only in Chef ${Version2} ($($onlyIn2.Count)):
$('=' * 50)
"@

foreach ($dll in $onlyIn2) {
    $info = $dlls2[$dll]
    $report += "`n$dll`t$($info.Size)`t$($info.LastWrite)"
}

$report += @"

`nDLLs with Differences ($($different.Count)):
$('=' * 50)
"@

foreach ($diff in $different) {
    $report += @"
`n$($diff.Path)
  ${Version1}: Size=$($diff.Version1_Size), LastWrite=$($diff.Version1_LastWrite)
  ${Version2}: Size=$($diff.Version2_Size), LastWrite=$($diff.Version2_LastWrite)
"@
}

$report += @"

`nIdentical DLLs ($($same.Count)):
$('=' * 50)
"@

foreach ($dll in $same | Select-Object -First 10) {
    $info = $dlls1[$dll]
    $report += "`n$dll`t$($info.Size)`t$($info.LastWrite)"
}

if ($same.Count -gt 10) {
    $report += "`n... and $($same.Count - 10) more identical DLLs"
}

# Save comparison report
$report | Out-File -FilePath $compareFile -Encoding UTF8

Write-Host "`nComparison completed!" -ForegroundColor Green
Write-Host "Files generated:" -ForegroundColor Yellow
Write-Host "  - $file1" -ForegroundColor Cyan
Write-Host "  - $file2" -ForegroundColor Cyan
Write-Host "  - $compareFile" -ForegroundColor Cyan

Write-Host "`nSummary:" -ForegroundColor Yellow
Write-Host "  - DLLs only in ${Version1}: $($onlyIn1.Count)" -ForegroundColor $(if ($onlyIn1.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  - DLLs only in ${Version2}: $($onlyIn2.Count)" -ForegroundColor $(if ($onlyIn2.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  - DLLs with differences: $($different.Count)" -ForegroundColor $(if ($different.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "  - Identical DLLs: $($same.Count)" -ForegroundColor Green

Play-CompletionSound -Success $true