# escape=`
FROM mcr.microsoft.com/windows/servercore:ltsc2022

# Set Chef version as build argument with default value
ARG CHEF_VERSION=18.8.11

# Set up PowerShell execution policy
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Install Chef via Omnitruck
RUN Write-Host \"Installing Chef version $env:CHEF_VERSION...\"; `
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    $script = (New-Object System.Net.WebClient).DownloadString('https://omnitruck.chef.io/install.ps1'); `
    $script = $script -replace '^\[Console\]::OutputEncoding.*$', '' -replace 'New-Object -typename System.Text.ASCIIEncoding', 'New-Object -typename System.Text.UTF8Encoding'; `
    Invoke-Expression $script; `
    Install-Project -project chef -version $env:CHEF_VERSION -channel stable

# Accept Chef license
ENV CHEF_LICENSE=accept-silent

# Verify Chef installation and search for Chef.PowerShell.Wrapper.dll
RUN Write-Host 'Verifying Chef installation...'; `
    chef-client --version; `
    Write-Host 'Searching for Chef.PowerShell.Wrapper.dll...'; `
    $wrapperDlls = Get-ChildItem -Path C:\opscode\chef -Include 'Chef.PowerShell.Wrapper.dll' -Recurse -ErrorAction SilentlyContinue; `
    if ($wrapperDlls) { `
        $wrapperDlls | ForEach-Object { `
            Write-Host "Found: $($_.FullName)"; `
            Write-Host "  Size: $($_.Length) bytes"; `
            Write-Host "  LastWriteTime: $($_.LastWriteTime)"; `
        } `
    } else { `
        Write-Host 'Chef.PowerShell.Wrapper.dll not found'; `
    }

# Create directories for Chef
RUN New-Item -ItemType Directory -Force -Path C:\chef; `
    New-Item -ItemType Directory -Force -Path C:\cookbooks; `
    New-Item -ItemType Directory -Force -Path C:\shared

# Set working directory
WORKDIR C:\chef

# Default command
CMD ["powershell"]
