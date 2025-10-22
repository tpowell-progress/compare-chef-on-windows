# Script to build, run, and test Chef Docker containers
# This script creates Windows containers with different Chef versions and tests them

param(
    [string]$ChefVersion1 = "18.8.11",
    [string]$ChefVersion2 = "18.8.46"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Chef Docker Container Test Script ===" -ForegroundColor Cyan
Write-Host "Testing Chef versions: $ChefVersion1 vs $ChefVersion2" -ForegroundColor Cyan
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

# Build and run first Chef version
Write-Host "`n=== Building Chef $ChefVersion1 container ===" -ForegroundColor Green
docker build --build-arg CHEF_VERSION=$ChefVersion1 -t chef-test:$ChefVersion1 .

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build Chef $ChefVersion1 image" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Running Chef $ChefVersion1 container ===" -ForegroundColor Green
docker run --rm `
    -e CHEF_LICENSE=accept-silent `
    -v "${PWD}\shared:C:\shared" `
    -v "${PWD}\cookbooks:C:\cookbooks" `
    chef-test:$ChefVersion1 `
    powershell -Command "chef-client -z -o recipe[test_recipe] --chef-license accept-silent"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Chef $ChefVersion1 execution failed" -ForegroundColor Red
    exit 1
}

# Build and run second Chef version
Write-Host "`n=== Building Chef $ChefVersion2 container ===" -ForegroundColor Green
docker build --build-arg CHEF_VERSION=$ChefVersion2 -t chef-test:$ChefVersion2 .

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build Chef $ChefVersion2 image" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Running Chef $ChefVersion2 container ===" -ForegroundColor Green
docker run --rm `
    -e CHEF_LICENSE=accept-silent `
    -v "${PWD}\shared:C:\shared" `
    -v "${PWD}\cookbooks:C:\cookbooks" `
    chef-test:$ChefVersion2 `
    powershell -Command "chef-client -z -o recipe[test_recipe] --chef-license accept-silent"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Chef $ChefVersion2 execution failed" -ForegroundColor Red
    exit 1
}

# Check results
Write-Host "`n=== Checking Results on Shared Volume ===" -ForegroundColor Cyan
Write-Host ""

$results = Get-ChildItem $sharedDir -Filter "chef-*.txt"

if ($results.Count -eq 0) {
    Write-Host "ERROR: No output files found in shared directory!" -ForegroundColor Red
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
Write-Host "Expected Chef versions: $ChefVersion1 and $ChefVersion2" -ForegroundColor White

$foundVersions = @()
foreach ($file in $results) {
    if ($file.Name -match 'chef-(\d+\.\d+\.\d+)\.txt') {
        $foundVersions += $matches[1]
    }
}

Write-Host "Found Chef versions: $($foundVersions -join ', ')" -ForegroundColor White

if ($foundVersions -contains $ChefVersion1 -and $foundVersions -contains $ChefVersion2) {
    Write-Host "`nSUCCESS: Both Chef versions executed successfully!" -ForegroundColor Green
} else {
    Write-Host "`nWARNING: Not all expected versions found" -ForegroundColor Yellow
}

Write-Host "`n=== Test Complete ===" -ForegroundColor Cyan
