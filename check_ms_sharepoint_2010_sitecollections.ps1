# Script name:   	check_sharepoint2010_sitecollection_sizes.ps1
# Version:			v1.6.6
# Created on:    	25/11/2014																			
# Author:        	JDC,WRI
# Purpose:       	Checks Microsoft Sharepoint 2010 site collections for size, reporting site
# 					collections that are near or over the set storage limits.
# Recent History:  	
# 	25/11/2014 => Script created - JDC
#	03/06/2015 => Sum of usage is reported as a counter - JDC
#	03/06/2015 => Added perfdata for webapps - JDC
#   30/11/2015 => Changed Default Exitcode to 3, added code for check on 0 = OK. - WRI
# Copyright:
#	This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public 
#	License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
#	version. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the 
#	implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
#	details at <http://www.gnu.org/licenses/>.

#Requires –Version 2.0


# Passing Structure
$TaskStruct = New-Object PSObject -Property @{
    WebApp = $null;
    UseSharepointWarningLimit = $true;
    WarningTreshold = [int]90;
    CriticalTreshold = [int]95;
    ExitCode = [int]3;
    OutputString = [string]"Critical: Error processing, no data returned"
}
	
#region Functions
Function Process-Args {
    Param ( 
        [Parameter(Mandatory=$True)]$Args
    )
	
# Loop through all passed arguments

    try {
        For ( $i = 0; $i -lt $Args.count; $i++ ) {     
            $CurrentArg = $Args[$i].ToString()
            if ($i -lt $Args.Count-1) {
                $Value = $Args[$i+1];
                Check-Strings $Value | out-null
            } else {
                $Value = ""
            };

            switch -regex ($CurrentArg) {
                "^(-WA|--WebApp)$" {
                    $TaskStruct.WebApp = $Value
                    $i++
                }
                "^(-w|--Warning)$" {
                    if (($value -match "^[\d]+$") -and ([int]$value -lt 100)) {
                        $TaskStruct.WarningTreshold = $value
                        $TaskStruct.UseSharepointWarningLimit = $false
                    } else {
                        throw "Warning treshold should be numeric and less than 100. Value given is $value"
                    }
                    $i++
                }
                "^(-c|--Critical)$" {
                    if (($value -match "^[\d]+$") -and ([int]$value -lt 100)) {
                        $TaskStruct.CriticalTreshold = $value
                    } else {
                        throw "Critical treshold should be numeric and less than 100. Value given is $value"
                    }
                    $i++
                 }
                 "^(-h|--Help)$" {
                    Write-Help
                }
                default {
                    throw "Unknown parameter $_"
                 }
            }
        }
    } catch {
		Write-Host $_
        Exit $Return.ExitCode
	}
}

# Function to check strings for invalid and potentially malicious chars

Function Check-Strings {
    Param ( [Parameter(Mandatory=$True)][string]$String )
    # `, `n, |, ; are bad, I think we can leave {}, @, and $ at this point.
    $BadChars=@("``", "|", ";", "`n")

    $BadChars | ForEach-Object {

        If ( $String.Contains("$_") ) {
            Write-Host "Unknown: String contains illegal characters."
            Exit $TaskStruct.ExitCode
        }
    }
    Return $true
} 

# Function to write help output
Function Write-Help {
    Write-Host @"
check_sharepoint2010_sitecollection_sizes.ps1:
    This script is designed to check the storage usage of Microsoft Sharepoint 2010 Site Collections.
Arguments:
   -WA or --WebApp ) Optional webapp to check. If omitted, all webapps are checked.
    -w or --Warning ) Warning threshold for percentage of quota usage. If omited, uses set quota warning limit.
    -c or --Critial ) Critical threshold for percentage of quota usage. Defaults to 95%.
    -h or --Help ) Print this help output.
"@
    Exit 0;
} 

#endregion Functions

# Main function to kick off functionality

Function Check-MS-Shp2010-SiteCollections {

    Add-PSSnapin Microsoft.Sharepoint.Powershell -ea SilentlyContinue

    $allsites = & {
        if ($TaskStruct.WebApp) {
            Get-SPSite -Limit ALL -WebApp $TaskStruct.WebApp
        } Else {
            Get-SPSite -Limit ALL
        }
    } | ? {$_.Quota.StorageMaximumLevel -ne 0} | Select URL, 
        @{Name='CurrentSize';Expression={[int]($_.Usage.Storage/1024/1024)}}, 
        @{Name="MaxSize";Expression={[int]($_.Quota.StorageMaximumLevel/1024/1024)}}, 
        @{Name="WarningSize";Expression={[int]($_.Quota.StorageWarningLevel/1024/1024)}},
        @{Name="PercentUsed";Expression={[int]($_.Usage.Storage*100/$_.Quota.StorageMaximumLevel)}}

    
        
   # $TaskStruct.ExitCode = 0 # default 0
    $WarnList = @()
    $CriticalList = @()
    $Result = "OK"
    
    $allsites | ? {$_.PercentUsed -lt $taskstruct.CriticalTreshold -and  ( ($taskstruct.UseSharepointWarningLimit -and $_.CurrentSize -lt $_.WarningSize) -or  (-not $taskstruct.UseSharepointWarningLimit -and $_.PercentUsed -lt $taskstruct.WarningTreshold)  )}     | % {
        $TaskStruct.ExitCode = 0
    }
    $allsites | ? {$_.PercentUsed -lt $taskstruct.CriticalTreshold -and  ( ($taskstruct.UseSharepointWarningLimit -and $_.CurrentSize -ge $_.WarningSize) -or  (-not $taskstruct.UseSharepointWarningLimit -and $_.PercentUsed -ge $taskstruct.WarningTreshold)  )}     | % {
        $TaskStruct.ExitCode = 1
        $Result = "WARN"
        $WarnList += "$($_.URL) at $($_.PercentUsed)% of quota ($($_.CurrentSize)/$($_.MaxSize)MB)"
    }
    $allsites | ? {$_.PercentUsed -ge $taskstruct.CriticalTreshold} | % {
        $TaskStruct.ExitCode = 2
        $Result = "CRITICAL"
        $CriticalList += "$($_.URL) at $($_.PercentUsed)% of quota ($($_.CurrentSize)/$($_.MaxSize)MB)"
    }
    
    
    
    $taskstruct.OutputString = $Result + ' : ' + (($CriticalList + $WarnList) -join ';') + '|' + ((
	
	Get-SPWebApplication | % {
		$size = ($_.sites | select -exp usage | select -exp storage | measure -sum).sum / 1GB
		"'$($_.url -replace '^http[s]*://(.*)/$','$1')'=$($size)G"
	}
    ) -join ' ')

    Write-Host $taskStruct.OutputString
    Exit $TaskStruct.ExitCode
}

# Main block

# Reuse threads
if ($PSVersionTable){$Host.Runspace.ThreadOptions = 'ReuseThread'}

# Main function
if($Args.count -ge 1){Process-Args $Args}

Check-MS-Shp2010-SiteCollections
