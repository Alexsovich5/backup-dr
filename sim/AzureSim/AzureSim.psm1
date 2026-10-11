# AzureSim: functions named after the AzureRM 6.x Recovery Services / Site Recovery
# cmdlets the toolkit calls, backed by a JSON state file instead of an Azure
# subscription.
#
# State file:  $env:BACKUPDR_SIM_STATE/azure.json (vaults, recoveryPlans,
#              protectedItems, jobs). When BACKUPDR_SIM_STATE is not set, every
#              sim/state/*.sample.json is copied to a new temp directory (relative
#              offsets resolved against the simulator clock) on first use.
# Clock:       $env:BACKUPDR_SIM_NOW (ISO 8601) when set, else Get-Date.
#
# Like the real ASR cmdlets, everything except Get-AzureRmRecoveryServicesVault
# needs a vault context set with Set-AzureRmRecoveryServicesAsrVaultContext first.
# For VMware VMs replicated to Azure, failover to Azure is an unplanned failover
# (PrimaryToRecovery) and planned failover is only allowed for failback
# (RecoveryToPrimary). Jobs complete immediately with State 'Succeeded'.

$script:SampleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
$script:TimeFormat = 'yyyy-MM-ddTHH:mm:ss'
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture
$script:VaultContext = $null

function Get-SimNow {
    if ($env:BACKUPDR_SIM_NOW) {
        return [datetime]::Parse($env:BACKUPDR_SIM_NOW, $script:Culture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    Get-Date
}

function ConvertTo-SimTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    [datetime]::Parse([string]$Value, $script:Culture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Resolve-SimOffsetText {
    # Rewrites quoted offsets such as "-26h" to absolute times relative to Anchor.
    param([string]$Text, [datetime]$Anchor)
    $evaluator = {
        param($m)
        $amount = [int]$m.Groups[2].Value
        if ($m.Groups[1].Value -eq '-') { $amount = -$amount }
        switch ($m.Groups[3].Value) {
            's' { $when = $Anchor.AddSeconds($amount) }
            'm' { $when = $Anchor.AddMinutes($amount) }
            'h' { $when = $Anchor.AddHours($amount) }
            'd' { $when = $Anchor.AddDays($amount) }
        }
        '"' + $when.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + '"'
    }.GetNewClosure()
    [regex]::Replace($Text, '"([+-])(\d+)([smhd])"', $evaluator)
}

function Get-SimStatePath {
    if (-not $env:BACKUPDR_SIM_STATE) {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('backupdr-sim-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $now = Get-SimNow
        foreach ($sample in @(Get-ChildItem -Path $script:SampleDir -Filter '*.sample.json' -File)) {
            $text = Resolve-SimOffsetText -Text (Get-Content -Path $sample.FullName -Raw) -Anchor $now
            $target = Join-Path $dir ($sample.Name -replace '\.sample\.json$', '.json')
            Set-Content -Path $target -Value $text -Encoding UTF8
        }
        $env:BACKUPDR_SIM_STATE = $dir
    }
    $path = Join-Path $env:BACKUPDR_SIM_STATE 'azure.json'
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        throw "AzureSim state file not found: $path"
    }
    $path
}

function Read-SimState {
    $state = Get-Content -Path (Get-SimStatePath) -Raw | ConvertFrom-Json
    foreach ($name in @('vaults', 'recoveryPlans', 'protectedItems', 'jobs')) {
        if (-not ($state.PSObject.Properties.Name -contains $name)) {
            $state | Add-Member -MemberType NoteProperty -Name $name -Value @()
        }
    }
    $state
}

function Save-SimState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Get-SimStatePath) -Encoding UTF8
}

function Get-SimProperty {
    param($Object, [string]$Name, $Default)
    if ($Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    $Default
}

function Get-SimSubscriptionId {
    param($State)
    [string](Get-SimProperty $State 'subscriptionId' '00000000-0000-0000-0000-000000000000')
}

function Get-SimVaultName {
    if (-not $script:VaultContext) {
        throw 'AzureSim: no vault context is set; call Set-AzureRmRecoveryServicesAsrVaultContext -Vault first'
    }
    $script:VaultContext.ResourceName
}

function Get-SimVaultId {
    param($State, [string]$VaultName)
    $vault = @($State.vaults | Where-Object { $_.name -eq $VaultName })[0]
    '/Subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.RecoveryServices/vaults/{2}' -f `
        (Get-SimSubscriptionId $State), [string]$vault.resourceGroupName, $VaultName
}

function ConvertTo-SimRecoveryPlan {
    param($Record, [string]$VaultId)
    [pscustomobject]@{
        PSTypeName                 = 'AzureSim.ASRRecoveryPlan'
        Name                       = [string]$Record.name
        FriendlyName               = [string]$Record.name
        ID                         = "$VaultId/replicationRecoveryPlans/$($Record.name)"
        ReplicationProvider        = @('InMageAzureV2')
        PrimaryFabricFriendlyName  = [string](Get-SimProperty $Record 'primaryFabric' '')
        RecoveryFabricFriendlyName = [string](Get-SimProperty $Record 'recoveryFabric' 'Microsoft Azure')
        CurrentSite                = [string](Get-SimProperty $Record 'currentSite' 'Primary')
    }
}

function ConvertTo-SimJob {
    param($Record)
    [pscustomobject]@{
        PSTypeName       = 'AzureSim.ASRJob'
        Name             = [string]$Record.name
        ID               = [string]$Record.id
        DisplayName      = [string]$Record.displayName
        State            = [string]$Record.state
        StateDescription = [string](Get-SimProperty $Record 'stateDescription' 'Completed')
        StartTime        = ConvertTo-SimTime $Record.startTime
        EndTime          = ConvertTo-SimTime (Get-SimProperty $Record 'endTime' $null)
        TargetObjectName = [string]$Record.targetObjectName
        TargetObjectType = [string](Get-SimProperty $Record 'targetObjectType' 'RecoveryPlan')
        AllowedActions   = @()
    }
}

function Invoke-SimFailover {
    param($RecoveryPlan, [string]$FromSite, [string]$ToSite, [string]$DisplayName)

    if ($RecoveryPlan -is [string]) { $planName = $RecoveryPlan } else { $planName = [string]$RecoveryPlan.Name }
    $vaultName = Get-SimVaultName
    $state = Read-SimState
    $record = @($state.recoveryPlans | Where-Object { $_.name -eq $planName -and $_.vaultName -eq $vaultName })[0]
    if (-not $record) {
        throw "AzureSim: recovery plan '$planName' not found in vault '$vaultName'"
    }
    $currentSite = [string](Get-SimProperty $record 'currentSite' 'Primary')
    if ($currentSite -ne $FromSite) {
        throw "AzureSim: recovery plan '$planName' is already at the $($ToSite.ToLowerInvariant()) site"
    }

    $record | Add-Member -MemberType NoteProperty -Name currentSite -Value $ToSite -Force
    foreach ($item in @($state.protectedItems | Where-Object { $_.recoveryPlan -eq $planName -and $_.vaultName -eq $vaultName })) {
        $item | Add-Member -MemberType NoteProperty -Name activeLocation -Value $ToSite -Force
    }

    $now = (Get-SimNow).ToString($script:TimeFormat, $script:Culture)
    $name = [guid]::NewGuid().ToString()
    $job = [pscustomobject]@{
        name             = $name
        id               = "$(Get-SimVaultId -State $state -VaultName $vaultName)/replicationJobs/$name"
        displayName      = $DisplayName
        state            = 'Succeeded'
        stateDescription = 'Completed'
        startTime        = $now
        endTime          = $now
        targetObjectName = $planName
        targetObjectType = 'RecoveryPlan'
    }
    $state.jobs = @($state.jobs) + $job
    Save-SimState $state
    ConvertTo-SimJob $job
}

function Get-AzureRmRecoveryServicesVault {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ResourceGroupName
    )
    $state = Read-SimState
    foreach ($record in @($state.vaults)) {
        if ($Name -and $record.name -ne $Name) { continue }
        if ($ResourceGroupName -and $record.resourceGroupName -ne $ResourceGroupName) { continue }
        [pscustomobject]@{
            PSTypeName        = 'AzureSim.ARSVault'
            Name              = [string]$record.name
            ID                = Get-SimVaultId -State $state -VaultName $record.name
            Type              = 'Microsoft.RecoveryServices/vaults'
            Location          = [string](Get-SimProperty $record 'location' '')
            ResourceGroupName = [string]$record.resourceGroupName
            SubscriptionId    = Get-SimSubscriptionId $state
        }
    }
}

function Set-AzureRmRecoveryServicesAsrVaultContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][object]$Vault)
    process {
        if ($Vault -is [string]) { $vaultName = $Vault } else { $vaultName = [string]$Vault.Name }
        $state = Read-SimState
        $record = @($state.vaults | Where-Object { $_.name -eq $vaultName })[0]
        if (-not $record) { throw "AzureSim: vault '$vaultName' not found" }
        $script:VaultContext = [pscustomobject]@{
            PSTypeName        = 'AzureSim.ASRVaultSettings'
            ResourceName      = [string]$record.name
            ResourceGroupName = [string]$record.resourceGroupName
            ResourceNamespace = 'Microsoft.RecoveryServices'
            ResouceType       = 'vaults'
        }
        $script:VaultContext
    }
}

function Get-AzureRmRecoveryServicesAsrRecoveryPlan {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$FriendlyName
    )
    $vaultName = Get-SimVaultName
    $state = Read-SimState
    $vaultId = Get-SimVaultId -State $state -VaultName $vaultName
    $wanted = $Name
    if (-not $wanted) { $wanted = $FriendlyName }
    $plans = @($state.recoveryPlans | Where-Object { $_.vaultName -eq $vaultName })
    if ($wanted) {
        $plans = @($plans | Where-Object { $_.name -eq $wanted })
        if ($plans.Count -eq 0) {
            throw "Operation failed. ClientRequestId: $([guid]::NewGuid()) NotFound: recovery plan '$wanted' was not found in vault '$vaultName'"
        }
    }
    foreach ($record in $plans) {
        ConvertTo-SimRecoveryPlan -Record $record -VaultId $vaultId
    }
}

function Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$RecoveryPlan,
        [Parameter(Mandatory = $true)][ValidateSet('PrimaryToRecovery', 'RecoveryToPrimary')][string]$Direction,
        [switch]$PerformSourceSideAction
    )
    if ($Direction -ne 'PrimaryToRecovery') {
        throw 'AzureSim: unplanned failover of VMware virtual machines replicated to Azure is only supported with -Direction PrimaryToRecovery; fail back with a planned failover'
    }
    Invoke-SimFailover -RecoveryPlan $RecoveryPlan -FromSite 'Primary' -ToSite 'Recovery' -DisplayName 'Unplanned failover'
}

function Start-AzureRmRecoveryServicesAsrPlannedFailoverJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$RecoveryPlan,
        [Parameter(Mandatory = $true)][ValidateSet('PrimaryToRecovery', 'RecoveryToPrimary')][string]$Direction
    )
    if ($Direction -ne 'RecoveryToPrimary') {
        throw 'AzureSim: planned failover from primary to recovery is not supported for VMware virtual machines replicated to Azure; use unplanned failover (Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob)'
    }
    Invoke-SimFailover -RecoveryPlan $RecoveryPlan -FromSite 'Recovery' -ToSite 'Primary' -DisplayName 'Planned failover'
}

function Get-AzureRmRecoveryServicesAsrJob {
    [CmdletBinding()]
    param(
        [string]$Name,
        [Parameter(ValueFromPipeline = $true)][object]$Job
    )
    process {
        $null = Get-SimVaultName
        $wanted = $Name
        if (-not $wanted -and $Job) { $wanted = [string]$Job.Name }
        $state = Read-SimState
        $records = @($state.jobs)
        if ($wanted) {
            $records = @($records | Where-Object { $_.name -eq $wanted })
            if ($records.Count -eq 0) {
                throw "Operation failed. ClientRequestId: $([guid]::NewGuid()) NotFound: job '$wanted' was not found"
            }
        }
        foreach ($record in $records) { ConvertTo-SimJob $record }
    }
}

function Get-AzureRmRecoveryServicesAsrReplicationProtectedItem {
    [CmdletBinding()]
    param(
        [object]$ProtectionContainer,
        [object]$RecoveryPlan,
        [string]$Name,
        [string]$FriendlyName
    )
    $vaultName = Get-SimVaultName
    $state = Read-SimState
    $vaultId = Get-SimVaultId -State $state -VaultName $vaultName
    $planName = $null
    if ($RecoveryPlan) {
        if ($RecoveryPlan -is [string]) { $planName = $RecoveryPlan } else { $planName = [string]$RecoveryPlan.Name }
    }
    $wanted = $Name
    if (-not $wanted) { $wanted = $FriendlyName }

    $items = @($state.protectedItems | Where-Object { $_.vaultName -eq $vaultName })
    if ($planName) { $items = @($items | Where-Object { $_.recoveryPlan -eq $planName }) }
    if ($wanted) {
        $items = @($items | Where-Object { $_.name -eq $wanted })
        if ($items.Count -eq 0) {
            throw "Operation failed. ClientRequestId: $([guid]::NewGuid()) NotFound: protected item '$wanted' was not found in vault '$vaultName'"
        }
    }

    foreach ($record in $items) {
        $rpo = [long](Get-SimProperty $record 'rpoInSeconds' 0)
        $calculated = ConvertTo-SimTime (Get-SimProperty $record 'lastRpoCalculatedTime' $null)
        [pscustomobject]@{
            PSTypeName              = 'AzureSim.ASRReplicationProtectedItem'
            Name                    = [string]$record.name
            FriendlyName            = [string]$record.name
            ID                      = "$vaultId/replicationProtectedItems/$($record.name)"
            ProtectionState         = [string](Get-SimProperty $record 'protectionState' 'Protected')
            ReplicationHealth       = [string](Get-SimProperty $record 'replicationHealth' 'Normal')
            ReplicationHealthErrors = @(Get-SimProperty $record 'replicationHealthErrors' @())
            ActiveLocation          = [string](Get-SimProperty $record 'activeLocation' 'Primary')
            ReplicationProvider     = 'InMageAzureV2'
            RecoveryPlanName        = [string](Get-SimProperty $record 'recoveryPlan' '')
            RpoInSeconds            = $rpo
            LastRpoCalculatedTime   = $calculated
            ProviderSpecificDetails = [pscustomobject]@{
                RpoInSeconds          = $rpo
                LastRpoCalculatedTime = $calculated
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Get-AzureRmRecoveryServicesVault', 'Set-AzureRmRecoveryServicesAsrVaultContext',
    'Get-AzureRmRecoveryServicesAsrRecoveryPlan',
    'Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob',
    'Start-AzureRmRecoveryServicesAsrPlannedFailoverJob',
    'Get-AzureRmRecoveryServicesAsrJob',
    'Get-AzureRmRecoveryServicesAsrReplicationProtectedItem'
)
