# Function to show menu and get user choice
function Show-Menu {
    Clear-Host
    Write-Host "================ User Management Menu ================"
    Write-Host "1: Unlock/Enable User Account"
    Write-Host "2: Process Leaver"
    Write-Host "3: Process New Starter"
    Write-Host "4: Compare User Groups"
    Write-Host "5: Exit"
    Write-Host "=================================================="
}

# Function to show menu and get user choice
function Compare-UserGroups {
    # Prompt the user for the AD usernames
    $user1 = Read-Host "Enter the username for User 1"
    $user2 = Read-Host "Enter the username for User 2"

    # Fetch the group memberships for each user
    try {
        $groupsUser1 = (Get-ADUser -Identity $user1 -Property MemberOf).MemberOf
        $groupsUser2 = (Get-ADUser -Identity $user2 -Property MemberOf).MemberOf

        # Convert Distinguished Names (DNs) of groups to their names
        $groupNamesUser1 = $groupsUser1 | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }
        $groupNamesUser2 = $groupsUser2 | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }

        # Find unique groups
        $commonGroups = $groupNamesUser1 | Where-Object { $groupNamesUser2 -contains $_ }
        $user1Only = $groupNamesUser1 | Where-Object { $groupNamesUser2 -notcontains $_ }
        $user2Only = $groupNamesUser2 | Where-Object { $groupNamesUser1 -notcontains $_ }

        # Display results
        Write-Host "Common groups:" -ForegroundColor Green
        if ($commonGroups) {
            $commonGroups | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "No common groups."
        }

        Write-Host "`nGroups unique to ${user1}:" -ForegroundColor Yellow
        if ($user1Only) {
            $user1Only | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "No unique groups."
        }

        Write-Host "`nGroups unique to ${user2}:" -ForegroundColor Cyan
        if ($user2Only) {
            $user2Only | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "No unique groups."
        }
    } catch {
        Write-Error "An error occurred: $_"
    }

    Write-Host "`nPress any key to return to the main menu..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# Function for enabling user account
function Enable-UserAccount {
    # Prompt for the username
    $username = Read-Host "Enter the username to enable"

    # Validate if the username is not empty
    if (-not [string]::IsNullOrWhiteSpace($username)) {
        try {
            # Check if the user exists in Active Directory
            $user = Get-ADUser -Identity $username -ErrorAction Stop

            # Enable the user account
            Enable-ADAccount -Identity $username

            Write-Host "User account '$username' has been enabled."
        }
        catch {
            Write-Host "Error: $_"
        }
    } else {
        Write-Host "You must provide a valid username."
    }
    
    Write-Host "`nPress any key to return to the main menu..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# Function for processing leavers
function Process-Leaver {
    # Prompt for the username of the user to process as a leaver
    $userName = Read-Host -Prompt "Enter the username of the leaver"

    # Define the path for the CSV file on the Desktop
    $csvPath = "$([Environment]::GetFolderPath('Desktop'))\${userName}_GroupMembership_MTS.csv"

    # Define the OU path to move the disabled user
    $disabledUserOuPath = "OU=Disabled Users,OU=Disabled_Accounts,OU=HiFX,DC=mts,DC=office,DC=eeft,DC=com"

    # Initialize counters for reporting
    $successfulRemovals = 0
    $failedRemovals = 0
    $skippedGroups = @()

    try {
        # Disable the user account
        Disable-ADAccount -Identity $userName
        Write-Output "User account '$userName' has been disabled."

        # Retrieve group memberships
        $userGroups = Get-ADUser -Identity $userName -Property MemberOf | Select-Object -ExpandProperty MemberOf

        # Export group memberships to CSV (do this before removing from groups)
        $groupMemberships = foreach ($groupDN in $userGroups) {
            try {
                Get-ADGroup -Identity $groupDN -ErrorAction Stop | Select-Object Name, DistinguishedName
            }
            catch {
                # If we can't get the group info, still record what we know
                [PSCustomObject]@{
                    Name = "Unknown Group"
                    DistinguishedName = $groupDN
                }
            }
        }
        $groupMemberships | Export-Csv -Path $csvPath -NoTypeInformation -Force
        Write-Output "Group memberships for '$userName' exported to $csvPath."

        # Remove the user from all groups
        Write-Output "Removing user from groups..."
        foreach ($groupDN in $userGroups) {
            try {
                # First, try to get the group name for better logging
                $groupName = try {
                    (Get-ADGroup -Identity $groupDN -ErrorAction Stop).Name
                } catch {
                    $groupDN
                }

                # Attempt to remove the user from the group
                Remove-ADGroupMember -Identity $groupDN -Members $userName -Confirm:$false -ErrorAction Stop
                Write-Output "✓ Successfully removed '$userName' from group '$groupName'."
                $successfulRemovals++
            }
            catch {
                # Log the specific error and continue with other groups
                $errorMessage = $_.Exception.Message
                Write-Warning "✗ Failed to remove '$userName' from group '$groupName': $errorMessage"
                $skippedGroups += [PSCustomObject]@{
                    GroupName = $groupName
                    GroupDN = $groupDN
                    Error = $errorMessage
                }
                $failedRemovals++
            }
        }

        # Move the user to the Disabled Users OU
        try {
            Move-ADObject -Identity (Get-ADUser -Identity $userName).DistinguishedName -TargetPath $disabledUserOuPath -ErrorAction Stop
            Write-Output "✓ User '$userName' has been moved to '$disabledUserOuPath'."
        }
        catch {
            Write-Warning "✗ Failed to move user to disabled OU: $($_.Exception.Message)"
        }

        # Provide summary report
        Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Cyan
        Write-Host "User: $userName" -ForegroundColor White
        Write-Host "Total groups processed: $($userGroups.Count)" -ForegroundColor White
        Write-Host "Successful removals: $successfulRemovals" -ForegroundColor Green
        Write-Host "Failed removals: $failedRemovals" -ForegroundColor Red

        if ($skippedGroups.Count -gt 0) {
            Write-Host "`nSkipped Groups (manual review may be required):" -ForegroundColor Yellow
            foreach ($skipped in $skippedGroups) {
                Write-Host "  • $($skipped.GroupName)" -ForegroundColor Yellow
                Write-Host "    Reason: $($skipped.Error)" -ForegroundColor DarkYellow
            }
            
            # Export skipped groups to a separate file for manual review
            $skippedGroupsPath = "$([Environment]::GetFolderPath('Desktop'))\${userName}_SkippedGroups_MTS.csv"
            $skippedGroups | Export-Csv -Path $skippedGroupsPath -NoTypeInformation -Force
            Write-Host "`nSkipped groups exported to: $skippedGroupsPath" -ForegroundColor Yellow
        }
        Write-Host "================================================" -ForegroundColor Cyan

    }
    catch {
        Write-Host "Critical Error during leaver processing: $_" -ForegroundColor Red
    }
    
    Write-Host "`nPress any key to return to the main menu..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# Function for processing new starter - copying permissions and moving to same OU
function Process-NewStarter {
    # Prompt for template username and new username
    $templateUsername = Read-Host "Enter the template username"
    $newUsername = Read-Host "Enter the new username"

    # Validate if the usernames are not empty
    if (-not [string]::IsNullOrWhiteSpace($templateUsername) -and -not [string]::IsNullOrWhiteSpace($newUsername)) {
        try {
            # Check if the template user exists in Active Directory
            $templateUser = Get-ADUser -Identity $templateUsername -ErrorAction Stop
            
            # Check if the new user exists in Active Directory
            $newUser = Get-ADUser -Identity $newUsername -ErrorAction Stop

            # Get the groups that the template user is a member of
            $templateUserGroups = Get-ADUser -Identity $templateUsername -Properties MemberOf | 
                                Select-Object -ExpandProperty MemberOf

            # Add the new user to the same groups as the template user
            Write-Host "Copying group memberships..."
            foreach ($group in $templateUserGroups) {
                try {
                    Add-ADGroupMember -Identity $group -Members $newUsername -ErrorAction Stop
                    $groupName = (Get-ADGroup -Identity $group).Name
                    Write-Host "✓ Added '$newUsername' to group '$groupName'." -ForegroundColor Green
                }
                catch {
                    $groupName = try { (Get-ADGroup -Identity $group).Name } catch { $group }
                    Write-Warning "✗ Failed to add '$newUsername' to group '$groupName': $($_.Exception.Message)"
                }
            }

            # Get the OU path of the template user
            $templateUserOU = ($templateUser.DistinguishedName -split ',', 2)[1]
            $newUserCurrentOU = ($newUser.DistinguishedName -split ',', 2)[1]

            # Move the new user to the same OU as the template user (if they're not already there)
            if ($templateUserOU -ne $newUserCurrentOU) {
                try {
                    Move-ADObject -Identity $newUser.DistinguishedName -TargetPath $templateUserOU -ErrorAction Stop
                    Write-Host "✓ Moved '$newUsername' to the same OU as '$templateUsername': $templateUserOU" -ForegroundColor Green
                }
                catch {
                    Write-Warning "✗ Failed to move '$newUsername' to template user's OU: $($_.Exception.Message)"
                }
            } else {
                Write-Host "✓ '$newUsername' is already in the same OU as '$templateUsername'." -ForegroundColor Yellow
            }

            # Reset password to the default new starter password
            try {
                $newPassword = ConvertTo-SecureString -String "1+64Welcome2xe" -AsPlainText -Force
                Set-ADAccountPassword -Identity $newUsername -NewPassword $newPassword -Reset -ErrorAction Stop
                # Disable the user must change password at next logon
                Set-ADUser -Identity $newUsername -ChangePasswordAtLogon $false -ErrorAction Stop
                Write-Host "✓ Password reset to default (user will not be required to change password at next logon)." -ForegroundColor Green
            }
            catch {
                Write-Warning "✗ Failed to reset password: $($_.Exception.Message)"
            }

            Write-Host "`nNew starter '$newUsername' has been successfully set up using '$templateUsername' as template." -ForegroundColor Cyan
        } catch {
            Write-Host "Error: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "You must provide valid template and new usernames." -ForegroundColor Red
    }
    
    Write-Host "`nPress any key to return to the main menu..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# Main program loop
do {
    Show-Menu
    $choice = Read-Host "Please enter your choice"
    
    switch ($choice) {
        '1' {
            Enable-UserAccount
        }
        '2' {
            Process-Leaver
        }
        '3' {
            Process-NewStarter
        }
        '4' {
            Compare-UserGroups
        }
        '5' {
            Write-Host "Exiting..."
            return
        }
        default {
            Write-Host "Invalid option. Please try again."
            Start-Sleep -Seconds 2
        }
    }
} while ($true)