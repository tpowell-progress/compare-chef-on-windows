param(
    [Parameter(Mandatory=$true)]
    [string]$MsiFile
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

Write-Host "=== Simple Chef Docker Container Test ===" -ForegroundColor Cyan
Write-Host "Testing with MSI file: $MsiFile" -ForegroundColor Yellow

# Validate MSI file exists
if (-not (Test-Path $MsiFile)) {
    Write-Host "Error: MSI file not found: $MsiFile" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

$msiPath = Resolve-Path $MsiFile
Write-Host ""

# Clean shared directory
Write-Host "Cleaning shared directory..." -ForegroundColor Yellow
if (Test-Path ".\shared") {
    Remove-Item ".\shared\*" -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path ".\shared" | Out-Null
}

# Copy test file to shared directory
$testFile = ".\test-chef-ps.rb"
if (Test-Path $testFile) {
    Copy-Item $testFile ".\shared\test-chef-ps.rb" -Force
    Write-Host "Copied test-chef-ps.rb to shared directory" -ForegroundColor Green
} else {
    Write-Host "Warning: test-chef-ps.rb not found in current directory" -ForegroundColor Yellow
}

# Copy MSI to root directory as chef-installer.msi for Dockerfile
$tempMsi = ".\chef-installer.msi"
Copy-Item $msiPath $tempMsi -Force

# Extract version from MSI filename or use "msi" as version
if ($msiPath -match 'chef-(\d+\.\d+\.\d+)') {
    $extractedVersion = $matches[1]
    $imageTag = "simple-$extractedVersion"
} else {
    $extractedVersion = "msi"
    $imageTag = "simple"
}

Write-Host "`n=== Building Chef MSI container ===" -ForegroundColor Green
docker build -f Dockerfile.msi -t chef-test:$imageTag .
Remove-Item $tempMsi -Force

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to build Chef MSI image" -ForegroundColor Red
    Play-CompletionSound -Success $false
    exit 1
}

# Run pre-check
Write-Host "`n=== Running Chef MSI container ===" -ForegroundColor Green
Write-Host "Verifying Chef installation..." -ForegroundColor Yellow

docker run --rm `
    -v "${PWD}\shared:C:\shared" `
    chef-test:$imageTag `
    powershell -Command {
        Write-Host '=== Chef Installation Verification ==='
        $chefVersion = (chef-client --version) -replace 'Chef Infra Client: ', ''
        Write-Host "Chef Version: $chefVersion"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $computerName = $env:COMPUTERNAME
        
        $chefClientPath = Get-Command chef-client | Select-Object -ExpandProperty Source
        $output = "Chef Version: $chefVersion`nInstallation Method: MSI`nComputer Name: $computerName`nTimestamp: $timestamp`nChef Client Path: $chefClientPath"
        
        $fileTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputFile = "C:\shared\chef-$chefVersion-$fileTimestamp.txt"
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
        $env:PATH="$env:PATH;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64;C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.1.0\bin\ruby_bin_folder\AMD64\shared\Microsoft.NETCore.App\5.0.0"
        Write-Host "Path: $env:PATH"
        chef-client -z -o recipe[test_recipe] --chef-license accept-silent
    }

if ($LASTEXITCODE -ne 0) {
    Write-Host "Chef MSI execution failed" -ForegroundColor Red
    Write-Host "`n=== Chef run failed - Starting interactive container for debugging ===" -ForegroundColor Yellow
    Write-Host "You will be dropped into a PowerShell session in the container." -ForegroundColor Cyan
    Write-Host "Type 'exit' to leave the container when you're done debugging." -ForegroundColor Cyan
    Write-Host ""
    
    # Start an interactive container for debugging
    docker run --rm -it `
        -e CHEF_LICENSE=accept-silent `
        -v "${PWD}\shared:C:\shared" `
        -v "${PWD}\cookbooks:C:\cookbooks" `
        chef-test:$imageTag `
        powershell
    
    Play-CompletionSound -Success $false
    exit 1
}

# Run chef-powershell test suite
Write-Host "`n=== Running chef-powershell test suite ===" -ForegroundColor Green
if (Test-Path ".\shared\test-chef-ps.rb") {
    docker run --rm `
        -e CHEF_LICENSE=accept-silent `
        -v "${PWD}\shared:C:\shared" `
        chef-test:$imageTag `
        powershell -Command {
            Write-Host "=== Chef PowerShell Test Suite ==="
            $rubyPath = "C:\opscode\chef\embedded\bin\ruby.exe"
            $testFile = "C:\shared\test-chef-ps.rb"
            
            if (Test-Path $rubyPath) {
                Write-Host "Ruby path: $rubyPath"
                Write-Host "Running test file: $testFile"
                Write-Host ""
                & $rubyPath $testFile
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "`nTest suite failed with exit code: $LASTEXITCODE" -ForegroundColor Red
                    exit $LASTEXITCODE
                } else {
                    Write-Host "`nTest suite completed successfully" -ForegroundColor Green
                }
            } else {
                Write-Host "Error: Ruby not found at $rubyPath" -ForegroundColor Red
                exit 1
            }
        }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nchef-powershell test suite failed" -ForegroundColor Red
        Write-Host "Starting interactive container for debugging..." -ForegroundColor Yellow
        
        docker run --rm -it `
            -e CHEF_LICENSE=accept-silent `
            -v "${PWD}\shared:C:\shared" `
            chef-test:$imageTag `
            powershell
        
        Play-CompletionSound -Success $false
        exit 1
    }
} else {
    Write-Host "Warning: test-chef-ps.rb not found in shared directory, skipping test suite" -ForegroundColor Yellow
}

Write-Host "`n=== Test completed successfully ===" -ForegroundColor Green
Write-Host "Check the shared directory for output files" -ForegroundColor Yellow
Play-CompletionSound -Success $true
