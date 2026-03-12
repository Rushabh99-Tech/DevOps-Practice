# Method 1: Using stored encrypted credentials
# First time setup - run these commands separately to create the encrypted credential file
# $credential = Get-Credential -Message "Enter domain admin credentials"
# $credential | Export-Clixml -Path "$env:USERPROFILE\secure_credentials.xml"

# Import credentials securely from file
function Get-SecureCredential {
    $credPath = "$env:USERPROFILE\secure_credentials.xml"
    
    if (Test-Path $credPath) {
        $importedCred = Import-Clixml -Path $credPath
        return $importedCred
    }
    else {
        Write-Host "No stored credentials found. Please enter credentials."
        $credential = Get-Credential -Message "Enter domain admin credentials"
        
        # Optionally save for future use
        $saveCredential = Read-Host "Would you like to save these credentials for future use? (y/n)"
        if ($saveCredential -eq 'y') {
            $credential | Export-Clixml -Path $credPath
        }
        
        return $credential
    }
}

# List of session host names
$sessionHosts = @(
    "MUXE-RDSH08B.hifxglobal.com",
    "MUXE-RDSH07B.hifxglobal.com",
    "MUXE-RDSH06B.hifxglobal.com",
    "MUXE-RDSH05B.hifxglobal.com",
    "MUXE-RDSH04B.hifxglobal.com",
    "MUXE-RDSH03B.hifxglobal.com",
    "MUXE-RDSH02B.hifxglobal.com",
    "MUXE-RDSH01B.hifxglobal.com"
)

# Get credentials securely
$DomainBCredential = Get-SecureCredential

# Prompt user for the username to search
do {
    $UserName = Read-Host -Prompt "Please enter the username to search for"
} until ($UserName)

Write-Host "Checking all session hosts simultaneously for user: $UserName"
$startTime = Get-Date

# PARALLEL PROCESSING: Check all servers simultaneously
$jobs = @()
foreach ($sessionHostName in $sessionHosts) {
    Write-Host "Starting check on host: $sessionHostName"
    
    $job = Start-Job -ScriptBlock {
        param($sessionHostName, $UserName, $DomainBCredential)
        
        try {
            # Direct command execution using Invoke-Command
            $quserResult = Invoke-Command -ComputerName $sessionHostName `
                -Credential $DomainBCredential `
                -ArgumentList $UserName `
                -ErrorAction Stop `
                -ScriptBlock {
                    param($username)
                    $result = quser 2>$null | Where-Object { $_ -match $username }
                    return $result
                }
            
            if ($quserResult) {
                return @{
                    HostName = $sessionHostName
                    UserFound = $true
                    Result = $quserResult
                    Error = $null
                }
            }
            else {
                return @{
                    HostName = $sessionHostName
                    UserFound = $false
                    Result = $null
                    Error = $null
                }
            }
        }
        catch {
            return @{
                HostName = $sessionHostName
                UserFound = $false
                Result = $null
                Error = $_.Exception.Message
            }
        }
    } -ArgumentList $sessionHostName, $UserName, $DomainBCredential
    
    $jobs += $job
}

# Wait for all jobs to complete and collect results
Write-Host "Waiting for all checks to complete..."
$results = @()
foreach ($job in $jobs) {
    $jobResult = Receive-Job -Job $job -Wait
    $results += $jobResult
    Remove-Job -Job $job
}

$endTime = Get-Date
$duration = $endTime - $startTime
Write-Host "All checks completed in $($duration.TotalSeconds) seconds"

# Process results
$sessionHost = $null
$foundHosts = @()

foreach ($result in $results) {
    if ($result.Error) {
        Write-Host "Error checking session on $($result.HostName): $($result.Error)" -ForegroundColor Yellow
    }
    elseif ($result.UserFound) {
        Write-Host "User $UserName found on host: $($result.HostName)" -ForegroundColor Green
        $foundHosts += $result.HostName
        if (-not $sessionHost) {
            $sessionHost = $result.HostName  # Use the first found host
        }
    }
    else {
        Write-Host "User $UserName not found on host: $($result.HostName)" -ForegroundColor Gray
    }
}

# Handle multiple sessions or no sessions found
if ($foundHosts.Count -eq 0) {
    Write-Host "User $UserName is not logged into any session host." -ForegroundColor Red
    exit
}
elseif ($foundHosts.Count -gt 1) {
    Write-Host "User $UserName found on multiple hosts: $($foundHosts -join ', ')" -ForegroundColor Yellow
    Write-Host "Using the first found host: $sessionHost" -ForegroundColor Yellow
}
else {
    Write-Host "User $UserName is logged into session host: $sessionHost" -ForegroundColor Green
}

# Define the process name to terminate
$processName = "DFXdesk.exe"

# Terminate the process
Write-Host "Terminating $processName process for user $UserName on $sessionHost..."
try {
    Invoke-Command -ComputerName $sessionHost `
        -Credential $DomainBCredential `
        -ArgumentList $UserName, $processName `
        -ScriptBlock {
            param($username, $processname)
            $processTerminated = $false
            Get-WmiObject -Class Win32_Process | ForEach-Object {
                try {
                    $owner = $_.GetOwner()
                    if ($owner.User -eq $username -and $_.Name -eq $processname) {
                        $_.Terminate() | Out-Null
                        Write-Host "Terminated process: $($_.Name) with ID $($_.ProcessId) for user $username"
                        $processTerminated = $true
                    }
                }
                catch {
                    # Suppress errors for processes we can't access
                }
            }
            if (-not $processTerminated) {
                Write-Host "No $processname process found for user $username"
            }
        }
}
catch {
    Write-Host "Error terminating processes: $($_.Exception.Message)" -ForegroundColor Red
}

# Get session ID and log off user
try {
    Write-Host "Logging off user ${UserName} from session host: $sessionHost"
    
    $sessionId = Invoke-Command -ComputerName $sessionHost `
        -Credential $DomainBCredential `
        -ArgumentList $UserName `
        -ScriptBlock {
            param($username)
            $quserOutput = quser | Where-Object { $_ -match $username }
            if ($quserOutput) {
                return ($quserOutput -split '\s+')[2]
            }
            return $null
        }

    if ($sessionId) {
        Invoke-Command -ComputerName $sessionHost `
            -Credential $DomainBCredential `
            -ArgumentList $sessionId `
            -ScriptBlock {
                param($sessionId)
                logoff $sessionId
                Write-Host "Logged off session ID: $sessionId"
            }
        Write-Host "User ${UserName} has been logged off from session host: $sessionHost" -ForegroundColor Green
    }
    else {
        Write-Host "Could not find session ID for user ${UserName}" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error during logoff: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "Script completed." -ForegroundColor Cyan


#testtesttest