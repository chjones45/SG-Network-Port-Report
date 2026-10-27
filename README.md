# SG-Network-Port-Report

`Invoke-SgNetworkPortReport.ps1` is a standalone, read-only PowerShell script that maps the network
layout of every node in a **NetApp StorageGRID** grid. It shows how the Grid, Admin and Client
Networks map to bonds, VLANs and physical ports, and reports port and bond speeds, link state,
LACP status and common problems.

It connects once to the Primary Admin Node over SSH, runs a single `run-each-node --parallel` pass
to collect data from every node, then builds a set of CSV and text reports on your Windows machine.

> **Disclaimer:** This is a community tool. It is not an official NetApp product and is not
> supported by NetApp Technical Support. It only reads configuration and status; it makes no changes to the grid.
> Test it in your own environment and use it at your own risk.

## Contents

- [What it reports](#what-it-reports)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters](#parameters)
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

## License

[MIT](LICENSE)
