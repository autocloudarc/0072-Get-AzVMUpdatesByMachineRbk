#requires -version 7.1

# For TLS 1.2, we need to use the TLS 1.2 ciphersuite list.
Using Namespace System.Net
Using Namespace System.Runtime.InteropServices
<#
.SYNOPSIS
Query the Azure Resource Graph for VM updates history


.DESCRIPTION
This sript will produce a CSV file with the Azure VM updates history by machine using the Azure Resource Graph

PRE-REQUISITES:
1. Before executing this script, ensure that you change the directory to the directory where the script is located. For example, if the script is in: c:\path\Get-VmUpdates.ps1 then
    change to this directory using the following command:
    Set-Location -Path c:\path

.EXAMPLE
. .\Get-AzVmUpdatesByMachineRbk.ps1 -rgpName <rgpName> -aaaName <aaaName> -Verbose

.INPUTS
None

.OUTPUTS
The outputs generated from this script includes:
1. A transcript log file to provide the full details of script execution. It will use the name format: <ScriptName>-TRANSCRIPT-<Date-Time>.log

.NOTES

CONTRIBUTORS
1. Julian Haward (AzApiCall module and module references Original Author)
2. Preston K. Parsard (Editor)

LEGAL DISCLAIMER:
This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment. 
THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. 
We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the object code form of the Sample Code, provided that You agree:
(i) to not use Our name, logo, or trademarks to market Your software product in which the Sample Code is embedded;
(ii) to include a valid copyright notice on Your software product in which the Sample Code is embedded; and
(iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against any claims or lawsuits, including attorneys' fees, that arise or result from the use or distribution of the Sample Code.
This posting is provided "AS IS" with no warranties, and confers no rights.

.LINK

.COMPONENT
Azure Update Management Center, Azure Resource Graph, PowerShell, Virtual Machines, Azure Automation

.ROLE
Automation Engineer
DevOps Engineer
Azure Engineer
Azure Administrator
Azure Architect

.FUNCTIONALITY
Generates a CSV file with the Azure VM updates history using the Azure Resource Graph

#>

#region 02.00 Execute script
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $True)]
    [string]$ManagementGroupId, #the Id, not the displayName
    [int]$SubscriptionBatchSize = 200, #max 200
    [string]$PSModuleRepository = "PSGallery", # Onlinie source for obtaining the AzAPICall module
    [string]$Title = "UPDATE MANAGEMENT CENTER HISTORY REPORT:", # The title of the report
    [int]$separatorWidth = 100, # The width of the separator line
    [string]$doubleSeparator = ("-"*$separatorWidth), # The separator used to separate the title from the report
    [string]$singleSeparator = ("-"*$separatorWidth), # The separator used to separate the report sections
	[string]$automationAccount = "adv-aaa-01", # Name of automation account
	[string]$sub = "azr-app1-dev-sub-01", # Name of authentication subscription with $automationAccount resource
	[string]$subId =    "11111111-1111-1111-1111-111111111111", # Subscription Id of authentication subscription
	[string]$tenantId = "22222222-2222-2222-2222-222222222222", # Tenant Id from which to enumerate target subscriptions for update management history information
	[string]$staResourceGroup = "umc-rgp-01", # Replace with <your> actual resource group name which contains the $automation account
    [string]$storageAccountName = "1sta1210", # Replace with <your> actual storage account name where you want to host the reports. The container name is 'reports'
    [string]$targetContainer = "reports", # Feel free to use your own preferred container name here.
	[string]$transcriptsContainer = "transcripts", # Container in storage account for transcripts
    [string]$queryReportType = "ByMachines", # You can either query by machines or by maintenence runs
    [string]$reportNamePrefix = "updateHistory$queryReportType-", # Prefix name for reports.
	[string]$reportTime = ((Get-Date -Format o).substring(0,16).replace(":","")), # Time stamp for report
	[string]$reportName = ($reportNamePrefix + $reportTime + ".csv") # Name of report
	# [string]$keyVaultName = "keyvault-name", # Name of KeyVault resource that will contain storage account key (optional)
	# [string]$keyVaultSecretName = "storage-account-key" # Name of storage account secret key (optional)
) # end param

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process 

Function Connect-ToAzureWithManagedIdentity
{
# Connect using a Managed Service Identity
try {
        $AzureContext = (Connect-AzAccount -Identity).context
    }
catch{
        Write-Output "There is no system-assigned user identity. Aborting."; 
        exit
    }
} # end function

# Create a transcript log file
function New-TranscriptLog
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPrefix,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$reportTime
    ) # end param

    # Construct transcript file full path
    $TranscriptFile = "$LogPrefix-TRANSCRIPT" + "-" + $reportTime + ".log"
    $script:Transcript = Join-Path -Path $LogDirectory -ChildPath $TranscriptFile

    # Create log and transcript files
    New-Item -Path $Transcript -ItemType File -Verbose 
} # end function

# Set TLS 1.2 for PackageManagement provider
function Set-TlsSecurityProtocolType
{
    [CmdletBinding()]
    param()
# Use TLS 1.2 to support PackageManagement provider
Write-Output "Configuring security protocol to use TLS 1.2 for PackageManagement support when installing modules." -Verbose
[ServicePointManager]::SecurityProtocol = [SecurityProtocolType]::Tls12
}

# Get required modules

function Get-RequiredModule
{
    [CmdletBinding(DefaultParameterSetName = "Get-RequiredModule")]
    param
    (
        [string[]]$TargetModules,
        [string]$PSModuleRepository
    ) # end param
    # Module repository setup and configuration
    Set-PSRepository -Name $PSModuleRepository -InstallationPolicy Trusted -Verbose
    # Install-PackageProvider -Name PackageManagement -ForceBootstrap -Force 

    foreach ($TargetModule in $TargetModules)
    { 
        # Bootstrap dependent module
        if (Get-InstalledModule -Name $TargetModule -ErrorAction SilentlyContinue)
        {
            # If module exists, update it
            [string]$currentVersionADM = (Find-Module -Name $TargetModule -Repository $PSModuleRepository).Version
            [string]$installedVersionADM = (Get-InstalledModule -Name $TargetModule).Version
            If ($currentVersionADM -ne $installedVersionADM)
            {
                # Update modules if required
                Update-Module -Name $TargetModule -Force -ErrorAction SilentlyContinue -Verbose
            } # end if
        } # end if
        # If the modules aren't already loaded, install and import it.
        else
        {
            Install-Module -Name $TargetModule -Repository $PSModuleRepository -Force -Verbose
        } #end If
        Import-Module -Name $TargetModule -Verbose
    } #end foreach
} #end Get-RequiredModule

# Get Entities
function getEntities
{
    Write-Output 'Entities'
    $startEntities = Get-Date
    $currentTask = ' Getting Entities'
    Write-Output $currentTask
    #https://management.azure.com/providers/Microsoft.Management/getEntities?api-version=2020-02-01
    $uri = "$($azAPICallConf['azAPIEndpointUrls'].ARM)/providers/Microsoft.Management/getEntities?api-version=2020-02-01"
    $method = 'POST'
    $script:arrayEntitiesFromAPI = AzAPICall -AzAPICallConfiguration $azAPICallConf -uri $uri -method $method -currentTask $currentTask

    Write-Output "  $($arrayEntitiesFromAPI.Count) Entities returned"

    $endEntities = Get-Date
    Write-Output " Getting Entities duration: $((NEW-TIMESPAN -Start $startEntities -End $endEntities).TotalSeconds) seconds"

    $startEntitiesdata = Get-Date
    Write-Output ' Processing Entities data'
    $script:htSubscriptionsMgPath = @{}
    $script:htManagementGroupsMgPath = @{}
    $script:htEntities = @{}
    $script:htEntitiesPlain = @{}

    foreach ($entity in $arrayEntitiesFromAPI)
    {
        $script:htEntitiesPlain.($entity.Name) = @{}
        $script:htEntitiesPlain.($entity.Name) = $entity
    }

    foreach ($entity in $arrayEntitiesFromAPI)
    {
        if ($entity.Type -eq '/subscriptions')
        {
            $script:htSubscriptionsMgPath.($entity.name) = @{}
            $script:htSubscriptionsMgPath.($entity.name).ParentNameChain = $entity.properties.parentNameChain
            $script:htSubscriptionsMgPath.($entity.name).ParentNameChainDelimited = $entity.properties.parentNameChain -join '/'
            $script:htSubscriptionsMgPath.($entity.name).Parent = $entity.properties.parent.Id -replace '.*/'
            $script:htSubscriptionsMgPath.($entity.name).ParentName = $htEntitiesPlain.($entity.properties.parent.Id -replace '.*/').properties.displayName
            $script:htSubscriptionsMgPath.($entity.name).DisplayName = $entity.properties.displayName
            $array = $entity.properties.parentNameChain
            $array += $entity.name
            $script:htSubscriptionsMgPath.($entity.name).path = $array
            $script:htSubscriptionsMgPath.($entity.name).pathDelimited = $array -join '/'
            $script:htSubscriptionsMgPath.($entity.name).level = (($entity.properties.parentNameChain).Count - 1)
        }
        if ($entity.Type -eq 'Microsoft.Management/managementGroups')
        {
            if ([string]::IsNullOrEmpty($entity.properties.parent.Id))
            {
                $parent = '__TenantRoot__'
            }
            else
            {
                $parent = $entity.properties.parent.Id -replace '.*/'
            }
            $script:htManagementGroupsMgPath.($entity.name) = @{}
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChain = $entity.properties.parentNameChain
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChainDelimited = $entity.properties.parentNameChain -join '/'
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChainCount = ($entity.properties.parentNameChain | Measure-Object).Count
            $script:htManagementGroupsMgPath.($entity.name).Parent = $parent
            $script:htManagementGroupsMgPath.($entity.name).ChildMgsAll = ($arrayEntitiesFromAPI.where( { $_.Type -eq 'Microsoft.Management/managementGroups' -and $_.properties.ParentNameChain -contains $entity.name } )).Name
            $script:htManagementGroupsMgPath.($entity.name).ChildMgsDirect = ($arrayEntitiesFromAPI.where( { $_.Type -eq 'Microsoft.Management/managementGroups' -and $_.properties.Parent.Id -replace '.*/' -eq $entity.name } )).Name
            $script:htManagementGroupsMgPath.($entity.name).DisplayName = $entity.properties.displayName
            $script:htManagementGroupsMgPath.($entity.name).Id = ($entity.name)
            $array = $entity.properties.parentNameChain
            $array += $entity.name
            $script:htManagementGroupsMgPath.($entity.name).path = $array
            $script:htManagementGroupsMgPath.($entity.name).pathDelimited = $array -join '/'
        }

        $script:htEntities.($entity.name) = @{}
        $script:htEntities.($entity.name).ParentNameChain = $entity.properties.parentNameChain
        $script:htEntities.($entity.name).Parent = $parent
        if ($parent -eq '__TenantRoot__')
        {
            $parentDisplayName = '__TenantRoot__'
        }
        else
        {
            $parentDisplayName = $htEntitiesPlain.($htEntities.($entity.name).Parent).properties.displayName
        }
        $script:htEntities.($entity.name).ParentDisplayName = $parentDisplayName
        $script:htEntities.($entity.name).DisplayName = $entity.properties.displayName
        $script:htEntities.($entity.name).Id = $entity.Name
    }

    Write-Output "  $(($htManagementGroupsMgPath.Keys).Count) Management Groups returned"
    Write-Output "  $(($htSubscriptionsMgPath.Keys).Count) Subscriptions returned"

    $endEntitiesdata = Get-Date
    Write-Output " Processing Entities data duration: $((NEW-TIMESPAN -Start $startEntitiesdata -End $endEntitiesdata).TotalSeconds) seconds"

    if (-not $htManagementGroupsMgPath.($ManagementGroupId))
    {
        Write-Output "ManagementGroupId '$ManagementGroupId' could not be found" 
        throw
    }

    $script:arrayEntitiesFromAPISubscriptionsCount = ($arrayEntitiesFromAPI.where( { $_.type -eq '/subscriptions' -and $_.properties.parentNameChain -contains $ManagementGroupId } ) | Sort-Object -Property id -Unique).count
    $script:arrayEntitiesFromAPIManagementGroupsCount = ($arrayEntitiesFromAPI.where( { $_.type -eq 'Microsoft.Management/managementGroups' -and $_.properties.parentNameChain -contains $ManagementGroupId } )  | Sort-Object -Property id -Unique).count + 1

    $endEntities = Get-Date
    Write-Output "Processing Entities duration: $((NEW-TIMESPAN -Start $startEntities -End $endEntities).TotalSeconds) seconds"
} # end function

# Get all subscriptions in the tenant
function getSubscriptions
{
    $startGetSubscriptions = Get-Date
    $currentTask = 'Getting all Subscriptions'
    Write-Output "$currentTask"
    $uri = "$($azAPICallConf['azAPIEndpointUrls'].ARM)/subscriptions?api-version=2020-01-01"
    $method = 'GET'
    $requestAllSubscriptionsAPI = AzAPICall -AzAPICallConfiguration $azAPICallConf -uri $uri -method $method -currentTask $currentTask

    Write-Output " $($requestAllSubscriptionsAPI.Count) Subscriptions returned"
    $script:htAllSubscriptionsFromAPI = @{}
    foreach ($subscription in $requestAllSubscriptionsAPI)
    {
        $script:htAllSubscriptionsFromAPI.($subscription.subscriptionId) = @{}
        $script:htAllSubscriptionsFromAPI.($subscription.subscriptionId).subDetails = $subscription
    }

    $endGetSubscriptions = Get-Date
    Write-Output "Getting all Subscriptions duration: $((NEW-TIMESPAN -Start $startGetSubscriptions -End $endGetSubscriptions).TotalSeconds) seconds"
} # end function

function getInScopeSubscriptions
{
    $childrenSubscriptions = $arrayEntitiesFromAPI.where( { $_.properties.parentNameChain -contains $ManagementGroupID -and $_.type -eq '/subscriptions' } ) | Sort-Object -Property id -Unique
    
    if (($childrenSubscriptions).Count -eq 0)
    {
        Write-Output "ManagementGroupId: $ManagementGroupId has $(($childrenSubscriptions).Count) child subscriptions" 
        throw
    }
    else
    {
        Write-Output "ManagementGroupId: $ManagementGroupId has $(($childrenSubscriptions).Count) child subscriptions"
    }
    
    $script:subsToProcessInCustomDataCollection = [System.Collections.ArrayList]@()
    $script:outOfScopeSubscriptions = [System.Collections.ArrayList]@()
    foreach ($childrenSubscription in $childrenSubscriptions)
    {
    
        $sub = $htAllSubscriptionsFromAPI.($childrenSubscription.name)
        if ($sub.subDetails.subscriptionPolicies.quotaId.startswith('AAD_', 'CurrentCultureIgnoreCase') -or $sub.subDetails.state -ne 'Enabled')
        {
            if (($sub.subDetails.subscriptionPolicies.quotaId).startswith('AAD_', 'CurrentCultureIgnoreCase'))
            {
                $null = $script:outOfScopeSubscriptions.Add([PSCustomObject]@{
                        subscriptionId      = $childrenSubscription.name
                        subscriptionName    = $childrenSubscription.properties.displayName
                        outOfScopeReason    = "QuotaId: AAD_ (State: $($sub.subDetails.state))"
                        ManagementGroupId   = $htSubscriptionsMgPath.($childrenSubscription.name).Parent
                        ManagementGroupName = $htSubscriptionsMgPath.($childrenSubscription.name).ParentName
                        Level               = $htSubscriptionsMgPath.($childrenSubscription.name).level
                    })
            }
            if ($sub.subDetails.state -ne 'Enabled')
            {
                $null = $script:outOfScopeSubscriptions.Add([PSCustomObject]@{
                        subscriptionId      = $childrenSubscription.name
                        subscriptionName    = $childrenSubscription.properties.displayName
                        outOfScopeReason    = "State: $($sub.subDetails.state)"
                        ManagementGroupId   = $htSubscriptionsMgPath.($childrenSubscription.name).Parent
                        ManagementGroupName = $htSubscriptionsMgPath.($childrenSubscription.name).ParentName
                        Level               = $htSubscriptionsMgPath.($childrenSubscription.name).level
                    })
            }
        }
        else
        {
    
            $null = $script:subsToProcessInCustomDataCollection.Add([PSCustomObject]@{
                    subscriptionId      = $childrenSubscription.name
                    subscriptionName    = $childrenSubscription.properties.displayName
                    subscriptionQuotaId = $sub.subDetails.subscriptionPolicies.quotaId
                })
        }
    }

    if (($subsToProcessInCustomDataCollection).Count -eq 0)
    {
        Write-Output "ManagementGroupId: $ManagementGroupId has no valid child subscriptions (check `$outOfScopeSubscriptions)" 
        throw
    }
    else
    {
        Write-Output "ManagementGroupId: $ManagementGroupId has $(($subsToProcessInCustomDataCollection).Count) valid child subscriptions (check `$outOfScopeSubscriptions)"
    }
} # end function

# Set TLS 1.2 standard
Set-TlsSecurityProtocolType -Verbose

# Obtain the AzApiCall module from the AzurePowerShell module gallery
# Get-RequiredModule -TargetModule $TargetModules -PSModuleRepository $PSModuleRepository -Verbose
# NOTE: The AzApiCall and Az modules should not be installed locally since the Automation account module asset will be used instead.

#region TRANSCRIPT
# Create Log file
[string]$Transcript = $null
# Use script filename without exension as a log prefix
# $LogPrefix = $scriptName.Split(".")[0]
$LogPrefix = "Get-AzVMUpdatesByMachinesRbk$queryReportType"
$logPath = $HOME
$LogDirectory = Join-Path $logPath -ChildPath $LogPrefix -Verbose
# Create log directory if not already present
If (-not(Test-Path -Path $LogDirectory -ErrorAction SilentlyContinue))
{
    New-Item -Path $LogDirectory -ItemType Directory -Verbose
} # end if

# funciton: Create log files for transcript
New-TranscriptLog -LogDirectory $LogDirectory -LogPrefix $LogPrefix -reportTime $reportTime -Verbose

Start-Transcript -Path $Transcript -IncludeInvocationHeader -Verbose
#endregion TRANSCRIPT

#region Authenticate to Azure
# Write-Output "Please see the open dialogue box in your browser to authenticate to your Azure subscription..."

# Clear any possible cached credentials for other subscriptions, but only if not running in cloud shell
if (-not($CloudEnvironmentMap))
{
    Clear-AzContext
    # Connect-AzAccount -Identity
	Connect-ToAzureWithManagedIdentity
	Set-AzContext -Tenant $tenantId
} # end if

# https://docs.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-with-ps
# To connect to AzureUSGovernment, use:
# Connect-AzAccount -EnvironmentName AzureUSGovernment

#endregion Authenticate to Azure

# Get storage account key in plain-text
# $storageAccountKey = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $keyVaultSecretName -AsPlainText)

#region Create container if necessary
$sta = Get-AzStorageAccount -ResourceGroupName $staResourceGroup -StorageAccountName $storageAccountName 
$containers = (Get-AzStorageContainer -Context $sta.Context).Name
if ($targetContainer -notin $containers)
{
    New-AzStorageContainer -Name $targetContainer -Context $sta.Context
} # end if
#endregion

try
{
    $azAPICallConf = initAzAPICall #-DebugAzAPICall $True
} # end try
catch
{
    Write-Output "Install AzAPICall Powershell Module https://www.powershellgallery.com/packages/AzAPICall"
    Write-Output "Install-Module -Name AzAPICall"
    throw
} # end catch

$header = "$Title $(Get-Date)"

Write-Output $doubleSeparator 
Write-Output $header
Write-Output $singleSeparator

getEntities
getSubscriptions
getInScopeSubscriptions

$queryByMachines = @"
patchinstallationresources
| where type =~ "microsoft.compute/virtualmachines/patchinstallationresults" or type =~ "microsoft.hybridcompute/machines/patchinstallationresults"
| where properties.lastModifiedDateTime > ago(30d )
| where properties.status in~ ("Succeeded","Failed","CompletedWithWarnings","InProgress")
| parse id with * 'achines/' resourceName '/patchInstallationResults/' *
| project id, resourceName, type, properties.status,properties.startDateTime, properties.lastModifiedDateTime, properties.startedBy,properties, tags
| union
(patchassessmentresources
| where type =~ "microsoft.compute/virtualmachines/patchassessmentresults" or type =~  "microsoft.hybridcompute/machines/patchassessmentresults"
| where properties.lastModifiedDateTime > ago(30d)
| where properties.status in~ ("Succeeded","Failed","CompletedWithWarnings","InProgress")
| parse id with * 'achines/' resourceName '/patchAssessmentResults/' *
| project id, resourceName, type, properties.status,properties.startDateTime, properties.lastModifiedDateTime, properties.startedBy ,properties, tags)
"@

$arrayUpdateResults = [System.Collections.ArrayList]@()

$counterBatch = [PSCustomObject] @{ Value = 0 }
$subscriptionsBatch = $subsToProcessInCustomDataCollection | Group-Object -Property { [math]::Floor($counterBatch.Value++ / $SubscriptionBatchSize) }
$subscriptionsBatchCount = ($subscriptionsBatch | Measure-Object).Count

$cnt = 0
foreach ($batch in $subscriptionsBatch)
{
    Write-Output " Batch #$($cnt)/$subscriptionsBatchCount - Executing query for $batch.Group.subscriptionId.Count Subscriptions"
    Write-Host "Query $($queryByMachines)"
    $subIds = $batch.Group.subscriptionId
    $res = Search-AzGraph -Query $queryByMachines -Subscription $subIds -Verbose
    $cnt++
    if ($res.count -gt 0)
    {
        $subIdIndex = 0
        foreach ($resource in $res)
        {
            # This may produce the following known error, but can be ignored (for now):..."| Key cannot be null. (Parameter 'key')""
            $mgInfo = $htSubscriptionsMgPath.($subIds[$subIdIndex])
            $resource | Add-Member -MemberType NoteProperty -Name 'ManagementGroupId' -Value $mgInfo.Parent
            $resource | Add-Member -MemberType NoteProperty -Name 'ManagementGroupPath' -Value $mgInfo.ParentNameChainDelimited
            $resource | Add-Member -MemberType NoteProperty -Name 'SubscriptionName' -Value $mgInfo.DisplayName
            $arrayUpdateResults.Add($resource)
            $subIdIndex++
        } # end foreach
    } # end if
    Write-Output "  $($res.count) update history records found"
} # end foreach

$updateResultsPath = Join-Path $LogDirectory -ChildPath $reportName

Write-Output $doubleSeparator
Write-Output "Array Update Results:"
Write-Output $doubleSeparator
Write-Output $singleSeparator
$arrayUpdateResults
$arrayUpdateResults | Export-Csv -Path $updateResultsPath -NoTypeInformation
Write-Output $singleSeparator
Write-Output "End of Report"
Write-Output $singleSeparator

$transcriptName = $Transcript | Split-Path -Leaf  

# Copy results to blob storage container 'reports'
Set-AzStorageBlobContent -File $updateResultsPath -Blob $reportName -Container $targetContainer -Context $sta.Context -Force -Verbose
# Show that the reports file was copied
Get-AzStorageBlob -container $targetContainer -context $sta.Context -Verbose
#endregion

Stop-Transcript -Verbose

# Copy transcript to blob storage container 'transcripts'
Set-AzStorageBlobContent -File $Transcript -Blob $transcriptName -Container $transcriptsContainer -Context $sta.Context -Force -Verbose 
# Show that the transcript file was copied
Get-AzStorageBlob -Container $transcriptsContainer -context $sta.Context -Verbose 

Get-Content -Path $Transcript -Verbose
Write-Output "End of Script!"
$doubleSeparator