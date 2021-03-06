#requires -Version 3

# Pull in vars
$vars = (Get-Item $PSScriptRoot).Parent.FullName + '\vars.ps1'
Invoke-Expression -Command ($vars)

### Import modules or snapins
$powercli = Get-PSSnapin -Name VMware.VimAutomation.Core -Registered

try 
{
    switch ($powercli.Version.Major) {
        {
            $_ -ge 6
        }
        {
            Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop
            Write-Host -Object 'PowerCLI 6+ module imported'
        }
        5
        {
            Add-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction Stop
            Write-Warning -Message 'PowerCLI 5 snapin added; recommend upgrading your PowerCLI version'
        }
        default 
        {
            throw 'This script requires PowerCLI version 5 or later'
        }
    }
}
catch 
{
    throw 'Could not load the required VMware.VimAutomation.Vds cmdlets'
}

# Ignore self-signed SSL certificates for vCenter Server (optional)
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -DisplayDeprecationWarnings:$false -Scope User -Confirm:$false

# Connect to vCenter
try 
{
    $null = Connect-VIServer $global:vc -ErrorAction Stop
}
catch 
{
    throw 'Could not connect to vCenter'
}

# Host vitals
[System.Collections.ArrayList]$vmhosts = (Get-VMHost).Name

foreach ($vmhost in $vmhosts)
{
    Write-Host -Object "Now pulling data from $vmhost"
    
    [System.Collections.ArrayList]$points = @()
    $points.Add([Math]::Round((Get-VMHost $vmhost).CpuUsageMhz[0] / (Get-VMHost $vmhost).CpuTotalMhz[0], 2) * 100)
    $points.Add([Math]::Round((Get-VMHost $vmhost).MemoryUsageGB[0] / (Get-VMHost $vmhost).MemoryTotalGB[0], 2) * 100)
    $points.Add(((Get-Stat -Entity (Get-VMHost $vmhost) -Stat 'cpu.ready.summation' -Realtime -MaxSamples 1).Value[0] / (20 * 1000)) * 100)

    # Wrap the points into a null array to meet InfluxDB json requirements. Sad panda.
    [System.Collections.ArrayList]$nullarray = @()
    $nullarray.Add($points)

    # Build the post body
    $body = @{}
    $body.Add('name',$vmhost)
    $body.Add('columns',@('CPU', 'RAM', 'RDY'))
    $body.Add('points',$nullarray)

    # Convert to json
    $finalbody = $body | ConvertTo-Json

    # Post to API
    try 
    {
        $r = Invoke-WebRequest -Uri $global:url -Body ('['+$finalbody+']') -ContentType 'application/json' -Method Post -ErrorAction:Stop
        Write-Host -Object "Data for $vmhost has been posted, status is $($r.StatusCode) $($r.StatusDescription)"        
    }
    catch 
    {
        throw 'Could not POST to InfluxDB API endpoint'
    }
}

# Disconnect
Disconnect-VIServer -Confirm:$false