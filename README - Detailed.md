# SG-Network-Port-Report

`Invoke-SgNetworkPortReport.ps1` is a standalone, read-only PowerShell script that maps the network
layout of every node in a **NetApp StorageGRID** grid. It shows how the Grid, Admin and Client
Networks map to bonds, VLANs and physical ports, and reports port and bond speeds, link state,
LACP status and common problems.

It connects once to the Primary Admin Node over SSH, runs a single `run-each-node --parallel` pass
to collect data from every node, then builds a set of CSV and text reports on your Windows machine.

> **Disclaimer:** This is a community tool. It is not an official NetApp product and is not
> supported by NetApp. It only reads configuration and status; it makes no changes to the grid.
> Test it in your own environment and use it at your own risk.

## Contents

- [What it reports](#what-it-reports)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [How it works](#how-it-works)
- [Password handling](#password-handling)
- [Output files](#output-files)
- [Issue detection](#issue-detection)
- [Sample output](#sample-output)
- [Troubleshooting](#troubleshooting)
- [Versioning](#versioning)
- [License](#license)

## What it reports

For every node in the grid:

| Item | How it is determined |
|------|----------------------|
| **Port Bond Mode** | `bond0` and `bond1` present = **Fixed**; only `bond0` = **Aggregate/LACP**; no StorageGRID bond interfaces = **N/A (no bond interfaces)** (for example, VMs) |
| **Grid Network** (`eth0`) | Parent bond from `eth0@bondN` in `ip link show` |
| **Admin Network** (`eth1`) | Parent bond (including non-standard names such as `eth1` on some appliances) or physical port (for example, `mtc1`) |
| **Client Network** (`eth2`) | Parent bond from `eth2@bondN` in `ip link show` |
| **VLAN ID** | From `/proc/net/vlan/config`. If the interface exists but has no VLAN entry, it is **Untagged** |
| **Network speed** | Effective speed of the bond or port carrying the network |
| **MTU, IP address, state** | From `ip -o link show` / `ip -o addr show` |
| **Bond members** | Member ports, each port's speed, duplex and status, and the bond's effective speed |
| **LACP details** | Active aggregator, LACP partner MAC, hash policy, LACP rate, members outside the active aggregator |
| **Issues** | Down ports, missing LACP partner, mixed speeds, half duplex, grid-wide MTU mismatch, and more |

Any field without a value (for example, the Client Network on a Storage Node without one) is
written as `N/A`.

## Requirements

- Windows with **Windows PowerShell 5.1** or **PowerShell 7+**.
  - Tested on Windows Server 2022 with PowerShell 5.1, and on Windows 11.
- **Windows OpenSSH client 8.4 or later** (`ssh.exe`), which needs `SSH_ASKPASS_REQUIRE` support.
  - Current Windows 10/11 and Windows Server builds include a suitable version. Check with `ssh -V`.
- SSH access (TCP 22 by default) from your machine to the **Primary Admin Node**.
- The StorageGRID **`admin`** account password. The same password is used for `sudo`.

No PowerShell modules are needed, and nothing is installed on the grid.

## Quick start

1. Download `Invoke-SgNetworkPortReport.ps1`. If Windows blocks the downloaded file, unblock it:

   ```powershell
   Unblock-File .\Invoke-SgNetworkPortReport.ps1
   ```

2. Run it and answer the prompts:

   ```powershell
   .\Invoke-SgNetworkPortReport.ps1
   ```

   ```text
  Invoke-SgNetworkPortReport version 0.9.2
   Enter the URL, FQDN or IP address of the StorageGRID Primary Admin Node: https://grid-admin.example.com:8443/
   Password for admin@grid-admin.example.com (also used for sudo): **************
   Connecting to admin@grid-admin.example.com:22 and running run-each-node --parallel (this can take a minute) ...
   ```

   You can enter a URL, FQDN or IP address. The URL scheme, port and path are removed, and SSH
   always uses `-SshPort` (default 22).

3. Open the reports in the `.\sg-network-report` folder.

If your execution policy blocks the script, you can run it for the current session only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SgNetworkPortReport.ps1
```

### More examples

```powershell
# Provide the Admin Node up front and choose an output folder
.\Invoke-SgNetworkPortReport.ps1 -Target grid-admin.example.com -OutputDir C:\Temp\sg-net

# Keep the raw collector output and the per-port CSV (useful for troubleshooting)
.\Invoke-SgNetworkPortReport.ps1 -KeepIntermediateOutputs

# Show which run-each-node launch method was used
.\Invoke-SgNetworkPortReport.ps1 -Verbose

# Re-build the reports from a saved raw file, without connecting to the grid
.\Invoke-SgNetworkPortReport.ps1 -InputPath .\sg-network-report\20261022T113002_sg-network-raw.txt
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Target` | *(prompted)* | URL, FQDN or IP address of the Primary Admin Node. |
| `-UserName` | `admin` | SSH user. It must be able to run `sudo` with its own password. |
| `-Password` | *(prompted, hidden)* | `SecureString` password. Normally you let the script prompt for it. |
| `-SshPort` | `22` | SSH port on the Admin Node. |
| `-SshExecutable` | `ssh` | Path to `ssh.exe`, if it is not on `PATH`. |
| `-TimeoutSeconds` | `900` | Maximum time to wait for the collection to finish. |
| `-OutputDir` | `.\sg-network-report` | Folder for the reports (created if needed). |
| `-KeepIntermediateOutputs` | off | Keep the raw collector output and the per-port CSV. |
| `-InputPath` | | Re-parse a saved raw collector file instead of connecting. The file is never deleted. |
| `-Verbose` | off | Show the run-each-node launch attempts and other detail. |

## How it works

1. The script connects as `admin` and runs `sudo -S`, sending the password on SSH's stdin. It then
   starts a root **login** shell (`su - root`).
   - `run-each-node` refuses to run from a plain `sudo` shell, so a real login shell is required.
   - The script tries three launch methods in turn, stopping at the first one `run-each-node`
     accepts:
     1. an interactive root login shell on a pseudo-terminal
     2. `su - root` with the command on stdin
     3. `su - root -c`
   - The launch attempts are shown only with `-Verbose`, or if every method is rejected. In that
     case the script also prints diagnostics to help troubleshoot.
2. A single `run-each-node --parallel` pass runs a small collector on every node. It gathers:
   - `ip -o link show` and `ip -o addr show`
   - `/proc/net/vlan/config`
   - `/proc/net/bonding/*`
   - `/sys/class/net/*` (operstate, speed, master and whether the port is physical)
   - `ethtool <iface>` for every interface

   Every line is tagged with a marker, the node name and the data source. This means the parser
   does not depend on how parallel output is interleaved. Commands that don't apply to a node (for
   example, bonding on a VM) are tolerated.
3. The output is parsed on Windows and mapped to nodes, networks, bonds and ports. The script then
   writes the reports.
4. After a successful run, it deletes the intermediate files (the raw output and the ports CSV)
   unless you use `-KeepIntermediateOutputs`. If a run fails, the raw output is always kept.

## Password handling

- The password is read with `Read-Host -AsSecureString` and is only requested once.
- It is never written to disk and never placed on a command line, locally or on the Admin Node.
- **SSH login:** `ssh.exe` gets the password from a temporary `SSH_ASKPASS` helper.
  - The helper file contains no secret. It decrypts a copy protected with Windows DPAPI (current
    user only).
  - That protected copy exists only in the `ssh.exe` process environment.
  - The helper is deleted when the script finishes.
- **sudo:** the password is written to SSH's stdin and read by `sudo -S` on the Admin Node.
  `su - root` is then run as root, so no separate root password is needed.

## Output files

Every file name starts with a local-time timestamp (`yyyyMMddTHHmmss`). This keeps each run's files
sorted and grouped together.

| File | Kept | Contents |
|------|------|----------|
| `<ts>_sg-network-summary.csv` | Always | One row per node: bond mode and Grid/Admin/Client details, plus issues |
| `<ts>_sg-network-bonds.csv` | Always | One row per bond: mode, networks, speeds, members, LACP details |
| `<ts>_sg-network-report.txt` | Always | Human-readable report: overview, issues, and per-node network, bond and port tables |
| `<ts>_sg-network-ports.csv` | With `-KeepIntermediateOutputs` | One row per physical port |
| `<ts>_sg-network-raw.txt` | With `-KeepIntermediateOutputs`, or on failure | Raw tagged collector output (can be re-parsed with `-InputPath`) |

### Summary CSV columns

`Node`, `DataComplete`, `PortBondMode`, `Bonds`; then for each of `Grid`, `Admin` and `Client`:
`<Net>Interface`, `<Net>ParentBond`, `<Net>ParentBondMode`, `<Net>ParentBondActiveSlave`,
`<Net>Vlan`, `<Net>Ports`, `<Net>Speed`, `<Net>Mtu`, `<Net>Address`, `<Net>State`; then
`BondSummary`, `IssueCount`, `Issues`.

- `ParentBond` is `None` when the network uses a physical port directly, such as on VMs or `eth1`
  on `mtc1`.
- `ParentBond` can also be a non-standard bond interface name (for example `eth1` on some physical
  appliances), not only `bond0`/`bond1`.
- `ParentBondMode` and `ParentBondActiveSlave` are populated when `ParentBond` resolves to a bond;
  otherwise they are `N/A`.
- `Vlan` is the VLAN ID, or `Untagged`.

### Bonds CSV columns

`Node`, `Bond`, `State`, `Mode`, `Networks`, `EffectiveSpeed`, `EffectiveSpeedMbps`, `KernelSpeed`,
`MembersUp`, `Members`, `ActiveSlave`, `LacpPartnerMac`, `ActiveAggregatorId`, `HashPolicy`,
`LacpRate`, `Mtu`

### Ports CSV columns

`Node`, `Port`, `Status`, `Bond`, `Networks`, `Speed`, `SpeedMbps`, `Duplex`, `LinkDetected`,
`State`, `Mtu`, `Mac`, `AggregatorId`, `LinkFailures`

The port `Status` is one of the following:

- `Up - active`
- `Up - standby`
- `Up - not in active LACP aggregator`
- `Down`
- `Unused`
- `Unused (link up)`

### How speeds are calculated

- **Port speed** is the link speed the port negotiated, from `ethtool` or `/sys/class/net`.
- **Effective bond speed** is the speed of the member ports that actually carry traffic:
  - **802.3ad (LACP):** the total of members that are up and in the active aggregator.
  - **active-backup (Fixed):** the speed of the currently active port.
- **Network speed** is the effective speed of the bond (or port) behind `eth0`, `eth1` or `eth2`.
- `KernelSpeed` is the speed the kernel reports for the bond interface itself, included for
  reference.

## Issue detection

The **ISSUES** section of the text report, and the `Issues` column of the summary CSV, flag:

- A bond member that is down, or a bond with no members up.
- An LACP member that is up but not in the active aggregator.
- No LACP partner detected (partner MAC is all zeros). This usually means LACP isn't configured on
  the switch.
- Bond members with different speeds.
- Ports running at half duplex.
- A non-bonded network port (for example, `mtc1` for the Admin Network) that is down.
- A network interface that is not `UP`.
- Grid Network MTU that differs between nodes (grid-wide check).
- Incomplete data collected from a node.

## Sample output

The samples below come from a small example grid. The example grid has:

- `dc1-sn1`: an appliance Storage Node using Aggregate/LACP, 4 × 25 Gb/s, a tagged Grid Network,
  and the Admin Network on `mtc1`.
- `dc1-sn2`: an appliance Storage Node using Fixed (active-backup) bonds, with one member port down.
- `dc1-gw1`: a virtual Gateway Node with no bonds.

All host names, addresses and MAC addresses are fictitious. The full sample files are in
[`samples/`](samples/).

### Console

```text
Invoke-SgNetworkPortReport version 0.9.2
Enter the URL, FQDN or IP address of the StorageGRID Primary Admin Node: https://grid-admin.example.com:8443/
Password for admin@grid-admin.example.com (also used for sudo): **************
Connecting to admin@grid-admin.example.com:22 and running run-each-node --parallel (this can take a minute) ...

Node    PortBondMode             Grid                      Admin                  Client                    Issues
----    ------------             ----                      -----                  ------                    ------
dc1-gw1 N/A (no bond interfaces) eth0, Untagged, 10 Gb/s   N/A                    N/A                            0
dc1-sn1 Aggregate/LACP           bond0, VLAN 100, 100 Gb/s mtc1, Untagged, 1 Gb/s bond0, Untagged, 100 Gb/s      0
dc1-sn2 Fixed                    bond0, Untagged, 25 Gb/s  N/A                    bond1, VLAN 200, 25 Gb/s       1

WARNING: 2 issue(s) detected - see the ISSUES section of the text report.
Summary CSV : C:\Reports\sg-network-report\20261022T113002_sg-network-summary.csv
Bonds CSV   : C:\Reports\sg-network-report\20261022T113002_sg-network-bonds.csv
Text report : C:\Reports\sg-network-report\20261022T113002_sg-network-report.txt
```

### Text report (excerpt)

```text
StorageGRID Network Port Report (Invoke-SgNetworkPortReport version 0.9.2)
Generated: 2026-10-22 11:30:03 (UTC+11:00)
Primary Admin Node: grid-admin.example.com
Nodes: 3
Networks: Grid = eth0, Admin = eth1, Client = eth2
Speeds: network/bond speed = sum of member ports carrying traffic (802.3ad: up members in the
        active aggregator; active-backup: the active port). Port speed is the negotiated link speed.
====================================================================================================

OVERVIEW
  Node    PortBondMode             Grid                      Admin                  Client                    Issues
  ----    ------------             ----                      -----                  ------                    ------
  dc1-gw1 N/A (no bond interfaces) eth0, Untagged, 10 Gb/s   N/A                    N/A                            0
  dc1-sn1 Aggregate/LACP           bond0, VLAN 100, 100 Gb/s mtc1, Untagged, 1 Gb/s bond0, Untagged, 100 Gb/s      0
  dc1-sn2 Fixed                    bond0, Untagged, 25 Gb/s  N/A                    bond1, VLAN 200, 25 Gb/s       1

ISSUES
  - [grid] Grid Network MTU is not the same on every node - MTU 1500 on 2 node(s): dc1-gw1, dc1-sn2 | MTU 1400 on 1 node(s): dc1-sn1
  - [dc1-sn2] bond0 member hic4 is down

====================================================================================================
Node: dc1-sn2    Port Bond Mode: Fixed
  Networks:
    Network Interface ParentBond Vlan     Ports     Speed   Mtu  State Address Path
    ------- --------- ---------- ----     -----     -----   ---  ----- ------- ----
    Grid    eth0      bond0      Untagged hic2 hic4 25 Gb/s 1500 UP    N/A     eth0 -> bond0
    Admin   eth1      N/A        N/A      N/A       N/A     N/A  N/A   N/A     N/A
    Client  eth2      bond1      200      hic1 hic3 25 Gb/s 1500 UP    N/A     eth2 -> bond1
  Bonds:
    Bond  State Mode                            Networks EffectiveSpeed KernelSpeed MembersUp ActiveSlave LacpPartnerMac HashPolicy Mtu
    ----  ----- ----                            -------- -------------- ----------- --------- ----------- -------------- ---------- ---
    bond0 UP    fault-tolerance (active-backup) Grid     25 Gb/s        25 Gb/s     1/2       hic2        N/A            N/A        1500
    bond1 UP    fault-tolerance (active-backup) Client   25 Gb/s        25 Gb/s     2/2       hic1        N/A            N/A        1500
  Ports:
    Port Status       Bond  Networks Speed   Duplex LinkDetected Mtu  Mac               AggregatorId LinkFailures
    ---- ------       ----  -------- -----   ------ ------------ ---  ---               ------------ ------------
    hic1 Up - active  bond1 Client   25 Gb/s Full   yes          1500 0e:1f:91:a0:e6:83 N/A          0
    hic2 Up - active  bond0 Grid     25 Gb/s Full   yes          1500 1a:bf:b7:43:d4:cf N/A          0
    hic3 Up - standby bond1 Client   25 Gb/s Full   yes          1500 92:f1:47:41:c2:70 N/A          0
    hic4 Down         bond0 Grid     N/A     N/A    no           1500 96:67:3e:4f:15:9f N/A          0
  Issues:
    - bond0 member hic4 is down
```

### Summary CSV (selected columns)

The table below includes both classic `bond0`/`bond1` examples and an appliance-style Admin
Network example where `eth1` is itself a bond interface.

| Node | PortBondMode | GridParentBond | GridParentBondMode | GridParentBondActiveSlave | GridVlan | GridSpeed | AdminInterface | AdminParentBond | AdminParentBondMode | AdminParentBondActiveSlave | AdminPorts | AdminSpeed | ClientParentBond | ClientParentBondMode | ClientParentBondActiveSlave | ClientVlan | ClientSpeed | IssueCount |
|------|--------------|----------------|--------------------|---------------------------|----------|-----------|----------------|-----------------|---------------------|----------------------------|------------|------------|------------------|----------------------|-----------------------------|------------|-------------|-----------:|
| dc1-gw1 | N/A (no bond interfaces) | None | N/A | N/A | Untagged | 10 Gb/s | eth1 | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 0 |
| dc1-sn1 | Aggregate/LACP | bond0 | IEEE 802.3ad Dynamic link aggregation | N/A | 100 | 100 Gb/s | eth1 | None | N/A | N/A | mtc1 | 1 Gb/s | bond0 | IEEE 802.3ad Dynamic link aggregation | N/A | Untagged | 100 Gb/s | 0 |
| dc1-sn2 | Fixed | bond0 | fault-tolerance (active-backup) | hic2 | Untagged | 25 Gb/s | eth1 | N/A | N/A | N/A | N/A | N/A | bond1 | fault-tolerance (active-backup) | hic1 | 200 | 25 Gb/s | 1 |
| dc1-adm1 | Aggregate/LACP | bond0 | IEEE 802.3ad Dynamic link aggregation | N/A | 134 | 200 Gb/s | eth1 | eth1 | fault-tolerance (active-backup) | mtc1 | mtc1 | 1 Gb/s | bond0 | IEEE 802.3ad Dynamic link aggregation | N/A | 13 | 200 Gb/s | 2 |

Example (CSV row) for a node where Admin `eth1` is a bond:

```text
Node,AdminInterface,AdminParentBond,AdminParentBondMode,AdminParentBondActiveSlave,AdminPorts,AdminSpeed
dc1-adm1,eth1,eth1,fault-tolerance (active-backup),mtc1,mtc1,1 Gb/s
```

### Bonds CSV

| Node | Bond | State | Mode | Networks | EffectiveSpeed | KernelSpeed | MembersUp | Members | ActiveSlave | LacpPartnerMac | HashPolicy | LacpRate |
|------|------|-------|------|----------|----------------|-------------|-----------|---------|-------------|----------------|------------|----------|
| dc1-sn1 | bond0 | UP | IEEE 802.3ad Dynamic link aggregation | Grid, Client | 100 Gb/s | 100 Gb/s | 4/4 | hic1 (25 Gb/s, Up), hic2 (25 Gb/s, Up), hic3 (25 Gb/s, Up), hic4 (25 Gb/s, Up) | N/A | 02:00:00:aa:bb:cc | layer2 (0) | slow |
| dc1-sn2 | bond0 | UP | fault-tolerance (active-backup) | Grid | 25 Gb/s | 25 Gb/s | 1/2 | hic2 (25 Gb/s, Up), hic4 (25 Gb/s, Down) | hic2 | N/A | N/A | N/A |
| dc1-sn2 | bond1 | UP | fault-tolerance (active-backup) | Client | 25 Gb/s | 25 Gb/s | 2/2 | hic1 (25 Gb/s, Up), hic3 (25 Gb/s, Up) | hic1 | N/A | N/A | N/A |

## Troubleshooting

| Symptom | What to do |
|---------|------------|
| `ssh` not found, or the password prompt keeps repeating | Install or update the Windows OpenSSH client (8.4+). Check with `ssh -V`. If `ssh.exe` is not on `PATH`, use `-SshExecutable`. |
| Authentication fails | Check the `admin` password, and that you can run `ssh admin@<admin-node>` manually. |
| `run-each-node rejected every launch method tried` | Run again with `-Verbose -KeepIntermediateOutputs`, and keep the diagnostics printed on screen and the raw file. |
| A node is missing, or `DataComplete` is `False` | Check the "Other run-each-node output" section at the end of the text report for nodes that could not be reached. |
| You want to change or check the parsing without reconnecting | Keep the raw file with `-KeepIntermediateOutputs`, then re-run with `-InputPath <raw file>`. |

Interface name assumptions:

- StorageGRID always uses `eth0` = Grid, `eth1` = Admin and `eth2` = Client.
- Physical port names (for example, `hic1`–`hic4` and `mtc1`–`mtc2` on appliances) are taken from
  the node as reported.

## Versioning

The script version is shown at start-up (`Invoke-SgNetworkPortReport version x.y.z`) and in the text
report header. The version history is in the `.NOTES` section of the script's comment-based help:

```powershell
Get-Help .\Invoke-SgNetworkPortReport.ps1 -Full
```

## License

[MIT](LICENSE)
