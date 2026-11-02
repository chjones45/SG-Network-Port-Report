#Requires -Version 5.1

[CmdletBinding()]
param([string]$ArtifactDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-SgNetworkPortReport.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '; ') }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:SgNetworkInterfaces = [ordered]@{ Grid = 'eth0'; Admin = 'eth1'; Client = 'eth2' }
$script:SgMarker = '@@SGNET@@'
$script:SgToolVersion = '1.0.5'
$script:SgNodeInventory = @{}
$script:SgAutomaticInventory = @{}
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -cne $Expected) { throw "FAIL: $Name (expected '$Expected', got '$Actual')" }
    $script:checks++
}

$networks = @{
    Grid = [pscustomobject]@{ Present = $true; Bond = 'bond0' }
    Client = [pscustomobject]@{ Present = $true; Bond = 'bond1' }
}
$lacp = [pscustomobject]@{ Bond = 'bond0'; Mode = 'IEEE 802.3ad Dynamic link aggregation' }
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp)).Mode 'Fixed' 'Fixed port mode can use LACP network bonding'
$networks.Client.Bond = 'bond0'
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp)).Mode 'Aggregate' 'Shared LACP data bond indicates Aggregate topology'
$networks.Client.Present = $false
$networks.Client.Bond = ''
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp)).Mode 'Unknown' 'Grid-only bond0 is not sufficient to infer Aggregate'
$fourPortBond = [pscustomobject]@{ Bond = 'bond0'; Mode = 'IEEE 802.3ad Dynamic link aggregation'; MemberDetail = @('hic1','hic2','hic3','hic4' | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
Assert-Equal (Get-SgPortBondAssessment $networks @($fourPortBond)).Mode 'Aggregate' 'Grid-only all-four appliance port LACP topology supports Aggregate'
$fixedGridBond = [pscustomobject]@{ Bond = 'bond0'; Mode = 'fault-tolerance (active-backup)'; MemberDetail = @('hic2','hic4' | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
Assert-Equal (Get-SgPortBondAssessment $networks @($fixedGridBond)).Mode 'Fixed' 'Grid-only paired appliance ports in Active-Backup support Fixed'
$uncertainGridBond = [pscustomobject]@{ Bond = 'bond0'; Mode = 'IEEE 802.3ad Dynamic link aggregation'; MemberDetail = @('hic2','hic4' | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
Assert-Equal (Get-SgPortBondAssessment $networks @($uncertainGridBond)).Mode 'Unknown' 'Two LACP members alone do not prove Fixed versus reduced-port Aggregate'
$vmware = Get-SgDeploymentAssessment -PlatformLines @('manufacturer=VMware, Inc.', 'product=VMware Virtual Platform', 'container=none')
Assert-Equal $vmware.Type 'VMware' 'Direct VMware DMI evidence identifies the VMware deployment'
$baremetal = Get-SgDeploymentAssessment -Inventory ([pscustomobject]@{ Platform = 'baremetal' })
Assert-Equal $baremetal.Type 'Baremetal' 'StorageGRID inventory platform identifies customer-hosted container deployment'
Assert-Equal (Get-SgDeploymentAssessment -PlatformLines @('manufacturer=VMware, Inc.', 'container=docker')).Type 'Unknown' 'Container on VMware host is not guessed to be a VMware appliance deployment'
Assert-Equal (Get-SgDeploymentAssessment -Inventory ([pscustomobject]@{ Platform = 'SGA' })).Type 'Appliance' 'Canonical StorageGRID SGA platform identifies an appliance'
Assert-Equal (Get-SgDeploymentAssessment -Inventory ([pscustomobject]@{ Platform = 'Linux' })).Type 'Baremetal' 'Canonical StorageGRID Linux platform identifies a customer-hosted node'
$metadataRecords = @(
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"example-vm","platform":"vSphere","nodeType":"primary-admin"}' },
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"example-linux","platform":"Linux","nodeType":"adc-sn"}' },
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = 'not-json' },
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"unsupported","platform":"unverified"}' }
)
$automaticMetadata = ConvertFrom-SgGridMetadata -Controller $metadataRecords
Assert-Equal $automaticMetadata.Count 2 'Local metadata parser accepts only valid supported records'
Assert-Equal $automaticMetadata['example-vm'].NodeType 'primary-admin' 'Node role evidence is retained without extra authentication'
$conflictingMetadata = @(
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"conflict","platform":"vSphere"}' },
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"conflict","platform":"Linux"}' },
    [pscustomobject]@{ Section = 'NODE_METADATA'; Text = '{"hostname":"conflict","platform":"vSphere"}' }
)
Assert-Equal (ConvertFrom-SgGridMetadata -Controller $conflictingMetadata)['conflict'] $null 'Conflicting local platform records are not guessed or restored by later duplicates'
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp) -Deployment 'VMware').Mode 'N/A - VMware' 'VMware appliance bond mode is skipped'
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp) -Deployment 'Baremetal').Mode 'N/A - Baremetal' 'Customer-hosted bond mode is skipped even when host bonds are visible'
Assert-Equal (Get-SgPortBondAssessment $networks @($uncertainGridBond) -ConfiguredMode 'Fixed').Mode 'Fixed' 'Verified installer inventory can resolve an otherwise ambiguous Grid-only LACP layout'
$networks.Client.Present = $true
$networks.Client.Bond = 'bond0'
Assert-Equal (Get-SgPortBondAssessment $networks @()).Mode 'Unknown' 'Shared bond without mode evidence remains unknown'
Assert-Equal (Get-SgPortBondAssessment $networks @($lacp) -Complete $false).Mode 'Unknown' 'Partial collection must not establish a port mode'
$networks.Grid.Bond = ''
$networks.Client.Bond = ''
Assert-Equal (Get-SgPortBondAssessment $networks @()).Mode 'Not applicable' 'Unbonded data interfaces do not imply an appliance bond mode'
$networks.Grid.Present = $false
Assert-Equal (Get-SgPortBondAssessment $networks @()).Mode 'Unknown' 'Missing Grid interface does not imply not applicable'
function New-TestCollection {
    $lines = New-Object System.Collections.Generic.List[string]
    $definitions = @(
        @{ Name = 'node2'; Kind = 'Fixed' },
        @{ Name = 'node10'; Kind = 'Aggregate' },
        @{ Name = 'node1'; Kind = 'Virtual' },
        @{ Name = 'node20'; Kind = 'Partial' },
        @{ Name = 'node30'; Kind = 'GridOnly' },
        @{ Name = 'node40'; Kind = 'VlanFailure' },
        @{ Name = 'node50-</script><script>window.pwned=1</script>'; Kind = 'Aggregate' }
    )
    foreach ($definition in $definitions) {
        $name = $definition.Name
        $kind = $definition.Kind
        $links = @('1: lo: <LOOPBACK,UP> mtu 65536 state UNKNOWN link/loopback 00:00:00:00:00:00', '3: eth1: <BROADCAST,UP,LOWER_UP> mtu 1500 state UP link/ether 02:00:00:00:00:10')
        $vlan = @('VLAN Dev name | VLAN ID | Device')
        if ($kind -eq 'Virtual') {
            $links += '2: eth0: <BROADCAST,UP,LOWER_UP> mtu 9000 state UP link/ether 02:00:00:00:00:11'
        }
        else {
            $links += '2: eth0@bond0: <BROADCAST,UP,LOWER_UP> mtu 9000 state UP link/ether 02:00:00:00:00:11'
            $links += '10: bond0: <BROADCAST,UP,LOWER_UP> mtu 9000 state UP link/ether 02:00:00:00:00:12'
            $vlan += 'eth0 | 100 | bond0'
            if ($kind -ne 'GridOnly') {
                $clientBond = if ($kind -eq 'Fixed') { 'bond1' } else { 'bond0' }
                $links += "4: eth2@${clientBond}: <BROADCAST,UP,LOWER_UP> mtu 9000 state UP link/ether 02:00:00:00:00:13"
                $vlan += "eth2 | 200 | $clientBond"
                if ($kind -eq 'Fixed') { $links += '11: bond1: <BROADCAST,UP,LOWER_UP> mtu 9000 state UP link/ether 02:00:00:00:00:14' }
            }
            $bonds = @('bond0')
            if ($kind -eq 'Fixed') { $bonds += 'bond1' }
            foreach ($bondName in $bonds) {
                $members = if ($bondName -eq 'bond1') { @('hic3','hic4') } else { @('hic1','hic2') }
                $mode = if ($bondName -eq 'bond1') { 'fault-tolerance (active-backup)' } else { 'IEEE 802.3ad Dynamic link aggregation' }
                $proc = @("=== $bondName ===", "Bonding Mode: $mode", 'MII Status: up', 'Transmit Hash Policy: layer2+3 (2)', 'LACP rate: fast', 'Active Aggregator Info:', 'Aggregator ID: 1', 'Partner Mac Address: 02:00:00:00:00:aa')
                if ($bondName -eq 'bond1') { $proc += 'Currently Active Slave: hic3' }
                foreach ($memberName in $members) {
                    $links += "20: ${memberName}: <BROADCAST,UP,LOWER_UP> mtu 9000 master $bondName state UP link/ether 02:00:00:00:00:21"
                    $lines.Add("@@SGNET@@|$name|SYSNET|$memberName operstate=up speed=25000 master=$bondName phys=1")
                    $proc += @("Slave Interface: $memberName", 'MII Status: up', 'Speed: 25000 Mbps', 'Duplex: full', 'Link Failure Count: 0', 'Aggregator ID: 1')
                }
                foreach ($line in $proc) { $lines.Add("@@SGNET@@|$name|BONDING|$line") }
            }
        }
        foreach ($line in $links) { $lines.Add("@@SGNET@@|$name|IPLINK|$line") }
        if ($kind -eq 'VlanFailure') { $vlan = @('cat: /proc/net/vlan/config: Permission denied') }
        foreach ($line in $vlan) { $lines.Add("@@SGNET@@|$name|VLAN|$line") }
        $lines.Add("@@SGNET@@|$name|ADDR|2: eth0 inet 192.0.2.10/24 scope global eth0")
        $lines.Add("@@SGNET@@|$name|ADDR|3: eth1 inet 198.51.100.10/24 scope global eth1")
        $lines.Add("@@SGNET@@|$name|STATUS|IPLINK=0")
        $lines.Add("@@SGNET@@|$name|STATUS|ADDR=0")
        $status = if ($kind -eq 'VlanFailure') { '1' } else { '0' }
        $lines.Add("@@SGNET@@|$name|STATUS|VLAN=$status")
        if ($kind -ne 'Partial') { $lines.Add("@@SGNET@@|$name|DONE|") }
    }
    $lines.Add('example-unreachable: SSH connection refused')
    $lines.Add('@@SGNET@@|__controller__|END|rc=0')
    return $lines.ToArray()
}

$raw = @(New-TestCollection)
$parsed = ConvertFrom-SgNetworkCollectorOutput -Lines $raw
Assert-Equal @($parsed.Nodes).Count 7 'All observed fixture nodes parsed'
$maps = @($parsed.Nodes | ForEach-Object { Get-SgNodeNetworkMap -Node $_ })
foreach ($expected in @(@('node2','Fixed'), @('node10','Aggregate'), @('node1','Not applicable'), @('node20','Unknown'), @('node30','Unknown'), @('node40','Aggregate'))) {
    $map = $maps | Where-Object { $_.Summary.Node -eq $expected[0] }
    Assert-Equal $map.Summary.PortBondMode $expected[1] "Integrated port mode: $($expected[0])"
}
$fixed = $maps | Where-Object { $_.Summary.Node -eq 'node2' }
Assert-Equal $fixed.Summary.GridNetworkBondMode 'LACP' 'Fixed Grid network remains independently labelled LACP'
Assert-Equal $fixed.Summary.ClientNetworkBondMode 'Active-Backup' 'Fixed Client network remains independently labelled Active-Backup'
Assert-Equal $fixed.Summary.GridVlan '100' 'Grid VLAN retained'
Assert-Equal $fixed.Summary.ClientVlan '200' 'Client VLAN retained'
$clientBondContext = ''
$allDownClientRaw = @(
    foreach ($line in @($raw | Where-Object { $_ -match '^@@SGNET@@\|node2\|' })) {
        if ($line -match '\|BONDING\|=== (\S+) ===$') { $clientBondContext = $Matches[1] }
        $updated = $line
        if ($clientBondContext -eq 'bond1' -and $updated -match '\|BONDING\|MII Status: up$') { $updated = $updated.Replace('MII Status: up', 'MII Status: down') }
        if ($updated -match '\|IPLINK\|(4: eth2@|20: hic[34]:)') { $updated = $updated.Replace('state UP', 'state DOWN').Replace('UP,LOWER_UP', '') }
        $updated
    }
)
$allDownClientParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $allDownClientRaw
$allDownClientMap = Get-SgNodeNetworkMap -Node $allDownClientParsed.Nodes[0]
Assert-Equal ($allDownClientMap.Bonds | Where-Object Bond -EQ 'bond1').EffectiveSpeedMbps 0 'A fully down bond has zero effective speed without aborting report generation'
Assert-Equal ($allDownClientMap.Issues -contains 'bond1 has no member ports up') $true 'A fully down bond remains an actionable finding'
Assert-Equal $fixed.Summary.PortBondSource 'Runtime topology (inferred)' 'Runtime inference is distinguished from confirmed installer settings'
$legacyRowMap = $fixed | ConvertTo-Json -Depth 14 | ConvertFrom-Json
foreach ($row in $legacyRowMap.Networks) { $row.PSObject.Properties.Remove('Observation') }
$legacyRowMap = Set-SgNodeReportAssessment -Map $legacyRowMap -CoreComplete $null -VlanSource Unrecorded
Assert-Equal ($legacyRowMap.Networks | Where-Object Network -EQ 'Grid').Observation 'UP' 'Older HTML network rows receive an observation field'
Assert-Equal ((Format-SgNetworkTextReport -NodeMaps @($legacyRowMap)).Contains('Port mode evidence:')) $true 'Older HTML evidence can regenerate text reports without newer row fields'
$sameVlanRaw = @($raw | Where-Object { $_ -match '^@@SGNET@@\|node10\|' } | ForEach-Object { $_ -replace '\|VLAN\|eth2 \| 200 \|', '|VLAN|eth2 | 100 |' })
$sameVlanParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $sameVlanRaw
$sameVlanMap = Get-SgNodeNetworkMap -Node $sameVlanParsed.Nodes[0]
Assert-Equal (@($sameVlanMap.Issues | Where-Object { $_ -match 'distinct network VLAN tags' }).Count -gt 0) $true 'Shared Aggregate bond with identical VLAN tags requires review'
$gridOnly = $maps | Where-Object { $_.Summary.Node -eq 'node30' }
Assert-Equal $gridOnly.Summary.PortBondStatus 'Unresolved' 'Unknown mode remains explicit without being treated as an established configuration fault'
Assert-Equal $gridOnly.Summary.NeedsReview $false 'Unresolved topology alone does not mark a node faulty'
Assert-Equal ([IO.File]::ReadAllText($scriptPath).Contains("'StrictHostKeyChecking=yes'")) $true 'Live SSH requires verified host trust'
$failed = $maps | Where-Object { $_.Summary.Node -eq 'node40' }
Assert-Equal $failed.Summary.GridVlan 'Unknown' 'Failed VLAN collection cannot mean Untagged'
Assert-Equal $failed.Summary.DataComplete $false 'Failed VLAN collection marks incomplete evidence'
$virtual = $maps | Where-Object { $_.Summary.Node -eq 'node1' }
Assert-Equal $virtual.Summary.GridVlan 'Untagged' 'Successful empty VLAN table establishes no observed tag'
Assert-Equal $virtual.Summary.ClientNetworkBondMode 'Not observed' 'Absent Client interface does not mean Disabled'
$virtualUnknownRaw = @($raw | Where-Object { $_ -match '^@@SGNET@@\|node1\|' } | ForEach-Object { $_ -replace '\|STATUS\|VLAN=0$', '|STATUS|VLAN=1' })
$virtualUnknown = ConvertFrom-SgNetworkCollectorOutput -Lines $virtualUnknownRaw
$virtualUnknownMap = Get-SgNodeNetworkMap -Node $virtualUnknown.Nodes[0]
Assert-Equal $virtualUnknownMap.Summary.PortBondMode 'Not applicable' 'Unbonded topology is independent of unavailable VLAN evidence'
Assert-Equal $virtualUnknownMap.Summary.GridVlan 'Unknown' 'Unbonded topology does not invent a VLAN tag'
$inactiveRaw = @($raw | Where-Object { $_ -match '^@@SGNET@@\|node1\|' -and $_ -notmatch '\|ADDR\|3: eth1' } | ForEach-Object {
    if ($_ -match '\|IPLINK\|3: eth1:') { $_ -replace 'state UP', 'state DOWN' -replace 'UP,LOWER_UP', '' } else { $_ }
})
$inactive = ConvertFrom-SgNetworkCollectorOutput -Lines $inactiveRaw
$inactiveMap = Get-SgNodeNetworkMap -Node $inactive.Nodes[0]
Assert-Equal (@($inactiveMap.Issues | Where-Object { $_ -match 'Admin Network.*down|Admin Network.*DOWN' }).Count) 0 'Unaddressed inactive optional network is not assumed to be a failed enabled network'
Assert-Equal ($inactiveMap.Networks | Where-Object Network -EQ 'Admin').Observation 'Inactive; enablement unknown' 'Optional inactive interface remains visible as an observation'
$addressedDown = ConvertFrom-SgNetworkCollectorOutput -Lines @($inactiveRaw + '@@SGNET@@|node1|ADDR|3: eth1 inet 198.51.100.10/24 scope global eth1')
$addressedDownMap = Get-SgNodeNetworkMap -Node $addressedDown.Nodes[0]
Assert-Equal (@($addressedDownMap.Issues | Where-Object { $_ -match 'Admin Network.*down|Admin Network.*DOWN' }).Count -gt 0) $true 'Addressed optional network still reports a down interface'
Assert-Equal $inactiveMap.Summary.AdminObservation 'Inactive; enablement unknown' 'Optional interface observation is preserved in summary CSV'
$vmRaw = @($virtualUnknownRaw + @(
    '@@SGNET@@|node1|PLATFORM|manufacturer=VMware, Inc.',
    '@@SGNET@@|node1|PLATFORM|product=VMware Virtual Platform',
    '@@SGNET@@|node1|PLATFORM|container=none',
    '@@SGNET@@|node1|VLAN|cat: /proc/net/vlan/config: No such file or directory'
))
$vmParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $vmRaw
$vmMap = Get-SgNodeNetworkMap -Node $vmParsed.Nodes[0]
Assert-Equal $vmMap.Summary.PortBondMode 'N/A - VMware' 'Confirmed VMware node receives requested applicability label'
Assert-Equal $vmMap.Summary.PortBondStatus 'Skipped' 'VMware applicability is a skip'
Assert-Equal $vmMap.Summary.PortBondSource 'Not applicable' 'Software skip is not presented as inferred appliance settings'
Assert-Equal $vmMap.Summary.NeedsReview $false 'Missing guest VLAN table is not a VMware configuration fault'
Assert-Equal $vmMap.Summary.GridVlan 'Unknown' 'VMware skip does not invent external VLAN tags'
Assert-Equal $vmMap.Summary.DataComplete $true 'Applicable node collection completes despite an expected external visibility limit'
$script:SgAutomaticInventory = @{ node1 = [pscustomobject]@{ Platform = 'vSphere'; NodeType = 'primary-admin'; Source = 'StorageGRID local dynip nodeConfig via existing SSH session' } }
$autoMap = Get-SgNodeNetworkMap -Node $virtualUnknown.Nodes[0]
Assert-Equal $autoMap.Summary.PortBondMode 'N/A - VMware' 'Canonical local metadata identifies VMware without an inventory file'
Assert-Equal $autoMap.Summary.GridPlatform 'vSphere' 'Automatic platform metadata is preserved for offline replay'
Assert-Equal $autoMap.Summary.GridNodeType 'primary-admin' 'Automatic node type is retained in report evidence'
Assert-Equal ($autoMap.Summary.DeploymentEvidence -match 'local dynip') $true 'Report records the authoritative local metadata source'
$script:SgNodeInventory = @{ node1 = [pscustomobject]@{ Platform = 'baremetal'; PortBondMode = '' } }
Assert-Equal (Get-SgNodeNetworkMap -Node $virtualUnknown.Nodes[0]).Summary.PortBondMode 'N/A - Baremetal' 'Explicit verified inventory takes precedence over automatic local metadata'
$script:SgNodeInventory = @{}
$script:SgAutomaticInventory = @{}
$persisted = Set-SgNodeReportAssessment -Map $autoMap -CoreComplete $true -VlanSource Absent
Assert-Equal $persisted.Summary.PortBondMode 'N/A - VMware' 'Saved HTML retains canonical platform identity without reconnecting or a separate inventory'
$permissionRaw = @($vmRaw | ForEach-Object { $_ -replace 'No such file or directory', 'Permission denied' })
$permissionParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $permissionRaw
$permissionMap = Get-SgNodeNetworkMap -Node $permissionParsed.Nodes[0]
Assert-Equal $permissionMap.Summary.NeedsReview $true 'VMware skip must not hide an unexpected VLAN permission failure'
$coreFailureRaw = @($vmRaw | ForEach-Object { $_ -replace '\|STATUS\|IPLINK=0$', '|STATUS|IPLINK=1' })
$coreFailureParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $coreFailureRaw
Assert-Equal (Get-SgNodeNetworkMap -Node $coreFailureParsed.Nodes[0]).Summary.NeedsReview $true 'VMware skip must not hide failed essential collection'
$gridDownRaw = @($vmRaw | ForEach-Object {
    if ($_ -match '\|IPLINK\|2: eth0:') { $_ -replace 'state UP', 'state DOWN' -replace 'UP,LOWER_UP', '' } else { $_ }
})
$gridDownParsed = ConvertFrom-SgNetworkCollectorOutput -Lines $gridDownRaw
Assert-Equal (Get-SgNodeNetworkMap -Node $gridDownParsed.Nodes[0]).Summary.NeedsReview $true 'VMware skip must not hide a genuine Grid link fault'
$script:SgNodeInventory = @{ node1 = [pscustomobject]@{ Platform = 'baremetal'; PortBondMode = '' } }
$bareMap = Get-SgNodeNetworkMap -Node $vmParsed.Nodes[0]
Assert-Equal $bareMap.Summary.PortBondMode 'N/A - Baremetal' 'Verified inventory takes precedence over host hypervisor hints'
Assert-Equal $bareMap.Summary.NeedsReview $false 'Baremetal external VLAN visibility alone is not actionable'
$script:SgNodeInventory = @{}
$reducedMap = $maps | Where-Object { $_.Summary.Node -eq 'node10' } | ConvertTo-Json -Depth 14 | ConvertFrom-Json
$downPort = $reducedMap.Ports | Where-Object Port -EQ 'hic2'
$downPort.Status = 'Down'; $downPort.LinkFailures = '0'
$reducedMap.Issues = @('bond0 member hic2 is down')
$reducedAssessment = Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available
Assert-Equal $reducedAssessment.Summary.NeedsReview $false 'Reduced-port LACP with zero down-port failure history is an observation without required-port intent'
Assert-Equal (@($reducedAssessment.Notes | Where-Object { $_ -match 'hic2 is down' }).Count -gt 0) $true 'Down port remains visible as an explicit observation'
$rescreened = Set-SgNodeReportAssessment -Map $reducedAssessment -CoreComplete $true -VlanSource Available
Assert-Equal $rescreened.Summary.NeedsReview $false 'Repeating assessment does not invent an attention finding'
Assert-Equal (@($rescreened.Notes | Where-Object { $_ -match 'hic2' }).Count -gt 0) $true 'Repeated assessment preserves down-port visibility explanations'
$script:SgNodeInventory = @{ node10 = [pscustomobject]@{ Platform = 'appliance'; RequiredPorts = @('hic1','hic2') } }
$reducedMap.Issues = @('bond0 member hic2 is down')
Assert-Equal (Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available).Summary.NeedsReview $true 'Inventory-required port down remains actionable'
$firstRequiredCount = $reducedMap.Summary.IssueCount
$reducedMap = Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available
Assert-Equal $reducedMap.Summary.IssueCount $firstRequiredCount 'Repeated required-port assessment does not duplicate its findings'
$script:SgNodeInventory = @{}
$downPort.LinkFailures = '7'
$reducedMap.Issues = @('bond0 member hic2 is down')
Assert-Equal (Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available).Summary.NeedsReview $true 'A down port with recorded failure history is not silently treated as unused wiring'
foreach ($member in $reducedMap.Bonds[0].MemberDetail) { $member.CarriesTraffic = $false }
$reducedMap.Issues = @('bond0 has no member ports up', 'bond0 member hic1 is down', 'bond0 member hic2 is down')
$allDown = Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available
Assert-Equal $allDown.Summary.NeedsReview $true 'Aggregate without an active data path remains actionable'
Assert-Equal ($allDown.Issues -contains 'bond0 has no member ports up') $true 'No-link finding is never demoted by reduced-port handling'
$script:SgNodeInventory = @{ node10 = [pscustomobject]@{ Platform = 'appliance'; RequiredPorts = @('hic9') } }
$reducedMap.Issues = @()
Assert-Equal (Set-SgNodeReportAssessment -Map $reducedMap -CoreComplete $true -VlanSource Available).Summary.NeedsReview $true 'An explicitly required missing port is actionable'
$conflictMap = $fixed | ConvertTo-Json -Depth 14 | ConvertFrom-Json
($conflictMap.Bonds | Where-Object Bond -EQ 'bond0').Mode = 'fault-tolerance (active-backup)'
$script:SgNodeInventory = @{ node2 = [pscustomobject]@{ Platform = 'appliance'; PortBondMode = 'Aggregate' } }
Assert-Equal (Set-SgNodeReportAssessment -Map $conflictMap -CoreComplete $true -VlanSource Available).Summary.NeedsReview $true 'Verified inventory does not hide an observed Aggregate/Active-Backup contradiction'
$script:SgNodeInventory = @{}
$legacy = ConvertFrom-SgNetworkCollectorOutput -Lines @($raw | Where-Object { $_ -notmatch '\|STATUS\|' })
$legacyFixed = Get-SgNodeNetworkMap -Node ($legacy.Nodes | Where-Object Name -EQ 'node2')
Assert-Equal $legacyFixed.Summary.PortBondMode 'Fixed' 'Older raw collections remain supported when VLAN headers are present'
$html = Format-SgNetworkHtmlReport -NodeMaps $maps -Target '</script><img src=x onerror=alert(1)>'
Assert-Equal ($html.Contains('<img src=x onerror')) $false 'Untrusted target cannot inject HTML'
Assert-Equal ($html.Contains('<script>window.pwned')) $false 'Untrusted node cannot escape the JSON script element'
$match = [regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', [Text.RegularExpressions.RegexOptions]::Singleline)
$model = $match.Groups[1].Value | ConvertFrom-Json
Assert-Equal @($model.nodes).Count 7 'HTML embeds all node evidence'
Assert-Equal $model.target '</script><img src=x onerror=alert(1)>' 'Safe JSON preserves exact evidence values'

$temporary = [string]::IsNullOrWhiteSpace($ArtifactDirectory)
$workspace = if ($temporary) { Join-Path ([IO.Path]::GetTempPath()) ('sg-report-test-' + [guid]::NewGuid().ToString('N')) } else { [IO.Path]::GetFullPath($ArtifactDirectory) }
try {
    $null = New-Item -ItemType Directory -Path $workspace -Force
    $inputFile = Join-Path $workspace 'synthetic-collector.txt'
    $raw | Set-Content -LiteralPath $inputFile -Encoding UTF8
    $output = Join-Path $workspace 'reports'
    & $scriptPath -InputPath $inputFile -OutputDir $output
    Assert-Equal (Test-Path -LiteralPath $inputFile) $true 'Offline input is never removed'
    $reports = @(Get-ChildItem -LiteralPath $output -File)
    Assert-Equal $reports.Count 5 'HTML, summary, bonds, ports and text are normal retained outputs'
    $htmlFile = $reports | Where-Object Extension -EQ '.html'
    $generatedHtml = Get-Content -LiteralPath $htmlFile.FullName -Raw
    Assert-Equal ($generatedHtml.Contains('<h2>Node Network Summary</h2>')) $true 'Overview uses the Node Network Summary heading'
    Assert-Equal ($generatedHtml.Contains('<h2>Node Comparison</h2>')) $false 'Old overview heading is absent'
    $modelMatch = [regex]::Match($generatedHtml, '<script id="report-data" type="application/json">(.*?)</script>', [Text.RegularExpressions.RegexOptions]::Singleline)
    $generatedModel = $modelMatch.Groups[1].Value | ConvertFrom-Json
    Assert-Equal @($generatedModel.files).Count 4 'Standalone HTML includes all four exports'
    foreach ($download in $generatedModel.files) {
        $bytes = [Convert]::FromBase64String($download.content)
        Assert-Equal ([Convert]::ToBase64String($bytes)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $output $download.name)))) "Embedded export is byte-identical: $($download.label)"
    }
    $inventoryPath = Join-Path $workspace 'verified-inventory.csv'
    @(
        [pscustomobject]@{ Node = 'node1'; Platform = 'vsphere'; PortBondMode = ''; RequiredPorts = '' },
        [pscustomobject]@{ Node = 'node30'; Platform = 'appliance'; PortBondMode = 'Fixed'; RequiredPorts = 'hic1;hic2' }
    ) | Export-Csv -LiteralPath $inventoryPath -NoTypeInformation
    $inventory = Import-SgNodeInventory -Path $inventoryPath
    Assert-Equal @($inventory['node30'].RequiredPorts).Count 2 'Required-port inventory parses explicit intent'
    $topologyPath = Join-Path $workspace 'network-topology.json'
    @{ data = @{ gridNodes = @(@{ nodeConfig = @{ hostname = 'node1'; platform = 'vsphere' } }) } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $topologyPath
    Assert-Equal (Import-SgNodeInventory -Path $topologyPath)['node1'].Platform 'vsphere' 'Exported StorageGRID topology platform is supported'
    $replayedOutput = Join-Path $workspace 'replayed'
    $originalHtmlHash = (Get-FileHash -LiteralPath $htmlFile.FullName -Algorithm SHA256).Hash
    & $scriptPath -InputPath $htmlFile.FullName -NodeInventoryPath $inventoryPath -OutputDir $replayedOutput
    Assert-Equal (Get-FileHash -LiteralPath $htmlFile.FullName -Algorithm SHA256).Hash $originalHtmlHash 'HTML replay does not modify the supplied report'
    $replayedHtml = Get-ChildItem -LiteralPath $replayedOutput -Filter '*.html' | Select-Object -First 1
    $replayedModel = Read-SgNetworkReportEvidence -Path $replayedHtml.FullName
    Assert-Equal ($replayedModel.nodes | Where-Object { $_.Summary.Node -eq 'node1' }).Summary.PortBondMode 'N/A - VMware' 'Saved HTML can be relabelled with verified platform inventory without recollection'
    Assert-Equal ($replayedModel.nodes | Where-Object { $_.Summary.Node -eq 'node30' }).Summary.PortBondMode 'Fixed' 'Verified installer mode resolves saved Grid-only ambiguity'
    Assert-Equal $replayedModel.originalGenerated $generatedModel.generated 'HTML replay preserves original report timestamp'
    $autoInputPath = Join-Path $workspace 'automatic-metadata-collector.txt'
    @($raw + @(
        '@@SGNET@@|__controller__|NODE_METADATA|{"hostname":"node1","platform":"vSphere","nodeType":"primary-admin"}',
        '@@SGNET@@|__controller__|NODE_METADATA|{"hostname":"inventory-only-node","platform":"Linux","nodeType":"adc-sn"}',
        '@@SGNET@@|__controller__|METADATA_STATUS|local-dynip-complete'
    )) | Set-Content -LiteralPath $autoInputPath -Encoding UTF8
    $automaticOutput = Join-Path $workspace 'automatic-platform'
    & $scriptPath -InputPath $autoInputPath -OutputDir $automaticOutput
    $automaticHtml = Get-ChildItem -LiteralPath $automaticOutput -Filter '*.html' | Select-Object -First 1
    $automaticModel = Read-SgNetworkReportEvidence -Path $automaticHtml.FullName
    Assert-Equal @($automaticModel.nodes).Count 7 'Inventory-only records do not invent collected nodes'
    Assert-Equal ($automaticModel.nodes | Where-Object { $_.Summary.Node -eq 'node1' }).Summary.PortBondMode 'N/A - VMware' 'Normal collection pipeline consumes canonical metadata without an inventory parameter'
    Assert-Equal ($automaticModel.nodes | Where-Object { $_.Summary.Node -eq 'node1' }).Summary.GridNodeType 'primary-admin' 'Normal pipeline preserves node type metadata'
    Assert-Equal ($generatedHtml.Contains("item.setAttribute('aria-pressed','false')")) $true 'Dashboard totals expose native button pressed states'
    Assert-Equal ($generatedHtml.Contains('function applyDashboardFilter(key)')) $true 'Generated report includes dashboard filter handling'
    if (-not $temporary) {
        $dashboardNodes = $generatedModel.nodes | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $completeFault = $generatedModel.nodes | Where-Object { $_.Summary.Node -eq 'node2' } | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $completeFault.Summary.Node = 'node-complete-fault'
        $completeFault.Summary.DataComplete = $true
        $completeFault.Summary.NeedsReview = $true
        $completeFault.Summary.IssueCount = 1
        $completeFault.Summary.Issues = 'hic1 is running half duplex'
        $completeFault.Issues = @('hic1 is running half duplex')
        $completeFault.Ports[0].Duplex = 'half'
        Assert-Equal @($dashboardNodes + @($completeFault)).Count 8 'Dashboard browser fixture contains eight flat node records'
        $dashboardPath = Join-Path $workspace 'dashboard-interaction-test.html'
        Format-SgNetworkHtmlReport -NodeMaps @($dashboardNodes + @($completeFault)) -GridIssues @('Synthetic grid-wide observation remains visible during filtering.') -Source 'Synthetic dashboard interaction fixture' | Set-Content -LiteralPath $dashboardPath -Encoding UTF8
        Write-Host "Dashboard fixture: $dashboardPath"
        Write-Host "Preview HTML: $($htmlFile.FullName)"
    }
}
finally { if ($temporary -and (Test-Path -LiteralPath $workspace)) { Remove-Item -LiteralPath $workspace -Recurse -Force } }
Write-Host "PASS: $script:checks assertions on PowerShell $($PSVersionTable.PSVersion)"