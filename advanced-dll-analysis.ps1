# Advanced DLL dependency analysis and alternative remediation approaches
param(
    [string]$MsiFile = "omnibus-ruby_chef_pkg_chef-client-18.8.50-1-x64.msi"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Advanced Chef PowerShell DLL Dependency Analysis ===" -ForegroundColor Cyan
Write-Host ""

# Create shared directory if it doesn't exist
$sharedDir = Join-Path $PSScriptRoot "shared"
if (-not (Test-Path $sharedDir)) {
    New-Item -ItemType Directory -Path $sharedDir | Out-Null
}

# Copy MSI to temporary location for Docker build
$tempMsi = Join-Path $PSScriptRoot "chef-installer.msi"
Copy-Item $MsiFile $tempMsi -Force

try {
    # Build Docker image with dumpbin tools for DLL analysis
    Write-Host "=== Building Chef MSI Docker Image with Analysis Tools ===" -ForegroundColor Green
    docker build -f Dockerfile.msi --build-arg INSTALL_DUMPBIN=True -t chef-dll-analysis:latest .
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build Chef analysis image" -ForegroundColor Red
        exit 1
    }

    # Create comprehensive analysis script
    $analysisScript = @'
Write-Host "======================================================================="
Write-Host "Advanced Chef PowerShell DLL Dependency Analysis"
Write-Host "======================================================================="

$dllPath = "C:\opscode\chef\embedded\lib\ruby\gems\3.1.0\gems\chef-powershell-18.6.3\bin\ruby_bin_folder\AMD64\Chef.PowerShell.Wrapper.dll"

Write-Host ""
Write-Host "=== DLL Existence and Properties ==="
if (Test-Path $dllPath) {
    $dllInfo = Get-Item $dllPath
    Write-Host "✓ DLL found: $dllPath"
    Write-Host "  Size: $($dllInfo.Length) bytes"
    Write-Host "  LastWriteTime: $($dllInfo.LastWriteTime)"
    Write-Host "  Attributes: $($dllInfo.Attributes)"
} else {
    Write-Host "✗ DLL not found: $dllPath"
    exit 1
}

Write-Host ""
Write-Host "=== DLL Dependencies Analysis (using dumpbin) ==="
try {
    $dumpbinOutput = & dumpbin.exe /dependents $dllPath 2>&1 | Out-String
    Write-Host "Dependencies found:"
    Write-Host $dumpbinOutput
} catch {
    Write-Host "Could not run dumpbin: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== System DLL Search Paths ==="
$env:PATH -split ';' | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object {
    Write-Host "  $($_)"
}

Write-Host ""
Write-Host "=== .NET Framework Analysis ==="
try {
    $netVersions = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP" -Recurse |
                   Get-ItemProperty -Name Version -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Version } | 
                   Select-Object PSPath, Version
    Write-Host ".NET Framework versions installed:"
    $netVersions | ForEach-Object { Write-Host "  $($_.Version) at $($_.PSPath)" }
} catch {
    Write-Host "Could not enumerate .NET versions: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Visual C++ Redistributables Check ==="
try {
    $vcredist = Get-WmiObject -Class Win32_Product | Where-Object { 
        $_.Name -like "*Visual C++*" -or $_.Name -like "*Microsoft Visual C++*" 
    } | Select-Object Name, Version
    if ($vcredist) {
        Write-Host "Visual C++ redistributables found:"
        $vcredist | ForEach-Object { Write-Host "  $($_.Name) - $($_.Version)" }
    } else {
        Write-Host "No Visual C++ redistributables found via WMI"
    }
} catch {
    Write-Host "Could not check VC++ redistributables: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Alternative Gem Operations ==="

# Try gem list to see if gem commands work at all
Write-Host "Testing basic gem functionality..."
try {
    $gemList = & "C:\opscode\chef\embedded\bin\gem.cmd" list chef-powershell 2>&1 | Out-String
    Write-Host "Gem list output:"
    Write-Host $gemList
} catch {
    Write-Host "Gem list failed: $($_.Exception.Message)"
}

# Try gem info  
Write-Host ""
Write-Host "Getting gem info..."
try {
    $gemInfo = & "C:\opscode\chef\embedded\bin\gem.cmd" info chef-powershell 2>&1 | Out-String
    Write-Host "Gem info output:"
    Write-Host $gemInfo
} catch {
    Write-Host "Gem info failed: $($_.Exception.Message)"
}

# Try gem pristine with .cmd extension
Write-Host ""
Write-Host "Attempting gem pristine with .cmd extension..."
try {
    $pristineCmd = & "C:\opscode\chef\embedded\bin\gem.cmd" pristine chef-powershell 2>&1 | Out-String
    Write-Host "Gem pristine (.cmd) output:"
    Write-Host $pristineCmd
} catch {
    Write-Host "Gem pristine (.cmd) failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== File Permissions Analysis ==="
try {
    $acl = Get-Acl $dllPath
    Write-Host "DLL file permissions:"
    $acl.Access | ForEach-Object {
        Write-Host "  $($_.IdentityReference): $($_.AccessControlType) - $($_.FileSystemRights)"
    }
} catch {
    Write-Host "Could not get file permissions: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Manual DLL Loading Test ==="
try {
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class DllTest {
            [DllImport("kernel32.dll")]
            public static extern IntPtr LoadLibrary(string dllToLoad);
            [DllImport("kernel32.dll")]
            public static extern IntPtr GetProcAddress(IntPtr hModule, string procedureName);
            [DllImport("kernel32.dll")]
            public static extern bool FreeLibrary(IntPtr hModule);
        }
"@
    
    $handle = [DllTest]::LoadLibrary($dllPath)
    if ($handle -ne [IntPtr]::Zero) {
        Write-Host "✓ Manual DLL loading succeeded"
        [DllTest]::FreeLibrary($handle) | Out-Null
    } else {
        $error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host "✗ Manual DLL loading failed with error: $error"
    }
} catch {
    Write-Host "Manual DLL loading test failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Alternative Remediation Attempts ==="

# Try gem uninstall and reinstall
Write-Host "Attempting gem uninstall/reinstall..."
try {
    Write-Host "Uninstalling chef-powershell..."
    & "C:\opscode\chef\embedded\bin\gem.cmd" uninstall chef-powershell --force 2>&1 | Out-String | Write-Host
    
    Write-Host "Reinstalling chef-powershell..."
    & "C:\opscode\chef\embedded\bin\gem.cmd" install chef-powershell 2>&1 | Out-String | Write-Host
    
    Write-Host "Checking if DLL exists after reinstall..."
    if (Test-Path $dllPath) {
        $dllInfoNew = Get-Item $dllPath
        Write-Host "✓ DLL recreated: Size: $($dllInfoNew.Length), Time: $($dllInfoNew.LastWriteTime)"
    } else {
        Write-Host "✗ DLL not recreated after reinstall"
    }
    
} catch {
    Write-Host "Gem uninstall/reinstall failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Final Chef Test ==="
try {
    Write-Host "Testing Chef after remediation attempts..."
    $chefResult = & chef-client -z -o recipe[test_recipe] --chef-license accept-silent 2>&1 | Out-String
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Chef test succeeded after remediation!"
    } else {
        Write-Host "✗ Chef test still fails after remediation"
        Write-Host "Error output:"
        Write-Host $chefResult
    }
} catch {
    Write-Host "Final Chef test failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "======================================================================="
'@

    # Run the comprehensive analysis
    Write-Host "`n=== Running Advanced DLL Analysis ===" -ForegroundColor Green
    docker run --rm -e CHEF_LICENSE=accept-silent -v "${PWD}\shared:C:\shared" -v "${PWD}\cookbooks:C:\cookbooks" chef-dll-analysis:latest powershell -Command $analysisScript

}
finally {
    # Clean up temporary MSI file
    if (Test-Path $tempMsi) {
        Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Advanced DLL Analysis Complete ===" -ForegroundColor Cyan