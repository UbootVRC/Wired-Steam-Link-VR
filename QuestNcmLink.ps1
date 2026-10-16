<#
    Quest USB NCM Link
    ------------------
    Puts the headset's USB port into NCM (USB Ethernet) mode and gives the
    resulting link a working IPv4 configuration, so Steam Link runs over the
    cable instead of Wi-Fi.

    Why this works the way it does (measured on a Quest 2 "hollywood",
    Android 14, build 52202280028100150, USB gadget HAL V2_0):

      * "svc usb setFunctions ncm,adb" is ALWAYS rejected. UsbService calls
        Preconditions.checkArgument(UsbManager.areSettableFunctions(f)), and
        that requires exactly ONE function bit. Passing two throws
        IllegalArgumentException before the gadget HAL is ever reached.
        ADB does not need to be listed - UsbDeviceManager ORs it in by itself
        whenever adb_enabled is true. So the correct call is plain "ncm".

      * RNDIS is not an option on this hardware. The gadget HAL answers
        setCurrentUsbFunctionsCb with status:4 (ERROR) and the framework falls
        back to charging. NCM is the only network gadget available.

      * Android's Tethering service cannot address the link: the build ships
        tetherableNcmRegexs = [] (empty), which is the exact cause of
        "ERROR could not enable IpServer for function NCM" in logcat.
        That message is a red herring - it is not what makes the link work.

      * What DOES work: the Ethernet service has an interface filter of
        ((eth\d)|(usb\d)), so it claims usb0 as a CLIENT interface and runs a
        DHCP client on it. The headset sits there broadcasting DHCPDISCOVER
        forever. All that is missing is a DHCP server on the PC end - which is
        what this script provides. On lease, Android brings up a real ETHERNET
        network and routes over the cable.

      * The Ethernet network must become the DEFAULT network or apps will keep
        using Wi-Fi. Android only prefers it once it VALIDATES, which needs
        real internet - hence the NAT below. Without NAT you would have to turn
        the headset's Wi-Fi off instead.

      * Any active VpnService on the headset captures uid 0-99999 and swallows
        all app traffic regardless of routing, so the cable goes unused while
        every check still reports success. Rare on a headset, but if the link
        looks perfect and Steam Link still cannot see the PC, that is the
        thing to check.
#>

[CmdletBinding()]
param(
    # Wi-Fi-off mode: rather than giving the headset internet through the cable
    # (which needs Windows NAT), switch the headset's Wi-Fi off so the cable is
    # its only route. Wi-Fi is switched back on when this script exits.
    # This is also the automatic fallback when Windows NAT is unavailable.
    # -NoInternet is accepted as an older name for the same switch.
    [Alias('NoInternet')]
    [switch]$WifiOff
)

$ErrorActionPreference = 'Continue'

# ----------------------------- configuration -----------------------------
$Subnet     = '192.168.42'
$PcIp       = "$Subnet.1"
$HeadsetIp  = "$Subnet.2"
$PrefixLen  = 24
$LinkCidr   = "$Subnet.0/$PrefixLen"
$DnsServers = @('1.1.1.1', '8.8.8.8')   # NATed out; WinNAT has no DNS proxy
$LeaseSecs  = 3600
$NatName    = 'QuestNcmLink'
$FwRuleName = 'Quest NCM Link (USB)'
$FwDhcpName = 'Quest NCM Link (DHCP)'
# -------------------------------------------------------------------------

function Say([string]$m) { Write-Host "  $m" }
function Ok ([string]$m) { Write-Host "  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "  $m" -ForegroundColor Red }

Write-Host ""
Write-Host "  Quest USB NCM Link" -ForegroundColor Cyan
Write-Host "  =================="
Write-Host ""

# State we need to undo on exit.
$script:Adb        = $null
$script:Serial     = $null
$script:AdapterIdx = $null
$script:NatMade    = $false
$script:FwMade     = $false
$script:FwDhcpMade = $false
$script:IpMade     = $false
$script:DhcpJob    = $null
$script:WifiOffByUs = $false

# Windows 10 ships the UsbNcm host driver, but its usbncm.inf only matches
# USB\MS_COMP_WINNCM (a Microsoft OS descriptor the Quest does not send). The
# generic USB\Class_02&SubClass_0d&Prot_00 line is there, commented out, and
# Windows 11 is what turned it on. So on Windows 10 the headset's NCM function
# lands under "Other devices" with Code 28. This binds the inbox driver to it
# the same way Device Manager's "Let me pick from a list" would.
$UsbNcmBindSource = @'
using System;
using System.Runtime.InteropServices;

public static class QuestNcmBind
{
    const uint DI_ENUMSINGLEINF             = 0x00010000;
    const uint DI_FLAGSEX_ALLOWEXCLUDEDDRVS = 0x00000800;
    const uint SPDIT_CLASSDRIVER            = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DEVINSTALL_PARAMS
    {
        public uint cbSize; public uint Flags; public uint FlagsEx;
        public IntPtr hwndParent; public IntPtr InstallMsgHandler; public IntPtr InstallMsgHandlerContext;
        public IntPtr FileQueue; public UIntPtr ClassInstallReserved; public uint Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DriverPath;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DRVINFO_DATA
    {
        public uint cbSize; public uint DriverType; public UIntPtr Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string MfgName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProviderName;
        public long DriverDate; public ulong DriverVersion;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instanceId, IntPtr hwnd, uint flags, ref SP_DEVINFO_DATA dev);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInstallParams(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DEVINSTALL_PARAMS p);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetDeviceInstallParams(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DEVINSTALL_PARAMS p);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref SP_DEVINFO_DATA dev, uint type);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiEnumDriverInfo(IntPtr set, ref SP_DEVINFO_DATA dev, uint type, uint index, ref SP_DRVINFO_DATA drv);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetSelectedDriver(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool DiInstallDevice(IntPtr hwnd, IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv, uint flags, out bool needReboot);

    static Exception Win32(string what)
    {
        return new Exception(what + " failed: " + new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
    }

    // Offers the device exactly one INF and installs the named model from it,
    // even though none of that INF's hardware IDs match the device.
    public static string Bind(string instanceId, string infPath, string description)
    {
        IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
        if (set == new IntPtr(-1)) throw Win32("SetupDiCreateDeviceInfoList");
        try
        {
            SP_DEVINFO_DATA dev = new SP_DEVINFO_DATA();
            dev.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref dev)) throw Win32("SetupDiOpenDeviceInfo");

            SP_DEVINSTALL_PARAMS p = new SP_DEVINSTALL_PARAMS();
            p.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINSTALL_PARAMS));
            if (!SetupDiGetDeviceInstallParams(set, ref dev, ref p)) throw Win32("SetupDiGetDeviceInstallParams");
            p.Flags      |= DI_ENUMSINGLEINF;
            p.FlagsEx    |= DI_FLAGSEX_ALLOWEXCLUDEDDRVS;
            p.DriverPath  = infPath;
            if (!SetupDiSetDeviceInstallParams(set, ref dev, ref p)) throw Win32("SetupDiSetDeviceInstallParams");

            if (!SetupDiBuildDriverInfoList(set, ref dev, SPDIT_CLASSDRIVER)) throw Win32("SetupDiBuildDriverInfoList");

            SP_DRVINFO_DATA drv = new SP_DRVINFO_DATA();
            drv.cbSize = (uint)Marshal.SizeOf(typeof(SP_DRVINFO_DATA));
            bool found = false;
            for (uint i = 0; SetupDiEnumDriverInfo(set, ref dev, SPDIT_CLASSDRIVER, i, ref drv); i++)
            {
                if (string.Equals(drv.Description, description, StringComparison.OrdinalIgnoreCase)) { found = true; break; }
            }
            if (!found) throw new Exception("'" + description + "' not offered by " + infPath);

            if (!SetupDiSetSelectedDriver(set, ref dev, ref drv)) throw Win32("SetupDiSetSelectedDriver");
            bool reboot;
            if (!DiInstallDevice(IntPtr.Zero, set, ref dev, ref drv, 0, out reboot)) throw Win32("DiInstallDevice");
            return drv.Description;
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@

# Returns the instance ID of a present NCM function that Windows found no
# driver for (Code 28), or $null.
function Find-DriverlessNcm {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Problem -eq 'CM_PROB_FAILED_INSTALL' -and
            ($_.CompatibleID -match '^USB\\Class_02&SubClass_0D')
        } |
        Select-Object -First 1 -ExpandProperty InstanceId
}

# First host address in the headset's subnet that is not the headset's own.
function Get-PeerAddress([string]$Ip, [int]$Prefix) {
    $b = [Net.IPAddress]::Parse($Ip).GetAddressBytes(); [Array]::Reverse($b)
    $n    = [uint64][BitConverter]::ToUInt32($b, 0)
    $net  = $n - ($n % ([uint64]1 -shl (32 - $Prefix)))
    $peer = $net + 1
    if ($peer -eq $n) { $peer++ }
    $toIp = { param($v) $o = [BitConverter]::GetBytes([uint32]$v); [Array]::Reverse($o); ([Net.IPAddress]$o).ToString() }
    [pscustomobject]@{ Pc = (& $toIp $peer); Cidr = "$(& $toIp $net)/$Prefix" }
}

function Bind-UsbNcmDriver([string]$InstanceId) {
    if (-not ('QuestNcmBind' -as [type])) { Add-Type -TypeDefinition $UsbNcmBindSource }
    [QuestNcmBind]::Bind($InstanceId, "$env:windir\INF\usbncm.inf", 'UsbNcm Host Device')
}

function Restore-Everything {
    Write-Host ""
    Say "Restoring..."

    if ($script:DhcpJob) {
        Stop-Job  $script:DhcpJob -ErrorAction SilentlyContinue
        Remove-Job $script:DhcpJob -Force -ErrorAction SilentlyContinue
    }
    if ($script:NatMade) {
        Remove-NetNat -Name $NatName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($script:FwMade) {
        Remove-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
    }
    if ($script:FwDhcpMade) {
        Remove-NetFirewallRule -DisplayName $FwDhcpName -ErrorAction SilentlyContinue
    }
    if ($script:IpMade -and $script:AdapterIdx) {
        Remove-NetIPAddress -InterfaceIndex $script:AdapterIdx -IPAddress $PcIp `
            -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 `
            -Dhcp Enabled -ErrorAction SilentlyContinue
    }
    if ($script:Serial) {
        if ($script:WifiOffByUs) {
            & $script:Adb -s $script:Serial shell svc wifi enable 2>&1 | Out-Null
            Say "Headset Wi-Fi switched back on."
        }
        # Blank function list = back to charging (+ adb).
        & $script:Adb -s $script:Serial shell svc usb setFunctions 2>&1 | Out-Null
    }
    Ok "Done. USB is back to normal."
}

try {
    # --------------------------------------------------------------- 1. adb
    # Prefer a copy shipped next to this script so the package is self-
    # contained - no C:\Android folder and no system PATH editing. Only
    # adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll are needed (~6.6 MB).
    $script:Adb = $null
    $candidates = @(
        (Join-Path $PSScriptRoot 'adb.exe'),
        (Join-Path $PSScriptRoot 'platform-tools\adb.exe'),
        (Join-Path $PSScriptRoot 'Android\platform-tools\adb.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $script:Adb = $c; break }
    }
    if (-not $script:Adb) {
        $onPath = Get-Command adb -ErrorAction SilentlyContinue
        if ($onPath) { $script:Adb = $onPath.Source }
    }
    if (-not $script:Adb) {
        Fail "[X] adb was not found."
        Say "    Put adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll in the same"
        Say "    folder as this script, or have adb on your PATH."
        return
    }
    & $script:Adb start-server 2>&1 | Out-Null

    $script:Serial = & $script:Adb devices |
        Where-Object { $_ -match '^\S+\s+device\s*$' -and $_ -notmatch ':' } |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Select-Object -First 1

    if (-not $script:Serial) {
        Fail "[X] No headset found on USB."
        Say "    - Is the cable plugged in?"
        Say "    - Did you accept 'Allow USB debugging' in the headset?"
        return
    }
    # This output gets pasted into bug reports, so keep the user's Windows
    # username and full device serial out of it. $script:Serial itself is
    # untouched - only what is printed is shortened.
    $serialShown = if ($script:Serial.Length -gt 8) {
        $script:Serial.Substring(0, 4) + '...' + $script:Serial.Substring($script:Serial.Length - 4)
    } else {
        $script:Serial
    }
    $adbShown = if ($script:Adb -like "$PSScriptRoot*") {
        '.\' + (Split-Path $script:Adb -Leaf) + '  (bundled)'
    } else {
        (Split-Path $script:Adb -Leaf) + '  (from PATH)'
    }
    Say "[1/5] Headset on USB: $serialShown"
    Say "      using adb: $adbShown"

    # ------------------------------------------------- 2. switch USB to NCM
    # Single function only - see the header comment.
    Say "[2/5] Switching USB to NCM..."
    & $script:Adb -s $script:Serial shell svc usb setFunctions ncm 2>&1 | Out-Null

    $adapter    = $null
    $bindTried  = $false
    $bindFailed = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'UsbNcm|NCM' -and $_.Status -eq 'Up' } |
            Select-Object -First 1
        if ($adapter) { break }

        # Windows 10 only: see Find-DriverlessNcm. Once bound, Windows
        # remembers the driver for this headset, so this runs once per PC.
        if (-not $bindTried) {
            $ncmDev = Find-DriverlessNcm
            if ($ncmDev) {
                $bindTried = $true
                Say "      No driver for the NCM device (Windows 10) - installing"
                Say "      the built-in UsbNcm driver for it..."
                try {
                    Bind-UsbNcmDriver $ncmDev | Out-Null
                    Ok  "      UsbNcm driver installed."
                } catch {
                    $bindFailed = $_.Exception.Message
                    Warn "      Could not install it: $bindFailed"
                }
            }
        }
    }
    if (-not $adapter) {
        Fail "      Windows never showed a UsbNcm adapter."
        if ($bindFailed) {
            Say  "      The NCM device has no driver. Install it by hand while"
            Say  "      this step is running: Device Manager > Other devices >"
            Say  "      the NCM device > Update driver > Browse my computer >"
            Say  "      Let me pick > Network adapters > Microsoft >"
            Say  "      UsbNcm Host Device. Then run this again."
        }
        Say  "      Check Device Manager > Network adapters for a yellow flag."
        Say  "      Confirm the gadget came up on the headset with:"
        Say  "        adb shell svc usb getFunctions      (expect: ncm)"
        return
    }
    $script:AdapterIdx = $adapter.ifIndex
    $pcMac = ($adapter.MacAddress -replace '-', ':').ToLower()
    Ok "      Windows adapter: '$($adapter.Name)' ($($adapter.LinkSpeed))"

    # --------------------------------------------------- 3. address PC side
    # Newer Quest builds keep a fixed address on usb0 for Steam Link's own
    # wired mode (10.86.13.37/29 on a Quest 2, Android 14 UP1A.231005.007.A1)
    # and then run no DHCP client, so a DISCOVER never comes. When the headset
    # already has an address, join its subnet instead of serving DHCP.
    $StaticHeadset = $false
    for ($i = 0; $i -lt 4; $i++) {
        $addr = & $script:Adb -s $script:Serial shell "ip -o -4 addr show usb0" 2>&1
        if ("$addr" -match 'inet (\d+\.\d+\.\d+\.\d+)/(\d+)') {
            $peer      = Get-PeerAddress $Matches[1] ([int]$Matches[2])
            $HeadsetIp = $Matches[1]
            $PrefixLen = [int]$Matches[2]
            $PcIp      = $peer.Pc
            $LinkCidr  = $peer.Cidr
            $StaticHeadset = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($StaticHeadset) {
        Say "      Headset already has a fixed address ($HeadsetIp/$PrefixLen),"
        Say "      so this PC joins that network instead of serving DHCP."
    }

    Say "[3/5] Configuring the PC end ($PcIp/$PrefixLen)..."
    Get-NetIPAddress -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $script:AdapterIdx -AddressFamily IPv4 `
        -Dhcp Disabled -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $script:AdapterIdx -IPAddress $PcIp `
        -PrefixLength $PrefixLen -ErrorAction Stop | Out-Null
    $script:IpMade = $true

    # Steam's firewall rules usually cover Private but not Public networks.
    Set-NetConnectionProfile -InterfaceIndex $script:AdapterIdx `
        -NetworkCategory Private -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $FwRuleName -Direction Inbound -Action Allow `
        -RemoteAddress $LinkCidr -Profile Any -ErrorAction SilentlyContinue | Out-Null
    $script:FwMade = $true

    # DHCP has to be allowed separately. A DISCOVER arrives from 0.0.0.0 to
    # 255.255.255.255, so it never matches the subnet-scoped rule above, and
    # Windows has no built-in allow for inbound UDP 67 (only 68, for the
    # client). Machines running Hyper-V/ICS happen to have one already, which
    # is why this is only noticed on editions without it, such as Home.
    if (-not $StaticHeadset) {
        New-NetFirewallRule -DisplayName $FwDhcpName -Direction Inbound -Action Allow `
            -Protocol UDP -LocalPort 67 -Profile Any -ErrorAction SilentlyContinue | Out-Null
        $script:FwDhcpMade = $true
    }

    # Internet over the cable needs Windows NAT. The MSFT_NetNat CIM class
    # ships with Hyper-V, so Windows Home generally does not have it and
    # New-NetNat fails with "Invalid class". Check before trying, so the
    # message is something a user can act on. A fixed-address headset has no
    # gateway on usb0, so NAT would do nothing for it.
    if (-not $WifiOff -and -not $StaticHeadset) {
        $natClass = Get-CimClass -Namespace root/StandardCimv2 `
            -ClassName MSFT_NetNat -ErrorAction SilentlyContinue
        if (-not $natClass) {
            Warn "      Windows NAT is not available on this PC."
            Warn "      (It ships with Hyper-V, so Windows Home usually"
            Warn "       does not have it. This is not a problem.)"
        } else {
            Get-NetNat -Name $NatName -ErrorAction SilentlyContinue |
                Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
            try {
                New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $LinkCidr `
                    -ErrorAction Stop | Out-Null
                $script:NatMade = $true
                Ok "      NAT is up - the headset gets internet over the cable"
            } catch {
                Warn "      Could not create NAT: $($_.Exception.Message)"
            }
        }
    }

    # ------------------------------------------------- 4. serve DHCP to usb0
    $DhcpServer = {
        param($PcIp, $OfferIp, $PrefixLen, $DnsServers, $LeaseSecs, $PcMac)

        $srv = [Net.IPAddress]::Parse($PcIp)
        $off = [Net.IPAddress]::Parse($OfferIp)
        $mb  = New-Object byte[] 4
        for ($b = 0; $b -lt 4; $b++) {
            $bits = [Math]::Max(0, [Math]::Min(8, $PrefixLen - ($b * 8)))
            $mb[$b] = [byte](((0xFF -shl (8 - $bits)) -band 0xFF))
        }

        $rx = New-Object Net.Sockets.Socket('InterNetwork', 'Dgram', 'Udp')
        $rx.SetSocketOption('Socket', 'ReuseAddress', $true)
        $rx.EnableBroadcast = $true
        try { $rx.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 67))) }
        catch { Write-Output "BIND-FAILED: $($_.Exception.Message)"; return }

        function New-Tx($ip) {
            $s = New-Object Net.Sockets.Socket('InterNetwork', 'Dgram', 'Udp')
            $s.SetSocketOption('Socket', 'ReuseAddress', $true)
            $s.EnableBroadcast = $true
            $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ip), 0)))
            return $s
        }
        $tx = $null

        function Get-Opt([byte[]]$p, [int]$code) {
            $i = 240
            while ($i -lt $p.Length) {
                $c = $p[$i]
                if ($c -eq 255) { return $null }
                if ($c -eq 0) { $i++; continue }
                $len = $p[$i + 1]
                if ($c -eq $code) { return $p[($i + 2)..($i + 1 + $len)] }
                $i += 2 + $len
            }
            return $null
        }

        function Build-Reply([byte[]]$req, [byte]$type) {
            $r = New-Object byte[] 320
            $r[0] = 2; $r[1] = 1; $r[2] = 6; $r[3] = 0
            [Array]::Copy($req, 4, $r, 4, 4)                       # xid
            [Array]::Copy($req, 10, $r, 10, 2)                     # flags
            [Array]::Copy($off.GetAddressBytes(), 0, $r, 16, 4)    # yiaddr
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, 20, 4)    # siaddr
            [Array]::Copy($req, 28, $r, 28, 16)                    # chaddr
            $r[236] = 99; $r[237] = 130; $r[238] = 83; $r[239] = 99
            $o = 240
            $r[$o++] = 53; $r[$o++] = 1; $r[$o++] = $type
            $r[$o++] = 54; $r[$o++] = 4
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, $o, 4); $o += 4
            $r[$o++] = 51; $r[$o++] = 4
            $lb = [BitConverter]::GetBytes([uint32]$LeaseSecs); [Array]::Reverse($lb)
            [Array]::Copy($lb, 0, $r, $o, 4); $o += 4
            $r[$o++] = 1; $r[$o++] = 4
            [Array]::Copy($mb, 0, $r, $o, 4); $o += 4
            $r[$o++] = 3; $r[$o++] = 4
            [Array]::Copy($srv.GetAddressBytes(), 0, $r, $o, 4); $o += 4
            $r[$o++] = 6; $r[$o++] = [byte](4 * $DnsServers.Count)
            foreach ($d in $DnsServers) {
                [Array]::Copy(([Net.IPAddress]::Parse($d)).GetAddressBytes(), 0, $r, $o, 4); $o += 4
            }
            $r[$o++] = 255
            return , $r[0..($o - 1)]
        }

        $buf = New-Object byte[] 1500
        Write-Output "DHCP server listening (offering $OfferIp)"

        while ($true) {
            if (-not $rx.Poll(1000000, 'SelectRead')) { continue }
            $remote = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
            try { $n = $rx.ReceiveFrom($buf, [ref]$remote) } catch { continue }
            if ($n -lt 240) { continue }
            $pkt = $buf[0..($n - 1)]
            if ($pkt[0] -ne 1) { continue }
            $t = Get-Opt $pkt 53
            if (-not $t) { continue }

            $mac = ($pkt[28..33] | ForEach-Object { $_.ToString('x2') }) -join ':'
            if ($mac -eq $PcMac) { continue }      # Windows' own client on this NIC
            if ($t[0] -ne 1 -and $t[0] -ne 3) { continue }

            $isDiscover = ($t[0] -eq 1)
            # Step 5's diagnosis keys on this word, so it has to be logged.
            Write-Output "$(if($isDiscover){'DISCOVER'}else{'REQUEST '}) <- $mac"
            $reply = Build-Reply $pkt $(if ($isDiscover) { 2 } else { 5 })

            # Renewals arrive unicast with ciaddr set; answer those directly.
            $ciaddr = [Net.IPAddress]::new([byte[]]$pkt[12..15])
            if (-not $isDiscover -and $ciaddr.ToString() -ne '0.0.0.0') {
                $dest = New-Object Net.IPEndPoint($ciaddr, 68)
            } else {
                $dest = New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 68)
            }

            for ($try = 0; $try -lt 2; $try++) {
                try {
                    if (-not $tx) { $tx = New-Tx $PcIp }
                    [void]$tx.SendTo($reply, $dest)
                    Write-Output "$(if($isDiscover){'OFFER'}else{'ACK  '}) -> $mac"
                    break
                } catch {
                    # Interface may still be settling right after re-enumeration.
                    if ($tx) { $tx.Close(); $tx = $null }
                    Start-Sleep -Milliseconds 400
                }
            }
        }
    }

    if ($StaticHeadset) {
        Say "[4/5] No DHCP needed - the headset has a fixed address."
    } else {
        Say "[4/5] Serving DHCP on the link..."
        $script:DhcpJob = Start-Job -Name 'QuestNcmDhcp' -ScriptBlock $DhcpServer -ArgumentList `
            $PcIp, $HeadsetIp, $PrefixLen, $DnsServers, $LeaseSecs, $pcMac
    }

    # ------------------------------------------------ 5. wait for the lease
    $leased  = $false
    $dhcpLog = @()
    if ($StaticHeadset) {
        # No lease to wait for; just prove the cable carries traffic. The
        # first ping or two can be lost while ARP resolves.
        Say "[5/5] Checking the headset answers over the cable..."
        for ($i = 0; $i -lt 5 -and -not $leased; $i++) {
            $leased = Test-Connection -ComputerName $HeadsetIp -Count 1 -Quiet
        }
    } else {
        Say "[5/5] Waiting for the headset to take the lease..."
    }
    for ($i = 0; $i -lt 40 -and -not $StaticHeadset; $i++) {
        Start-Sleep -Seconds 2
        $dhcpLog += Receive-Job $script:DhcpJob -ErrorAction SilentlyContinue
        $addr = & $script:Adb -s $script:Serial shell "ip -o -4 addr show usb0" 2>&1
        if ("$addr" -match [regex]::Escape($HeadsetIp)) { $leased = $true; break }

        # Say something useful rather than sitting silent for 80 seconds.
        if ($i -eq 7) {
            if ($dhcpLog -match 'BIND-FAILED') {
                Warn "      Could not listen on UDP 67 - something else owns it"
                Warn "      (another DHCP server, or Internet Connection Sharing)."
            } elseif (-not ($dhcpLog -match 'DISCOVER')) {
                Say  "      Nothing heard from the headset yet, still waiting..."
            } else {
                Say  "      Headset is asking, waiting for it to accept..."
            }
        }
    }

    # Without NAT the cable cannot pass Android's internet check, so Wi-Fi
    # stays the default network and the cable goes unused. Switching Wi-Fi off
    # makes the cable the only route. Put back in Restore-Everything.
    # Not for a fixed-address headset: that network has no gateway, so it
    # never becomes the default either way. Steam Link uses it directly.
    if ($leased -and -not $script:NatMade -and -not $StaticHeadset) {
        Say "      No internet on the cable, so switching the headset's"
        Say "      Wi-Fi off to force traffic onto it."
        & $script:Adb -s $script:Serial shell svc wifi disable 2>&1 | Out-Null
        $script:WifiOffByUs = $true
        Start-Sleep -Seconds 5
    }

    Write-Host ""
    Write-Host "  ----------------------------------------------------------"
    if ($leased) {
        Ok "  Link is up."
        Write-Host ""
        Write-Host "        Headset : $HeadsetIp" -ForegroundColor White
        Write-Host "        This PC : $PcIp" -ForegroundColor White
        Write-Host ""

        # One dump, both questions asked of it.
        $conn = & $script:Adb -s $script:Serial shell "dumpsys connectivity" 2>&1
        $def  = $conn | Select-String '^Active default network'
        $eth  = $conn | Select-String 'Ethernet CONNECTED'

        if ($eth) { Ok "  Headset has an ETHERNET network on the cable." }
        Say "  $def"

        if ($StaticHeadset) {
            Say  "  The headset set this network up itself for Steam Link's"
            Say  "  wired mode. Wi-Fi is left as it is."
        } elseif ($script:NatMade) {
            Say  "  Give it ~15s to validate, then it becomes the default"
            Say  "  network on its own. You can leave Wi-Fi on."
        } else {
            Ok   "  Headset Wi-Fi is off, so the cable is its only route."
            Say  "  Steam Link does not need the headset to have internet."
            Say  "  Wi-Fi comes back when you press a key to exit."
        }
        Write-Host ""
        Say "  In Steam Link, connect to $PcIp"
    } elseif ($StaticHeadset) {
        Fail "  The headset has $HeadsetIp but does not answer over the cable."
        Write-Host ""
        Say "  Check that Windows has the address and the headset sees it:"
        Say "      Get-NetIPAddress -InterfaceIndex $($script:AdapterIdx) -AddressFamily IPv4"
        Say "      adb shell ping -I usb0 -c 3 $PcIp"
    } else {
        $dhcpLog += Receive-Job $script:DhcpJob -ErrorAction SilentlyContinue
        Fail "  The headset never took a lease."
        Write-Host ""

        if ($dhcpLog -match 'BIND-FAILED') {
            Say "  This PC could not listen for DHCP on UDP 67. Something else"
            Say "  already owns it - usually another DHCP server or Internet"
            Say "  Connection Sharing. Find it with:"
            Say "      Get-NetUDPEndpoint -LocalPort 67 | Select LocalAddress,OwningProcess"
        } elseif (-not ($dhcpLog -match 'DISCOVER')) {
            Say "  This PC never heard the headset ask for an address, which"
            Say "  narrows it to one of two things:"
            Say ""
            Say "   1. Security software is blocking inbound UDP 67. This script"
            Say "      adds a rule for it, so check a third-party firewall."
            Say "   2. The headset is not asking. Confirm with:"
            Say "        adb shell svc usb getFunctions       (expect: ncm)"
            Say "        adb logcat -d | findstr DhcpClient   (expect: DHCPDISCOVER)"
        } else {
            Say "  The headset asked and this PC answered, but the address never"
            Say "  took. Check what the headset ended up with:"
            Say "      adb shell ip -o addr show usb0"
        }
        Write-Host ""
        $dhcpLog | Select-Object -Last 8 | ForEach-Object { Say "   dhcp: $_" }
    }
    Write-Host "  ----------------------------------------------------------"

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "  Leave this window open while you play."
    Write-Host "  Press any key here to restore normal USB mode."
    Write-Host "  =========================================================="
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
finally {
    Restore-Everything
}
