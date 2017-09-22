<#
.SYNOPSIS
Creates a static patch baseline from an array of IDs that have been uploaded to Update Manager.

.DESCRIPTION
Creates a static patch baseline that includes all of the patches listed in the ID array that's passed in. 
This can then be added to a baseline group. Usually useful for 3rd party vendor patches that are included 
with ISOs and such. 
Please note that this assumes the patches have already been uploaded to update manager first.

.PARAMETER idByVendorArray
Specifies a string array of patch idByVendors

.PARAMETER Name
Specifies the name of the baseline

.PARAMETER Description
Optional description for the baseline

.NOTES
Author: Scott Haas
Website: www.definebroken.com
ChangeLog:
22-September-2017
 * Initial script on github

.EXAMPLE 
#Create a new patch baseline for dell openmanage version 8.5.0 for ESXI 6.5
PS> New-StaticPatchBaseline -idByVendorArray "Dell_OpenManage_ESXi650_OM850" -Name "Fixed OpenManage ESXi 6.5" 

.EXAMPLE 
#Create a new patch baseline based on all of the included drivers from ISO Custom-DellEMC-6.5.0.update01
PS> $dellISObyIDs = "i40e-2.0.6-2494585","igb-5.3.3-2494585","ixgbe-4.5.1-2494585","megaraid_sas-06.805.56.00","qedil-1.0.11.0.0818.1600","qla4xxx-644.6.06.0","cnic_register-1.713.30.v60.1","bnx2-2.2.6b.v60.2","bnx2x-2.713.30.v60.8","cnic-2.713.30.v60.6","bnx2fc-1.713.30.v60.6","bnx2i-2.713.30.v60.5","VMW-ESX-6.5.0-qcnic-1.0.0.28","VMW-ESX-6.5.0-qfle3-1.0.49.0","VMW-ESX-6.5.0-qfle3f-1.0.18.0","VMW-ESX-6.5.0-qfle3i-1.0.0.20","VMW-ESX-6.0.0-igbn-1.3.1","VMW-ESX-6.0.0-qedf-1.2.13.8.18160","VMW-ESX-6.5.0-bnxtnet-20.6.34.0","VMW-ESX-6.5.0-brcmfcoe-11.2.1153.13","VMW-ESX-6.5.0-dell_shared_perc8-06.806.89.00","VMW-ESX-6.5.0-elxiscsi-11.2.1152.0","VMW-ESX-6.5.0-elxnet-11.2.1149.0","VMW-ESX-6.5.0-lpfc-11.2.156.20","VMW-ESX-6.5.0-lsi_mr3-7.700.50.00","VMW-ESX-6.5.0-nqlcnic-6.0.63","VMW-ESX-6.5.0-qedentv-3.0.6.9","VMW-ESXi-6.0.0-qlnativefc-2.1.50.0"
PS>  
PS> New-StaticPatchBaseline -idByVendorArray $dellISObyIDs -Name "Fixed DellEMC 6.5.0.update01 Baseline" -Description "Based on VMware-VMvisor-Installer-6.5.0.update01-5969303.x86_64-DellEMC_Customized-A00.iso"

.LINK
Reference: https://github.com/ScottHaas/vcenter-build-scripts
#>
[cmdletBinding()]
param(
    [Parameter(Mandatory=$true,HelpMessage="String array of patch ids")]
    [ValidateNotNullOrEmpty()]
    [String[]]$idByVendorArray,
    [Parameter(Mandatory=$true,HelpMessage="Name for the static patch baseline")]
    [ValidateNotNullOrEmpty()]
    [String]$Name,
    [Parameter(Mandatory=$false,HelpMessage="Description for baseline")]
    [string]$description = ""
)

$existingbaseline = Get-PatchBaseline -name $Name -ErrorAction SilentlyContinue
    
If ($existingbaseline) {
    write-host "Static Patch Baseline already exists. Skipping $Name."
} else {
    $patches = @()
    foreach($patchID in $idByVendorArray){
        $patches += get-patch|?{$_.idbyvendor -eq $patchID}
    }

    $patchcount = $patches.count
    $inputarraycount = $idbyvendorarray.count
    
    if ($patchcount -ne $inputarraycount){
        write-host "Some patches were skipped since they do not exist in Update Manager. $patchcount of $inputarraycount found."
    }
    $results = New-PatchBaseline -Name $Name -extension -static -IncludePatch $patches -Description $description
} 

if ($results){
    write-host "Static Patch Baseline Created"
    return $results
}
