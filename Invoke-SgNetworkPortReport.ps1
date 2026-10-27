<#
.SYNOPSIS
Maps the bond, VLAN and physical port layout of every node in a NetApp StorageGRID grid.

.DESCRIPTION
Standalone, read-only tool. It:
  1. Prompts for the Primary Admin Node (URL, FQDN or IP) and the 'admin' password (once).
  2. Connects over SSH as 'admin', authenticates sudo with the same password, and starts
     run-each-node from an interactive root login shell ('su - root' on a pseudo-terminal), because
     run-each-node refuses to run from a plain sudo shell. If that is rejected, 'su - root' with
     the command on stdin and then 'su - root -c' are tried. A single 'run-each-node --parallel' pass collects,
     from every node:
        ip -o link show            (bonds, bond members, ethN@parent, MTU, MAC)
        ip -o addr show            (IP addresses of eth0 / eth1 / eth2)
        /proc/net/vlan/config      (VLAN IDs for eth0 / eth1 / eth2, or Untagged)
        /proc/net/bonding/*        (bond mode, LACP aggregator / partner, active port, member
                                    MII status, speed, duplex, link failures, permanent MAC)
        /sys/class/net/*           (operstate, speed, master, physical port flag)
        ethtool <iface>            (speed, duplex and link detected for every interface)
     Every output line is tagged on the node with '@@SGNET@@|<node>|<section>|', so the parser
     does not depend on how run-each-node formats or interleaves parallel output.
  3. Maps nodes, networks (Grid = eth0, Admin = eth1, Client = eth2), bonds and ports together
     and writes:
        <ts>_sg-network-summary.csv   one row per node: bond mode, and per network the parent
                                      bond, VLAN, ports, speed, MTU, address, state; issues
        <ts>_sg-network-bonds.csv     one row per bond: mode, networks, effective speed, members
                                      up, LACP partner / aggregator, hash policy, MTU
        <ts>_sg-network-report.txt    overview, issues, and per-node network / bond / port tables
     Fields with no value are written as 'N/A'.
  4. After a successful run, removes the intermediate outputs (the raw collector output
     <ts>_sg-network-raw.txt and the per-port CSV <ts>_sg-network-ports.csv) unless
     -KeepIntermediateOutputs is specified. A failed run always keeps the raw output.

Password handling:
  * The password is read with Read-Host -AsSecureString and never written to disk, never placed
    on a command line and never passed to the remote host as an argument.
  * SSH login: ssh.exe obtains the password through a temporary SSH_ASKPASS helper. The helper
    file contains no secret; it decrypts a DPAPI (current Windows user only) protected copy that
    is supplied only in the ssh.exe child process environment.
  * sudo: the password is written to ssh's stdin and consumed by 'sudo -S' on the Admin Node.
    sudo runs as root, so 'su - root' does not need a separate root password.

.NOTES
Version: 0.9.2 (also shown on screen at start-up). Increment $script:SgToolVersion with every change.
  0.1.0  Initial release: sudo bash launcher.
  0.2.0  Launch run-each-node through sudo su - root.
  0.3.0  Version display; fallback launch methods (pty, detached pty); diagnostics on rejection.
  0.4.0  Launch from a real root login shell ("-bash") so run-each-node sees the same parent
         shell as an interactive "su -"; wider diagnostics (Ruby libraries, process ancestry).
  0.5.0  Admin Network (eth1); per-network ports, speed, MTU, IP and state; bonds CSV (effective
         speed, LACP partner / aggregator) and ports CSV (replaces the bond-members CSV);
         issue detection; overview table in the text report and console.
  0.6.0  'N/A' for empty fields; UnusedPorts removed from the summary CSV; raw output and ports
         CSV removed after a successful run unless -KeepIntermediateOutputs is specified.
  0.7.0  Try the interactive-pty launch method first (the one accepted in the field); launch
         attempt lines are only shown with -Verbose, or when every method is rejected.
  0.8.0  Output file names start with the timestamp (<ts>_sg-network-<type>) so each run's
         files sort and group together.
  0.9.0  Timestamps (file names and report header) use the local time of the machine running
         the script instead of UTC; the report header shows the UTC offset.
  0.9.1  Bond detection now supports non-standard bond interface names (for example, Admin
      Network eth1 as a bond on physical appliances), so parent bond/member reporting is
      correct in summary CSV and text reports.
  0.9.2  Summary CSV now includes explicit per-network parent bond details for Grid/Admin/Client:
      <Network>ParentBondMode and <Network>ParentBondActiveSlave.

Requires Windows PowerShell 5.1 or PowerShell 7+ on Windows, and the Windows OpenSSH client 8.4+
(SSH_ASKPASS_REQUIRE support; current Windows 10/11 and Server builds ship a suitable ssh.exe).

.PARAMETER Target
URL, FQDN or IP address of the Primary Admin Node. Prompted for when omitted.

.PARAMETER InputPath
Re-parse a raw collector output file saved by a previous run (with -KeepIntermediateOutputs)
instead of connecting to the grid. The input file is never deleted.

.PARAMETER KeepIntermediateOutputs
Keep the raw collector output and the per-port CSV for troubleshooting. By default they are
deleted after a successful run, leaving the summary CSV, bonds CSV and text report.

.EXAMPLE
PS> .\Invoke-SgNetworkPortReport.ps1

.EXAMPLE
PS> .\Invoke-SgNetworkPortReport.ps1 -KeepIntermediateOutputs:$true

.EXAMPLE
PS> .\Invoke-SgNetworkPortReport.ps1 -Target https://grid-admin.example.test -OutputDir C:\Temp\sg-net

.EXAMPLE
PS> .\Invoke-SgNetworkPortReport.ps1 -InputPath .\sg-network-report\20261022T000000_sg-network-raw.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$Target,
    [Parameter(Mandatory = $false)][string]$UserName = 'admin',
    [Parameter(Mandatory = $false)][System.Security.SecureString]$Password,
    [Parameter(Mandatory = $false)][int]$SshPort = 22,
    [Parameter(Mandatory = $false)][string]$SshExecutable = 'ssh',
    [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900,
    [Parameter(Mandatory = $false)][string]$InputPath,
    [Parameter(Mandatory = $false)][string]$OutputDir = '.\sg-network-report',
    [Parameter(Mandatory = $false)][switch]$KeepIntermediateOutputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SgToolVersion = '0.9.2'
$script:SgMarker = '@@SGNET@@'
# StorageGRID fixed interface roles.
$script:SgNetworkInterfaces = [ordered]@{
    'Grid'   = 'eth0'
    'Admin'  = 'eth1'
    'Client' = 'eth2'
}

#region Connection helpers ---------------------------------------------------------------------

function ConvertTo-SgSshHost {
    <#
    .SYNOPSIS
    Reduces a URL, FQDN or IP address (optionally with a port or path) to a bare SSH host name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Target)

    $text = $Target.Trim() -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $text = ($text -split '/', 2)[0]
    $text = ($text -split '@')[-1]
    # Strip a port from host:port or [ipv6]:port, but leave a bare IPv6 address alone.
    if ($text -match '^\[(?<h>[^\]]+)\](:\d+)?$') { $text = $Matches['h'] }
    elseif (@($text.ToCharArray() | Where-Object { $_ -eq ':' }).Count -eq 1) { $text = ($text -split ':')[0] }
    $text = $text.Trim('[', ']')
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Could not determine a host name from '$Target'." }
    return $text
}

function ConvertTo-SgNativeArgument {
    <#
    .SYNOPSIS
    Quotes one argument using the Windows (MSVCRT) command-line rules, for ProcessStartInfo.Arguments.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$builder.Append('\' * ($backslashes * 2 + 1)).Append('"')
        }
        else {
            [void]$builder.Append('\' * $backslashes).Append($ch)
        }
        $backslashes = 0
    }
    [void]$builder.Append('\' * ($backslashes * 2)).Append('"')
    return $builder.ToString()
}

function New-SgAskPassHelper {
    <#
    .SYNOPSIS
    Writes a temporary SSH_ASKPASS helper that returns the DPAPI-protected password from its
    environment. The helper itself contains no secret.
    #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Core') { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
    else { $hostExe = Join-Path $PSHOME 'powershell.exe' }

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('sgnet-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $helperPath = Join-Path $directory 'askpass.cmd'
    $command = '$s = ConvertTo-SecureString $env:SGNET_ASKPASS_BLOB; [Console]::Out.Write((New-Object System.Net.NetworkCredential -ArgumentList '''', $s).Password)'
    $content = "@`"$hostExe`" -NoLogo -NoProfile -NonInteractive -Command `"$command`"`r`n"
    [System.IO.File]::WriteAllText($helperPath, $content, (New-Object System.Text.ASCIIEncoding))
    return $helperPath
}

function Invoke-SgNativeProcess {
    <#
    .SYNOPSIS
    Runs a native executable with redirected streams, optional stdin bytes and extra environment
    variables that are visible to the child process only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $false)][hashtable]$Environment = @{},
        [Parameter(Mandatory = $false)][byte[]]$StandardInputBytes,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-SgNativeArgument -Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $stdin = $process.StandardInput.BaseStream
        if ($null -ne $StandardInputBytes -and $StandardInputBytes.Length -gt 0) {
            $stdin.Write($StandardInputBytes, 0, $StandardInputBytes.Length)
            $stdin.Flush()
        }
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "$([System.IO.Path]::GetFileName($FilePath)) did not finish within $TimeoutSeconds seconds."
        }
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-SgNetworkCollectorScript {
    <#
    .SYNOPSIS
    Generates the bash collector run as root on the Primary Admin Node. It fans out to every
    node with a single 'run-each-node --parallel' call.
    #>
    [CmdletBinding()]
    param()

    # Runs on each node. Every line is tagged with node and section so parallel output can be
    # re-assembled reliably. Nothing in here fails the node (the '|| true' behaviour).
    $nodeScript = @'
M='@@SGNET@@'
H=$(hostname 2>/dev/null)
tag() { awk -v p="${M}|${H}|$1|" '{ print p $0; fflush() }'; }
{ ip -o link show 2>&1; } | tag IPLINK
{ ip -o addr show 2>&1; } | tag ADDR
{ cat /proc/net/vlan/config 2>/dev/null; } | tag VLAN
for f in /proc/net/bonding/*; do
    [ -e "$f" ] || continue
    echo "=== ${f##*/} ==="
    cat "$f" 2>/dev/null
done | tag BONDING
for p in /sys/class/net/*; do
    i=${p##*/}
    [ -d "$p" ] && [ "$i" != "lo" ] || continue
    m=$(readlink "$p/master" 2>/dev/null); m=${m##*/}
    ph=0; [ -e "$p/device" ] && ph=1
    printf '%s operstate=%s speed=%s master=%s phys=%s\n' "$i" "$(cat "$p/operstate" 2>/dev/null)" "$(cat "$p/speed" 2>/dev/null)" "$m" "$ph"
done | tag SYSNET
if command -v ethtool >/dev/null 2>&1; then
    for p in /sys/class/net/*; do
        i=${p##*/}
        [ -d "$p" ] && [ "$i" != "lo" ] || continue
        echo "=== $i ==="
        ethtool "$i" 2>&1
    done | tag ETHTOOL
fi
echo "${M}|${H}|DONE|"
exit 0
'@ -replace "`r`n", "`n"

    $nodeScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($nodeScript))

    $controller = @'
#!/bin/bash
# StorageGRID network port collector v__VERSION__ (generated -- read-only, safe to review).
# run-each-node only runs from a root shell started with "su -" (not "su" or "sudo"). It appears to
# look at the shell that started it, so it is launched from a real root login shell ("-bash"),
# trying progressively closer matches to a person typing at "su -":
#   interactive-pty : su - root on a pseudo-terminal    (interactive login shell with a tty; tried
#                     first - the only method accepted by StorageGRID 11.x run-each-node in the field)
#   shell-stdin     : su - root, command fed on stdin   (run-each-node's parent is "-bash")
#   shell-c         : su - root -c "cmd; exit"          (parent is "-bash -c ...", no exec shortcut)
exec </dev/null
M='@@SGNET@@'
say() { echo "${M}|__controller__|$1|$2"; }
say BEGIN "uid=$(id -u) host=$(hostname) version=__VERSION__"
if [ "$(id -u)" != "0" ]; then
    say ERROR "collector is not running as root"
    exit 3
fi
REN=$(export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"; command -v run-each-node 2>/dev/null)
if [ -z "$REN" ]; then
    say ERROR "run-each-node was not found in PATH"
    exit 4
fi
TMPD=$(mktemp -d /tmp/sgnet.XXXXXX) || { say ERROR "mktemp failed"; exit 5; }
trap 'rm -rf "$TMPD"' EXIT
B64='__NODE_SCRIPT_B64__'
INNER="$REN --parallel 'echo $B64 | base64 -d | bash'"
REJECT='Must run from a root shell'
HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1
# Strip CRs (pty output) and replace the long encoded node script in echoed commands.
clean() { tr -d '\r' | sed "s|$B64|<node-script>|g"; }

run_method() {
    OUT="$TMPD/out.$1"; RC=''
    case "$1" in
        shell-stdin)
            # "exit" is on the same line so bash has already read it if run-each-node reads stdin.
            printf '%s; exit $?\n' "$INNER" | su - root >"$OUT" 2>&1; RC=$? ;;
        shell-c)
            su - root -c "$INNER; exit \$?" >"$OUT" 2>&1; RC=$? ;;
        interactive-pty)
            # Keep script's stdin open until the shell exits; an early EOF can end the session.
            { printf '%s; exit $?\n' "$INNER"; while [ ! -e "$TMPD/done" ]; do sleep 1; done; } |
                { script -qec "su - root" /dev/null >"$OUT" 2>&1; RC=$?; touch "$TMPD/done"; echo "$RC" >"$TMPD/rc"; }
            RC=$(cat "$TMPD/rc" 2>/dev/null) ;;
    esac
}

TRIED=''
for METHOD in interactive-pty shell-stdin shell-c; do
    if [ "$METHOD" = interactive-pty ] && [ "$HAVE_SCRIPT" != 1 ]; then continue; fi
    TRIED="$TRIED $METHOD"
    run_method "$METHOD"
    if grep -q "$REJECT" "$OUT"; then
        say ATTEMPT "method=$METHOD result=rejected rc=$RC"
        clean <"$OUT" | cut -c1-300 | while IFS= read -r l; do say REJECTED "$l"; done
        continue
    fi
    say ATTEMPT "method=$METHOD result=ran rc=$RC"
    clean <"$OUT"
    say END "rc=${RC:-unknown}"
    exit 0
done

say ERROR "run-each-node rejected every launch method tried:$TRIED"
diag() { while IFS= read -r l; do say DIAG "$l"; done; }
T=''; command -v timeout >/dev/null 2>&1 && T='timeout 60'
{
    echo "run-each-node path: $REN"
    ls -lL "$REN" 2>&1
    echo "first line: $(head -n1 "$REN" 2>/dev/null | cut -c1-200 | tr -cd '[:print:]')"
    echo "script available: $HAVE_SCRIPT"
    echo "--- require/load lines in run-each-node:"
    grep -n -E '^[[:space:]]*(require|require_relative|load)[[:space:](]' "$REN" 2>&1 | cut -c1-200 | head -n 40
    echo "--- lines in run-each-node mentioning sudo/su/login/parent/env/uid:"
    grep -n -I -E 'sudo|getlogin|logname|ppid|/proc/|ENV\[|uid|root shell|su -|"su"|-bash' "$REN" 2>&1 | cut -c1-200 | head -n 60
    echo "--- files containing the rejection message:"
    FILES=$($T grep -rIl --exclude-dir=proc "$REJECT" /usr/local /usr/lib/ruby /var/lib/gems /usr/share/ruby* /opt /etc 2>/dev/null | head -n 5)
    [ -n "$FILES" ] || echo "(none found)"
    for f in $FILES; do
        echo "file: $f"
        grep -n -I -B20 -A3 "$REJECT" "$f" 2>&1 | cut -c1-200 | head -n 80
    done
    echo "--- root login shell environment and process ancestry (via shell-stdin method):"
    printf '%s\n' 'echo "tty=$(tty 2>&1) shlvl=$SHLVL user=$USER logname=$LOGNAME home=$HOME term=$TERM"; p=$$; while [ -n "$p" ] && [ "$p" -gt 1 ]; do ps -o pid=,ppid=,user=,args= -p "$p" 2>/dev/null | cut -c1-120; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " "); done' | su - root 2>&1
    echo "--- rejection output (shell-stdin):"
    clean <"$TMPD/out.shell-stdin" | cut -c1-200 | head -n 20
} | diag
exit 6
'@

    $script = $controller.Replace('__NODE_SCRIPT_B64__', $nodeScriptB64).Replace('__VERSION__', $script:SgToolVersion)
    # StorageGRID nodes are Linux; keep LF endings so bash does not choke on CR.
    return ($script -replace "`r`n", "`n")
}

function Invoke-SgNetworkCollector {
    <#
    .SYNOPSIS
    SSHes to the Primary Admin Node with a password, authenticates sudo with the same
    password, and runs the collector through su - root. Returns the collector's stdout lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][System.Security.SecureString]$Password,
        [Parameter(Mandatory = $false)][int]$Port = 22,
        [Parameter(Mandatory = $false)][string]$SshExecutable = 'ssh',
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900
    )

    $sshCommand = Get-Command -Name $SshExecutable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $sshCommand) { throw "OpenSSH client '$SshExecutable' was not found. Install the Windows OpenSSH Client optional feature." }

    $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptText))
    # Single quotes only, so the remote command survives Windows argument quoting unchanged.
    # run-each-node is started by the collector through su - root (see New-SgNetworkCollectorScript).
    # sudo -S consumes the admin password; su from root needs no additional password.
    $remoteCommand = "sudo -S -p '' bash -c 'bash <(printf %s $encodedScript | base64 -d)'"

    $sshArgs = @(
        '-T',
        '-p', [string]$Port,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=30',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'PreferredAuthentications=keyboard-interactive,password',
        "$UserName@$ComputerName",
        $remoteCommand
    )

    $helperPath = New-SgAskPassHelper
    $passwordBytes = $null
    $bstr = [IntPtr]::Zero
    try {
        $environment = @{
            SSH_ASKPASS         = $helperPath
            SSH_ASKPASS_REQUIRE = 'force'
            DISPLAY             = 'sgnet:0'
            SGNET_ASKPASS_BLOB  = (ConvertFrom-SecureString -SecureString $Password)
        }

        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) + "`n")

        Write-Verbose "Running: $($sshCommand.Source) $(($sshArgs | Select-Object -First ($sshArgs.Count - 1)) -join ' ') <collector>"
        $result = Invoke-SgNativeProcess -FilePath $sshCommand.Source -ArgumentList $sshArgs -Environment $environment -StandardInputBytes $passwordBytes -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($null -ne $passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
        Remove-Item -LiteralPath (Split-Path -Parent $helperPath) -Recurse -Force -ErrorAction SilentlyContinue
    }

    $stdoutLines = @($result.StdOut -split "`r?`n")
    $stderrText = (@($result.StdErr -split "`r?`n") | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^Warning: Permanently added' }) -join [Environment]::NewLine

    if ($stderrText -match '(?i)incorrect password attempt|Sorry, try again') {
        throw "sudo rejected the password for '$UserName' on $ComputerName."
    }
    if ($stderrText -match '(?i)is not in the sudoers file|not allowed to execute') {
        throw "'$UserName' is not permitted to use sudo on $ComputerName. sudo output: $stderrText"
    }
    if ($result.ExitCode -eq 255) {
        throw "ssh to $UserName@$ComputerName failed (exit 255). Check the host, port and password. ssh output: $stderrText"
    }

    if (-not @($stdoutLines | Where-Object { $_ -like "$($script:SgMarker)|__controller__|BEGIN|*" })) {
        throw "The collector did not start on $ComputerName (ssh exit $($result.ExitCode)). Output: $stderrText"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Verbose "ssh/sudo stderr: $stderrText"
    }

    return ,[string[]]$stdoutLines
}

#endregion

#region Parsing --------------------------------------------------------------------------------

function ConvertFrom-SgNetworkCollectorOutput {
    <#
    .SYNOPSIS
    Groups tagged collector lines by node and section. Untagged lines (run-each-node banners,
    per-node ssh errors) are kept separately so failures stay visible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $nodes = [ordered]@{}
    $controller = New-Object System.Collections.Generic.List[object]
    $untagged = New-Object System.Collections.Generic.List[string]
    $pattern = [regex]('{0}\|(?<node>[^|]*)\|(?<section>[A-Z_]+)\|(?<text>.*)$' -f [regex]::Escape($script:SgMarker))

    foreach ($rawLine in $Lines) {
        $line = ([string]$rawLine).TrimEnd("`r")
        $match = $pattern.Match($line)
        if (-not $match.Success) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $untagged.Add($line) }
            continue
        }
        $nodeName = $match.Groups['node'].Value
        $section = $match.Groups['section'].Value
        $text = $match.Groups['text'].Value

        if ($nodeName -eq '__controller__') {
            $controller.Add([pscustomobject]@{ Section = $section; Text = $text })
            continue
        }
        if (-not $nodes.Contains($nodeName)) {
            $nodes[$nodeName] = [pscustomobject]@{
                Name     = $nodeName
                Complete = $false
                Sections = @{
                    IPLINK  = New-Object System.Collections.Generic.List[string]
                    ADDR    = New-Object System.Collections.Generic.List[string]
                    VLAN    = New-Object System.Collections.Generic.List[string]
                    BONDING = New-Object System.Collections.Generic.List[string]
                    SYSNET  = New-Object System.Collections.Generic.List[string]
                    ETHTOOL = New-Object System.Collections.Generic.List[string]
                }
            }
        }
        $node = $nodes[$nodeName]
        if ($section -eq 'DONE') { $node.Complete = $true }
        elseif ($node.Sections.ContainsKey($section)) { $node.Sections[$section].Add($text) }
    }

    return [pscustomobject]@{
        Nodes      = [object[]]@($nodes.Values)
        Controller = [object[]]$controller.ToArray()
        Untagged   = [string[]]$untagged.ToArray()
    }
}

function ConvertFrom-SgIpLink {
    <#
    .SYNOPSIS
    Parses 'ip -o link show' (or 'ip link show | grep bond') output into one object per interface.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $links = [ordered]@{}
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*\d+:\s+(?<name>[^:@\s]+)(?:@(?<parent>[^:\s]+))?:\s+<(?<flags>[^>]*)>(?<rest>.*)$')
        if (-not $m.Success) { continue }
        $rest = $m.Groups['rest'].Value
        $parent = $m.Groups['parent'].Value
        if ($parent -eq 'NONE' -or $parent -match '^if\d+$') { $parent = '' }

        $master = ''
        $mm = [regex]::Match($rest, '\bmaster\s+(?<v>\S+)')
        if ($mm.Success) { $master = $mm.Groups['v'].Value }
        $state = ''
        $sm = [regex]::Match($rest, '\bstate\s+(?<v>\S+)')
        if ($sm.Success) { $state = $sm.Groups['v'].Value }
        $mtu = ''
        $tm = [regex]::Match($rest, '\bmtu\s+(?<v>\d+)')
        if ($tm.Success) { $mtu = $tm.Groups['v'].Value }
        $mac = ''
        $am = [regex]::Match($rest, '\blink/\S+\s+(?<v>[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b')
        if ($am.Success) { $mac = $am.Groups['v'].Value.ToLowerInvariant() }

        $name = $m.Groups['name'].Value
        $links[$name] = [pscustomobject]@{
            Name   = $name
            Parent = $parent
            Master = $master
            State  = $state
            Mtu    = $mtu
            Mac    = $mac
            Flags  = $m.Groups['flags'].Value -split ','
        }
    }
    return $links
}

function ConvertFrom-SgIpAddr {
    <#
    .SYNOPSIS
    Parses 'ip -o addr show' into iface -> list of global addresses (IPv4 and global IPv6, CIDR form).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $result = @{}
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*\d+:\s+(?<name>[^\s@]+)(?:@\S+)?\s+(?<fam>inet6?)\s+(?<addr>\S+)(?<rest>.*)$')
        if (-not $m.Success) { continue }
        if ($m.Groups['fam'].Value -eq 'inet6' -and $m.Groups['rest'].Value -notmatch '\bscope global\b') { continue }
        $name = $m.Groups['name'].Value
        if (-not $result.ContainsKey($name)) { $result[$name] = New-Object System.Collections.Generic.List[string] }
        $result[$name].Add($m.Groups['addr'].Value)
    }
    return $result
}

function ConvertFrom-SgVlanConfig {
    <#
    .SYNOPSIS
    Parses /proc/net/vlan/config ("eth0 | 100 | bond0") into a VLAN device -> {VlanId, Parent} map.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $vlans = @{}
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\s*(?<dev>\S+)\s*\|\s*(?<vid>\d+)\s*\|\s*(?<parent>\S+)\s*$')
        if (-not $m.Success) { continue }
        $vlans[$m.Groups['dev'].Value] = [pscustomobject]@{
            Device = $m.Groups['dev'].Value
            VlanId = [int]$m.Groups['vid'].Value
            Parent = $m.Groups['parent'].Value
        }
    }
    return $vlans
}

function ConvertFrom-SgEthtool {
    <#
    .SYNOPSIS
    Parses '=== iface ===' delimited ethtool output into iface -> {SpeedMbps, Duplex, LinkDetected, Port}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $result = @{}
    $current = $null
    foreach ($line in $Lines) {
        $header = [regex]::Match($line, '^=== (?<iface>\S+) ===$')
        if ($header.Success) {
            $current = [pscustomobject]@{ Interface = $header.Groups['iface'].Value; SpeedMbps = $null; Duplex = ''; LinkDetected = ''; Port = '' }
            $result[$current.Interface] = $current
            continue
        }
        if ($null -eq $current) { continue }
        $kv = [regex]::Match($line, '^\s*(?<k>Speed|Duplex|Link detected|Port):\s*(?<v>.*?)\s*$')
        if (-not $kv.Success) { continue }
        $value = $kv.Groups['v'].Value
        switch ($kv.Groups['k'].Value) {
            'Speed' {
                $sp = [regex]::Match($value, '^(?<n>\d+)\s*Mb/s')
                if ($sp.Success) { $current.SpeedMbps = [long]$sp.Groups['n'].Value }
            }
            'Duplex' { $current.Duplex = $value }
            'Link detected' { $current.LinkDetected = $value }
            'Port' { $current.Port = $value }
        }
    }
    return $result
}

function ConvertFrom-SgBondingProc {
    <#
    .SYNOPSIS
    Parses /proc/net/bonding/<bond> output into bond objects with bond-level and per-member
    details (mode, MII status, LACP aggregator/partner info, active slave, member speed/duplex/link failures).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $bonds = @{}
    $bond = $null
    $member = $null
    $section = ''
    foreach ($line in $Lines) {
        $header = [regex]::Match($line, '^=== (?<bond>\S+) ===$')
        if ($header.Success) {
            $bond = [pscustomobject]@{
                Name = $header.Groups['bond'].Value; Mode = ''; MiiStatus = ''; HashPolicy = ''; LacpRate = ''
                ActiveSlave = ''; ActiveAggregatorId = ''; PartnerMac = ''; Members = [ordered]@{}
            }
            $bonds[$bond.Name] = $bond
            $member = $null
            $section = ''
            continue
        }
        if ($null -eq $bond) { continue }
        if ($line -match '^\s*Active Aggregator Info:') { $section = 'activeagg'; continue }
        if ($line -match '^\s*details (actor|partner) lacp pdu:') { $section = 'pdu'; continue }
        $kv = [regex]::Match($line, '^\s*(?<k>[^:]+?):\s*(?<v>.*?)\s*$')
        if (-not $kv.Success) { continue }
        $key = $kv.Groups['k'].Value
        $value = $kv.Groups['v'].Value
        if ($key -eq 'Slave Interface') {
            $member = [pscustomobject]@{ Name = $value; MiiStatus = ''; SpeedMbps = $null; Duplex = ''; LinkFailures = ''; PermanentMac = ''; AggregatorId = '' }
            $bond.Members[$value] = $member
            $section = 'member'
            continue
        }
        if ($null -eq $member) {
            switch ($key) {
                'Bonding Mode'            { $bond.Mode = $value }
                'MII Status'              { $bond.MiiStatus = $value }
                'Transmit Hash Policy'    { $bond.HashPolicy = $value }
                'LACP rate'               { $bond.LacpRate = $value }
                'LACP active'             { }
                'Currently Active Slave'  { $bond.ActiveSlave = $value }
                'Aggregator ID'           { if ($section -eq 'activeagg') { $bond.ActiveAggregatorId = $value } }
                'Partner Mac Address'     { if ($section -eq 'activeagg') { $bond.PartnerMac = $value.ToLowerInvariant() } }
            }
            continue
        }
        if ($section -eq 'pdu') { continue }
        switch ($key) {
            'MII Status'         { $member.MiiStatus = $value }
            'Duplex'             { $member.Duplex = $value }
            'Link Failure Count' { $member.LinkFailures = $value }
            'Permanent HW addr'  { $member.PermanentMac = $value.ToLowerInvariant() }
            'Aggregator ID'      { $member.AggregatorId = $value }
            'Speed' {
                $sp = [regex]::Match($value, '^(?<n>\d+)')
                if ($sp.Success) { $member.SpeedMbps = [long]$sp.Groups['n'].Value }
            }
        }
    }
    return $bonds
}

function ConvertFrom-SgSysNet {
    <#
    .SYNOPSIS
    Parses the "iface operstate=.. speed=.. master=.. [phys=0|1]" lines collected from /sys/class/net.
    Phys is $null when the collector predates the phys field (v0.4.0 and older raw files).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $result = @{}
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^(?<i>\S+) operstate=(?<o>\S*) speed=(?<s>-?\d*) master=(?<m>\S*)(?: phys=(?<p>[01]))?\s*$')
        if (-not $m.Success) { continue }
        $speed = $null
        if ($m.Groups['s'].Value -match '^\d+$' -and [long]$m.Groups['s'].Value -gt 0) { $speed = [long]$m.Groups['s'].Value }
        $phys = $null
        if ($m.Groups['p'].Success) { $phys = ($m.Groups['p'].Value -eq '1') }
        $result[$m.Groups['i'].Value] = [pscustomobject]@{ OperState = $m.Groups['o'].Value; SpeedMbps = $speed; Master = $m.Groups['m'].Value; Physical = $phys }
    }
    return $result
}
#endregion

#region Mapping --------------------------------------------------------------------------------

function Format-SgSpeed {
    param([Parameter(Mandatory = $false)][AllowNull()]$Mbps)

    if ($null -eq $Mbps) { return 'Unknown' }
    $value = [double]$Mbps
    if ($value -ge 1000) { return ('{0:0.##} Gb/s' -f ($value / 1000)) }
    return ('{0} Mb/s' -f $value)
}

function Get-SgNaturalSortKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)
    return [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(6, '0') })
}

function Get-SgBondInterfaceNames {
    <#
    .SYNOPSIS
    Discovers bond interface names, including non-standard names (for example eth1 on
    physical appliances), from all parsed sources.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Links,
        [Parameter(Mandatory = $true)][hashtable]$BondProc,
        [Parameter(Mandatory = $true)][hashtable]$SysNet
    )

    $bondLookup = @{}
    foreach ($name in @($BondProc.Keys)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) { $bondLookup[$name] = $true }
    }
    foreach ($link in @($Links.Values)) {
        if ($null -ne $link -and -not [string]::IsNullOrWhiteSpace($link.Master)) { $bondLookup[$link.Master] = $true }
    }
    foreach ($name in @($SysNet.Keys)) {
        $master = $SysNet[$name].Master
        if (-not [string]::IsNullOrWhiteSpace($master)) { $bondLookup[$master] = $true }
    }

    return @($bondLookup.Keys | Sort-Object -Unique | Sort-Object { Get-SgNaturalSortKey -Name $_ })
}

function Resolve-SgNetworkPath {
    <#
    .SYNOPSIS
    Walks from a network interface (eth0/eth1/eth2) through VLAN and stacked (macvlan) devices down
    to its bond or physical port, returning the bond, the last device on the path and the VLAN ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Interface,
        [Parameter(Mandatory = $true)]$Links,
        [Parameter(Mandatory = $true)][hashtable]$Vlans,
        [Parameter(Mandatory = $false)][string[]]$BondNames = @()
    )

    if (-not $Links.Contains($Interface)) {
        return [pscustomobject]@{ Present = $false; Interface = $Interface; Bond = ''; Terminal = ''; Vlan = ''; Path = '' }
    }

    $vlanId = $null
    $path = New-Object System.Collections.Generic.List[string]
    $current = $Interface
    $bond = ''
    $bondLookup = @{}
    foreach ($bondName in @($BondNames)) {
        if (-not [string]::IsNullOrWhiteSpace($bondName)) { $bondLookup[$bondName] = $true }
    }
    for ($hop = 0; $hop -lt 6 -and -not [string]::IsNullOrWhiteSpace($current); $hop++) {
        if ($path.Contains($current)) { break }
        $path.Add($current)
        if ($current -match '^bond\d+$' -or $bondLookup.ContainsKey($current)) { $bond = $current; break }

        $next = ''
        if ($Vlans.ContainsKey($current)) {
            if ($null -eq $vlanId) { $vlanId = $Vlans[$current].VlanId }
            $next = $Vlans[$current].Parent
        }
        if ([string]::IsNullOrWhiteSpace($next) -and $Links.Contains($current)) {
            $next = $Links[$current].Parent
            if ([string]::IsNullOrWhiteSpace($next)) { $next = $Links[$current].Master }
        }
        $current = $next
    }

    $vlanText = 'Untagged'
    if ($null -ne $vlanId) { $vlanText = [string]$vlanId }

    return [pscustomobject]@{
        Present   = $true
        Interface = $Interface
        Bond      = $bond
        Terminal  = $path[$path.Count - 1]
        Vlan      = $vlanText
        Path      = ($path -join ' -> ')
    }
}

function Get-SgPortDetail {
    <#
    .SYNOPSIS
    Combines ethtool, ip link, /proc/net/bonding and /sys/class/net data for one port.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Links,
        [Parameter(Mandatory = $true)][hashtable]$Ethtool,
        [Parameter(Mandatory = $true)][hashtable]$SysNet,
        [Parameter(Mandatory = $false)][AllowNull()]$BondMember
    )

    $speed = $null; $linkDetected = ''; $duplex = ''; $state = ''; $mtu = ''; $mac = ''; $mii = ''
    $aggregatorId = ''; $linkFailures = ''
    if ($Ethtool.ContainsKey($Name)) {
        $speed = $Ethtool[$Name].SpeedMbps
        $linkDetected = $Ethtool[$Name].LinkDetected
        $duplex = $Ethtool[$Name].Duplex
    }
    if ($Links.Contains($Name)) {
        $state = $Links[$Name].State
        $mtu = $Links[$Name].Mtu
        $mac = $Links[$Name].Mac
    }
    if ($null -ne $BondMember) {
        $mii = $BondMember.MiiStatus
        $aggregatorId = $BondMember.AggregatorId
        $linkFailures = $BondMember.LinkFailures
        if ($null -eq $speed) { $speed = $BondMember.SpeedMbps }
        if ([string]::IsNullOrWhiteSpace($duplex)) { $duplex = $BondMember.Duplex }
        # Bond members inherit the bond's MAC; the permanent address identifies the physical port.
        if (-not [string]::IsNullOrWhiteSpace($BondMember.PermanentMac)) { $mac = $BondMember.PermanentMac }
    }
    if ($SysNet.ContainsKey($Name)) {
        if ($null -eq $speed) { $speed = $SysNet[$Name].SpeedMbps }
        if ([string]::IsNullOrWhiteSpace($state)) { $state = $SysNet[$Name].OperState.ToUpperInvariant() }
    }
    if ($duplex -match '^Unknown') { $duplex = '' }
    $isUp = ($linkDetected -eq 'yes') -or ([string]::IsNullOrWhiteSpace($linkDetected) -and ($state -eq 'UP' -or $mii -eq 'up'))

    return [pscustomobject]@{
        Name         = $Name
        SpeedMbps    = $speed
        Speed        = Format-SgSpeed -Mbps $speed
        Duplex       = $duplex
        LinkDetected = $linkDetected
        State        = $state
        MiiStatus    = $mii
        Mtu          = $mtu
        Mac          = $mac
        AggregatorId = $aggregatorId
        LinkFailures = $linkFailures
        IsUp         = $isUp
    }
}

function Get-SgNodeNetworkMap {
    <#
    .SYNOPSIS
    Builds the per-node network, bond and port detail (plus detected issues) from parsed sections.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Node)

    $links = ConvertFrom-SgIpLink -Lines $Node.Sections['IPLINK'].ToArray()
    $addrs = ConvertFrom-SgIpAddr -Lines $Node.Sections['ADDR'].ToArray()
    $vlans = ConvertFrom-SgVlanConfig -Lines $Node.Sections['VLAN'].ToArray()
    $ethtool = ConvertFrom-SgEthtool -Lines $Node.Sections['ETHTOOL'].ToArray()
    $bondProc = ConvertFrom-SgBondingProc -Lines $Node.Sections['BONDING'].ToArray()
    $sysNet = ConvertFrom-SgSysNet -Lines $Node.Sections['SYSNET'].ToArray()
    $issues = New-Object System.Collections.Generic.List[string]

    $bondNames = @(Get-SgBondInterfaceNames -Links $links -BondProc $bondProc -SysNet $sysNet)
    $sgBondNames = @($bondNames | Where-Object { $_ -match '^bond\d+$' })

    # User rule: bond0 only = all ports aggregated (Aggregate/LACP); bond0 + bond1 = Fixed.
    if ($sgBondNames.Count -eq 0) { $portBondMode = 'N/A (no bond interfaces)' }
    elseif ($sgBondNames -contains 'bond1') { $portBondMode = 'Fixed' }
    else { $portBondMode = 'Aggregate/LACP' }

    # Networks first, so bonds and ports can be labelled with the networks they carry.
    $networks = [ordered]@{}
    foreach ($networkName in $script:SgNetworkInterfaces.Keys) {
        $networks[$networkName] = Resolve-SgNetworkPath -Interface $script:SgNetworkInterfaces[$networkName] -Links $links -Vlans $vlans -BondNames $bondNames
    }
    $bondNetworks = @{}
    foreach ($networkName in $networks.Keys) {
        $n = $networks[$networkName]
        if ($n.Present -and $n.Bond) {
            if (-not $bondNetworks.ContainsKey($n.Bond)) { $bondNetworks[$n.Bond] = New-Object System.Collections.Generic.List[string] }
            $bondNetworks[$n.Bond].Add($networkName)
        }
    }

    # Bonds
    $bonds = New-Object System.Collections.Generic.List[object]
    $bondByName = @{}
    $portBond = @{}
    foreach ($bondName in $bondNames) {
        $proc = $null
        if ($bondProc.ContainsKey($bondName)) { $proc = $bondProc[$bondName] }
        $memberNames = @(
            @($links.Values | Where-Object { $_.Master -eq $bondName } | ForEach-Object { $_.Name }) +
            @($(if ($null -ne $proc) { $proc.Members.Keys })) +
            @($sysNet.Keys | Where-Object { $sysNet[$_].Master -eq $bondName })
        ) | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { Get-SgNaturalSortKey -Name $_ }

        $mode = ''; $activeAgg = ''; $partnerMac = ''; $activeSlave = ''; $hashPolicy = ''; $lacpRate = ''
        if ($null -ne $proc) {
            $mode = $proc.Mode; $activeAgg = $proc.ActiveAggregatorId; $partnerMac = $proc.PartnerMac
            $activeSlave = $proc.ActiveSlave; $hashPolicy = $proc.HashPolicy; $lacpRate = $proc.LacpRate
        }
        $isLacp = $mode -match '802\.3ad'
        $isActiveBackup = $mode -match 'active-backup'

        $members = New-Object System.Collections.Generic.List[object]
        foreach ($memberName in $memberNames) {
            $pm = $null
            if ($null -ne $proc -and $proc.Members.Contains($memberName)) { $pm = $proc.Members[$memberName] }
            $detail = Get-SgPortDetail -Name $memberName -Links $links -Ethtool $ethtool -SysNet $sysNet -BondMember $pm
            $inActiveAgg = $null
            if ($isLacp -and $activeAgg -and $detail.AggregatorId) { $inActiveAgg = ($detail.AggregatorId -eq $activeAgg) }
            $carrying = $detail.IsUp -and ($inActiveAgg -ne $false)
            if ($isActiveBackup -and $activeSlave) { $carrying = $detail.IsUp -and ($memberName -eq $activeSlave) }
            $detail | Add-Member -NotePropertyName InActiveAggregator -NotePropertyValue $inActiveAgg
            $detail | Add-Member -NotePropertyName CarriesTraffic -NotePropertyValue $carrying
            $members.Add($detail)
            $portBond[$memberName] = $bondName
        }

        $effective = ($members | Where-Object { $_.CarriesTraffic -and $null -ne $_.SpeedMbps } | Measure-Object -Property SpeedMbps -Sum).Sum
        if ($null -eq $effective) { $effective = 0 }
        $kernelSpeed = $null
        if ($ethtool.ContainsKey($bondName)) { $kernelSpeed = $ethtool[$bondName].SpeedMbps }
        $state = ''; $mtu = ''
        if ($links.Contains($bondName)) { $state = $links[$bondName].State; $mtu = $links[$bondName].Mtu }
        $upCount = @($members | Where-Object { $_.IsUp }).Count

        $lacpPartner = ''
        if ($isLacp -and $partnerMac) {
            if ($partnerMac -match '^(00:){5}00$') { $lacpPartner = 'None' } else { $lacpPartner = $partnerMac }
        }

        # Issue checks
        if ($members.Count -gt 0 -and $upCount -eq 0) { $issues.Add("$bondName has no member ports up") }
        foreach ($m in $members) {
            if (-not $m.IsUp) { $issues.Add("$bondName member $($m.Name) is down") }
            elseif ($m.InActiveAggregator -eq $false) {
                $issues.Add("$bondName member $($m.Name) is up but not in the active LACP aggregator (aggregator $($m.AggregatorId), active $activeAgg) - check the switch port-channel")
            }
            if ($m.IsUp -and $m.Duplex -match 'half') { $issues.Add("$bondName member $($m.Name) is running half duplex") }
        }
        if ($lacpPartner -eq 'None' -and $upCount -gt 0) { $issues.Add("$bondName has no LACP partner (partner MAC is all zeros) - switch is not negotiating LACP") }
        $upSpeeds = @($members | Where-Object { $_.IsUp -and $null -ne $_.SpeedMbps } | ForEach-Object { $_.SpeedMbps } | Sort-Object -Unique)
        if ($upSpeeds.Count -gt 1) {
            $issues.Add("$bondName members are running at different speeds: $(@($members | Where-Object { $_.IsUp } | ForEach-Object { '{0}={1}' -f $_.Name, $_.Speed }) -join ', ')")
        }

        $carried = @()
        if ($bondNetworks.ContainsKey($bondName)) { $carried = @($bondNetworks[$bondName]) }
        $bond = [pscustomobject]@{
            Node               = $Node.Name
            Bond               = $bondName
            State              = $state
            Mode               = $mode
            Networks           = ($carried -join ', ')
            EffectiveSpeed     = Format-SgSpeed -Mbps $effective
            EffectiveSpeedMbps = $effective
            KernelSpeed        = $(if ($null -eq $kernelSpeed) { '' } else { Format-SgSpeed -Mbps $kernelSpeed })
            MembersUp          = ('{0}/{1}' -f $upCount, $members.Count)
            Members            = (@($members | ForEach-Object { '{0} ({1}, {2})' -f $_.Name, $_.Speed, $(if ($_.IsUp) { 'Up' } else { 'Down' }) }) -join ', ')
            ActiveSlave        = $activeSlave
            LacpPartnerMac     = $lacpPartner
            ActiveAggregatorId = $activeAgg
            HashPolicy         = $hashPolicy
            LacpRate           = $lacpRate
            Mtu                = $mtu
            MemberDetail       = [object[]]$members.ToArray()
        }
        $bonds.Add($bond)
        $bondByName[$bondName] = $bond
    }

    # Networks: ports, speed, MTU, addresses, state
    $portNetworks = @{}
    $networkRows = New-Object System.Collections.Generic.List[object]
    foreach ($networkName in $networks.Keys) {
        $n = $networks[$networkName]
        $iface = $n.Interface
        if (-not $n.Present) {
            $networkRows.Add([pscustomobject]@{
                    Network = $networkName; Interface = $iface; ParentBond = ''; Vlan = ''; Ports = ''
                    Speed = ''; SpeedMbps = $null; Mtu = ''; Address = ''; State = ''; Path = ''; Present = $false
                })
            continue
        }
        $portList = @()
        $speed = $null
        if ($n.Bond) {
            $parent = $n.Bond
            if ($bondByName.ContainsKey($n.Bond)) {
                $portList = @($bondByName[$n.Bond].MemberDetail | ForEach-Object { $_.Name })
                $speed = $bondByName[$n.Bond].EffectiveSpeedMbps
            }
        }
        else {
            $parent = 'None'
            $portList = @($n.Terminal)
            $detail = Get-SgPortDetail -Name $n.Terminal -Links $links -Ethtool $ethtool -SysNet $sysNet
            $speed = $detail.SpeedMbps
            if ($null -eq $speed -and $ethtool.ContainsKey($iface)) { $speed = $ethtool[$iface].SpeedMbps }
            if (-not $detail.IsUp) { $issues.Add("$networkName Network port $($n.Terminal) is down") }
        }
        foreach ($p in $portList) {
            if (-not $portNetworks.ContainsKey($p)) { $portNetworks[$p] = New-Object System.Collections.Generic.List[string] }
            $portNetworks[$p].Add($networkName)
        }
        $state = $links[$iface].State
        if ($state -and $state -notin @('UP', 'UNKNOWN')) { $issues.Add("$networkName Network interface $iface is $state") }
        $address = ''
        if ($addrs.ContainsKey($iface)) { $address = (@($addrs[$iface]) -join ' ') }

        $networkRows.Add([pscustomobject]@{
                Network    = $networkName
                Interface  = $iface
                ParentBond = $parent
                Vlan       = $n.Vlan
                Ports      = ($portList -join ' ')
                Speed      = Format-SgSpeed -Mbps $speed
                SpeedMbps  = $speed
                Mtu        = $links[$iface].Mtu
                Address    = $address
                State      = $state
                Path       = $n.Path
                Present    = $true
            })
    }

    # Ports: every physical port, bond member and network end device (bonds, VLANs, macvlans excluded).
    $portNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($sysNet.Keys)) {
        if ($sysNet[$name].Physical -eq $true) { $portNames.Add($name) }
        elseif ($null -eq $sysNet[$name].Physical -and $links.Contains($name) -and -not $links[$name].Parent -and -not $vlans.ContainsKey($name) -and $name -match '^(hic|mtc|en|eth)') {
            $portNames.Add($name)
        }
    }
    foreach ($name in @($portBond.Keys) + @($portNetworks.Keys)) { $portNames.Add($name) }
    $bondNameLookup = @{}
    foreach ($bondName in @($bondNames)) { $bondNameLookup[$bondName] = $true }
    $portNames = @($portNames | Where-Object { $_ -and $_ -ne 'lo' -and -not $bondNameLookup.ContainsKey($_) } | Sort-Object -Unique | Sort-Object { Get-SgNaturalSortKey -Name $_ })

    $ports = New-Object System.Collections.Generic.List[object]
    foreach ($name in $portNames) {
        $bondName = ''
        $detail = $null
        if ($portBond.ContainsKey($name)) {
            $bondName = $portBond[$name]
            $detail = @($bondByName[$bondName].MemberDetail | Where-Object { $_.Name -eq $name })[0]
        }
        else {
            $detail = Get-SgPortDetail -Name $name -Links $links -Ethtool $ethtool -SysNet $sysNet
            $detail | Add-Member -NotePropertyName InActiveAggregator -NotePropertyValue $null
            $detail | Add-Member -NotePropertyName CarriesTraffic -NotePropertyValue $detail.IsUp
        }
        $carried = @()
        if ($bondName -and $bondNetworks.ContainsKey($bondName)) { $carried = @($bondNetworks[$bondName]) }
        elseif ($portNetworks.ContainsKey($name)) { $carried = @($portNetworks[$name]) }

        if ($bondName) {
            $bond = $bondByName[$bondName]
            if (-not $detail.IsUp) { $status = 'Down' }
            elseif ($detail.InActiveAggregator -eq $false) { $status = 'Up - not in active LACP aggregator' }
            elseif ($bond.Mode -match 'active-backup' -and $bond.ActiveSlave -and $bond.ActiveSlave -ne $name) { $status = 'Up - standby' }
            else { $status = 'Up - active' }
        }
        elseif ($carried.Count -gt 0) {
            if ($detail.IsUp) { $status = 'Up - active' } else { $status = 'Down' }
        }
        else {
            if ($detail.IsUp) { $status = 'Unused (link up)' } else { $status = 'Unused' }
        }

        $ports.Add([pscustomobject]@{
                Node         = $Node.Name
                Port         = $name
                Status       = $status
                Bond         = $bondName
                Networks     = ($carried -join ', ')
                Speed        = $(if ($detail.IsUp) { $detail.Speed } else { '' })
                SpeedMbps    = $(if ($detail.IsUp) { $detail.SpeedMbps } else { $null })
                Duplex       = $(if ($detail.IsUp) { $detail.Duplex } else { '' })
                LinkDetected = $detail.LinkDetected
                State        = $detail.State
                Mtu          = $detail.Mtu
                Mac          = $detail.Mac
                AggregatorId = $detail.AggregatorId
                LinkFailures = $detail.LinkFailures
            })
    }

    $summary = [ordered]@{
        Node         = $Node.Name
        DataComplete = $Node.Complete
        PortBondMode = $portBondMode
        Bonds        = ($bondNames -join ', ')
    }
    foreach ($row in $networkRows) {
        $parentBondMode = ''
        $parentBondActiveSlave = ''
        if ($row.ParentBond -and $row.ParentBond -ne 'None' -and $bondByName.ContainsKey($row.ParentBond)) {
            $parentBondMode = $bondByName[$row.ParentBond].Mode
            $parentBondActiveSlave = $bondByName[$row.ParentBond].ActiveSlave
        }
        $summary["$($row.Network)Interface"] = $row.Interface
        $summary["$($row.Network)ParentBond"] = $row.ParentBond
        $summary["$($row.Network)ParentBondMode"] = $parentBondMode
        $summary["$($row.Network)ParentBondActiveSlave"] = $parentBondActiveSlave
        $summary["$($row.Network)Vlan"] = $row.Vlan
        $summary["$($row.Network)Ports"] = $row.Ports
        $summary["$($row.Network)Speed"] = $(if ($row.Present) { $row.Speed } else { '' })
        $summary["$($row.Network)Mtu"] = $row.Mtu
        $summary["$($row.Network)Address"] = $row.Address
        $summary["$($row.Network)State"] = $row.State
    }
    $summary['BondSummary'] = (@($bonds | ForEach-Object { '{0} [{1}, {2} up]' -f $_.Bond, $_.EffectiveSpeed, $_.MembersUp }) -join '; ')
    $summary['IssueCount'] = $issues.Count
    $summary['Issues'] = ($issues -join '; ')

    return [pscustomobject]@{
        Summary  = [pscustomobject]$summary
        Networks = [object[]]$networkRows.ToArray()
        Bonds    = [object[]]$bonds.ToArray()
        Ports    = [object[]]$ports.ToArray()
        Issues   = [string[]]$issues.ToArray()
    }
}

function Get-SgGridIssues {
    <#
    .SYNOPSIS
    Grid-wide consistency checks (for example, the Grid Network MTU must match on every node).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$NodeMaps)

    $issues = New-Object System.Collections.Generic.List[string]
    $gridMtus = @($NodeMaps | ForEach-Object {
            $nodeName = $_.Summary.Node
            $_.Networks | Where-Object { $_.Network -eq 'Grid' -and $_.Present -and $_.Mtu } | ForEach-Object { [pscustomobject]@{ Node = $nodeName; Mtu = $_.Mtu } }
        })
    $groups = @($gridMtus | Group-Object -Property Mtu)
    if ($groups.Count -gt 1) {
        $detail = @($groups | Sort-Object Count -Descending | ForEach-Object { 'MTU {0} on {1} node(s): {2}' -f $_.Name, $_.Count, (@($_.Group | ForEach-Object { $_.Node }) -join ', ') }) -join ' | '
        $issues.Add("Grid Network MTU is not the same on every node - $detail")
    }
    $incomplete = @($NodeMaps | Where-Object { -not $_.Summary.DataComplete } | ForEach-Object { $_.Summary.Node })
    if ($incomplete.Count -gt 0) { $issues.Add("Collection did not complete on: $($incomplete -join ', ')") }
    return [string[]]$issues.ToArray()
}

function ConvertTo-SgReportRow {
    <#
    .SYNOPSIS
    Copies the selected properties of each row, replacing null or empty values with 'N/A'.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $false)][string[]]$Property
    )

    foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        $names = $Property
        if (-not $names) { $names = @($row.PSObject.Properties | ForEach-Object { $_.Name }) }
        $out = [ordered]@{}
        foreach ($name in $names) {
            $value = $row.$name
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { $value = 'N/A' }
            $out[$name] = $value
        }
        [pscustomobject]$out
    }
}

function Format-SgNetworkCell {
    <#
    .SYNOPSIS
    Compact one-cell description of a network for console / overview tables, e.g. "bond0, VLAN 134, 100 Gb/s".
    #>
    param([Parameter(Mandatory = $true)]$NetworkRow)

    if (-not $NetworkRow.Present) { return 'N/A' }
    $via = $NetworkRow.ParentBond
    if ($via -eq 'None') { $via = $NetworkRow.Ports }
    $vlan = $NetworkRow.Vlan
    if ($vlan -ne 'Untagged') { $vlan = "VLAN $vlan" }
    return ('{0}, {1}, {2}' -f $via, $vlan, $NetworkRow.Speed)
}

function Format-SgIndentedTable {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][object[]]$Property,
        [Parameter(Mandatory = $false)][string]$Indent = '    '
    )

    if (@($Rows).Count -eq 0) { return "$Indent(none)" }
    $names = @($Property | ForEach-Object { [string]$_ })
    $text = (@(ConvertTo-SgReportRow -Rows $Rows -Property $names) | Format-Table -Property $names -AutoSize | Out-String -Width 400)
    $out = @($text -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $Indent + $_.TrimEnd() })
    return ($out -join [Environment]::NewLine)
}

function Get-SgOverviewRows {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$NodeMaps)

    foreach ($map in $NodeMaps) {
        $row = [ordered]@{ Node = $map.Summary.Node; PortBondMode = $map.Summary.PortBondMode }
        foreach ($n in $map.Networks) { $row[$n.Network] = Format-SgNetworkCell -NetworkRow $n }
        $row['Issues'] = $map.Summary.IssueCount
        [pscustomobject]$row
    }
}

function Format-SgNetworkTextReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$NodeMaps,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$GridIssues = @(),
        [Parameter(Mandatory = $false)][string]$Target,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Untagged = @()
    )

    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("StorageGRID Network Port Report (Invoke-SgNetworkPortReport version $($script:SgToolVersion))")
    [void]$sb.AppendLine(('Generated: {0} (UTC{1})' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (Get-Date).ToString('zzz')))
    if ($Target) { [void]$sb.AppendLine("Primary Admin Node: $Target") }
    [void]$sb.AppendLine("Nodes: $(@($NodeMaps).Count)")
    [void]$sb.AppendLine('Networks: ' + (@($script:SgNetworkInterfaces.Keys | ForEach-Object { '{0} = {1}' -f $_, $script:SgNetworkInterfaces[$_] }) -join ', '))
    [void]$sb.AppendLine('Speeds: network/bond speed = sum of member ports carrying traffic (802.3ad: up members in the')
    [void]$sb.AppendLine('        active aggregator; active-backup: the active port). Port speed is the negotiated link speed.')
    [void]$sb.AppendLine(('=' * 100))

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('OVERVIEW')
    $overview = @(Get-SgOverviewRows -NodeMaps $NodeMaps)
    $columns = @('Node', 'PortBondMode') + @($script:SgNetworkInterfaces.Keys) + @('Issues')
    [void]$sb.AppendLine((Format-SgIndentedTable -Rows $overview -Property $columns -Indent '  '))

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('ISSUES')
    $allIssues = @($GridIssues | ForEach-Object { "[grid] $_" }) + @($NodeMaps | ForEach-Object { $node = $_.Summary.Node; $_.Issues | ForEach-Object { "[$node] $_" } })
    if ($allIssues.Count -eq 0) { [void]$sb.AppendLine('  No issues detected.') }
    else { foreach ($i in $allIssues) { [void]$sb.AppendLine("  - $i") } }

    foreach ($map in $NodeMaps) {
        $s = $map.Summary
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('=' * 100))
        [void]$sb.AppendLine("Node: $($s.Node)    Port Bond Mode: $($s.PortBondMode)")
        if (-not $s.DataComplete) { [void]$sb.AppendLine('  WARNING: collection did not complete on this node; data may be partial.') }

        [void]$sb.AppendLine('  Networks:')
        [void]$sb.AppendLine((Format-SgIndentedTable -Rows $map.Networks -Property Network, Interface, ParentBond, Vlan, Ports, Speed, Mtu, State, Address, Path))

        [void]$sb.AppendLine('  Bonds:')
        [void]$sb.AppendLine((Format-SgIndentedTable -Rows $map.Bonds -Property Bond, State, Mode, Networks, EffectiveSpeed, KernelSpeed, MembersUp, ActiveSlave, LacpPartnerMac, HashPolicy, Mtu))

        [void]$sb.AppendLine('  Ports:')
        [void]$sb.AppendLine((Format-SgIndentedTable -Rows $map.Ports -Property Port, Status, Bond, Networks, Speed, Duplex, LinkDetected, Mtu, Mac, AggregatorId, LinkFailures))

        if (@($map.Issues).Count -gt 0) {
            [void]$sb.AppendLine('  Issues:')
            foreach ($i in $map.Issues) { [void]$sb.AppendLine("    - $i") }
        }
    }

    if (@($Untagged).Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('=' * 100))
        [void]$sb.AppendLine('Other run-each-node output (check for nodes that could not be reached):')
        foreach ($line in $Untagged) { [void]$sb.AppendLine("  $line") }
    }
    return $sb.ToString().TrimEnd() + $nl
}

#endregion

#region Main -----------------------------------------------------------------------------------

# Local time of the machine running the script; the UTC offset is recorded in the text report.
$timestamp = (Get-Date).ToString('yyyyMMddTHHmmss')
Write-Host "Invoke-SgNetworkPortReport version $($script:SgToolVersion)" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$outputDirResolved = (Resolve-Path -LiteralPath $OutputDir).ProviderPath

if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $rawOutputPath = ''
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "Input file not found: $InputPath" }
    Write-Host "Parsing saved collector output from $InputPath ..."
    $collectorLines = [string[]]@(Get-Content -LiteralPath $InputPath)
    $sshHost = ''
}
else {
    if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        throw 'Live collection uses Windows DPAPI and the Windows OpenSSH client; run it on Windows, or use -InputPath.'
    }
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = Read-Host 'Enter the URL, FQDN or IP address of the StorageGRID Primary Admin Node'
    }
    $sshHost = ConvertTo-SgSshHost -Target $Target
    if ($null -eq $Password) {
        $Password = Read-Host -AsSecureString "Password for $UserName@$sshHost (also used for sudo)"
    }
    if ($Password.Length -eq 0) { throw 'A password is required.' }

    $scriptText = New-SgNetworkCollectorScript
    Write-Host "Connecting to $UserName@${sshHost}:$SshPort and running run-each-node --parallel (this can take a minute) ..."
    $collectorLines = Invoke-SgNetworkCollector -ScriptText $scriptText -ComputerName $sshHost -UserName $UserName -Password $Password -Port $SshPort -SshExecutable $SshExecutable -TimeoutSeconds $TimeoutSeconds

    $rawOutputPath = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-raw.txt"
    Set-Content -LiteralPath $rawOutputPath -Value $collectorLines -Encoding UTF8
    Write-Host "Raw collector output saved to: $rawOutputPath"
}

$parsed = ConvertFrom-SgNetworkCollectorOutput -Lines $collectorLines
$controllerError = @($parsed.Controller | Where-Object { $_.Section -eq 'ERROR' }) | Select-Object -First 1
# Launch attempts are troubleshooting detail: shown with -Verbose, or always when every method failed.
foreach ($attempt in @($parsed.Controller | Where-Object { $_.Section -eq 'ATTEMPT' })) {
    if ($null -ne $controllerError) { Write-Host "run-each-node launch: $($attempt.Text)" }
    else { Write-Verbose "run-each-node launch: $($attempt.Text)" }
}
if ($null -ne $controllerError) {
    $diagnostics = @($parsed.Controller | Where-Object { $_.Section -eq 'DIAG' } | ForEach-Object { $_.Text })
    if ($diagnostics.Count -gt 0) {
        Write-Host ''
        Write-Host 'Diagnostics from the Admin Node (please share these with the script author):' -ForegroundColor Yellow
        $diagnostics | ForEach-Object { Write-Host "  $_" }
        Write-Host ''
    }
    throw "Collector failed: $($controllerError.Text). No reports were generated; see the raw collector output for details."
}
if (@($parsed.Untagged | Where-Object { $_ -match 'Must run from a root shell' }).Count -gt 0 -and @($parsed.Nodes).Count -eq 0) {
    throw 'run-each-node rejected the root shell ("Must run from a root shell using su -"). No reports were generated; see the raw collector output for details.'
}
$controllerEnd = @($parsed.Controller | Where-Object { $_.Section -eq 'END' }) | Select-Object -Last 1
if ($null -ne $controllerEnd -and $controllerEnd.Text -match '^rc=(\d+)$' -and $Matches[1] -ne '0') {
    throw "run-each-node failed (exit $($Matches[1])). See the raw collector output for details; no reports were generated."
}
if (@($parsed.Nodes).Count -eq 0) {
    throw "No node data was found in the collector output. Untagged output: $(@($parsed.Untagged) -join '; ')"
}

$nodeMaps = @($parsed.Nodes | Sort-Object -Property Name | ForEach-Object { Get-SgNodeNetworkMap -Node $_ })
$gridIssues = @(Get-SgGridIssues -NodeMaps $nodeMaps)

$summaryCsv = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-summary.csv"
@(ConvertTo-SgReportRow -Rows @($nodeMaps | ForEach-Object { $_.Summary })) | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8

$bondCsv = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-bonds.csv"
$bondColumns = @('Node', 'Bond', 'State', 'Mode', 'Networks', 'EffectiveSpeed', 'EffectiveSpeedMbps', 'KernelSpeed', 'MembersUp', 'Members', 'ActiveSlave', 'LacpPartnerMac', 'ActiveAggregatorId', 'HashPolicy', 'LacpRate', 'Mtu')
@(ConvertTo-SgReportRow -Rows @($nodeMaps | ForEach-Object { $_.Bonds }) -Property $bondColumns) | Export-Csv -LiteralPath $bondCsv -NoTypeInformation -Encoding UTF8

$portCsv = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-ports.csv"
@(ConvertTo-SgReportRow -Rows @($nodeMaps | ForEach-Object { $_.Ports })) | Export-Csv -LiteralPath $portCsv -NoTypeInformation -Encoding UTF8

$textReport = Format-SgNetworkTextReport -NodeMaps $nodeMaps -GridIssues $gridIssues -Target $sshHost -Untagged $parsed.Untagged
$textPath = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-report.txt"
Set-Content -LiteralPath $textPath -Value $textReport -Encoding UTF8

Write-Host ''
$columns = @('Node', 'PortBondMode') + @($script:SgNetworkInterfaces.Keys) + @('Issues')
@(Get-SgOverviewRows -NodeMaps $nodeMaps) | Format-Table -Property $columns -AutoSize | Out-String -Width 250 | Write-Host
$issueTotal = $gridIssues.Count + (@($nodeMaps | ForEach-Object { $_.Issues }) | Measure-Object).Count
if ($issueTotal -gt 0) {
    Write-Warning "$issueTotal issue(s) detected - see the ISSUES section of the text report."
}

# Post-run cleanup: keep only the summary CSV, bonds CSV and text report unless asked otherwise.
# A file supplied with -InputPath is never deleted.
$intermediateFiles = @($portCsv)
if ($rawOutputPath) { $intermediateFiles += $rawOutputPath }
if ($KeepIntermediateOutputs) {
    Write-Host "Ports CSV   : $portCsv"
    if ($rawOutputPath) { Write-Host "Raw output  : $rawOutputPath" }
}
else {
    foreach ($file in $intermediateFiles) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    }
    Write-Host 'Intermediate outputs (raw collector output, ports CSV) removed; use -KeepIntermediateOutputs to keep them.'
}
Write-Host "Summary CSV : $summaryCsv"
Write-Host "Bonds CSV   : $bondCsv"
Write-Host "Text report : $textPath"

#endregion
