# Script to analyze differences between pre and post dumpbin DLL states
# Identifies what was added and compares with ruby_bin folder DLLs

param(
    [string]$PreFile = ".\shared\predumpbin.txt",
    [string]$PostFile = ".\shared\postdumpbin.txt"
)

$ErrorActionPreference = "Stop"

Write-Host "=== DLL Change Analysis Script ===" -ForegroundColor Cyan
Write-Host ""

# Validate input files exist
if (-not (Test-Path $PreFile)) {
    Write-Host "ERROR: Pre-dumpbin file not found: $PreFile" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $PostFile)) {
    Write-Host "ERROR: Post-dumpbin file not found: $PostFile" -ForegroundColor Red
    exit 1
}

Write-Host "Analyzing files:" -ForegroundColor Yellow
Write-Host "  Pre:  $PreFile"
Write-Host "  Post: $PostFile"
Write-Host ""

# Helper function to parse DLL information from file
function Parse-DllInfo {
    param([string]$FilePath)
    
    $content = Get-Content $FilePath -Raw
    $dllInfo = @{}
    
    # Split by DLL sections
    $sections = $content -split '(?m)^=== (.+?\.dll) ===$'
    
    for ($i = 1; $i -lt $sections.Count; $i += 2) {
        $dllName = $sections[$i].Trim()
        $dllContent = $sections[$i + 1]
        
        if ($dllContent -notmatch 'Not found') {
            # Parse multiple instances of the same DLL
            $instances = $dllContent -split '(?m)^Path: '
            
            foreach ($instance in $instances) {
                if ($instance.Trim() -eq '') { continue }
                
                # Extract path
                if ($instance -match '^(.+?)[\r\n]') {
                    $path = $matches[1].Trim()
                    
                    # Extract size
                    $size = if ($instance -match 'Size: (\d+)') { $matches[1] } else { 'Unknown' }
                    
                    # Extract MD5
                    $md5 = if ($instance -match 'MD5: ([A-F0-9]+)') { $matches[1] } else { 'Unknown' }
                    
                    # Extract SHA256
                    $sha256 = if ($instance -match 'SHA256: ([A-F0-9]+)') { $matches[1] } else { 'Unknown' }
                    
                    # Extract LastWriteTime
                    $lastWrite = if ($instance -match 'LastWriteTime: (.+?)[\r\n]') { $matches[1].Trim() } else { 'Unknown' }
                    
                    # Create unique key for this DLL instance
                    $key = "$dllName|$path"
                    
                    $dllInfo[$key] = @{
                        Name = $dllName
                        Path = $path
                        Size = $size
                        MD5 = $md5
                        SHA256 = $sha256
                        LastWriteTime = $lastWrite
                    }
                }
            }
        }
    }
    
    return $dllInfo
}

Write-Host "Parsing pre-dumpbin state..." -ForegroundColor Yellow
$preDlls = Parse-DllInfo -FilePath $PreFile

Write-Host "Parsing post-dumpbin state..." -ForegroundColor Yellow
$postDlls = Parse-DllInfo -FilePath $PostFile

Write-Host ""
Write-Host "=== Analysis Results ===" -ForegroundColor Cyan
Write-Host ""

# Find added DLLs
$addedDlls = @{}
foreach ($key in $postDlls.Keys) {
    if (-not $preDlls.ContainsKey($key)) {
        $addedDlls[$key] = $postDlls[$key]
    }
}

# Find removed DLLs (shouldn't happen, but check anyway)
$removedDlls = @{}
foreach ($key in $preDlls.Keys) {
    if (-not $postDlls.ContainsKey($key)) {
        $removedDlls[$key] = $preDlls[$key]
    }
}

# Find changed DLLs (same path, different checksum)
$changedDlls = @{}
foreach ($key in $preDlls.Keys) {
    if ($postDlls.ContainsKey($key)) {
        $pre = $preDlls[$key]
        $post = $postDlls[$key]
        
        if ($pre.SHA256 -ne $post.SHA256) {
            $changedDlls[$key] = @{
                Pre = $pre
                Post = $post
            }
        }
    }
}

# Display results
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Total DLLs before: $($preDlls.Count)" -ForegroundColor White
Write-Host "  Total DLLs after:  $($postDlls.Count)" -ForegroundColor White
Write-Host "  Added:             $($addedDlls.Count)" -ForegroundColor Green
Write-Host "  Removed:           $($removedDlls.Count)" -ForegroundColor Red
Write-Host "  Changed:           $($changedDlls.Count)" -ForegroundColor Yellow
Write-Host ""

# Report added DLLs
if ($addedDlls.Count -gt 0) {
    Write-Host "=== ADDED DLLs ===" -ForegroundColor Green
    Write-Host ""
    
    foreach ($key in ($addedDlls.Keys | Sort-Object)) {
        $dll = $addedDlls[$key]
        Write-Host "  $($dll.Name)" -ForegroundColor Cyan
        Write-Host "    Path:          $($dll.Path)"
        Write-Host "    Size:          $($dll.Size) bytes"
        Write-Host "    LastWriteTime: $($dll.LastWriteTime)"
        Write-Host "    MD5:           $($dll.MD5)"
        Write-Host "    SHA256:        $($dll.SHA256)"
        Write-Host ""
    }
}

# Report removed DLLs
if ($removedDlls.Count -gt 0) {
    Write-Host "=== REMOVED DLLs ===" -ForegroundColor Red
    Write-Host ""
    
    foreach ($key in ($removedDlls.Keys | Sort-Object)) {
        $dll = $removedDlls[$key]
        Write-Host "  $($dll.Name)" -ForegroundColor Cyan
        Write-Host "    Path:          $($dll.Path)"
        Write-Host "    Size:          $($dll.Size) bytes"
        Write-Host "    MD5:           $($dll.MD5)"
        Write-Host "    SHA256:        $($dll.SHA256)"
        Write-Host ""
    }
}

# Report changed DLLs
if ($changedDlls.Count -gt 0) {
    Write-Host "=== CHANGED DLLs ===" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($key in ($changedDlls.Keys | Sort-Object)) {
        $change = $changedDlls[$key]
        Write-Host "  $($change.Pre.Name)" -ForegroundColor Cyan
        Write-Host "    Path: $($change.Pre.Path)"
        Write-Host ""
        Write-Host "    BEFORE:" -ForegroundColor Yellow
        Write-Host "      Size:          $($change.Pre.Size) bytes"
        Write-Host "      LastWriteTime: $($change.Pre.LastWriteTime)"
        Write-Host "      MD5:           $($change.Pre.MD5)"
        Write-Host "      SHA256:        $($change.Pre.SHA256)"
        Write-Host ""
        Write-Host "    AFTER:" -ForegroundColor Yellow
        Write-Host "      Size:          $($change.Post.Size) bytes"
        Write-Host "      LastWriteTime: $($change.Post.LastWriteTime)"
        Write-Host "      MD5:           $($change.Post.MD5)"
        Write-Host "      SHA256:        $($change.Post.SHA256)"
        Write-Host ""
    }
}

# Now compare added DLLs with ruby_bin folder equivalents
if ($addedDlls.Count -gt 0) {
    Write-Host "=== COMPARISON WITH ruby_bin FOLDER ===" -ForegroundColor Cyan
    Write-Host ""
    
    # Group DLLs by name to find ruby_bin versions
    $dllsByName = @{}
    foreach ($key in $postDlls.Keys) {
        $dll = $postDlls[$key]
        if (-not $dllsByName.ContainsKey($dll.Name)) {
            $dllsByName[$dll.Name] = @()
        }
        $dllsByName[$dll.Name] += $dll
    }
    
    foreach ($key in ($addedDlls.Keys | Sort-Object)) {
        $addedDll = $addedDlls[$key]
        $dllName = $addedDll.Name
        
        Write-Host "Analyzing: $dllName" -ForegroundColor Cyan
        Write-Host "  Added location: $($addedDll.Path)" -ForegroundColor Green
        
        # Find ruby_bin versions of this DLL
        $rubyBinVersions = $dllsByName[$dllName] | Where-Object { 
            $_.Path -match 'ruby_bin.*AMD64' -and $_.Path -ne $addedDll.Path
        }
        
        if ($rubyBinVersions) {
            Write-Host "  Found in ruby_bin\AMD64:" -ForegroundColor Yellow
            
            foreach ($rubyDll in $rubyBinVersions) {
                Write-Host "    Path: $($rubyDll.Path)"
                
                # Compare checksums
                if ($rubyDll.SHA256 -eq $addedDll.SHA256) {
                    Write-Host "      âœ“ IDENTICAL (SHA256 matches)" -ForegroundColor Green
                } else {
                    Write-Host "      âœ— DIFFERENT (SHA256 mismatch)" -ForegroundColor Red
                    Write-Host "        ruby_bin SHA256: $($rubyDll.SHA256)"
                    Write-Host "        Added SHA256:    $($addedDll.SHA256)"
                    
                    # Compare sizes
                    if ($rubyDll.Size -eq $addedDll.Size) {
                        $sizeBytes = $rubyDll.Size
                        Write-Host "        Size: Same - $sizeBytes bytes"
                    } else {
                        $rubySize = $rubyDll.Size
                        $addedSize = $addedDll.Size
                        Write-Host "        Size: Different - ruby_bin: $rubySize bytes, added: $addedSize bytes" -ForegroundColor Yellow
                    }
                }
                Write-Host ""
            }
        } else {
            Write-Host "  NOT found in ruby_bin\AMD64 folder" -ForegroundColor Magenta
            Write-Host ""
        }
    }
}

# Summary of findings
Write-Host "=== KEY FINDINGS ===" -ForegroundColor Cyan
Write-Host ""

if ($addedDlls.Count -eq 0 -and $changedDlls.Count -eq 0) {
    Write-Host "âœ“ No changes detected - Installing dumpbin did not add or modify any of the tracked DLLs" -ForegroundColor Green
} else {
    if ($addedDlls.Count -gt 0) {
        Write-Host "â€¢ Dumpbin installation added $($addedDlls.Count) DLL(s)" -ForegroundColor Yellow
        
        # Check if any added DLLs match ruby_bin versions
        $identicalToRubyBin = 0
        $differentFromRubyBin = 0
        $notInRubyBin = 0
        
        $dllsByName = @{}
        foreach ($key in $postDlls.Keys) {
            $dll = $postDlls[$key]
            if (-not $dllsByName.ContainsKey($dll.Name)) {
                $dllsByName[$dll.Name] = @()
            }
            $dllsByName[$dll.Name] += $dll
        }
        
        foreach ($key in $addedDlls.Keys) {
            $addedDll = $addedDlls[$key]
            $rubyBinVersions = $dllsByName[$addedDll.Name] | Where-Object { 
                $_.Path -match 'ruby_bin.*AMD64' -and $_.Path -ne $addedDll.Path
            }
            
            if ($rubyBinVersions) {
                $isIdentical = $false
                foreach ($rubyDll in $rubyBinVersions) {
                    if ($rubyDll.SHA256 -eq $addedDll.SHA256) {
                        $isIdentical = $true
                        break
                    }
                }
                
                if ($isIdentical) {
                    $identicalToRubyBin++
                } else {
                    $differentFromRubyBin++
                }
            } else {
                $notInRubyBin++
            }
        }
        
        if ($identicalToRubyBin -gt 0) {
            Write-Host "  - $identicalToRubyBin DLL(s) are IDENTICAL to ruby_bin\AMD64 versions" -ForegroundColor Green
        }
        if ($differentFromRubyBin -gt 0) {
            Write-Host "  - $differentFromRubyBin DLL(s) are DIFFERENT from ruby_bin\AMD64 versions" -ForegroundColor Red
        }
        if ($notInRubyBin -gt 0) {
            Write-Host "  - $notInRubyBin DLL(s) are NOT present in ruby_bin\AMD64 folder" -ForegroundColor Magenta
        }
    }
    
    if ($changedDlls.Count -gt 0) {
        Write-Host "â€¢ Dumpbin installation modified $($changedDlls.Count) existing DLL(s)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Analysis Complete ===" -ForegroundColor Cyan
