# SG-Network-Port-Report

**Version 1.0.5** - Node Network Summary heading, clickable dashboard totals and safe reporting of bonds with no active members. Includes automatic platform discovery over the existing SSH session, with no REST login prompt. Runtime topology inference still needs comparison with confirmed installer settings.

`Invoke-SgNetworkPortReport.ps1` is a standalone, read-only PowerShell script that maps the network
layout of every node in a **NetApp StorageGRID** grid. It shows how the Grid, Admin and Client
Networks map to bonds, VLANs and physical ports, and reports port and bond speeds, link state,
LACP status and common problems.

It connects once to the Primary Admin Node over SSH, runs a single `run-each-node --parallel` pass
to collect data from every node, then builds a self-contained HTML report plus CSV and text outputs on your Windows machine.

> **Disclaimer:** This is a community tool. It is not an official NetApp product and is not
> supported by NetApp Technical Support. It only reads configuration and status; it makes no changes to the grid.
> Test it in your own environment and use it at your own risk.

## Contents

- [What it reports](#what-it-reports)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [Reference and tests](#reference-and-tests)
- [License](#license)

## What it reports

For every node in the grid:

| Item | How it is determined |
|------|----------------------|
| **Port Bond Mode** | Separate Grid/Client parent bonds infer **Fixed**; shared LACP or Grid-only LACP containing hic1-hic4 infers **Aggregate**. A Grid-only Active-Backup appliance pair infers **Fixed**. Two LACP members alone remain **Unknown** unless installer-confirmed inventory resolves the mode. VMware/Baremetal deployments are skipped as **N/A - VMware** / **N/A - Baremetal** when identified. |
| **Network Bond Mode** | Separate per-network value: **LACP**, **Active-Backup**, **Independent**, **Unknown**, or **Not observed**. Fixed port bond mode can also use LACP. |
| **Grid Network** (`eth0`) | Parent bond from `eth0@bondN` in `ip link show` |
| **Admin Network** (`eth1`) | Parent bond (including non-standard names such as `eth1` on some appliances) or physical port (for example, `mtc1`) |
| **Client Network** (`eth2`) | Parent bond from `eth2@bondN` in `ip link show` |
| **VLAN ID** | From `/proc/net/vlan/config`. **Untagged** requires a successfully observed VLAN table; failed/unavailable collection is **Unknown**. |
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

2. Verify SSH trust first. Obtain the Admin Node host-key fingerprint through a trusted channel, then compare it before accepting:

  ```powershell
  ssh -o StrictHostKeyChecking=ask admin@grid-admin.example.com
  ```

  Exit after verification. Do not bypass changed-key warnings. For a non-default SSH port, add `-p <port>` here and use `-SshPort <port>` below. Unattended collection requires a previously trusted key.

3. Run it and answer the prompts:

   ```powershell
  .\Invoke-SgNetworkPortReport.ps1 -OpenReport
   ```

   ```text
  Invoke-SgNetworkPortReport version 1.0.5
   Enter the URL, FQDN or IP address of the StorageGRID Primary Admin Node: https://grid-admin.example.com:8443/
   Password for admin@grid-admin.example.com (also used for sudo): **************
   Connecting to admin@grid-admin.example.com:22 and running run-each-node --parallel (this can take a minute) ...
   ```

   You can enter a URL, FQDN or IP address. The URL scheme, port and path are removed, and SSH
   always uses `-SshPort` (default 22).

4. The HTML report opens with `-OpenReport`. Otherwise open the printed HTML path in `.\sg-network-report`.

The HTML contains a node comparison, port and network bond modes, VLANs, search and filters, natural node-name sorting, attention-only results and expandable evidence. CSV and text downloads are embedded, so sharing the HTML alone preserves them. All three CSV files and the text report are also retained beside the HTML. Reports contain infrastructure data: keep real reports and raw evidence private.

Dashboard totals are clickable filter buttons with keyboard support and a highlighted active state. A total selects its category and clears unrelated filters; selecting it again or choosing **Nodes observed** restores all nodes and natural sorting. **Incomplete** selects only actionable nodes with incomplete evidence, matching its displayed count. Additional form filters can narrow that selection; Reset filters clears it. Totals always describe the whole report, and grid-wide observations remain visible while node results are filtered.

This is observed runtime evidence, not a reconstruction of every Appliance Installer setting. A missing interface is not proof of a disabled network. Unaddressed inactive Admin/Client interfaces are shown as inactive with enablement unknown, rather than automatically flagged as failed enabled networks. Virtual nodes may have no `/proc/net/vlan/config`; their VLANs remain Unknown even when unbonded topology is clear. Hypervisor/switch-side tags are not visible from guest evidence. Negotiated link speeds do not establish the configured Auto/fixed speed. Node role/model collection is not yet implemented. Incomplete/untagged collector output can indicate unreachable nodes; expected grid membership is not independently verified.

Software VLAN visibility limits and unresolved appliance modes are information, not configuration faults. Actual permission/collection failures and link/LACP faults still require attention. In Aggregate mode, down members with zero recorded failures and an active data path can reflect documented reduced-port wiring; they remain explicit observations, not proof of intentional disconnection. Use `RequiredPorts` to declare ports that must be up. Positive failure history, total link loss, and required ports missing/down remain actionable. See [NetApp port bond modes](https://docs.netapp.com/us-en/storagegrid-appliances/installconfig/gathering-installation-information-sg6000.html#port-bond-modes).

### Deployment Evidence And Inventory

New collections first ask the Admin Node's installed `Bycast::Helpers::DynipStatic.nodes` helper for allowlisted `hostname`, `platform` and `nodeType` metadata. This uses the same SSH/sudo session and password as collection: no REST-account prompt, additional Windows dependency, or API-password guessing. Canonical vSphere, Linux and SGA platforms map to VMware, Baremetal and Appliance. The metadata source and node type are retained in the report for offline replay.

This is an internal, version-dependent StorageGRID helper, not a public compatibility contract. Discovery is best effort, bounded when the standard Linux timeout utility is present, and never stops network collection merely because metadata is unavailable. Errors are reduced to non-secret status/class messages; local service protection is handled by the installed helper. The collector does not extract or copy its protection token. Direct per-node DMI/container evidence remains a fallback, and an unavailable source is not guessed from MACs or names.

For older reports without platform metadata, explicit overrides, or installer-confirmed bond/wiring settings, optionally use `-NodeInventoryPath` with an exported StorageGRID `/private/network-topology` JSON (`nodeConfig.platform`) or a verified CSV:

```csv
Node,Platform,PortBondMode,RequiredPorts
example-vm-01,VMware,,
example-container-01,Baremetal,,
example-appliance-01,appliance,Fixed,hic2;hic4
```

Names must match collected hostnames. `PortBondMode` and `RequiredPorts` are optional operator-verified settings/wiring intent. Never fill them by guesswork. The report identifies configured inventory versus inferred topology, and records missing legacy completion status rather than claiming fresh validation. No report data is sent to external APIs.

```powershell
# Reassess a saved HTML report without connecting; originals remain unchanged
.\Invoke-SgNetworkPortReport.ps1 -InputPath .\previous-report.html -NodeInventoryPath .\node-inventory.csv -OpenReport
```

If your execution policy blocks the script, you can run it for the current session only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-SgNetworkPortReport.ps1
```

### More examples

```powershell
# Provide the Admin Node up front and choose an output folder
.\Invoke-SgNetworkPortReport.ps1 -Target grid-admin.example.com -OutputDir C:\Temp\sg-net

# Keep the raw collector output for troubleshooting (the ports CSV is always retained)
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
| `-KeepIntermediateOutputs` | off | Keep newly collected raw output; every report is retained regardless. |
| `-OpenReport` | off | Open the generated HTML in the default browser. |
| `-InputPath` | | Reassess saved raw output or HTML JSON evidence instead of connecting. The input is never modified or deleted. |
| `-NodeInventoryPath` | | Optional verified node/deployment CSV or exported network-topology JSON. |
| `-Verbose` | off | Show the run-each-node launch attempts and other detail. |

## Reference and tests

Network-link terminology: [StorageGRID appliance link configuration](https://docs.netapp.com/us-en/storagegrid-appliances/installconfig/configuring-network-links.html).

Offline regression checks from the source checkout (no grid access): `powershell.exe -NoProfile -File .\Tests\Test-SgNetworkReport.ps1` and `pwsh -NoProfile -File .\Tests\Test-SgNetworkReport.ps1`.

## License

[MIT](LICENSE)
