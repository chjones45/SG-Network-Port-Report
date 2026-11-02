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
    <ts>_sg-network-report.html   primary, self-contained report with filters, sorting,
                      expandable evidence and embedded CSV/text downloads
        <ts>_sg-network-summary.csv   one row per node: bond mode, and per network the parent
                                      bond, VLAN, ports, speed, MTU, address, state; issues
        <ts>_sg-network-bonds.csv     one row per bond: mode, networks, effective speed, members
                                      up, LACP partner / aggregator, hash policy, MTU
        <ts>_sg-network-ports.csv     retained detailed per-port results
        <ts>_sg-network-report.txt    overview, issues, and per-node network / bond / port tables
     Fields with no value are written as 'N/A'.
  4. After a successful run, removes newly collected raw output
      <ts>_sg-network-raw.txt unless
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
Version: 1.0.5 (also shown on screen at start-up). Increment $script:SgToolVersion with every change.
    1.0.5  Report zero active bond members without an empty Measure-Object failure.
    1.0.4  Rename the overview heading to Node Network Summary.
    1.0.3  Clickable dashboard totals apply matching result filters with keyboard access and active-state feedback.
    1.0.2  Discover canonical platform metadata through the existing SSH session using the installed local dynip helper; no REST credential prompt.
    1.0.1  Software deployment applicability, Grid-only appliance evidence, inventory input and separated visibility notes.
    1.0.0  HTML-first reporting, evidence-based port bond modes, explicit unknown VLANs and retained port detail CSV.
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
Re-parse saved raw collector output or an HTML report's embedded JSON instead of connecting.
Saved HTML is parsed as data only, never executed. The supplied input is never modified or deleted.

.PARAMETER NodeInventoryPath
Optional verified CSV (Node,Platform,PortBondMode,RequiredPorts) or exported StorageGRID
network-topology JSON. Use Platform VMware/vsphere, Baremetal/linux, or appliance.
PortBondMode and RequiredPorts are optional installer/wiring intent, not automatic guesses.

.PARAMETER KeepIntermediateOutputs
Keep newly collected raw output for troubleshooting. HTML, summary/bonds/ports CSV and text
reports are always retained. A file supplied with InputPath is never deleted.

.PARAMETER OpenReport
Open the HTML report in the default browser after successful generation.

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
    [Parameter(Mandatory = $false)][string]$NodeInventoryPath,
    [Parameter(Mandatory = $false)][string]$OutputDir = '.\sg-network-report',
    [Parameter(Mandatory = $false)][switch]$KeepIntermediateOutputs,
    [Parameter(Mandatory = $false)][switch]$OpenReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SgToolVersion = '1.0.5'
$script:SgNodeInventory = @{}
$script:SgAutomaticInventory = @{}
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
collect() {
    section=$1; shift
    output=$("$@" 2>&1); status=$?
    printf '%s\n' "$output" | tag "$section"
    printf '%s=%s\n' "$section" "$status" | tag STATUS
}
collect IPLINK ip -o link show
collect ADDR ip -o addr show
collect VLAN cat /proc/net/vlan/config
{
    if [ -r /sys/class/dmi/id/sys_vendor ]; then printf 'manufacturer=%s\n' "$(cat /sys/class/dmi/id/sys_vendor)"; fi
    if [ -r /sys/class/dmi/id/product_name ]; then printf 'product=%s\n' "$(cat /sys/class/dmi/id/product_name)"; fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        container=$(systemd-detect-virt --container 2>/dev/null || true)
        printf 'container=%s\n' "${container:-unknown}"
    else printf 'container=unknown\n'; fi
} | tag PLATFORM
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
if command -v ruby >/dev/null 2>&1; then
        META_TIMEOUT=()
        if command -v timeout >/dev/null 2>&1; then META_TIMEOUT=(timeout 20); fi
        "${META_TIMEOUT[@]}" ruby 2>/dev/null <<'SG_METADATA_RUBY'
begin
    require 'bycast/command'
    require 'bycast/log'
    require 'bycast/helpers/dynip'
    require 'json'
    records = Bycast::Helpers::DynipStatic.nodes
    records.each do |record|
        config = record['nodeConfig']
        next unless config.is_a?(Hash)
        selected = {}
        %w[hostname platform nodeType].each do |key|
            value = config[key]
            selected[key] = value if value.is_a?(String)
        end
        next if selected['hostname'].to_s.empty? || selected['platform'].to_s.empty?
        puts '@@SGNET@@|__controller__|NODE_METADATA|' + JSON.generate(selected)
    end
    puts '@@SGNET@@|__controller__|METADATA_STATUS|local-dynip-complete'
rescue StandardError, LoadError => error
    puts '@@SGNET@@|__controller__|METADATA_STATUS|local-dynip-unavailable:' + error.class.to_s
end
SG_METADATA_RUBY
        if [ "$?" -ne 0 ]; then say METADATA_STATUS 'local-dynip-unavailable:execution-or-timeout'; fi
else
        say METADATA_STATUS 'local-dynip-unavailable:ruby-not-found'
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
        '-o', 'StrictHostKeyChecking=yes',
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
                    STATUS  = New-Object System.Collections.Generic.List[string]
                    PLATFORM = New-Object System.Collections.Generic.List[string]
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

function Get-SgOptionalValue {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    elseif ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Import-SgNodeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::GetExtension($Path) -ieq '.csv') { $records = @(Import-Csv -LiteralPath $Path) }
    else {
        $inventory = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($wrapper in 'sg_network_topology', 'data') {
            $nested = Get-SgOptionalValue $inventory $wrapper $null
            if ($null -ne $nested) { $inventory = $nested }
        }
        $gridNodes = Get-SgOptionalValue $inventory 'gridNodes' $null
        if ($null -ne $gridNodes) { $records = @($gridNodes | ForEach-Object { Get-SgOptionalValue $_ 'nodeConfig' $null }) }
        else { $records = @($inventory) }
    }
    $result = @{}
    foreach ($record in $records) {
        $name = [string](Get-SgOptionalValue $record 'Node' (Get-SgOptionalValue $record 'hostname'))
        $platform = [string](Get-SgOptionalValue $record 'Platform')
        $mode = [string](Get-SgOptionalValue $record 'PortBondMode')
        $requiredPorts = @(([string](Get-SgOptionalValue $record 'RequiredPorts')) -split '[,;\s]+' | Where-Object { $_ })
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Every inventory record requires Node or hostname.' }
        if ($result.ContainsKey($name)) { throw "Duplicate inventory node: $name" }
        if ($mode -and $mode -notin 'Fixed', 'Aggregate') { throw "Inventory PortBondMode must be Fixed, Aggregate or empty: $name" }
        if (@($requiredPorts | Where-Object { $_ -notmatch '^[A-Za-z0-9._:-]+$' }).Count -gt 0) { throw "Invalid inventory RequiredPorts: $name" }
        $result[$name] = [pscustomobject]@{ Platform = $platform; PortBondMode = $mode; RequiredPorts = [string[]]$requiredPorts; Source = 'Verified node inventory / exported StorageGRID topology' }
    }
    return $result
}

function ConvertFrom-SgGridMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Controller)

    $result = @{}
    foreach ($record in @($Controller | Where-Object { $_.Section -eq 'NODE_METADATA' })) {
        try { $metadata = $record.Text | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        $name = [string](Get-SgOptionalValue $metadata 'hostname')
        $platform = [string](Get-SgOptionalValue $metadata 'platform')
        $type = [string](Get-SgOptionalValue $metadata 'nodeType')
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 255 -or $name -match '[\r\n|]' -or
            $platform -notmatch '^(?i:vmware|vsphere|bare[- ]?metal|linux|docker|container|SGA|appliance)$') { continue }
        if ($result.ContainsKey($name)) {
            if ($null -eq $result[$name] -or $result[$name].Platform -ine $platform) { $result[$name] = $null }
            continue
        }
        $result[$name] = [pscustomobject]@{
            Platform = $platform
            NodeType = $type
            Source = 'StorageGRID local dynip nodeConfig via existing SSH session'
        }
    }
    return $result
}

function Get-SgDeploymentAssessment {
    [CmdletBinding()]
    param(
        [string[]]$PlatformLines = @(),
        $Inventory,
        [bool]$HasAppliancePorts = $false
    )

    $platform = [string](Get-SgOptionalValue $Inventory 'Platform')
    $configuredMode = [string](Get-SgOptionalValue $Inventory 'PortBondMode')
    $type = 'Unknown'
    $evidence = 'Deployment metadata was not collected; no inference is made from MAC addresses or node names.'
    if ($platform) {
        if ($platform -match '^(?i:vmware|vsphere)$') { $type = 'VMware' }
        elseif ($platform -match '^(?i:bare[- ]?metal|linux|docker|container)$') { $type = 'Baremetal' }
        elseif ($platform -match '(?i:appliance|^SGA$|^SGF?\d+)') { $type = 'Appliance' }
        $metadataSource = [string](Get-SgOptionalValue $Inventory 'Source' 'Verified inventory')
        $evidence = "Platform $platform. Source: $metadataSource."
    }
    elseif ($HasAppliancePorts) {
        $type = 'Appliance'
        $evidence = 'Appliance-style hic data ports were observed; topology classification, not a model identification.'
    }
    else {
        $values = @{}
        foreach ($line in $PlatformLines) {
            if ($line -match '^(manufacturer|product|container)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
        }
        $container = [string](Get-SgOptionalValue $values 'container')
        $manufacturer = [string](Get-SgOptionalValue $values 'manufacturer')
        $product = [string](Get-SgOptionalValue $values 'product')
        if (($manufacturer + ' ' + $product) -match '(?i)VMware' -and (-not $container -or $container -eq 'none')) {
            $type = 'VMware'
            $evidence = 'VMware DMI platform observed without a detected container boundary.'
        }
        elseif ($container -and $container -ne 'none') {
            $evidence = 'Container boundary observed; an inventory platform is required to distinguish customer-hosted nodes from appliance internals.'
        }
    }
    return [pscustomobject]@{ Type = $type; Evidence = $evidence; ConfiguredPortBondMode = $configuredMode }
}

function Get-SgPortBondAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Networks,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Bonds,
        [bool]$Complete = $true,
        [string]$Deployment = 'Unknown',
        [string]$ConfiguredMode = ''
    )

    $mode = 'Unknown'
    $evidence = 'Insufficient topology evidence to distinguish Fixed from Aggregate.'
    $grid = $Networks['Grid']
    $client = $Networks['Client']
    if ($Deployment -in 'VMware', 'Baremetal') {
        $mode = "N/A - $Deployment"
        $evidence = 'Appliance port bond mode is not applicable to this software deployment. Host/vSwitch bonding and VLANs are outside the node-level observation.'
    }
    elseif ($ConfiguredMode -in 'Fixed', 'Aggregate') {
        $mode = $ConfiguredMode
        $evidence = 'Port bond mode supplied by verified inventory; compare with Appliance Installer configuration when updating that inventory.'
    }
    elseif (-not $Complete -or -not $grid.Present) {
        $evidence = 'Collection is incomplete or the Grid Network interface was not observed.'
    }
    elseif (-not $grid.Bond -and -not $client.Bond) {
        $mode = 'Not applicable'
        $evidence = 'No bonded Grid or Client Network path was observed; appliance port bond mode is not established.'
    }
    elseif ($grid.Bond -and $client.Present -and $client.Bond) {
        if ($grid.Bond -ne $client.Bond) {
            $mode = 'Fixed'
            $evidence = "Grid and Client Networks use separate parent bonds ($($grid.Bond), $($client.Bond))."
        }
        else {
            $shared = @($Bonds | Where-Object { $_.Bond -eq $grid.Bond })
            if ($shared.Count -eq 1 -and $shared[0].Mode -match '802\.3ad') {
                $mode = 'Aggregate'
                $evidence = "Grid and Client Networks share the same LACP parent bond ($($grid.Bond))."
            }
            else { $evidence = 'Grid and Client share a parent bond, but LACP evidence is missing or contradictory.' }
        }
    }
    elseif ($grid.Bond -and -not $client.Present) {
        $gridBonds = @($Bonds | Where-Object { $_.Bond -eq $grid.Bond })
        if ($gridBonds.Count -eq 1) {
            $gridBond = $gridBonds[0]
            $members = @()
            if ($gridBond.PSObject.Properties.Name -contains 'MemberDetail') {
                $members = @($gridBond.MemberDetail | ForEach-Object Name | Sort-Object -Unique)
            }
            if ($gridBond.Mode -match '802\.3ad' -and ($members -join ',') -eq 'hic1,hic2,hic3,hic4') {
                $mode = 'Aggregate'
                $evidence = "Grid-only LACP bond $($grid.Bond) contains all four appliance data ports (hic1-hic4); topology inference, not an installer configuration read."
            }
            elseif ($gridBond.Mode -match 'active-backup' -and $members.Count -eq 2 -and @($members | Where-Object { $_ -notmatch '^hic[1-4]$' }).Count -eq 0) {
                $mode = 'Fixed'
                $evidence = "Grid-only Active-Backup bond $($grid.Bond) uses a pair of appliance data ports; Aggregate requires LACP."
            }
        }
    }
    return [pscustomobject]@{ Mode = $mode; Evidence = $evidence }
}

function Set-SgNodeReportAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Map,
        [string[]]$PlatformLines = @(),
        $CoreComplete = $null,
        [ValidateSet('Available', 'Absent', 'Failed', 'Unrecorded')][string]$VlanSource = 'Unrecorded'
    )

    $notes = New-Object System.Collections.Generic.List[string]
    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($row in $Map.Networks) {
        if ($row.PSObject.Properties.Name -notcontains 'Observation') {
            $observation = if (-not $row.Present) { 'Not observed' }
                elseif ($row.Network -in 'Admin', 'Client' -and [string]::IsNullOrWhiteSpace($row.Address) -and $row.State -ne 'UP') { 'Inactive; enablement unknown' }
                else { $row.State }
            $row | Add-Member -NotePropertyName Observation -NotePropertyValue $observation
        }
        $Map.Summary | Add-Member -NotePropertyName "$($row.Network)Observation" -NotePropertyValue $row.Observation -Force
    }
    foreach ($issue in @($Map.Issues)) {
        if ($issue -notmatch '^(Port bond mode could not be established:|VLAN collection is unavailable;|Collection evidence is incomplete;|Essential link/address collection|VLAN collection failed;|Appliance VLAN evidence is unavailable;|Inventory-required port |Inventory states Aggregate |Grid and Client Networks share a data bond with identical VLAN observations;)') { $issues.Add([string]$issue) }
    }
    $inventory = $null
    if ($script:SgNodeInventory.ContainsKey($Map.Summary.Node)) { $inventory = $script:SgNodeInventory[$Map.Summary.Node] }
    $automatic = $null
    if ($script:SgAutomaticInventory.ContainsKey($Map.Summary.Node)) { $automatic = $script:SgAutomaticInventory[$Map.Summary.Node] }
    elseif ([string](Get-SgOptionalValue $Map.Summary 'GridPlatform')) {
        $automatic = [pscustomobject]@{
            Platform = [string](Get-SgOptionalValue $Map.Summary 'GridPlatform')
            NodeType = [string](Get-SgOptionalValue $Map.Summary 'GridNodeType')
            Source = [string](Get-SgOptionalValue $Map.Summary 'GridMetadataSource')
        }
    }
    if ($null -ne $automatic) {
        foreach ($entry in @{ GridPlatform = $automatic.Platform; GridNodeType = $automatic.NodeType; GridMetadataSource = $automatic.Source }.GetEnumerator()) {
            $Map.Summary | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
        }
        if (-not [string](Get-SgOptionalValue $inventory 'Platform')) {
            $inventory = [pscustomobject]@{
                Platform = $automatic.Platform
                PortBondMode = [string](Get-SgOptionalValue $inventory 'PortBondMode')
                RequiredPorts = @(Get-SgOptionalValue $inventory 'RequiredPorts' @())
                Source = $automatic.Source
            }
        }
    }
    $hasAppliancePorts = @($Map.Ports | Where-Object { $_.Port -match '^hic[1-4]$' }).Count -gt 0
    $deployment = Get-SgDeploymentAssessment -PlatformLines $PlatformLines -Inventory $inventory -HasAppliancePorts $hasAppliancePorts
    $networkPaths = [ordered]@{}
    foreach ($name in 'Grid', 'Client', 'Admin') {
        $row = @($Map.Networks | Where-Object { $_.Network -eq $name })
        $networkPaths[$name] = [pscustomobject]@{
            Present = $row.Count -gt 0 -and $row[0].Present
            Bond = $(if ($row.Count -gt 0 -and $row[0].ParentBond -ne 'None') { $row[0].ParentBond } else { '' })
        }
    }
    $topologyComplete = $networkPaths['Grid'].Present -and ($null -eq $CoreComplete -or [bool]$CoreComplete)
    $assessment = Get-SgPortBondAssessment -Networks $networkPaths -Bonds @($Map.Bonds) -Complete $topologyComplete -Deployment $deployment.Type -ConfiguredMode $deployment.ConfiguredPortBondMode
    $softwareScope = $deployment.Type -in 'VMware', 'Baremetal' -or ($assessment.Mode -eq 'Not applicable' -and -not $hasAppliancePorts)
    $requiredPorts = @(Get-SgOptionalValue $inventory 'RequiredPorts' @())
    $retainedIssues = New-Object System.Collections.Generic.List[string]
    foreach ($issue in $issues) {
        if ($issue -match '^(?<bond>\S+) member (?<port>\S+) is down$') {
            $bondName = $Matches['bond']; $portName = $Matches['port']
            $bond = @($Map.Bonds | Where-Object { $_.Bond -eq $bondName })
            $port = @($Map.Ports | Where-Object { $_.Port -eq $portName })
            $zeroFailures = $port.Count -eq 1 -and [string]$port[0].LinkFailures -eq '0'
            $hasActivePath = $bond.Count -eq 1 -and @($bond[0].MemberDetail | Where-Object { $_.CarriesTraffic }).Count -gt 0
            $unusedBond = $bond.Count -eq 1 -and [string]::IsNullOrWhiteSpace($bond[0].Networks)
            $reducedAggregate = $assessment.Mode -eq 'Aggregate' -and $bond.Count -eq 1 -and $bond[0].Mode -match '802\.3ad' -and $hasActivePath -and $zeroFailures
            if ($portName -notin $requiredPorts -and ($unusedBond -or $reducedAggregate)) {
                $notes.Add("$bondName member $portName is down. Reduced-port Aggregate wiring or an unused bond can be intentional; no required-port intent is recorded for this port. Current member state remains in the details.")
                continue
            }
        }
        if ($issue -match '^(?<network>Admin|Client) Network (port .* is down|interface .* is \S+)$') {
            $optional = @($Map.Networks | Where-Object { $_.Network -eq $Matches['network'] })
            if ($optional.Count -eq 1 -and [string]::IsNullOrWhiteSpace($optional[0].Address) -and $optional[0].State -ne 'UP') {
                $notes.Add("$($optional[0].Network) interface is inactive without a global address; enablement is not established.")
                continue
            }
        }
        $retainedIssues.Add($issue)
    }
    $issues = $retainedIssues
    foreach ($downPort in @($Map.Ports | Where-Object { $_.Status -eq 'Down' })) {
        if (@($notes | Where-Object { $_ -match ('\b' + [regex]::Escape($downPort.Port) + '\b') }).Count -eq 0) {
            $notes.Add("Observed down port $($downPort.Port) on $($downPort.Bond). Port state is retained independently of assessment; required-port intent and failure evidence determine whether attention is needed.")
        }
    }
    foreach ($requiredPort in $requiredPorts) {
        $observed = @($Map.Ports | Where-Object { $_.Port -eq $requiredPort })
        if ($observed.Count -ne 1) { $issues.Add("Inventory-required port $requiredPort was not observed; review inventory and collection.") }
        elseif ($observed[0].Status -notmatch '^Up|link up') { $issues.Add("Inventory-required port $requiredPort is not up.") }
    }
    if ($deployment.ConfiguredPortBondMode -eq 'Aggregate' -and $networkPaths['Grid'].Bond) {
        $gridBondEvidence = @($Map.Bonds | Where-Object { $_.Bond -eq $networkPaths['Grid'].Bond })
        if ($gridBondEvidence.Count -eq 1 -and $gridBondEvidence[0].Mode -match 'active-backup') {
            $issues.Add('Inventory states Aggregate but the observed Grid bond uses Active-Backup; reconcile installer settings and runtime evidence.')
        }
    }
    $vlanAvailable = $VlanSource -eq 'Available'
    if ($VlanSource -eq 'Unrecorded') {
        $vlanAvailable = @($Map.Networks | Where-Object { $_.Present -and ($_.Vlan -eq 'Unknown' -or [string]::IsNullOrWhiteSpace($_.Vlan)) }).Count -eq 0
    }
    $externalVlan = $softwareScope -and -not $vlanAvailable -and $VlanSource -in 'Absent', 'Unrecorded'
    if ($null -ne $CoreComplete -and -not [bool]$CoreComplete) { $issues.Add('Essential link/address collection did not complete; review collection errors.') }
    if (-not $vlanAvailable) {
        if ($externalVlan) { $notes.Add('Node-side VLAN source is unavailable. Hypervisor/host/switch VLAN tags are not established; this is a visibility limitation, not an appliance configuration failure.') }
        elseif ($VlanSource -eq 'Failed') { $issues.Add('VLAN collection failed; review source permissions or collection errors.') }
        else { $issues.Add('Appliance VLAN evidence is unavailable; tags cannot be verified.') }
    }
    if ($null -eq $CoreComplete) { $notes.Add('Original per-command completion status is not recorded in this saved report; essential collection status has not been revalidated.') }
    if ($assessment.Mode -eq 'Unknown') { $notes.Add("Port bond mode is unresolved: $($assessment.Evidence)") }
    if ($assessment.Mode -eq 'Aggregate' -and $vlanAvailable -and $networkPaths['Client'].Present) {
        $gridRow = $Map.Networks | Where-Object Network -EQ 'Grid'
        $clientRow = $Map.Networks | Where-Object Network -EQ 'Client'
        if ($gridRow.Vlan -eq $clientRow.Vlan -and -not (@($issues | Where-Object { $_ -match 'distinct network VLAN tags' }).Count -gt 0)) {
            $issues.Add('Grid and Client Networks share a data bond with identical VLAN observations; Aggregate mode requires distinct network VLAN tags. Review appliance and switch configuration.')
        }
    }
    if ($assessment.Mode -eq 'Not applicable' -and $deployment.Type -eq 'Unknown') {
        $notes.Add('Unbonded data interfaces were observed, but VMware versus Baremetal was not collected. Recollect platform evidence or supply verified node inventory for a precise N/A label.')
    }
    $notes.Add($deployment.Evidence)
    $status = if ($assessment.Mode -like 'N/A -*' -or $assessment.Mode -eq 'Not applicable') { 'Skipped' } elseif ($assessment.Mode -eq 'Unknown') { 'Unresolved' } else { 'Assessed' }
    $modeSource = if ($status -eq 'Skipped') { 'Not applicable' } elseif ($deployment.ConfiguredPortBondMode) { 'Verified inventory' } elseif ($status -eq 'Assessed') { 'Runtime topology (inferred)' } else { 'Unresolved' }
    $complete = $null -ne $CoreComplete -and [bool]$CoreComplete -and ($vlanAvailable -or $externalVlan)
    foreach ($entry in @{
        Deployment = $deployment.Type; DeploymentEvidence = $deployment.Evidence
        PortBondMode = $assessment.Mode; PortBondEvidence = $assessment.Evidence
        PortBondStatus = $status; PortBondSource = $modeSource; DataComplete = $complete; CoreDataComplete = $CoreComplete
        NeedsReview = $issues.Count -gt 0; IssueCount = $issues.Count; Issues = ($issues -join '; ')
        VlanSource = $VlanSource; VisibilityNotes = ($notes -join ' ')
        RequiredPorts = ($requiredPorts -join ' ')
    }.GetEnumerator()) {
        $Map.Summary | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
    }
    $Map | Add-Member -NotePropertyName Issues -NotePropertyValue ([string[]]$issues.ToArray()) -Force
    $Map | Add-Member -NotePropertyName Notes -NotePropertyValue ([string[]]$notes.ToArray()) -Force
    $Map | Add-Member -NotePropertyName PlatformEvidence -NotePropertyValue ([string[]]$PlatformLines) -Force
    return $Map
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
    $sectionStatus = @()
    if ($Node.Sections.ContainsKey('STATUS')) { $sectionStatus = @($Node.Sections['STATUS']) }
    $vlanAvailable = @($sectionStatus | Where-Object { $_ -eq 'VLAN=0' }).Count -gt 0
    if (-not (@($sectionStatus | Where-Object { $_ -match '^VLAN=' }).Count -gt 0)) {
        $vlanAvailable = $vlans.Count -gt 0 -or @($Node.Sections['VLAN'] | Where-Object { $_ -match '^\s*VLAN Dev name\s*\|' }).Count -gt 0
    }
    $dataComplete = $Node.Complete -and $links.Count -gt 0 -and $vlanAvailable -and
        @($sectionStatus | Where-Object { $_ -match '^(IPLINK|ADDR)=[1-9][0-9]*$' }).Count -eq 0
    $topologyComplete = $Node.Complete -and $links.Count -gt 0 -and
        @($sectionStatus | Where-Object { $_ -match '^IPLINK=[1-9][0-9]*$' }).Count -eq 0
    $coreComplete = $Node.Complete -and $links.Count -gt 0 -and
        @($sectionStatus | Where-Object { $_ -match '^(IPLINK|ADDR)=[1-9][0-9]*$' }).Count -eq 0
    $vlanSource = if ($vlanAvailable) { 'Available' }
        elseif (@($Node.Sections['VLAN'] | Where-Object { $_ -match 'No such file or directory' }).Count -gt 0) { 'Absent' }
        elseif (@($sectionStatus | Where-Object { $_ -match '^VLAN=[1-9][0-9]*$' }).Count -gt 0) { 'Failed' }
        else { 'Unrecorded' }

    # Networks first, so bonds and ports can be labelled with the networks they carry.
    $networks = [ordered]@{}
    foreach ($networkName in $script:SgNetworkInterfaces.Keys) {
        $networks[$networkName] = Resolve-SgNetworkPath -Interface $script:SgNetworkInterfaces[$networkName] -Links $links -Vlans $vlans -BondNames $bondNames
        if ($networks[$networkName].Present -and -not $vlanAvailable) { $networks[$networkName].Vlan = 'Unknown' }
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

        $effective = [long]0
        foreach ($activeMember in @($members | Where-Object { $_.CarriesTraffic -and $null -ne $_.SpeedMbps })) {
            $effective += [long]$activeMember.SpeedMbps
        }
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
                    Network = $networkName; Interface = $iface; ParentBond = ''; Vlan = 'Not observed'; Ports = ''
                    Speed = ''; SpeedMbps = $null; Mtu = ''; Address = ''; State = ''; Path = ''; Present = $false; Observation = 'Not observed'
                })
            continue
        }
        $address = ''
        if ($addrs.ContainsKey($iface)) { $address = (@($addrs[$iface]) -join ' ') }
        $checkLinkState = $networkName -eq 'Grid' -or -not [string]::IsNullOrWhiteSpace($address)
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
            if ($checkLinkState -and -not $detail.IsUp) { $issues.Add("$networkName Network port $($n.Terminal) is down") }
        }
        foreach ($p in $portList) {
            if (-not $portNetworks.ContainsKey($p)) { $portNetworks[$p] = New-Object System.Collections.Generic.List[string] }
            $portNetworks[$p].Add($networkName)
        }
        $state = $links[$iface].State
        if ($checkLinkState -and $state -and $state -notin @('UP', 'UNKNOWN')) { $issues.Add("$networkName Network interface $iface is $state") }

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
                Observation = $(if (-not $checkLinkState -and $state -ne 'UP') { 'Inactive; enablement unknown' } else { $state })
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
        DataComplete = $dataComplete
        PortBondMode = 'Unknown'
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
        $networkBondMode = 'Unknown'
        if (-not $row.Present) { $networkBondMode = 'Not observed' }
        elseif ($row.ParentBond -eq 'None') { $networkBondMode = 'Independent' }
        elseif ($parentBondMode -match '802\.3ad') { $networkBondMode = 'LACP' }
        elseif ($parentBondMode -match 'active-backup') { $networkBondMode = 'Active-Backup' }
        if ($row.Present -and $networkBondMode -eq 'Unknown') { $issues.Add("$($row.Network) Network bond mode is unknown; bond evidence is unavailable or unrecognised.") }
        $row | Add-Member -NotePropertyName NetworkBondMode -NotePropertyValue $networkBondMode
        $summary["$($row.Network)NetworkBondMode"] = $networkBondMode
        $summary["$($row.Network)Vlan"] = $row.Vlan
        $summary["$($row.Network)Ports"] = $row.Ports
        $summary["$($row.Network)Speed"] = $(if ($row.Present) { $row.Speed } else { '' })
        $summary["$($row.Network)Mtu"] = $row.Mtu
        $summary["$($row.Network)Address"] = $row.Address
        $summary["$($row.Network)State"] = $row.State
        $summary["$($row.Network)Observation"] = $row.Observation
    }
    $summary['BondSummary'] = (@($bonds | ForEach-Object { '{0} [{1}, {2} up]' -f $_.Bond, $_.EffectiveSpeed, $_.MembersUp }) -join '; ')
    $summary['IssueCount'] = $issues.Count
    $summary['Issues'] = ($issues -join '; ')

    $map = [pscustomobject]@{
        Summary  = [pscustomobject]$summary
        Networks = [object[]]$networkRows.ToArray()
        Bonds    = [object[]]$bonds.ToArray()
        Ports    = [object[]]$ports.ToArray()
        Issues   = [string[]]$issues.ToArray()
    }
    $platformLines = @()
    if ($Node.Sections.ContainsKey('PLATFORM')) { $platformLines = @($Node.Sections['PLATFORM']) }
    return Set-SgNodeReportAssessment -Map $map -PlatformLines $platformLines -CoreComplete $coreComplete -VlanSource $vlanSource
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
    $incomplete = @($NodeMaps | Where-Object { $_.Summary.NeedsReview -and -not $_.Summary.DataComplete } | ForEach-Object { $_.Summary.Node })
    if ($incomplete.Count -gt 0) { $issues.Add("Evidence is incomplete or unavailable on: $($incomplete -join ', ')") }
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

function Read-SgNetworkReportEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $html = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'Saved HTML does not contain supported network-report JSON evidence.' }
    $report = $match.Groups[1].Value | ConvertFrom-Json
    if ($report.PSObject.Properties.Name -notcontains 'nodes' -or @($report.nodes).Count -eq 0) { throw 'Saved report contains no node evidence.' }
    foreach ($node in $report.nodes) {
        foreach ($property in 'Summary', 'Networks', 'Bonds', 'Ports', 'Issues') {
            if ($node.PSObject.Properties.Name -notcontains $property) { throw "Saved report node is missing: $property" }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-SgOptionalValue $node.Summary 'Node'))) { throw 'Saved report node has no identity.' }
    }
    return $report
}

function Format-SgNetworkHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$NodeMaps,
        [AllowEmptyCollection()][string[]]$GridIssues = @(),
        [AllowEmptyCollection()][string[]]$Untagged = @(),
        [string]$Target,
        [string]$Source = 'SSH collection',
        [string]$OriginalGenerated = '',
        [hashtable]$ReportFiles = @{}
    )

    $files = @(
        foreach ($label in @($ReportFiles.Keys | Sort-Object)) {
            $path = $ReportFiles[$label]
            [ordered]@{ label = $label; name = [IO.Path]::GetFileName($path); content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
        }
    )
    $payload = [ordered]@{
        version = $script:SgToolVersion
        generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        target = $Target
        source = $Source
        originalGenerated = $OriginalGenerated
        nodes = @($NodeMaps)
        gridIssues = @($GridIssues)
        otherOutput = @($Untagged)
        files = $files
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 14 -Compress
    $json = $json.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    $template = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>StorageGRID Network Port Report</title>
<style>
@font-face{font-family:ReportText;src:local("Aptos"),local("Calibri")}@font-face{font-family:ReportHeading;src:local("Bahnschrift"),local("Franklin Gothic Medium")}
:root{--ink:#25292b;--muted:#606b70;--line:#d9e1e2;--accent:#007d78;--wash:#f3f7f6;--warn:#99422d;--warn-bg:#fff2e9}*{box-sizing:border-box}body{margin:0;color:var(--ink);background:#fff;font:16px/1.5 ReportText,"Segoe UI",sans-serif;letter-spacing:0;overflow-wrap:anywhere}button,input,select{font:inherit}button,a,input,select,summary{outline-offset:3px}a{color:#006d68;text-underline-offset:3px}button{cursor:pointer}h1,h2,h3{font-family:ReportHeading,"Segoe UI",sans-serif;letter-spacing:0;line-height:1.2}h1{font-size:36px;margin:9px 0 16px}h2{font-size:25px;margin:0 0 20px}h3{font-size:19px;margin:24px 0 12px}.shell{width:min(1500px,calc(100% - 64px));margin:auto}.masthead{background:#24292b;border-top:4px solid var(--accent);color:white}.brand{display:flex;justify-content:space-between;align-items:center;gap:20px;min-height:76px}.brand strong{font:600 27px ReportHeading,"Segoe UI",sans-serif}.brand span{color:#ccd7d4;font-size:14px}.heading{padding:36px 0 24px;border-bottom:2px solid var(--ink);background:linear-gradient(100deg,#fff 60%,#f0f7f5)}.eyebrow{font-size:12px;text-transform:uppercase;font-weight:700;color:var(--accent);margin:0}.metadata{display:flex;gap:10px 28px;flex-wrap:wrap;font-size:14px;color:var(--muted)}.metadata strong{color:var(--ink)}.stats{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));border-bottom:1px solid var(--line);margin:24px 0}.stat{padding:12px 20px;border-right:1px solid var(--line)}.stat:first-child{padding-left:0}.stat:last-child{border:0}.stat strong{font:600 32px ReportHeading,"Segoe UI",sans-serif;display:block}.stat span{font-size:14px;color:var(--muted)}.stat.attention strong{color:var(--warn)}.notice{border-left:3px solid var(--accent);background:var(--wash);padding:14px 18px;font-size:14px;margin:20px 0}.warning{border-left-color:var(--warn);background:var(--warn-bg)}.warning summary{cursor:pointer;font-weight:700}.warning pre{white-space:pre-wrap;overflow-wrap:anywhere}.downloads{display:flex;gap:10px;flex-wrap:wrap;margin:23px 0}.download{display:inline-flex;align-items:center;gap:20px;padding:9px 14px;min-height:42px;border:1px solid #aebebc;background:#fff;color:#005f5a;border-radius:3px;font-size:14px;text-decoration:none}.download:hover{background:var(--wash)}.navigation{display:flex;gap:24px;border-bottom:1px solid var(--line);padding:6px 0 18px;margin:20px 0 28px}section{margin-bottom:36px;min-width:0}.filters{display:flex;gap:12px;flex-wrap:wrap;align-items:end;background:var(--wash);padding:16px;border-block:1px solid var(--line)}.filters label{display:flex;flex-direction:column;gap:6px;font-size:13px;font-weight:600;min-width:140px}.filters label.search{flex:1;min-width:210px}.filters input[type=search],select{border:1px solid #b7c5c3;border-radius:3px;background:#fff;color:var(--ink);padding:9px 10px;min-height:42px;max-width:100%}.filters label.toggle{flex-direction:row;align-items:center;min-height:42px;gap:8px}.reset{min-height:42px;padding:9px 14px;border:1px solid #b7c5c3;background:white;border-radius:3px}.results{display:flex;justify-content:space-between;gap:20px;margin:15px 0;font-size:14px;color:var(--muted)}.table-scroll{overflow:auto;max-width:100%}table{width:100%;border-collapse:collapse;text-align:left;font-size:14px}th,td{padding:13px 15px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--wash);font-weight:600;white-space:nowrap}th button{border:0;background:transparent;color:inherit;padding:0;display:flex;align-items:center;gap:8px;font-weight:600;text-align:left;min-height:28px}td.node-name{font-weight:700;min-width:160px}.network-mode{display:block;font-weight:600;white-space:nowrap}.vlan{display:block;color:#005f5a;font-size:13px;margin-top:3px}.subtle{display:block;color:var(--muted);font-size:12px;margin-top:5px}.badge{display:inline-block;padding:3px 8px;border-radius:3px;font-size:12px;background:#e6f4f0;color:#12534a;font-weight:600;white-space:nowrap}.badge.review{background:var(--warn-bg);color:var(--warn)}.badge.neutral{background:#edf0f1;color:#4f5c62}.node-detail{border-bottom:1px solid var(--line);scroll-margin-top:20px}.node-detail>summary{cursor:pointer;display:flex;align-items:center;gap:18px;padding:20px 4px;list-style-position:inside}.node-detail>summary::before{content:'+';font-size:23px;color:var(--accent);width:20px;flex-shrink:0}.node-detail[open]>summary::before{content:'-'}summary .node-title{font:600 22px ReportHeading,"Segoe UI",sans-serif;flex:1}.detail-body{padding:0 4px 26px;min-width:0}.issue-list{padding-left:24px;color:var(--warn)}.issue-list li{margin:7px 0}.port-strip{display:flex;gap:10px;flex-wrap:wrap;margin:18px 0}.port{border:1px solid var(--line);border-top:4px solid var(--accent);padding:9px 12px;min-width:130px;max-width:250px}.port.down{border-top-color:var(--warn);background:#fff8f4}.port strong{display:block}.port span{display:block;font-size:12px;color:var(--muted)}.empty{text-align:center;padding:35px;color:var(--muted)}footer{border-top:1px solid var(--line);padding:25px 0;margin-top:35px;font-size:13px;color:var(--muted)}code,pre{font-family:Consolas,"Cascadia Mono",monospace;font-size:13px}.skip{position:absolute;top:-100px;left:20px;background:white;padding:10px}.skip:focus{top:12px;z-index:5}[hidden]{display:none!important}@media(max-width:900px){.stats{grid-template-columns:repeat(3,minmax(0,1fr))}.stat{padding:12px}.stat:nth-child(3){border:0}.stat:first-child{padding-left:12px}.filters label{flex:1;min-width:150px}}@media(max-width:600px){.shell{width:calc(100% - 32px)}h1{font-size:29px}.heading{padding:25px 0 20px}.brand{min-height:66px}.brand strong{font-size:24px}.brand span{font-size:12px}.stats{margin-block:18px}.stat strong{font-size:27px}.stat span{font-size:12px}.filters{padding:12px;gap:12px}.filters label,.filters label.search{min-width:100%;width:100%}.filters label.toggle{min-width:0;width:auto}.results{flex-wrap:wrap;gap:8px}.downloads{gap:8px}.download{font-size:13px;padding:8px 10px}.node-detail>summary{gap:10px}summary .node-title{font-size:18px}.node-detail .badge{white-space:normal}th,td{padding:11px 12px}.notice{padding:12px}.network-mode{font-size:13px}}@media print{.filters,.downloads,.navigation,.skip{display:none}.shell{width:100%}.table-scroll{overflow:visible}.node-detail{break-inside:avoid}.masthead{background:white;color:black}.stats{grid-template-columns:repeat(6,1fr)}}
.stats .stat{appearance:none;background:transparent;color:inherit;text-align:left;border:0;border-right:1px solid var(--line);border-radius:0;min-width:0;width:100%;transition:background-color .12s}.stats .stat:last-child{border-right:0}.stats .stat:hover{background:var(--wash)}.stats .stat[aria-pressed=true]{background:#e5f3ef;box-shadow:inset 0 -3px 0 var(--accent)}.stats .stat:focus-visible{outline:3px solid var(--accent);outline-offset:-3px}@media(prefers-reduced-motion:reduce){.stats .stat{transition:none}}
</style></head><body><a class="skip" href="#overview">Skip to report</a><header class="masthead"><div class="shell brand"><strong>NetApp</strong><span>StorageGRID / Network Port Report</span></div></header>
<main class="shell"><div class="heading"><p class="eyebrow">Observed network configuration</p><h1>StorageGRID Network Links</h1><div id="metadata" class="metadata"></div></div><div id="stats" class="stats" aria-label="Collection overview"></div><p id="coverage" class="notice"></p><div id="collection-warning" class="notice warning" hidden></div><div id="downloads" class="downloads" aria-label="Report downloads"></div><nav class="navigation"><a href="#overview">Network overview</a><a href="#node-details">Node details</a></nav>
<section id="overview"><h2>Node Network Summary</h2><form id="filters" class="filters"><label class="search">Search<input id="search" type="search" placeholder="Node, address or VLAN" autocomplete="off"></label><label>Port bond mode<select id="port-mode"><option value="">All modes</option><option>Fixed</option><option>Aggregate</option><option>Not applicable</option><option>Unknown</option></select></label><label>Network<select id="network"><option value="">All networks</option><option>Grid</option><option>Client</option><option>Admin</option></select></label><label>Network bond mode<select id="bond-mode"><option value="">All modes</option><option>LACP</option><option>Active-Backup</option><option>Independent</option><option>Unknown</option><option>Not observed</option></select></label><label>VLAN<select id="vlan"><option value="">All VLANs</option></select></label><label class="toggle"><input id="attention" type="checkbox">Attention only</label><button class="reset" type="reset">Reset filters</button></form><div class="results"><span id="result-count" role="status" aria-live="polite"></span><span>Port bond mode: topology inference. Network bond mode: observed kernel evidence.</span></div><div class="table-scroll"><table id="comparison"><thead><tr><th scope="col" data-sort="node"><button type="button">Node <span aria-hidden="true">&#8597;</span></button></th><th scope="col" data-sort="mode"><button type="button">Port bond mode <span aria-hidden="true">&#8597;</span></button></th><th scope="col" data-sort="Grid"><button type="button">Grid Network / VLAN <span aria-hidden="true">&#8597;</span></button></th><th scope="col" data-sort="Client"><button type="button">Client Network / VLAN <span aria-hidden="true">&#8597;</span></button></th><th scope="col" data-sort="Admin"><button type="button">Admin Network / VLAN <span aria-hidden="true">&#8597;</span></button></th><th scope="col" data-sort="issues"><button type="button">Attention <span aria-hidden="true">&#8597;</span></button></th></tr></thead><tbody></tbody></table></div></section>
<section id="node-details"><h2>Node Details</h2><div id="details"></div></section><div class="notice">Runtime evidence is not a copy of the Appliance Installer settings. Fixed port bond mode can use LACP or Active-Backup network bonding. A missing interface is not proof that its network was disabled. Negotiated speeds do not establish the configured Auto/fixed link-speed setting.</div></main><footer><div class="shell">Point-in-time observations, not an overall grid-health verdict. Reports contain infrastructure data; store and share securely.</div></footer>
<script id="report-data" type="application/json">__SG_DATA__</script><script>
'use strict';
const report=JSON.parse(document.getElementById('report-data').textContent);
const byId=id=>document.getElementById(id);
const collator=new Intl.Collator(undefined,{numeric:true,sensitivity:'base'});
const el=(tag,text,className)=>{const item=document.createElement(tag);if(text!==undefined&&text!==null)item.textContent=String(text);if(className)item.className=className;return item;};
const value=item=>item===null||item===undefined||item===''?'Unknown':String(item);
const networks=node=>node.Networks||[];
const network=(node,name)=>networks(node).find(item=>item.Network===name);
const vlanText=item=>!item||!item.Present?'Not observed':value(item.Vlan);
const bondText=item=>!item||!item.Present?'Not observed':value(item.NetworkBondMode);
const attention=node=>node.Summary.NeedsReview===true;
const nodeIds=new Map(report.nodes.map((node,index)=>[node,'node-'+index]));
const badge=(text,kind)=>el('span',text,'badge'+(kind?' '+kind:''));
let sortKey='node',sortDirection=1,dashboardFilter='all';
for(const [label,text] of [['Primary Admin Node',report.target||'Not recorded'],['Generated',report.generated],['Source',report.source],['Version',report.version]]){const item=el('span');item.append(el('strong',label+': '),document.createTextNode(text));byId('metadata').append(item);}
if(report.originalGenerated){const item=el('span');item.append(el('strong','Original report generated: '),document.createTextNode(report.originalGenerated));byId('metadata').append(item);}
const counts=[['Nodes observed',report.nodes.length,'all'],['Fixed',report.nodes.filter(node=>node.Summary.PortBondMode==='Fixed').length,'fixed'],['Aggregate',report.nodes.filter(node=>node.Summary.PortBondMode==='Aggregate').length,'aggregate'],['Unknown mode',report.nodes.filter(node=>node.Summary.PortBondMode==='Unknown').length,'unknown'],['Needs review',report.nodes.filter(attention).length,'attention'],['Incomplete',report.nodes.filter(node=>attention(node)&&!node.Summary.DataComplete).length,'incomplete']];
for(const [label,count,key] of counts){const item=el('button',null,'stat'+(count&&['Needs review','Incomplete'].includes(label)?' attention':''));item.type='button';item.dataset.filter=key;item.setAttribute('aria-pressed','false');item.setAttribute('aria-controls','comparison details');const description=key==='all'?'Show all '+count+' observed nodes':'Show '+count+' nodes: '+label;item.setAttribute('aria-label',description);item.title=description;item.append(el('strong',count),el('span',label));item.addEventListener('click',()=>applyDashboardFilter(key));byId('stats').append(item);}
function applyDashboardFilter(key){const next=dashboardFilter===key?'all':key;for(const id of ['search','port-mode','network','bond-mode','vlan'])byId(id).value='';byId('attention').checked=false;sortKey='node';sortDirection=1;dashboardFilter=next;if(next==='fixed')byId('port-mode').value='Fixed';if(next==='aggregate')byId('port-mode').value='Aggregate';if(next==='unknown')byId('port-mode').value='Unknown';if(next==='attention'||next==='incomplete')byId('attention').checked=true;render();}
function updateDashboardSelection(){if(dashboardFilter==='fixed'&&byId('port-mode').value!=='Fixed'||dashboardFilter==='aggregate'&&byId('port-mode').value!=='Aggregate'||dashboardFilter==='unknown'&&byId('port-mode').value!=='Unknown'||['attention','incomplete'].includes(dashboardFilter)&&!byId('attention').checked)dashboardFilter='';if(dashboardFilter==='all'&&(['search','port-mode','network','bond-mode','vlan'].some(id=>byId(id).value)||byId('attention').checked))dashboardFilter='';for(const button of byId('stats').querySelectorAll('button'))button.setAttribute('aria-pressed',String(button.dataset.filter===dashboardFilter));}
const notApplicable=report.nodes.filter(node=>node.Summary.PortBondStatus==='Skipped').length;
byId('coverage').textContent=report.nodes.length+' node(s) returned parsed evidence; '+notApplicable+' appliance port-mode assessments are not applicable (skipped). Unknown deployment labels require recollection or verified inventory, not guesses from names or MACs. Expected grid membership is not independently verified.';
for(const mode of ['N/A - VMware','N/A - Baremetal']){const option=el('option',mode);option.value=mode;byId('port-mode').append(option);}
if(report.gridIssues.length||report.otherOutput.length){const warning=byId('collection-warning');warning.hidden=false;warning.append(el('strong','Grid-wide collection / configuration observations'));const list=el('ul');for(const issue of report.gridIssues)list.append(el('li',issue));warning.append(list);if(report.otherOutput.length){const details=el('details');details.append(el('summary','Other collector output - check for unreachable nodes'),el('pre',report.otherOutput.join('\n')));warning.append(details);}}
for(const file of report.files){const button=el('button',file.label+' \u2193','download');button.type='button';button.addEventListener('click',()=>{const bytes=Uint8Array.from(atob(file.content),character=>character.charCodeAt(0));const url=URL.createObjectURL(new Blob([bytes],{type:file.name.endsWith('.csv')?'text/csv;charset=utf-8':'text/plain;charset=utf-8'}));const link=el('a');link.href=url;link.download=file.name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),10000);});byId('downloads').append(button);}
const vlans=[...new Set(report.nodes.flatMap(node=>networks(node).filter(item=>item.Present).map(vlanText)))].sort(collator.compare);
for(const vlan of vlans){const option=el('option',vlan);option.value=vlan;byId('vlan').append(option);}
const sortValue=node=>{if(sortKey==='node')return node.Summary.Node;if(sortKey==='mode')return node.Summary.PortBondMode;if(sortKey==='issues')return Number(node.Summary.IssueCount)+(attention(node)?0.1:0);return vlanText(network(node,sortKey));};
function makeTable(rows,columns){const wrapper=el('div',null,'table-scroll');const table=el('table');const head=el('thead');const header=el('tr');for(const [label] of columns){const cell=el('th',label);cell.scope='col';header.append(cell);}head.append(header);table.append(head);const body=el('tbody');for(const row of rows){const line=el('tr');for(const [,key] of columns)line.append(el('td',value(row[key])));body.append(line);}if(!rows.length){const line=el('tr'),cell=el('td','No evidence collected.','empty');cell.colSpan=columns.length;line.append(cell);body.append(line);}table.append(body);wrapper.append(table);return wrapper;}
function render(){updateDashboardSelection();const opened=new Set([...document.querySelectorAll('.node-detail[open]')].map(item=>item.id));const query=byId('search').value.trim().toLowerCase();const mode=byId('port-mode').value,scope=byId('network').value,bond=byId('bond-mode').value,vlan=byId('vlan').value;const filtered=report.nodes.filter(node=>{if(query&&!JSON.stringify(node).toLowerCase().includes(query))return false;if(mode&&node.Summary.PortBondMode!==mode)return false;if(byId('attention').checked&&!attention(node))return false;if(dashboardFilter==='incomplete'&&(node.Summary.DataComplete||!attention(node)))return false;if(scope||bond||vlan){const candidates=networks(node).filter(item=>!scope||item.Network===scope);if(!candidates.some(item=>(!bond||bondText(item)===bond)&&(!vlan||vlanText(item)===vlan)))return false;}return true;}).sort((first,second)=>{const firstValue=sortValue(first),secondValue=sortValue(second);const difference=typeof firstValue==='number'?firstValue-secondValue:collator.compare(String(firstValue),String(secondValue));return sortDirection*difference||collator.compare(first.Summary.Node,second.Summary.Node);});
byId('result-count').textContent=filtered.length+' of '+report.nodes.length+' nodes shown';const body=byId('comparison').tBodies[0];body.replaceChildren();const detailRoot=byId('details');detailRoot.replaceChildren();for(const header of document.querySelectorAll('th[data-sort]'))header.setAttribute('aria-sort',header.dataset.sort===sortKey?(sortDirection===1?'ascending':'descending'):'none');
for(const node of filtered){const row=el('tr');const name=el('td',null,'node-name');const link=el('a',node.Summary.Node);link.href='#'+nodeIds.get(node);link.addEventListener('click',()=>{byId(nodeIds.get(node)).open=true;});name.append(link);name.append(el('span','Deployment: '+value(node.Summary.Deployment),'subtle'));if(!node.Summary.DataComplete&&attention(node))name.append(el('span','Incomplete evidence','subtle'));row.append(name);const modeCell=el('td');modeCell.append(badge(node.Summary.PortBondMode,['Skipped','Unresolved'].includes(node.Summary.PortBondStatus)?'neutral':''),el('span',node.Summary.PortBondSource,'subtle'));row.append(modeCell);for(const networkName of ['Grid','Client','Admin']){const item=network(node,networkName),cell=el('td');cell.append(el('span',bondText(item),'network-mode'));const vlanValue=vlanText(item);cell.append(el('span',/^\d+$/.test(vlanValue)?'VLAN '+vlanValue:vlanValue,'vlan'));if(item&&item.Present)cell.append(el('span',(item.ParentBond==='None'?'Direct interface':value(item.ParentBond))+' / '+value(item.Observation),'subtle'));row.append(cell);}const issueCell=el('td');const finding=attention(node)?(Number(node.Summary.IssueCount)?node.Summary.IssueCount+' issue(s)':'Review'):node.Summary.PortBondStatus==='Skipped'?'Skipped - N/A':node.Summary.PortBondStatus==='Unresolved'?'Informational':'No detected issues';issueCell.append(badge(finding,attention(node)?'review':'neutral'));row.append(issueCell);body.append(row);
const details=el('details',null,'node-detail');details.id=nodeIds.get(node);details.open=opened.has(details.id);const summary=el('summary');summary.append(el('span',node.Summary.Node,'node-title'),badge(node.Summary.PortBondMode,attention(node)?'review':'neutral'));details.append(summary);const content=el('div',null,'detail-body');content.append(el('p',node.Summary.PortBondEvidence,'notice'));if(node.Issues.length){const issues=el('ul',null,'issue-list');for(const issue of node.Issues)issues.append(el('li',issue));content.append(issues);}content.append(el('h3','Networks'),makeTable(networks(node),[['Network','Network'],['Network bond mode','NetworkBondMode'],['VLAN','Vlan'],['Interface','Interface'],['Parent bond','ParentBond'],['Member ports','Ports'],['Effective speed','Speed'],['MTU','Mtu'],['State','State'],['Address','Address'],['Path','Path']]));content.append(el('h3','Ports'));const strip=el('div',null,'port-strip');for(const port of node.Ports){const tile=el('div',null,'port'+(/^Down/.test(port.Status)?' down':''));tile.append(el('strong',port.Port),el('span',port.Status),el('span',value(port.Speed)));strip.append(tile);}content.append(strip,makeTable(node.Ports,[['Port','Port'],['Status','Status'],['Bond','Bond'],['Networks','Networks'],['Negotiated speed','Speed'],['Duplex','Duplex'],['Link detected','LinkDetected'],['MTU','Mtu'],['MAC','Mac'],['Aggregator','AggregatorId'],['Link failures','LinkFailures']]));content.append(el('h3','Bond Evidence'),makeTable(node.Bonds,[['Bond','Bond'],['Kernel mode','Mode'],['Networks','Networks'],['Members up','MembersUp'],['Effective speed','EffectiveSpeed'],['Kernel speed','KernelSpeed'],['Active member','ActiveSlave'],['LACP partner','LacpPartnerMac'],['LACP rate','LacpRate'],['Hash policy','HashPolicy'],['Members','Members']]));details.append(content);detailRoot.append(details);}
if(!filtered.length){const row=el('tr'),cell=el('td','No nodes match the selected filters.','empty');cell.colSpan=6;row.append(cell);body.append(row);detailRoot.append(el('p','No nodes match the selected filters.','empty'));}for(const node of filtered){if(node.Notes&&node.Notes.length){const list=el('ul');for(const note of node.Notes)list.append(el('li',note));const noteBlock=el('div',null,'notice');noteBlock.append(el('strong','Applicability and visibility'),list);byId(nodeIds.get(node)).querySelector('.detail-body').prepend(noteBlock);}}}
byId('filters').addEventListener('submit',event=>event.preventDefault());byId('filters').addEventListener('input',render);byId('filters').addEventListener('change',render);byId('filters').addEventListener('reset',()=>{sortKey='node';sortDirection=1;dashboardFilter='all';setTimeout(render,0);});for(const header of document.querySelectorAll('th[data-sort]'))header.querySelector('button').addEventListener('click',()=>{sortDirection=sortKey===header.dataset.sort?-sortDirection:1;sortKey=header.dataset.sort;render();});render();
</script></body></html>
'@
    return $template.Replace('__SG_DATA__', $json)
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
        [void]$sb.AppendLine("  Port mode evidence: $($s.PortBondEvidence)")
        [void]$sb.AppendLine("  Deployment: $($s.Deployment)    Assessment: $($s.PortBondStatus)")
        foreach ($note in @($map.Notes)) { [void]$sb.AppendLine("  NOTE: $note") }
        if ($s.NeedsReview -and -not $s.DataComplete) { [void]$sb.AppendLine('  WARNING: required collection evidence is incomplete or unavailable.') }

        [void]$sb.AppendLine('  Networks:')
        [void]$sb.AppendLine((Format-SgIndentedTable -Rows $map.Networks -Property Network, Interface, ParentBond, Vlan, Ports, Speed, Mtu, State, Observation, Address, Path))

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
if ($NodeInventoryPath) { $script:SgNodeInventory = Import-SgNodeInventory -Path $NodeInventoryPath }
$timestamp = (Get-Date).ToString('yyyyMMddTHHmmss')
Write-Host "Invoke-SgNetworkPortReport version $($script:SgToolVersion)" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$outputDirResolved = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
$savedReport = $null

if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $rawOutputPath = ''
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "Input file not found: $InputPath" }
    Write-Host "Reading saved network evidence from $InputPath ..."
    if ([IO.Path]::GetExtension($InputPath) -in '.html', '.htm') {
        $savedReport = Read-SgNetworkReportEvidence -Path $InputPath
        $collectorLines = @()
        $sshHost = [string](Get-SgOptionalValue $savedReport 'target')
    }
    else {
        $collectorLines = [string[]]@(Get-Content -LiteralPath $InputPath)
        $sshHost = ''
    }
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

if ($null -ne $savedReport) {
    $nodeMaps = @(
        foreach ($map in $savedReport.nodes) {
            $core = Get-SgOptionalValue $map.Summary 'CoreDataComplete' $null
            if ($null -eq $core -and $map.Summary.DataComplete -eq $true) { $core = $true }
            $platform = @(Get-SgOptionalValue $map 'PlatformEvidence' @())
            $vlanSource = [string](Get-SgOptionalValue $map.Summary 'VlanSource' 'Unrecorded')
            Set-SgNodeReportAssessment -Map $map -PlatformLines $platform -CoreComplete $core -VlanSource $vlanSource
        }
    )
    $parsed = [pscustomobject]@{ Untagged = @(Get-SgOptionalValue $savedReport 'otherOutput' @()) }
}
else {
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

$script:SgAutomaticInventory = ConvertFrom-SgGridMetadata -Controller @($parsed.Controller)
$nodeMaps = @($parsed.Nodes | Sort-Object -Property Name | ForEach-Object { Get-SgNodeNetworkMap -Node $_ })
}
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

$htmlPath = Join-Path -Path $outputDirResolved -ChildPath "${timestamp}_sg-network-report.html"
$reportFiles = @{ 'Summary CSV' = $summaryCsv; 'Bond detail CSV' = $bondCsv; 'Port detail CSV' = $portCsv; 'Text report' = $textPath }
$reportSource = if ($savedReport) { 'Saved HTML evidence; no new collection' } elseif ($InputPath) { 'Saved raw collection' } else { 'SSH collection' }
$originalGenerated = if ($savedReport) { [string](Get-SgOptionalValue $savedReport 'originalGenerated' (Get-SgOptionalValue $savedReport 'generated')) } else { '' }
if ($savedReport -and -not $originalGenerated) { $originalGenerated = [string](Get-SgOptionalValue $savedReport 'generated') }
$htmlReport = Format-SgNetworkHtmlReport -NodeMaps $nodeMaps -GridIssues $gridIssues -Untagged $parsed.Untagged -Target $sshHost -Source $reportSource -OriginalGenerated $originalGenerated -ReportFiles $reportFiles
Set-Content -LiteralPath $htmlPath -Value $htmlReport -Encoding UTF8

Write-Host ''
$columns = @('Node', 'PortBondMode') + @($script:SgNetworkInterfaces.Keys) + @('Issues')
@(Get-SgOverviewRows -NodeMaps $nodeMaps) | Format-Table -Property $columns -AutoSize | Out-String -Width 250 | Write-Host
$issueTotal = $gridIssues.Count + (@($nodeMaps | ForEach-Object { $_.Issues }) | Measure-Object).Count
if ($issueTotal -gt 0) {
    Write-Warning "$issueTotal issue(s) detected - see the ISSUES section of the text report."
}

# Post-run cleanup retains every report and removes only newly collected raw evidence.
# A file supplied with -InputPath is never deleted.
$intermediateFiles = @()
if ($rawOutputPath) { $intermediateFiles += $rawOutputPath }
if ($KeepIntermediateOutputs) {
    if ($rawOutputPath) { Write-Host "Raw output  : $rawOutputPath" }
}
else {
    foreach ($file in $intermediateFiles) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    }
    if ($rawOutputPath) { Write-Host 'Newly collected raw output removed; use -KeepIntermediateOutputs to retain it.' }
}
Write-Host "Summary CSV : $summaryCsv"
Write-Host "Bonds CSV   : $bondCsv"
Write-Host "Ports CSV   : $portCsv"
Write-Host "Text report : $textPath"
Write-Host "HTML report : $htmlPath" -ForegroundColor Cyan
if ($OpenReport) { Start-Process -FilePath $htmlPath }

#endregion
