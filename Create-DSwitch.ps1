<#
.SYNOPSIS
Creates a new Distributed Switch with custom settings from json files.

.DESCRIPTION
Creates a new DSwitch on the vCenter utilizing json file for configuration details.

.PARAMETER jsonDSwitchFile
Specifies settings for the new distributed switch. Examples should be by this script.

.PARAMETER verboseLogFile
Optional log file for script output. Default goes to Create-DSwitch.log.

.PARAMETER confirmDetails
Optional setting to disable confirmation of settings before applying to the host. Set to $false if you wish to bypass.

.NOTES
Author: Scott Haas
Website: www.definebroken.com
Credit: Utilized code from www.virtu-al.net and www.virtuallyghetto.com

Changelog:
12-July-2017
 * Initial Script
24-Aug-2017
 * Adjusted script for public consumption on github

ToDo:
 * Add multiple verifications and whatif option
 * Set NIOC config for each portgroup

.EXAMPLE
Create a new DSwitch on vCenter "vCenter" with the name "DSwitch.Data" using verbose log file defined and confirm before creating it.

PS> Create-DSwitch.ps1 -jsonDSwitchFile vCenter_DSwitch.data.json -verboseLogFile vCenter_DSwitch.data.log -confirmDetails $true

.LINK
Reference: https://github.com/ScottHaas/vcenter-build-scripts
#>
[cmdletBinding()]
Param (
    [Parameter(Mandatory=$false,HelpMessage="Filename for the JSON formatted file for the DSwitch settings")]
    [ValidateNotNullorEmpty()]
    [string]$jsonDSwitchFile,

    [Parameter(Mandatory=$false,HelpMessage="Filename for verbose logfile of script output")]
    [ValidateNotNullOrEmpty()]
    [string]$verboseLogFile = "Create-DSwitch.log",

    [Parameter(Mandatory=$false,HelpMessage='Set to $false to bypass confirmation of settings before applying to host.')]
    [ValidateNotNullOrEmpty()]
    [boolean]$confirmDetails = $true
)

#Functions
Function My-Logger {
    param(
    [Parameter(Mandatory=$false)]
    [String]$message,
    [Parameter(Mandatory=$false)]
    [switch]$error 
    )
    
   if ($error -and $message) {
       Write-Host "$message.message"
       $logMessage = "`t[error]`t$message.message"
       $logMessage | out-file -append -literalpath $verboseLogFile
    } elseif ($message){
        #$timeStamp = Get-Date -Format "M/d/yyyy hh:mm:ss "
        $timeStamp = get-date -format G
        Write-Host -NoNewline -ForegroundColor White "$timestamp"
        Write-Host -ForegroundColor Green "`t$message"
        $logMessage = "$timeStamp`t$message"
        $logMessage | out-file -append -literalpath $verboseLogFile
    }
    
}

#Create VDS Portgroups
function Create-VDS-Portgroup{
	Param (
		[Parameter(Mandatory=$true)]$vdsobj,
		[Parameter(Mandatory=$true)][string]$name,
		[int32]$vlan,
		[string]$vlantrunk,
		[string]$activeUplinks,
		[string]$standbyUplinks,
		[string]$unusedUplinks,
        	[string]$portBinding,
		[int32]$numPorts = 8,
		[boolean]$failback = $true,
		[string]$lbPolicy = "LoadBalanceSrcId",
		[switch]$whatif
	)
	
	$VDSPortgroup = get-vdportgroup -Name $name -VDSwitch $vdsobj -errorvariable err -erroraction:silentlycontinue
	if (!$err){
		My-Logger ("VDS Portgroup already exists: "+ $name)
	} else {
		My-Logger ("Creating VDS Portgroup: " + $name)
		$newVDSPortgroup = new-vdportgroup -name $name -vds $vdsobj -NumPorts $numPorts -whatif:$whatif 
		if ($vlantrunk){$null = $newVDSPortgroup|set-vdvlanconfiguration -vlantrunkrange $vlantrunk -whatif:$whatif}
		if ($vlan){$null = $newVDSPortgroup|set-vdvlanconfiguration -vlanid $vlan -whatif:$whatif}
		if ($portBinding){$null = $newVDSPortgroup|set-vdportgroup -PortBinding $portbinding -whatif:$whatif}

		My-Logger ("Setting teaming policy for: " + $name)
		$newTeamingPolicy = $newVDSPortgroup | get-vduplinkteamingpolicy| set-vduplinkteamingpolicy -enablefailback $failback -LoadBalancingPolicy $lbPolicy -whatif:$whatif
		if ($activeUplinks) {$null = $newVDSPortgroup| get-vduplinkteamingpolicy| set-vduplinkteamingpolicy -activeuplinkport $activeUplinks -whatif:$whatif }
		if ($standbyUplinks) {$null = $newVDSPortgroup | get-vduplinkteamingpolicy|set-vduplinkteamingpolicy -StandbyUplinkPort $standbyUplinks -whatif:$whatif}
		if ($unusedUplinks) {$null = $newVDSPortgroup | get-vduplinkteamingpolicy|set-vduplinkteamingpolicy -UnusedUplinkPort $unusedUplinks -whatif:$whatif}
	}
}

#NIOC
function create-NIOCCustomPool{
    Param (
        $dvSw,
        [string]$Name,
        [string]$Description,
        [long]$reservation = 0
    )

    $dvSw.extensiondata.UpdateViewData()

    $currTotalReservation = ($dvsw.extensiondata.config.InfrastructureTrafficResourceConfig|?{$_.key -match "virtualMachine"}).AllocationInfo.Reservation

    if ($reservation -gt $currTotalReservation){
        my-logger -error ("Reservation exceeds the total capacity of the DSwitch currently at " + $currTotalReservation + ". Setting to 0 to create the pool.")
        $reservation = 0
    }
    $dvsw.extensiondata.DvsReconfigureVmVnicNetworkResourcePool.Invoke(@{name=$Name;description=$Description;allocationInfo=@{reservationQuota=$reservation};operation='add'})
    
}

function Set-NIOCSystemPool{
    Param (
        [parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        $dvSw,
        [string]$key,
        [long]$limit = -1, 
        [long]$reservation = 0,
        [string]$shares = "normal" 
    )
    $dvSw.extensiondata.updateviewdata()
    $currCapacity = $dvSw.extensiondata.runtime.resourceruntimeinfo.available
    if ($currCapacity -lt $reservation){
        my-logger -error ("Reservation exceeds available capacity of the DSwitch currently at "+ $currCapacity + ". Setting to 0 to create the pool.")
        $reservation = 0
    }
    
    if ($dvsw.extensiondata.config.networkresourcecontrolversion -match "version3"){
        $spec = New-Object VMware.Vim.DVSConfigSpec
        $spec.ConfigVersion = $dvsw.extensiondata.config.ConfigVersion
        $spec.InfrastructureTrafficResourceConfig = New-Object VMware.Vim.DvsHostInfrastructureTrafficResource
        $spec.InfrastructureTrafficResourceConfig[0].key = $key
        $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo = New-Object VMware.Vim.DvsHostInfrastructureTrafficResourceAllocation
        $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Limit = $limit
        $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Reservation = $reservation
        $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Shares = New-Object VMware.Vim.SharesInfo
        if ("high","low","normal" -contains $shares){
            $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Shares.Level = $shares
        } else {
            $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Shares.Level = "custom"
            $spec.InfrastructureTrafficResourceConfig[0].AllocationInfo.Shares.Shares = [int]$shares
        }
        $dvsw.extensiondata.reconfigureDvs_Task($spec)
    } else { my-logger -error "NIOC not upgraded to version3 yet. No change." }
}

function get-NIOCPools {
    param(
        $dvsw,
        [string]$name = "*",
        [switch]$infra
    )
    $dvsw.extensiondata.updateviewdata()
    
    if ($dvsw.extensiondata.config.NetworkResourceControlVersion -match "version3"){

        if ($infra){
            $result = $dvsw.extensiondata.config.infrastructuretrafficresourceconfig|?{$_.Key -like $name}|%{
	            New-Object PSObject -Property @{
		            Key = $_.Key
		            Description = $_.Description
		            Limit = $_.AllocationInfo.Limit
		            Reservation = $_.AllocationInfo.Reservation
		            Shares = $_.AllocationInfo.Shares.Shares
		            Level = $_.AllocationInfo.Shares.Level
	                }
            }
         } else {
            $result = $dvsw.extensiondata.config.VmVnicNetworkResourcePool|?{$_.name -like $name}|%{
                New-Object PSObject -Property @{
                    Name = $_.Name
                    Description = $_.Description
                    Key = $_.Key
                    ConfigVersion = $_.ConfigVersion
                    ReservationQuota = $_.AllocationInfo.ReservationQuota
                }
            }
         } 
    } else {
        if ($infra){$poolFilter = $dvsw.extensiondata.NetworkResourcepool|?{$_.key -match "iSCSI|management|hbr|vsan|faultTolerance|virtualmachine|nfs|vmotion|vdp"}
            
        } else {$poolFilter = $dvsw.extensiondata.NetworkResourcePool|?{$_.key -notmatch "iSCSI|management|hbr|vsan|faultTolerance|virtualmachine|nfs|vmotion|vdp"}
            
        }
    
	    $result = $poolFilter|%{

            New-Object PSObject -Property @{
		        Key = $_.Key
                Name = $_.Name
		        Description = $_.Description
                ConfigVersion = $_.ConfigVersion
		        Limit = $_.AllocationInfo.Limit
		        Shares = $_.AllocationInfo.Shares.Shares
		        Level = $_.AllocationInfo.Shares.Level
                priorityTag = $_.AllocationInfo.PriorityTag
	            }
        }
    
    } 
    return $result
}

function Enable-NIOCandUpgrade {
    param(
        $dvSw
    )
    $dvSw.extensiondata.updateviewdata()
    my-logger "Upgrading NIOC to version 3"
    $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
    $spec.networkResourceControlVersion = 'version3'
    $spec.lacpApiVersion = 'multipleLag'
    $spec.configVersion = $dvSw.ExtensionData.config.configVersion
    try{$dvSw.ExtensionData.ReconfigureDvs($spec)}catch{my-logger "Unable to upgrade NIOC"}

    #Enable NIOC
    my-logger "Enabling NIOC"
    try{$dvSw.ExtensionData.EnableNetworkResourceManagement($true)} catch {my-logger "Unable to enable NIOC"}
}


#Start Code
$startTime = get-date -format G

#JSON
$jsonObj = get-content $jsonDSwitchFile|convertfrom-json

#Connect
My-Logger ("Connecting to: " + $jsonObj.vcname)
$vcenter = connect-viserver -server $jsonObj.vcname -ErrorVariable Err
if ($Err){My-Logger -Error $Err}

$vdsLocation = (get-datacenter -Name $jsonObj.vDatacenter)|get-folder $jsonObj.vdsFolder

if ($confirmDetails -eq $true){
    My-Logger "Confirming Details:"
    Write-host -ForegroundColor Magenta "`nPlease confirm the following configuration`n" 

    Write-host -ForegroundColor Yellow "---- Distributed Switch Info ----"
    write-host -nonewline -ForegroundColor green "vCenter: "
    write-host -ForegroundColor White $jsonObj.vcname 
    write-host -nonewline -ForegroundColor green "Datacenter: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vDatacenter | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "Folder Location: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsFolder | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "vdsContactName: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsContactName | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "LLDP Protocol: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsLinkDiscoveryProto | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "LLDP Direction: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsLinkDiscoveryProtoOp | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "DSwitch Name: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsName | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "MTU: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsMtu | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "Number of Uplinks: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsNumUpLinks | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "DSwitch Version: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsVersion | out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "Uplink Names:" | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White ($jsonObj.vdsUplinkNames -join ", ")| out-file -append -literalpath $verboseLogFile
    write-host -nonewline -ForegroundColor green "NIOC Enable: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White $jsonObj.vdsNIOCEnable | out-file -append -literalpath $verboseLogFile
    
    #write-host -foregroundcolor Yellow "`n---- NIOC Resource Pools ----"
    write-host -ForegroundColor green "NIOC Custom Resource Pools: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White ($jsonObj.vdsNIOCCustomRPs.foreach({[PSCustomObject]$_})|select Name, Description, Reservation|format-table -autosize|out-string).trim()
    write-host -ForegroundColor green "NIOC System Resource Pools: " | out-file -append -LiteralPath $verboseLogFile
    write-host -ForegroundColor White ($jsonObj.vdsNIOCSystemRPs.foreach({[PSCustomObject]$_})|select Key, Level, Reservation|format-table -autosize|out-string).trim() 
    write-host -ForegroundColor green "DSwitch Portgroups: "
    write-host -ForegroundColor White ($jsonObj.vdsPortgroups.foreach({[PSCustomObject]$_})|select Name, vlan, vlantrunk, activeuplinks, standbyuplinks, unuseduplinks, portbinding, failback, lbpolicy |format-table -autosize|out-string).trim()

    write-host -ForegroundColor Magenta "`nWould you like to proceed with this DSwitch Build?`n" | out-file -append -LiteralPath $verboseLogFile
    $answer = Read-Host -prompt "Do you accept (Y or N)"
    if($answer -ne "Y" -or $answer -ne "y"){
        My-Logger "You have answered no to proceed. Exiting Script."
        exit
    }
    My-Logger "You have answered yes to proceed. Executing script."
    clear-host
}

#Begin Setup
#Create DSwitches
my-logger "Creating new DSwitch"
$vdsDSwitchobj = New-VDSwitch -Name $jsonObj.vdsName -Location $vdsLocation -ContactName $jsonObj.vdsContactName -LinkDiscoveryProtocol $jsonObj.vdsLinkDiscoveryProto -LinkDiscoveryProtocolOperation $jsonObj.vdsLinkDiscoveryProtoOp -Mtu $jsonObj.vdsMtu -NumUplinkPorts $jsonObj.vdsNumUpLinks -Server $vcenter -Version $jsonObj.vdsVersion -ErrorVariable Err
if ($Err){My-Logger -Error $Err}

#Rename Data DVUplinks
my-logger "Renaming DVUplinks"
$UplinkNameSpec = New-Object VMware.Vim.DVSConfigSpec
$UplinkNameSpec.configVersion = $vdsDSwitchobj.ExtensionData.Config.ConfigVersion
$UplinkNameSpec.uplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
$UplinkNameSpec.uplinkPortPolicy.uplinkPortName = $jsonObj.vdsUplinkNames
try{$vdsDSwitchobj.ExtensionData.ReconfigureDVS($UplinkNameSpec)} Catch {my-logger "Unable to rename DVUplinks"}

#Refresh VDS Variables
$vdsDSwitchobj = get-vdswitch -name $jsonObj.vdsName -location $vdsLocation

#Enable and upgrade to NIOC v3 and Enhanced LACP Support. 
my-logger "Enabling NIOC and upgrading to v3"
Enable-NIOCandUpgrade -dvsw $vdsDSwitchobj

#Disable VDS HealthCheck
my-logger "Disabling VDS HealthChecks"
try{
    $vdsDSwitchobj|Get-View |?{
        ($_.config.HealthCheckConfig|?{$_.enable -notmatch "true"})
        }|%{
            $_.UpdateDVSHealthCheckConfig(@((new-object Vmware.Vim.VMwareDVSVlanMtuHealthCheckConfig -property @{enable=0;interval="1"}),
                                            (new-object Vmware.Vim.VMwareDVSTeamingHealthCheckConfig -property @{enable=0;interval="1"})))
        }
} catch {my-logger -error "Error disabling VDS HealthChecks"}

#Customize NIOC System RPs
foreach ($systemRP in $jsonObj.vdsNIOCSystemRPs){
    my-logger ("Customizing System RP: " + $systemRP.key)
    Set-NIOCSystemPool -dvsw $vdsDSwitchobj -key $systemRP.key -shares $systemRP.level -reservation $systemRP.reservation 
}

#Create NIOC Custom Network RPs
foreach ($customRP in $jsonObj.vdsNIOCCustomRPs){
    my-logger ("Creating Custom Resource Pool: " + $customRP.name)
    create-NIOCCustomPool -dvsw $vdsDSwitchobj -name $customRP.name -Description $customRP.description -Reservation $customRP.Reservation
}

#Create DSwitch Portgroups
foreach ($vdsPortgroup in $jsonObj.vdsPortgroups){
    $vdsPortName = $vdsPortgroup.name

    $currPortgroup = get-vdportgroup -Name $vdsPortName -VDSwitch $vdsDswitchobj -errorvariable err -erroraction:silentlycontinue
  	if (!$err){
		My-Logger "$vdsPortName already exists"
        #TBD Check current settings
    } else {
        create-vds-portgroup -vdsobj $vdsDSwitchobj -name $vdsPortgroup.name -vlan $vdsPortgroup.vlan -vlantrunk $vdsPortgroup.vlantrunk -activeUplinks $vdsPortgroup.activeuplinks -standbyuplinks $vdsPortgroup.standbyuplinks -unuseduplinks $vdsPortgroup.unuseduplinks -portbinding $vdsPortgroup.portbinding
    }

    #Failback
    if ($vdsPortgroup.failback -eq $false){
        $currTeamingPolicy = get-vdportgroup -name $vdsPortgroup.name | Get-VDUplinkTeamingPolicy
       
        if ($currTeamingPolicy.enablefailback -ne $vdsPortgroup.failback){
            my-logger "Disabling failback on: $vdsPortName"
            $currTeamingPolicy | set-vduplinkteamingpolicy -enablefailback $vdsPortgroup.failback -ErrorVariable Err
            if ($Err){My-Logger -Error $Err}
        }
    }
    #Load balance Policy
    if ($vdsPortgroup.lbpolicy){
        $currTeamingPolicy = get-vdportgroup -name $vdsPortgroup.name | get-vduplinkteamingpolicy
        
        if ($currTeamingPolicy.LoadBalancingPolicy -ne $vdsPortgroup.lbpolicy){ 
            my-logger "Setting lbpolicy on: $vdsPortName"
            get-vdportgroup -name $vdsPortgroup.name | Get-VDUplinkTeamingPolicy|Set-VDUplinkTeamingPolicy -LoadBalancingPolicy $vdsPortgroup.lbpolicy -ErrorVariable Err
            if ($Err){My-Logger -Error $Err}
         }
    }
    #TBD Set network resource pool
    #if ($vdsPortgroup.ResourcePool){
        
    #}
    
}


My-Logger ("Disconnecting vCenter: " + $jsonObj.vcname)
disconnect-viserver $jsonObj.vcname -confirm:$false -ErrorVariable Err
if ($Err){My-Logger -Error $Err}

$endTime = get-date -format G
$duration = [math]::Round((New-TimeSpan -Start $startTime -End $EndTime).TotalMinutes,2)
My-Logger "DSwitch Setup Complete!"
My-Logger ""
My-Logger "Start Time: $startTime"
My-Logger "End Time: $EndTime"
My-Logger "Duration: $duration minutes"