# =====================================================================
#  Tonytheboi Auto Screenshare - combined Minecraft screenshare tool
#  Runs every check from the SS guide and writes an HTML report to the
#  Desktop. Also launches the external tools (services script, mod
#  analyzer, P1AE javaw, spokwn parsers, NirSoft tools, System Informer).
#
#  Run from CMD as admin:
#    powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\TonytheboiAutoScreenshare.ps1"
#  or, once hosted on GitHub:
#    powershell -ExecutionPolicy Bypass -Command "Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/tonytheboi/Tonytheboi-Auto-SS-Tool/main/TonytheboiAutoScreenshare.ps1')"
#
#  Read-only: nothing here deletes or changes the player's files, except
#  the [C] Cleanup option, which removes only what this tool downloaded.
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Tonytheboi Auto Screenshare must be run as Administrator.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    return
}

# ------------------------------ settings -----------------------------
$Script:Version   = '1.4'
$Script:ToolDir   = Join-Path $env:ProgramData 'TonytheboiAutoSS'
$Script:RecentHrs = 24          # "recent" window for most checks

# External tools (update these links when new versions come out)
$Script:Url = @{
    Services    = 'https://raw.githubusercontent.com/praiselily/lilith-ps/refs/heads/main/Services.ps1'
    ModAnalyzer = 'https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1'
    P1AE        = 'https://github.com/p1aegg/javaw/releases/download/v1.12/P1AE.Javaw.exe'
    SystemInformerRepo = 'winsiderss/systeminformer'   # official releases, signer checked before running
    # Extra public SS tools
    PrefetchParserRepo = 'spokwn/prefetch-parser'     # GitHub repo: newest release .exe is downloaded
    BamParserRepo      = 'spokwn/BAM-parser'
    WinPrefetchView    = 'https://www.nirsoft.net/utils/winprefetchview-x64.zip'
    LastActivityView   = 'https://www.nirsoft.net/utils/lastactivityview.zip'
}

# Name keywords that get a file/process flagged for a closer look (case-insensitive).
# A match is a lead, not proof - always check what it actually is.
$Script:CheatWords = @(
    'vape','slinky','whiteout','doomsday','ravenb','raven-b','liquidbounce','wurst','meteor-client',
    'aristois','novoline','rusherhack','future-client','konas','phobos','sigma5','entropy-client',
    'autoclick','auto-click','clicker','injector','inject','xenos','kdmapper','manualmap',
    'cleaner','privazer','bleachbit','ccleaner','usnjrnl','prefetchclean','hider','bypass','spoofer'
)

# Folders where jars are expected (game, launchers, Java installs)
$Script:KnownJarDirs = '(?i)\\\.minecraft\\|\\minecraft\\|\\\.lunarclient\\|\\lunarclient|\\badlion|\\\.feather|\\feather|\\prismlauncher\\|\\multimc|\\polymc|\\modrinthapp\\|\\curseforge\\|\\\.tlauncher|\\tlauncher|\\atlauncher|\\gdlauncher|\\salwyrr|\\labymod|\\java\\|\\jdk|\\jre|\\eclipse adoptium|\\zulu|\\microsoft\.4297127d64ec6|\\program files\\'

# Lines in PowerShell history that come from SS tools themselves (ignored)
$Script:SSUrls = '(?i)praiselily|YarpLetapStan|Lafferrr|p1aegg|Orbdiff|SSTool|Tonytheboi|spokwn|nirsoft'

# ------------------------------ native helpers -----------------------
if (-not ('SSNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SSNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, int ucchMax);
    [DllImport("ntdll.dll")]
    public static extern uint RtlGetCompressionWorkSpaceSize(ushort format, out uint bufferWorkspaceSize, out uint fragmentWorkspaceSize);
    [DllImport("ntdll.dll")]
    public static extern uint RtlDecompressBufferEx(ushort format, byte[] uncompressed, int uncompressedSize, byte[] compressed, int compressedSize, out int finalSize, byte[] workspace);
}
'@
}

# Map \Device\HarddiskVolumeN -> C:  and volume serial -> C:
$Script:DevMap = @{}
foreach ($d in [IO.DriveInfo]::GetDrives()) {
    $letter = $d.Name.TrimEnd('\')
    $sb = New-Object Text.StringBuilder 1024
    if ([SSNative]::QueryDosDevice($letter, $sb, 1024) -gt 0) { $Script:DevMap[$sb.ToString().ToUpper()] = $letter }
}
$Script:SerialMap = @{}
foreach ($ld in Get-CimInstance Win32_LogicalDisk) {
    if ($ld.VolumeSerialNumber) { $Script:SerialMap[$ld.VolumeSerialNumber.ToUpper()] = $ld.DeviceID }
}

function Convert-DevicePath([string]$p) {
    if (-not $p) { return $p }
    $up = $p.ToUpper()
    foreach ($k in $Script:DevMap.Keys) {
        if ($up.StartsWith($k + '\')) { return $Script:DevMap[$k] + $p.Substring($k.Length) }
    }
    $m = [regex]::Match($p, '^\\VOLUME\{[0-9A-Fa-f]+-([0-9A-Fa-f]{8})\}', 'IgnoreCase')
    if ($m.Success -and $Script:SerialMap.ContainsKey($m.Groups[1].Value.ToUpper())) {
        return $Script:SerialMap[$m.Groups[1].Value.ToUpper()] + $p.Substring($m.Length)
    }
    return $p
}

function Test-CheatWord([string]$text) {
    if (-not $text) { return $null }
    $t = $text.ToLower()
    foreach ($w in $Script:CheatWords) { if ($t.Contains($w)) { return $w } }
    return $null
}

function Test-OddPath([string]$path) {
    return ($path -match '(?i)\\temp\\|\\tmp\\|\\downloads\\|\\desktop\\|\\appdata\\local\\temp|\\\$recycle\.bin\\') -or
           ($path -match '^[A-Za-z]:' -and $path.Substring(0,2).ToUpper() -ne $env:SystemDrive.ToUpper() -and
            ([IO.DriveInfo]::new($path.Substring(0,2))).DriveType -eq 'Removable')
}

# Modrinth App extracts its own agent (theseus.jar, used for Quick Play) to
# %TEMP%\.tmpXXXX\ on every launch. Returns 'ok' if the jar is genuinely that
# agent, 'tampered' if it uses the name/manifest but carries other classes,
# or $null if it isn't a theseus jar at all.
function Test-ModrinthAgent([string]$jarPath) {
    if ($jarPath -notmatch '(?i)\\theseus\.jar$' -or -not (Test-Path -LiteralPath $jarPath)) { return $null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $mf = $zip.GetEntry('META-INF/MANIFEST.MF')
            if (-not $mf) { return 'tampered' }
            $r = New-Object IO.StreamReader($mf.Open()); $text = $r.ReadToEnd(); $r.Close()
            if ($text -notmatch 'Premain-Class:\s*com\.modrinth\.theseus\.agent\.TheseusAgent') { return 'tampered' }
            foreach ($e in $zip.Entries) {
                if ($e.FullName.EndsWith('/')) { continue }
                if ($e.FullName -notmatch '^(META-INF/|com/modrinth/theseus/)') { return 'tampered' }
            }
            return 'ok'
        } finally { $zip.Dispose() }
    } catch { return $null }
}

# Read a jar (or a jar-shaped temp file) and return its mod id/name/version
# from fabric.mod.json, quilt.mod.json or META-INF/mods.toml, plus its
# top-level packages. Returns $null if the file isn't a readable zip.
function Get-JarModInfo([string]$path) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($path)
    } catch { return $null }
    try {
        $info = [pscustomobject]@{ Id = $null; Name = $null; Version = ''; Packages = @() }
        function ReadEntry($n) { $e = $zip.GetEntry($n); if (-not $e) { return $null }; $r = New-Object IO.StreamReader($e.Open()); $t = $r.ReadToEnd(); $r.Close(); $t }
        $j = ReadEntry 'fabric.mod.json'
        if (-not $j) { $j = ReadEntry 'quilt.mod.json' }
        if ($j) {
            $info.Id      = [regex]::Match($j, '"id"\s*:\s*"([^"]+)"').Groups[1].Value
            $info.Name    = [regex]::Match($j, '"name"\s*:\s*"([^"]+)"').Groups[1].Value
            $info.Version = [regex]::Match($j, '"version"\s*:\s*"([^"]+)"').Groups[1].Value
        } else {
            $t = ReadEntry 'META-INF/mods.toml'
            if (-not $t) { $t = ReadEntry 'META-INF/neoforge.mods.toml' }
            if ($t) {
                $info.Id      = [regex]::Match($t, 'modId\s*=\s*"([^"]+)"').Groups[1].Value
                $info.Name    = [regex]::Match($t, 'displayName\s*=\s*"([^"]+)"').Groups[1].Value
                $info.Version = [regex]::Match($t, 'version\s*=\s*"([^"]+)"').Groups[1].Value
            }
        }
        if (-not $info.Id) { $info.Id = $null }
        $info.Packages = @($zip.Entries | Where-Object { $_.FullName -like '*.class' } |
            ForEach-Object { ($_.FullName -split '/')[0..([Math]::Min(1, ($_.FullName -split '/').Count - 2))] -join '.' } |
            Sort-Object -Unique | Select-Object -First 8)
        return $info
    } finally { $zip.Dispose() }
}

# ------------------------------ report -------------------------------
$Script:Report  = New-Object System.Collections.Generic.List[object]
$Script:Current = $null

function Add-Section([string]$Title) {
    $Script:Current = [pscustomobject]@{ Title = $Title; Items = New-Object System.Collections.Generic.List[object] }
    $Script:Report.Add($Script:Current)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

# How much each finding counts toward the suspicion score (0-1).
# Matched against "LEVEL|text"; first match wins. Unmatched: FLAG 0.30, WARN 0.03.
# Tune these to your server - they are judgement calls, not measured odds.
$Script:Weights = @(
    ,@('theseus\.jar but contains extra', 0.85)
    ,@('Unknown -javaagent', 0.65)
    ,@('Native agent loaded', 0.55)
    ,@('JNativeHook loaded into javaw', 0.45)
    ,@('Unsigned DLL loaded into javaw', 0.40)
    ,@('Hidden files or folders inside the mods', 0.50)
    ,@('DisableAttachMechanism', 0.40)
    ,@('^FLAG\|.*log was cleared', 0.45)
    ,@('^WARN\|.*log was cleared', 0.10)
    ,@('USN journal (is not active|was created)', 0.45)
    ,@('prefetch files were deleted', 0.45)
    ,@('^FLAG\|.*(Prefetch is disabled|Prefetch folder is empty|nearly empty)', 0.45)
    ,@('^FLAG\|.*BAM (has no entries|driver)', 0.40)
    ,@('^FLAG\|.*Defender exclusions', 0.40)
    ,@('^WARN\|.*Defender exclusions', 0.08)
    ,@('Test signing is ON|integrity checks are OFF', 0.35)
    ,@('^FLAG\|(SysMain|PcaSvc|EventLog) is', 0.25)
    ,@('loaded jars from outside', 0.25)
    ,@('running a jar from an unusual place', 0.20)
    ,@('JNativeHook files in Temp', 0.20)
    ,@('not normal mods', 0.15)
    ,@('Xbootclasspath', 0.15)
    ,@('Modified Minecraft jar', 0.60)
    ,@('Custom versions in', 0.12)
    ,@('suspicious names|keyword list|Running programs worth asking', 0.12)
    ,@('Jars opened by double-click', 0.12)
    ,@('suspicious command', 0.10)
    ,@('NOT in the folder anymore', 0.10)
    ,@('Startup entries worth checking', 0.10)
    ,@('virtual machine', 0.10)
    ,@('Secure Boot is OFF', 0.08)
    ,@('jar file\(s\) deleted or renamed|Files added or changed', 0.02)
)

function Get-FindingWeight([string]$Level, [string]$Text) {
    if ($Level -ne 'FLAG' -and $Level -ne 'WARN') { return 0 }
    $key = "$Level|$Text"
    foreach ($w in $Script:Weights) { if ($key -match $w[0]) { return [double]$w[1] } }
    if ($Level -eq 'FLAG') { return 0.30 } else { return 0.03 }
}

# Level: OK, INFO, WARN (look closer), FLAG (strong red flag)
function Add-Finding([string]$Level, [string]$Text, [string]$Detail = '') {
    $Script:Current.Items.Add([pscustomobject]@{ Level = $Level; Text = $Text; Detail = $Detail; Weight = (Get-FindingWeight $Level $Text); Section = $Script:Current.Title })
    $color = @{ OK = 'Green'; INFO = 'Gray'; WARN = 'Yellow'; FLAG = 'Red' }[$Level]
    Write-Host ('[{0}] {1}' -f $Level, $Text) -ForegroundColor $color
    if ($Detail) {
        $lines = $Detail -split "`n"
        $lines | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        if ($lines.Count -gt 15) { Write-Host "      ... ($($lines.Count - 15) more lines in the report)" -ForegroundColor DarkGray }
    }
}

# Combine finding weights into a 0-99 suspicion score.
# FLAGs combine as independent signals; WARNs together can add at most 30%,
# so a pile of minor leads on a normal PC can't push someone into "likely".
function Get-Verdict {
    $all  = @($Script:Report | ForEach-Object { $_.Items })
    $flagItems = @($all | Where-Object { $_.Level -eq 'FLAG' -and $_.Weight -gt 0 })
    $warnItems = @($all | Where-Object { $_.Level -eq 'WARN' -and $_.Weight -gt 0 })
    $pf = 1.0; foreach ($i in $flagItems) { $pf *= (1 - $i.Weight) }
    $pw = 1.0; foreach ($i in $warnItems) { $pw *= (1 - $i.Weight) }
    $flagP = 1 - $pf
    $warnP = [Math]::Min(0.30, 1 - $pw)
    $score = [int][Math]::Round(100 * (1 - (1 - $flagP) * (1 - $warnP)))
    if ($score -gt 99) { $score = 99 }
    $band = switch ($score) {
        { $_ -ge 70 } { 'HIGH - strong evidence, review the top reasons and ban if they hold up'; break }
        { $_ -ge 40 } { 'SUSPICIOUS - real red flags, dig into the top reasons before deciding'; break }
        { $_ -ge 15 } { 'SOME CONCERNS - ask the player about the reasons below'; break }
        default       { 'LOW - nothing significant found by the automated checks' }
    }
    $top = @($all | Where-Object { $_.Weight -gt 0 } | Sort-Object Weight -Descending | Select-Object -First 8)
    $cleanup = @($all | Where-Object { $_.Weight -ge 0.25 -and $_.Text -match '(?i)cleared|deleted|recreated|empty|disabled|not active|stopped' })
    $cheat   = @($all | Where-Object { $_.Weight -ge 0.25 -and $_.Text -match '(?i)javaagent|agent|DLL|JNativeHook|Hidden files|theseus|unusual place|outside game' })
    [pscustomobject]@{
        Score = $score; Band = $band; Top = $top
        Flags = $flagItems.Count; Warns = $warnItems.Count
        Cleanup = $cleanup.Count; Cheat = $cheat.Count
        Live = [bool](Get-Process javaw -ErrorAction SilentlyContinue)
        SecureBootOff = [bool]($all | Where-Object { $_.Text -match 'Secure Boot is OFF' })
    }
}

function Write-Summary($v) {
    Write-Host ''
    Write-Host '==================== SUMMARY ====================' -ForegroundColor Cyan
    $c = 'Green'; if ($v.Score -ge 70) { $c = 'Red' } elseif ($v.Score -ge 40) { $c = 'DarkYellow' } elseif ($v.Score -ge 15) { $c = 'Yellow' }
    Write-Host ("  Suspicion score: {0}%" -f $v.Score) -ForegroundColor $c
    Write-Host "  $($v.Band)" -ForegroundColor $c
    Write-Host ("  FLAG: {0}   WARN: {1}   cheat-evidence findings: {2}   cleanup-evidence findings: {3}" -f $v.Flags, $v.Warns, $v.Cheat, $v.Cleanup)
    if ($v.Top) {
        Write-Host '  Top reasons:'
        foreach ($t in $v.Top) { Write-Host ("   [{0}] {1}  ({2:P0})" -f $t.Level, $t.Text, $t.Weight) -ForegroundColor Gray }
    }
    if ($v.SecureBootOff) { Write-Host '  RULE: Secure Boot is OFF - a ban under your server rules regardless of the score.' -ForegroundColor Red }
    Write-Host '  Not included: memory scan [J], mod analyzer [M], kernel dump. Run those and weigh them yourself.' -ForegroundColor DarkGray
    if (-not $v.Live) { Write-Host '  Minecraft was not running, so live process checks were skipped.' -ForegroundColor DarkGray }
    Write-Host '==================================================' -ForegroundColor Cyan
}

function Save-Report {
    if ($Script:Report.Count -eq 0) { return }
    $desk = [Environment]::GetFolderPath('Desktop')
    $file = Join-Path $desk ('SS_Report_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $all   = $Script:Report | ForEach-Object { $_.Items }
    $flags = @($all | Where-Object Level -eq 'FLAG').Count
    $warns = @($all | Where-Object Level -eq 'WARN').Count
    $os    = Get-CimInstance Win32_OperatingSystem
    function E($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $v = Get-Verdict
    $scoreClass = 'bO'; if ($v.Score -ge 40) { $scoreClass = 'bF' } elseif ($v.Score -ge 15) { $scoreClass = 'bW' }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><title>SS Report - $(E $env:COMPUTERNAME)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#111418;color:#e6e6e6;margin:0;padding:24px;max-width:1100px}
h1{margin:0 0 4px}h2{margin:28px 0 8px;border-bottom:1px solid #333;padding-bottom:4px}
.meta{color:#9aa0a6;font-size:14px}.sum{display:flex;gap:12px;margin:16px 0}
.box{padding:10px 16px;border-radius:8px;font-weight:600}
.FLAG{color:#ff6b6b}.WARN{color:#ffd166}.OK{color:#6bd68a}.INFO{color:#9aa0a6}
.bF{background:#3a1717}.bW{background:#3a3217}.bO{background:#173a22}
.verdict{font-size:18px;margin:6px 0 8px}.item{margin:6px 0}.lvl{display:inline-block;width:52px;font-weight:700}
pre{background:#1b1f24;border:1px solid #2a2f36;border-radius:6px;padding:8px;white-space:pre-wrap;word-break:break-all;font-size:12px;margin:4px 0 10px 52px;max-height:420px;overflow:auto}
</style></head><body>
<h1>SS Report - $(E $env:COMPUTERNAME)</h1>
<div class="meta">User: $(E $env:USERNAME) &middot; Generated: $(Get-Date) &middot; Boot: $(E $os.LastBootUpTime) &middot; Tonytheboi Auto Screenshare v$Script:Version</div>
<div class="sum"><div class="box $scoreClass">Suspicion score: $($v.Score)%</div><div class="box bF">FLAG: $flags</div><div class="box bW">WARN: $warns</div></div>
<div class="verdict"><b>$(E $v.Band)</b></div>
$(if ($v.SecureBootOff) { "<div class='verdict FLAG'><b>Rule: Secure Boot is OFF - a ban under your server rules regardless of the score.</b></div>" })
<div class="meta">Cheat-evidence findings: $($v.Cheat) &middot; Cleanup-evidence findings: $($v.Cleanup)$(if (-not $v.Live) { ' &middot; Minecraft was not running, live checks skipped' })</div>
<h2>Summary - top reasons</h2>
$(if ($v.Top) { ($v.Top | ForEach-Object { "<div class='item'><span class='lvl $($_.Level)'>$($_.Level)</span>$(E $_.Text) <span class='meta'>($(E $_.Section), weight $([int]($_.Weight*100))%)</span></div>" }) -join "`n" } else { "<div class='item OK'>No red flags or warnings.</div>" })
<div class="meta" style="margin-top:10px">The score is a weighted sum of the automated checks, not a measured probability. It does not include the memory scan, mod analyzer or kernel dump - run those and weigh them yourself. Never ban on the number alone: check the reasons.</div>
<div class="meta">FLAG = strong red flag. WARN = look closer / ask the player. A single WARN is a lead, not a verdict.</div>
"@)
    foreach ($s in $Script:Report) {
        [void]$sb.Append("<h2>$(E $s.Title)</h2>")
        foreach ($i in $s.Items) {
            [void]$sb.Append("<div class='item'><span class='lvl $($i.Level)'>$($i.Level)</span>$(E $i.Text)</div>")
            if ($i.Detail) { [void]$sb.Append("<pre>$(E $i.Detail)</pre>") }
        }
    }
    [void]$sb.Append('</body></html>')
    [IO.File]::WriteAllText($file, $sb.ToString(), [Text.Encoding]::UTF8)
    Write-Summary $v
    Write-Host "Report saved: $file" -ForegroundColor Green
    Start-Process $file
}

# ------------------------------ prefetch helpers ---------------------
function Read-PrefetchBytes([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 8) { return $null }
    if ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x41 -and $bytes[2] -eq 0x4D) {   # "MAM" = compressed (Win10/11)
        $size = [BitConverter]::ToInt32($bytes, 4)
        $comp = New-Object byte[] ($bytes.Length - 8)
        [Array]::Copy($bytes, 8, $comp, 0, $comp.Length)
        $out = New-Object byte[] $size
        [uint32]$ws1 = 0; [uint32]$ws2 = 0
        [void][SSNative]::RtlGetCompressionWorkSpaceSize(4, [ref]$ws1, [ref]$ws2)
        $work = New-Object byte[] ([Math]::Max([int]$ws1, 1))
        [int]$final = 0
        $st = [SSNative]::RtlDecompressBufferEx(4, $out, $size, $comp, $comp.Length, [ref]$final, $work)
        if ($st -ne 0) { return $null }
        return $out
    }
    return $bytes
}

function Get-PrefetchRunTimes([byte[]]$d) {
    $times = @()
    if (-not $d -or $d.Length -lt 0xD0) { return $times }
    $ver = [BitConverter]::ToInt32($d, 0)
    $count = 1; if ($ver -ge 26) { $count = 8 }
    for ($i = 0; $i -lt $count; $i++) {
        $ft = [BitConverter]::ToInt64($d, 0x80 + 8 * $i)
        if ($ft -gt 0) {
            try {
                $t = [DateTime]::FromFileTime($ft)
                if ($t.Year -ge 2015 -and $t -le (Get-Date).AddDays(1)) { $times += $t }
            } catch {}
        }
    }
    return ($times | Sort-Object -Descending)
}

function Get-PrefetchJarRefs([byte[]]$d) {
    if (-not $d) { return @() }
    $found = @()
    foreach ($off in 0, 1) {
        if ($d.Length -le $off) { continue }
        $s = [Text.Encoding]::Unicode.GetString($d, $off, $d.Length - $off)
        $ms = [regex]::Matches($s, '\\(?:VOLUME\{[^}\x00]{1,80}\}|DEVICE\\HARDDISKVOLUME\d+)\\[^\x00]{1,400}?\.JAR(?=\x00)', 'IgnoreCase')
        foreach ($m in $ms) { $found += (Convert-DevicePath $m.Value) }
    }
    return ($found | Sort-Object -Unique)
}

# =====================================================================
#  CHECKS
# =====================================================================

function Test-SystemInfo {
    Add-Section 'System and Minecraft processes'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $up = (Get-Date) - $os.LastBootUpTime
    Add-Finding 'INFO' ("{0} ({1}) - {2} {3}" -f $env:COMPUTERNAME, $env:USERNAME, $os.Caption, $os.Version) ("Installed: {0}`nBooted:    {1}`nUptime:    {2:%d}d {2:hh}h {2:mm}m" -f $os.InstallDate, $os.LastBootUpTime, $up)
    if ($up.TotalMinutes -lt 60) { Add-Finding 'WARN' ("PC was booted {0:N0} minutes ago - memory evidence from before the reboot is gone" -f $up.TotalMinutes) }
    if ("$($cs.Manufacturer) $($cs.Model)" -match '(?i)vmware|virtualbox|virtual machine|qemu|kvm|hyper-v|parallels|xen') {
        Add-Finding 'WARN' "Running inside a virtual machine: $($cs.Manufacturer) $($cs.Model)"
    }

    $procs = Get-CimInstance Win32_Process -Filter "Name like 'java%'"
    if (-not $procs) { Add-Finding 'WARN' 'No java/javaw process running - Minecraft is closed, so live checks (memory, command line) are not possible'; return }
    $javaw = @($procs | Where-Object Name -eq 'javaw.exe')
    if ($javaw.Count -gt 1) { Add-Finding 'WARN' "$($javaw.Count) javaw.exe processes running - make sure you know which is the game and what the others are" }
    foreach ($p in $procs) {
        $start = $p.CreationDate
        $age = (Get-Date) - $start
        Add-Finding 'INFO' ("{0} PID {1} - started {2} ({3:N0} min ago)" -f $p.Name, $p.ProcessId, $start, $age.TotalMinutes) ("Path: {0}`nCommand line:`n{1}" -f $p.ExecutablePath, $p.CommandLine)
        if ($age.TotalMinutes -lt 15) { Add-Finding 'WARN' ("PID {0} started only {1:N0} minutes ago - game may have been relaunched before the SS" -f $p.ProcessId, $age.TotalMinutes) }
        $cl = [string]$p.CommandLine
        foreach ($m in [regex]::Matches($cl, '-javaagent:("[^"]+"|\S+)')) {
            $agent = $m.Groups[1].Value.Trim('"')
            $modrinth = Test-ModrinthAgent $agent
            if ($modrinth -eq 'ok') { Add-Finding 'INFO' "Modrinth App launcher agent on PID $($p.ProcessId) (verified contents): $agent" }
            elseif ($modrinth -eq 'tampered') { Add-Finding 'FLAG' "Agent named like Modrinth's theseus.jar but contains extra classes on PID $($p.ProcessId): $agent" }
            elseif ($agent -notmatch $Script:KnownJarDirs) { Add-Finding 'FLAG' "Unknown -javaagent on PID $($p.ProcessId): $agent" }
            else { Add-Finding 'INFO' "Launcher javaagent on PID $($p.ProcessId): $agent" }
        }
        foreach ($m in [regex]::Matches($cl, '-(agentpath|agentlib):("[^"]+"|\S+)')) { Add-Finding 'FLAG' "Native agent loaded on PID $($p.ProcessId): $($m.Value)" }
        if ($cl -match '-Xbootclasspath') { Add-Finding 'WARN' "PID $($p.ProcessId) uses -Xbootclasspath (classes injected ahead of the game)" }
        if ($cl -match 'DisableAttachMechanism') { Add-Finding 'FLAG' "PID $($p.ProcessId) has -XX:+DisableAttachMechanism (blocks inspection tools)" }
        $jm = [regex]::Match($cl, '-jar\s+("[^"]+"|\S+)')
        if ($jm.Success) {
            $jar = $jm.Groups[1].Value.Trim('"')
            if ($jar -notmatch $Script:KnownJarDirs) { Add-Finding 'WARN' "PID $($p.ProcessId) is running a jar from an unusual place: $jar" }
        }
        if ($p.ExecutablePath -and (Test-OddPath $p.ExecutablePath)) { Add-Finding 'WARN' "Java running from an unusual path: $($p.ExecutablePath)" }
        Test-JavawModules $p
    }
}

# Native DLLs loaded into a java process. Catches DLL-injected clients and
# Java autoclickers that hook the mouse (JNativeHook), which never show up
# in the mods folder or the command line.
function Test-JavawModules($p) {
    $proc = Get-Process -Id $p.ProcessId
    if (-not $proc) { return }
    $mods = @($proc.Modules | ForEach-Object FileName | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $mods) { Add-Finding 'WARN' "Could not list DLLs loaded in PID $($p.ProcessId) (protected process or access denied)"; return }
    $javaHome = ''
    if ($p.ExecutablePath) { $javaHome = Split-Path (Split-Path $p.ExecutablePath -Parent) -Parent }
    # Natives the game and common mods unpack and load (often unsigned)
    $knownNative = '(?i)lwjgl|glfw|openal|jemalloc|jinput|jnidispatch|\bjna|discord|sqlite|zstd|lz4|rocksdb|jcef|libcef|chrome_elf|libGLESv2|libEGL|d3dcompiler|vulkan|nvoglv|atio6axx|ig\d+icd|amdxx|nvd3dum|OverlayHook|gameoverlay|RTSSHooks|obs-|graphics-hook|nahimic|sonic|nvspcap|opus4j|rnnoise4j|speex4j|lame4j'
    $flaggedHook = @(); $unsigned = @(); $other = @()
    foreach ($m in $mods) {
        if ($m -like "$env:windir\*") { continue }
        if ($javaHome -and $m -like "$javaHome\*") { continue }
        $name = Split-Path $m -Leaf
        if ($name -match '(?i)JNativeHook') { $flaggedHook += $m; continue }
        $other += $m
        if ($name -match $knownNative -or $m -match $Script:KnownJarDirs) { continue }
        $sig = (Get-AuthenticodeSignature -LiteralPath $m).Status
        if ("$sig" -ne 'Valid') { $unsigned += "$m   [$sig]" }
    }
    if ($other) { Add-Finding 'INFO' "Non-Windows DLLs loaded in PID $($p.ProcessId)" ($other -join "`n") }
    if ($flaggedHook) { Add-Finding 'WARN' "JNativeHook loaded into javaw PID $($p.ProcessId) - global mouse/keyboard hook used by Java autoclickers" ($flaggedHook -join "`n") }
    if ($unsigned) { Add-Finding 'WARN' "Unsigned DLL loaded into javaw PID $($p.ProcessId) - check what each one is" ($unsigned -join "`n") }
    elseif (-not $flaggedHook) { Add-Finding 'OK' "No unknown unsigned DLLs loaded in PID $($p.ProcessId)" }
}

function Test-Services {
    Add-Section 'Services'
    $crit = [ordered]@{ SysMain = 'FLAG'; PcaSvc = 'FLAG'; EventLog = 'FLAG'; DPS = 'WARN'; DiagTrack = 'WARN'; DusmSvc = 'WARN' }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $display = @{}
    foreach ($n in $crit.Keys) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'"
        if (-not $s) { Add-Finding 'WARN' "$n service not found"; continue }
        $display[$s.DisplayName] = $n
        if ($s.State -eq 'Running' -and $s.StartMode -ne 'Disabled') { Add-Finding 'OK' "$n running ($($s.StartMode))" }
        else { Add-Finding $crit[$n] "$n is $($s.State), start mode $($s.StartMode)" }
    }
    $bam = Get-CimInstance Win32_SystemDriver -Filter "Name='bam'"
    if (-not $bam) { Add-Finding 'WARN' 'BAM driver not present (older Windows build?)' }
    elseif ($bam.State -ne 'Running') { Add-Finding 'FLAG' "BAM driver is $($bam.State), start mode $($bam.StartMode)" }
    else { Add-Finding 'OK' 'BAM driver running' }

    $hits = @()
    foreach ($e in Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7036, 7040; StartTime = $boot }) {
        $dn = [string]$e.Properties[0].Value
        if (-not $display.ContainsKey($dn)) { continue }
        if ($e.Id -eq 7036 -and ([string]$e.Properties[1].Value) -match '(?i)running|en cours|wird ausgef|in esecuzione|en ejecuci') { continue }
        $hits += ('{0}  [{1}] {2}' -f $e.TimeCreated, $e.Id, ($e.Message -replace '\s+', ' '))
    }
    if ($hits) { Add-Finding 'WARN' "These services were stopped or had their start type changed since boot ($boot)" ($hits -join "`n") }
    else { Add-Finding 'OK' 'No stops or start-type changes for these services since boot' }
}

function Test-SecureBoot {
    Add-Section 'Secure Boot and boot configuration'
    try {
        $sbOn = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($sbOn) { Add-Finding 'OK' 'Secure Boot is ON' } else { Add-Finding 'FLAG' 'Secure Boot is OFF (ban per server rules)' }
    } catch {
        Add-Finding 'WARN' 'Secure Boot check not supported - legacy BIOS mode, Secure Boot cannot be on' $_.Exception.Message
    }
    $bcd = (& bcdedit /enum '{current}' 2>&1) | Out-String
    if ($bcd -match '(?im)^\s*testsigning\s+Yes') { Add-Finding 'FLAG' 'Test signing is ON (unsigned drivers can load)' }
    if ($bcd -match '(?im)^\s*nointegritychecks\s+Yes') { Add-Finding 'FLAG' 'Driver integrity checks are OFF' }
    if ($bcd -match '(?im)^\s*debug\s+Yes') { Add-Finding 'WARN' 'Kernel debugging is enabled' }
    if ($bcd -notmatch '(?im)testsigning\s+Yes|nointegritychecks\s+Yes') { Add-Finding 'OK' 'No test signing / integrity check bypass in boot config' }
    Add-Finding 'INFO' 'bcdedit output' $bcd.Trim()
}

function Test-EventLogs {
    Add-Section 'Event logs'
    $any = $false
    foreach ($c in @(@{ Log = 'Security'; Id = 1102 }, @{ Log = 'System'; Id = 104 })) {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = $c.Log; Id = $c.Id } -MaxEvents 10
        if ($ev) {
            $any = $true
            $recent = @($ev | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) })
            $lvl = 'WARN'; if ($recent.Count) { $lvl = 'FLAG' }
            Add-Finding $lvl "$($c.Log) log was cleared $($ev.Count) time(s) (event $($c.Id))" (($ev | ForEach-Object { "{0}  {1}" -f $_.TimeCreated, ($_.Message -replace '\s+', ' ') }) -join "`n")
        }
    }
    if (-not $any) { Add-Finding 'OK' 'No record of the Security or System log being cleared' }
    foreach ($log in 'Security', 'System', 'Application') {
        $oldest = Get-WinEvent -LogName $log -MaxEvents 1 -Oldest
        if ($oldest) {
            $lvl = 'INFO'; if ($oldest.TimeCreated -gt (Get-Date).AddHours(-$Script:RecentHrs)) { $lvl = 'WARN' }
            Add-Finding $lvl "$log log starts at $($oldest.TimeCreated)$(if ($lvl -eq 'WARN') { ' - very recent, log may have been wiped' })"
        } else { Add-Finding 'WARN' "$log log is empty or unreadable" }
    }
}

function Test-PSHistory {
    Add-Section 'PowerShell history'
    $pattern = '(?i)remove-item|\bdel\b|\brm\b|\berase\b|prefetch|wevtutil|clear-eventlog|fsutil|\busn\b|stop-service|set-service|sc(\.exe)?\s+(config|stop|delete)|\biwr\b|\birm\b|\biex\b|invoke-webrequest|invoke-restmethod|invoke-expression|downloadfile|start-bitstransfer|\.jar\b|bcdedit|add-mppreference|set-mppreference|reg\s+delete|clear-history|recycle'
    $files = Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' -Force
    $mine = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path $mine)) { Add-Finding 'WARN' "No PowerShell history for $env:USERNAME - never used PowerShell interactively, or the file was deleted" }
    foreach ($f in $files) {
        $user = ($f.FullName -split '\\')[2]
        $lines = @(Get-Content $f.FullName)
        $lvl = 'INFO'; if ($lines.Count -lt 5) { $lvl = 'WARN' }
        Add-Finding $lvl ("{0}: {1} commands, last written {2}" -f $user, $lines.Count, $f.LastWriteTime) ("Last 20 commands:`n" + (($lines | Select-Object -Last 20) -join "`n"))
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern -and $lines[$i] -notmatch $Script:SSUrls) { $hits += ('line {0}: {1}' -f ($i + 1), $lines[$i]) }
        }
        if ($hits) { Add-Finding 'WARN' "$user - $($hits.Count) suspicious command(s) in history (deleting, downloading, logs, services)" ($hits -join "`n") }
        else { Add-Finding 'OK' "$user - no suspicious commands in history" }
    }
}

function Test-Prefetch {
    Add-Section 'Prefetch'
    $ep = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters').EnablePrefetcher
    if ($ep -eq 0) { Add-Finding 'FLAG' 'Prefetch is disabled in the registry (EnablePrefetcher = 0)' }
    $pf = @(Get-ChildItem 'C:\Windows\Prefetch' -Filter '*.pf' -Force | Sort-Object LastWriteTime -Descending)
    if ($pf.Count -eq 0) { Add-Finding 'FLAG' 'Prefetch folder is empty - it was cleared'; return }
    $oldest = ($pf | Sort-Object CreationTime | Select-Object -First 1).CreationTime
    $msg = "{0} prefetch files, oldest created {1}" -f $pf.Count, $oldest
    if ($pf.Count -lt 30) { Add-Finding 'FLAG' "$msg - nearly empty, likely cleared" }
    elseif ($oldest -gt (Get-Date).AddHours(-$Script:RecentHrs)) { Add-Finding 'WARN' "$msg - nothing older than $($Script:RecentHrs)h, likely cleared" }
    else { Add-Finding 'OK' $msg }

    $recent = $pf | Select-Object -First 50
    Add-Finding 'INFO' 'Last 50 programs run (newest first)' (($recent | ForEach-Object { '{0}  {1}' -f $_.LastWriteTime, $_.Name }) -join "`n")

    $kw = @()
    foreach ($f in $pf) { $w = Test-CheatWord $f.Name; if ($w) { $kw += ('{0}  {1}   (matched "{2}")' -f $f.LastWriteTime, $f.Name, $w) } }
    if ($kw) { Add-Finding 'WARN' "Prefetch entries with suspicious names - check what these are" ($kw -join "`n") }
    else { Add-Finding 'OK' 'No prefetch names match the keyword list' }
}

function Test-BAM {
    Add-Section 'BAM (Background Activity Moderator)'
    $rows = @()
    foreach ($root in 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings', 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\UserSettings') {
        foreach ($sidKey in Get-ChildItem $root) {
            $key = Get-Item $sidKey.PSPath
            foreach ($name in $key.GetValueNames()) {
                if ($name -notlike '\Device\*') { continue }
                $val = $key.GetValue($name)
                if ($val -isnot [byte[]] -or $val.Length -lt 8) { continue }
                $t = [DateTime]::FromFileTime([BitConverter]::ToInt64($val, 0))
                $rows += [pscustomobject]@{ Time = $t; Path = (Convert-DevicePath $name) }
            }
        }
    }
    if (-not $rows) { Add-Finding 'FLAG' 'BAM has no entries - it was cleared or disabled'; return }
    $rows = $rows | Sort-Object Time -Descending
    $since = (Get-Date).AddHours(-$Script:RecentHrs)
    $recent = @($rows | Where-Object Time -gt $since)
    Add-Finding 'INFO' "$($rows.Count) BAM entries, $($recent.Count) in the last $($Script:RecentHrs)h"

    $detail = @(); $odd = @()
    foreach ($r in ($rows | Where-Object Time -gt (Get-Date).AddDays(-7))) {
        $exists = Test-Path -LiteralPath $r.Path
        $sig = 'deleted'
        if ($exists) { $sig = (Get-AuthenticodeSignature -LiteralPath $r.Path).Status }
        $line = '{0}  [{1}]  {2}' -f $r.Time, $sig, $r.Path
        if ($r.Time -gt $since) { $detail += $line }
        $why = @()
        if (-not $exists) { $why += 'file deleted after running' }
        elseif ("$sig" -ne 'Valid') { $why += "signature: $sig" }
        if (Test-OddPath $r.Path) { $why += 'unusual folder' }
        $w = Test-CheatWord $r.Path; if ($w) { $why += "name matches '$w'" }
        if ($why.Count -ge 2 -or $w -or (-not $exists -and $r.Time -gt $since)) { $odd += "$line   <- $($why -join ', ')" }
    }
    if ($detail) { Add-Finding 'INFO' "Programs run in the last $($Script:RecentHrs)h" ($detail -join "`n") }
    if ($odd) { Add-Finding 'WARN' 'BAM entries worth checking (last 7 days: deleted, unsigned in odd folders, or suspicious names)' ($odd -join "`n") }
    else { Add-Finding 'OK' 'Nothing suspicious in BAM for the last 7 days' }
}

function Test-Usn {
    Add-Section 'USN journal (deleted / renamed files on C:)'
    $q = (& fsutil usn queryjournal C: 2>&1) | Out-String
    $m = [regex]::Match($q, '0x[0-9a-fA-F]{16}')
    if (-not $m.Success) { Add-Finding 'FLAG' 'USN journal is not active on C: - it was deleted or disabled' $q.Trim(); return }
    $created = [DateTime]::FromFileTime([Convert]::ToInt64($m.Value.Substring(2), 16))
    $install = (Get-CimInstance Win32_OperatingSystem).InstallDate
    if ($created -gt (Get-Date).AddDays(-7) -and [Math]::Abs(($created - $install).TotalHours) -gt 24) {
        Add-Finding 'FLAG' "USN journal was created $created (Windows installed $install) - it was likely deleted and recreated"
    } else { Add-Finding 'OK' "USN journal active since $created" }

    Write-Host '  Reading the journal, this can take a minute...' -ForegroundColor DarkGray
    $lines = New-Object System.Collections.Generic.List[string]
    & fsutil usn readjournal C: csv 2>$null | ForEach-Object {
        if ($_ -match '(?i)\.(jar|exe|dll|pf)"?\s*,' -and $_ -match '(?i)delete|rename') { $lines.Add($_) }
    }
    if ($lines.Count -eq 0) { Add-Finding 'INFO' 'No deleted or renamed .jar/.exe/.dll/.pf files found in the journal'; return }
    $hdr = 0..24 | ForEach-Object { "c$_" }
    $events = @{}
    foreach ($r in ($lines | ConvertFrom-Csv -Header $hdr)) {
        $name = [string]$r.c1
        $isDel = $false; $isRen = $false
        if ($r.c3 -match '^0x[0-9a-fA-F]+$') {
            $bits = [Convert]::ToInt64($r.c3.Substring(2), 16)
            $isDel = ($bits -band 0x200) -ne 0
            $isRen = ($bits -band 0x1000) -ne 0
        } else {
            $isDel = "$($r.c4)" -match '(?i)delete'
            $isRen = "$($r.c4)" -match '(?i)rename old'
        }
        if (-not ($isDel -or $isRen)) { continue }
        $t = [datetime]::MinValue
        [void][datetime]::TryParse([string]$r.c5, [ref]$t)
        $action = 'renamed'; if ($isDel) { $action = 'deleted' }
        $events["$name|$action"] = [pscustomobject]@{ Name = $name; Action = $action; Time = $t }
    }
    $ev = $events.Values | Sort-Object Time -Descending

    $pfDel = @($ev | Where-Object { $_.Name -match '(?i)\.pf$' -and $_.Action -eq 'deleted' })
    if ($pfDel.Count -gt 10) { Add-Finding 'FLAG' "$($pfDel.Count) prefetch files were deleted - Prefetch was cleaned" (($pfDel | Select-Object -First 50 | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Name }) -join "`n") }
    elseif ($pfDel.Count -gt 0) { Add-Finding 'WARN' "$($pfDel.Count) prefetch file(s) deleted" (($pfDel | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Name }) -join "`n") }

    $jars = @($ev | Where-Object { $_.Name -match '(?i)\.jar$' })
    if ($jars) { Add-Finding 'WARN' "$($jars.Count) jar file(s) deleted or renamed - compare names and times to the SS (mod updates also do this)" (($jars | ForEach-Object { '{0}  {1,-8} {2}' -f $_.Time, $_.Action, $_.Name }) -join "`n") }
    else { Add-Finding 'OK' 'No jars deleted or renamed' }

    $cut = (Get-Date).AddHours(-3)
    $exe = @($ev | Where-Object { $_.Name -match '(?i)\.(exe|dll)$' -and $_.Time -gt $cut -and $_.Action -eq 'deleted' })
    if ($exe) { Add-Finding 'WARN' "$($exe.Count) exe/dll file(s) deleted in the last 3 hours" (($exe | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Name }) -join "`n") }
    $kw = @($ev | Where-Object { Test-CheatWord $_.Name })
    if ($kw) { Add-Finding 'WARN' 'Deleted/renamed files with suspicious names' (($kw | ForEach-Object { '{0}  {1,-8} {2}' -f $_.Time, $_.Action, $_.Name }) -join "`n") }
}

function Test-Jars {
    Add-Section 'Executed jar files'
    # 1. Prefetch for java/javaw: files referenced
    $pfs = Get-ChildItem 'C:\Windows\Prefetch' -Force | Where-Object { $_.Name -match '^JAVAW?\.EXE-' }
    if (-not $pfs) { Add-Finding 'INFO' 'No java/javaw prefetch files' }
    foreach ($f in $pfs) {
        $d = Read-PrefetchBytes $f.FullName
        if (-not $d) { Add-Finding 'WARN' "Could not read $($f.Name)"; continue }
        $times = Get-PrefetchRunTimes $d
        $jars = Get-PrefetchJarRefs $d
        # Modrinth App's agent is extracted to %TEMP%\.tmpXXXX\theseus.jar on every launch.
        # If the file still exists, verify its contents; if it's gone, the launcher cleaned it up.
        $modrinthPat = '(?i)\\temp\\\.tmp[a-z0-9]+\\theseus\.jar$'
        $modrinthOk = @(); $modrinthBad = @(); $unknown = @()
        foreach ($j in $jars) {
            if ($j -match $Script:KnownJarDirs) { continue }
            if ($j -match $modrinthPat) {
                if (-not (Test-Path -LiteralPath $j)) { $modrinthOk += "$j   (temp copy already removed by the launcher)" }
                elseif ((Test-ModrinthAgent $j) -eq 'ok') { $modrinthOk += "$j   (contents verified)" }
                else { $modrinthBad += $j }
                continue
            }
            $unknown += $j
        }
        $info = "Last run times:`n" + (($times | ForEach-Object { "  $_" }) -join "`n") + "`n`nJars referenced:`n" + (($jars | ForEach-Object { "  $_" }) -join "`n")
        Add-Finding 'INFO' "$($f.Name) - $($jars.Count) jar(s) referenced" $info
        if ($modrinthOk) { Add-Finding 'INFO' "$($modrinthOk.Count) Modrinth App launcher agent(s) (theseus.jar) - normal for Modrinth" ($modrinthOk -join "`n") }
        if ($modrinthBad) { Add-Finding 'FLAG' "Agent named like Modrinth's theseus.jar but contains extra classes (from prefetch)" ($modrinthBad -join "`n") }
        if ($unknown) { Add-Finding 'WARN' "$($f.Name) loaded jars from outside game/launcher folders" ($unknown -join "`n") }
    }

    # 2. Recently opened jars (shortcuts in Recent)
    $sh = New-Object -ComObject WScript.Shell
    $lnks = Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\Recent\*.jar.lnk' -Force | Sort-Object LastWriteTime -Descending
    if ($lnks) {
        $list = @(); $odd = @()
        foreach ($l in $lnks) {
            $target = $sh.CreateShortcut($l.FullName).TargetPath
            $line = '{0}  {1}' -f $l.LastWriteTime, $target
            $list += $line
            if ($target -notmatch $Script:KnownJarDirs -or (Test-CheatWord $target)) { $odd += $line }
        }
        Add-Finding 'INFO' "$($lnks.Count) jar(s) opened through Explorer (Recent)" ($list -join "`n")
        if ($odd) { Add-Finding 'WARN' 'Jars opened by double-click from outside game folders' ($odd -join "`n") }
    } else { Add-Finding 'OK' 'No jars in Recent items' }

    # 3. RecentDocs .jar MRU
    $rk = Get-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs\.jar'
    if ($rk) {
        $names = foreach ($v in $rk.GetValueNames()) {
            if ($v -eq 'MRUListEx') { continue }
            $b = $rk.GetValue($v)
            if ($b -is [byte[]]) { ([Text.Encoding]::Unicode.GetString($b) -split "`0")[0] }
        }
        if ($names) { Add-Finding 'INFO' 'RecentDocs .jar list (registry)' ($names -join "`n") }
    }

    # 4. Java crash logs
    $logs = @()
    $logs += Get-ChildItem $env:USERPROFILE -Filter 'hs_err_pid*.log' -Recurse -Depth 4 -File -Force
    if ($logs) {
        $out = foreach ($lg in $logs) {
            $cl = (Select-String -Path $lg.FullName -Pattern '^Command Line:' | Select-Object -First 1).Line
            "{0}  {1}`n    {2}" -f $lg.LastWriteTime, $lg.FullName, $cl
        }
        Add-Finding 'INFO' "$($logs.Count) Java crash log(s) - they show the command line of crashed JVMs" ($out -join "`n")
    }
}

# Decide what a versions\<name> folder is from its <name>.json:
#  vanilla  = official Mojang version (Mojang download URL, normal main class, jar hash matches)
#  loader   = Fabric / Quilt / Forge / NeoForge / OptiFine profile on top of a vanilla version
#  custom   = anything else (unknown main class, no Mojang download, no json)
#  modified = Mojang version whose jar does not match Mojang's published SHA-1
function Get-VersionVerdict([string]$dir) {
    $name = Split-Path $dir -Leaf
    $jsonPath = Join-Path $dir "$name.json"
    if (-not (Test-Path -LiteralPath $jsonPath)) { return [pscustomobject]@{ Kind = 'custom'; Why = 'no version .json' } }
    try { $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json } catch { return [pscustomobject]@{ Kind = 'custom'; Why = 'unreadable version .json' } }
    $loaderMain = '(?i)net\.fabricmc|org\.quiltmc|cpw\.mods|net\.minecraftforge|net\.neoforged|launchwrapper|optifine'
    if ($j.inheritsFrom) {
        if ($j.mainClass -match $loaderMain -or -not $j.mainClass) { return [pscustomobject]@{ Kind = 'loader'; Why = "on top of $($j.inheritsFrom)" } }
        return [pscustomobject]@{ Kind = 'custom'; Why = "unknown main class $($j.mainClass)" }
    }
    if ($j.mainClass -match $loaderMain) { return [pscustomobject]@{ Kind = 'loader'; Why = '' } }
    $url = [string]$j.downloads.client.url
    if ($j.mainClass -ne 'net.minecraft.client.main.Main' -or $url -notmatch '^https://(piston-data|launcher)\.mojang\.com/') {
        return [pscustomobject]@{ Kind = 'custom'; Why = "main class $($j.mainClass), download $url" }
    }
    $jar = Join-Path $dir "$name.jar"
    $want = [string]$j.downloads.client.sha1
    if ($want -and (Test-Path -LiteralPath $jar)) {
        $have = (Get-FileHash -LiteralPath $jar -Algorithm SHA1).Hash
        if ($have -ne $want.ToUpper()) { return [pscustomobject]@{ Kind = 'modified'; Why = "jar SHA-1 $have, Mojang's is $($want.ToUpper())" } }
        return [pscustomobject]@{ Kind = 'vanilla'; Why = 'jar hash verified' }
    }
    return [pscustomobject]@{ Kind = 'vanilla'; Why = 'jar not downloaded' }
}

function Test-Mods {
    Add-Section 'Mods folders'
    # Only the instance that is actually running: read --gameDir from the game's command line
    $dirs = @()
    $running = @(Get-CimInstance Win32_Process -Filter "Name like 'java%'" | Where-Object { $_.CommandLine -match '--gameDir|net\.minecraft|fabric|forge|quilt|lunar' })
    foreach ($proc in $running) {
        $m = [regex]::Match([string]$proc.CommandLine, '--gameDir\s+("([^"]+)"|(\S+))')
        if ($m.Success) {
            $gd = $m.Groups[2].Value; if (-not $gd) { $gd = $m.Groups[3].Value }
            $dirs += Join-Path $gd 'mods'
            Add-Finding 'INFO' "Checking the running instance only (PID $($proc.ProcessId)): $gd"
        }
    }
    if ($running -and -not $dirs) {
        Add-Finding 'WARN' 'Minecraft is running but its game folder could not be read from the command line - falling back to checking every known mods folder'
    }
    if (-not $dirs) {
        if (-not $running) { Add-Finding 'INFO' 'Minecraft is not running - checking every known mods folder instead of just the launched one' }
        $dirs += Join-Path $env:APPDATA '.minecraft\mods'
        $dirs += Get-ChildItem (Join-Path $env:APPDATA 'PrismLauncher\instances\*\*\mods') -Directory | ForEach-Object FullName
        $dirs += Get-ChildItem (Join-Path $env:APPDATA 'ModrinthApp\profiles\*\mods') -Directory | ForEach-Object FullName
        $dirs += Get-ChildItem (Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances\*\mods') -Directory | ForEach-Object FullName
        $dirs += Get-ChildItem (Join-Path $env:APPDATA '.feather\*\mods') -Directory | ForEach-Object FullName
    }
    $dirs = $dirs | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique
    if (-not $dirs) { Add-Finding 'INFO' 'No mods folders found'; return }
    $since = (Get-Date).AddHours(-$Script:RecentHrs)
    foreach ($dir in $dirs) {
        $files = @(Get-ChildItem $dir -Force -File -Recurse -Depth 1)
        $jars = @($files | Where-Object Extension -eq '.jar')
        $folder = Get-Item $dir -Force
        Add-Finding 'INFO' ("{0} - {1} jar(s), folder modified {2}" -f $dir, $jars.Count, $folder.LastWriteTime) (($jars | Sort-Object LastWriteTime -Descending | ForEach-Object { '{0}  {1,10:N0} KB  {2}' -f $_.LastWriteTime, ($_.Length / 1KB), $_.Name }) -join "`n")
        $new = @($files | Where-Object { $_.LastWriteTime -gt $since -or $_.CreationTime -gt $since })
        if ($new) { Add-Finding 'WARN' "Files added or changed in the last $($Script:RecentHrs)h" (($new | ForEach-Object { '{0}  {1}' -f $_.LastWriteTime, $_.Name }) -join "`n") }
        # Java leftover temp copies (zipfstmp*.tmp): open each and see which mod it is
        $zipfs = @($files | Where-Object { $_.Name -match '^zipfstmp\d+\.tmp$' })
        if ($zipfs) {
            $present = @{}
            foreach ($j in $jars) { $mi = Get-JarModInfo $j.FullName; if ($mi -and $mi.Id) { $present[$mi.Id.ToLower()] = $j.Name } }
            $okList = @(); $gone = @(); $unknown = @()
            foreach ($z in $zipfs) {
                $mi = Get-JarModInfo $z.FullName
                $when = $z.LastWriteTime
                if (-not $mi) { $unknown += ('{0}  {1}  (not a readable jar - inspect manually)' -f $when, $z.Name); continue }
                if (-not $mi.Id) { $unknown += ('{0}  {1}  no mod metadata, packages: {2}' -f $when, $z.Name, ($mi.Packages -join ', ')); continue }
                $label = '{0} {1}' -f $mi.Id, $mi.Version
                if ($present.ContainsKey($mi.Id.ToLower())) { $okList += ('{0}  {1}  -> {2} (still installed as {3})' -f $when, $z.Name, $label, $present[$mi.Id.ToLower()]) }
                else { $gone += ('{0}  {1}  -> {2} ({3}) - NOT in the folder anymore' -f $when, $z.Name, $label, $mi.Name) }
            }
            if ($okList) { Add-Finding 'INFO' "$($okList.Count) Java temp copies (zipfstmp) of mods that are still installed - harmless leftovers" ($okList -join "`n") }
            if ($gone) { Add-Finding 'WARN' 'Java temp copies of mods that are no longer in the folder - find out what these were' ($gone -join "`n") }
            if ($unknown) { Add-Finding 'WARN' 'Java temp copies that are not normal mods - open them and check the packages' ($unknown -join "`n") }
        }
        $other = @($files | Where-Object { $_.Extension -notin '.jar', '.disabled', '.json', '.toml', '.txt', '.cfg', '.properties', '.index' -and $_.Name -notmatch '^zipfstmp\d+\.tmp$' })
        if ($other) { Add-Finding 'WARN' 'Non-jar files in the mods folder' (($other | ForEach-Object FullName) -join "`n") }
        $hidden = @(Get-ChildItem $dir -Force -Recurse -Depth 2 | Where-Object { $_.Attributes -match 'Hidden|System' })
        if ($hidden) { Add-Finding 'FLAG' 'Hidden files or folders inside the mods folder' (($hidden | ForEach-Object FullName) -join "`n") }
        $kw = @($files | Where-Object { Test-CheatWord $_.Name })
        if ($kw) { Add-Finding 'WARN' 'Mod file names matching the keyword list' (($kw | ForEach-Object Name) -join "`n") }
    }
    # Game versions (a client can be installed as a "version" instead of a mod).
    # Judged by the version's own .json + jar, not by its name, so new Mojang
    # names (26.1-snapshot-5, April Fools versions...) need no list.
    $checked = @()
    $runningJava = @(Get-CimInstance Win32_Process -Filter "Name like 'java%'")
    foreach ($proc in $runningJava) {
        $cl = [string]$proc.CommandLine
        foreach ($m in [regex]::Matches($cl, '([A-Za-z]:\\[^;"]*?\\versions\\([^\\;"]+))\\\2\.jar', 'IgnoreCase')) {
            $checked += $m.Groups[1].Value
        }
    }
    $checked = @($checked | Sort-Object -Unique)
    if ($checked) {
        Add-Finding 'INFO' 'Checking only the game version(s) the running Minecraft was launched with' ($checked -join "`n")
        $toCheck = $checked
    } else {
        $vdir = Join-Path $env:APPDATA '.minecraft\versions'
        $toCheck = @(Get-ChildItem $vdir -Directory -Force | ForEach-Object FullName)
        if ($runningJava) { Add-Finding 'INFO' 'Could not tell which version the running game uses - checking every folder in .minecraft\versions' }
        elseif ($toCheck) { Add-Finding 'INFO' 'Minecraft is not running - checking every folder in .minecraft\versions' }
    }
    $okList = @(); $custom = @(); $modified = @()
    foreach ($vd in $toCheck) {
        $r = Get-VersionVerdict $vd
        $line = '{0}  [{1}]  {2}' -f (Get-Item -LiteralPath $vd -Force).LastWriteTime, $r.Kind, $vd
        if ($r.Why) { $line += "   - $($r.Why)" }
        switch ($r.Kind) {
            'modified' { $modified += $line }
            'custom'   { $custom += $line }
            default    { $okList += $line }
        }
    }
    if ($okList) { Add-Finding 'INFO' "$($okList.Count) official Mojang or mod-loader version(s)" ($okList -join "`n") }
    if ($custom) { Add-Finding 'WARN' 'Custom versions in the versions folder - not an official Mojang version or a known mod loader' ($custom -join "`n") }
    if ($modified) { Add-Finding 'FLAG' 'Modified Minecraft jar - does not match the hash Mojang published for that version' ($modified -join "`n") }
    Add-Finding 'INFO' 'Run [M] Yarp mod analyzer for a full analysis of the jars themselves'
}

function Test-Extra {
    Add-Section 'Startup entries, autoclicker natives, USB devices'
    # Startup entries (autoclickers and loaders often start with Windows)
    $entries = @()
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                   'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        $item = Get-Item $k
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) { $entries += [pscustomobject]@{ Where = $k; Name = $n; Cmd = [string]$item.GetValue($n) } }
    }
    foreach ($f in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        Get-ChildItem $f -Force -File | Where-Object Name -ne 'desktop.ini' | ForEach-Object { $entries += [pscustomobject]@{ Where = $f; Name = $_.Name; Cmd = $_.FullName } }
    }
    if ($entries) {
        Add-Finding 'INFO' "$($entries.Count) startup entries" (($entries | ForEach-Object { '{0} = {1}' -f $_.Name, $_.Cmd }) -join "`n")
        $odd = @($entries | Where-Object { (Test-CheatWord "$($_.Name) $($_.Cmd)") -or $_.Cmd -match '(?i)\.ahk|autohotkey|\.jar|javaw|\\temp\\|\\downloads\\|powershell.*-enc' })
        if ($odd) { Add-Finding 'WARN' 'Startup entries worth checking' (($odd | ForEach-Object { '{0} = {1}' -f $_.Name, $_.Cmd }) -join "`n") }
    }

    # JNativeHook / JNA natives left in Temp by Java autoclickers
    $natives = @(Get-ChildItem $env:TEMP -Recurse -Depth 2 -Force -File -Filter '*JNativeHook*')
    if ($natives) { Add-Finding 'WARN' 'JNativeHook files in Temp - left behind by Java programs that hook the mouse/keyboard (common in Java autoclickers)' (($natives | ForEach-Object { '{0}  {1}' -f $_.LastWriteTime, $_.FullName }) -join "`n") }
    else { Add-Finding 'OK' 'No JNativeHook leftovers in Temp' }

    # USB storage devices ever connected (cheats are sometimes run from a USB stick)
    $usb = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' | ForEach-Object {
        Get-ChildItem $_.PSPath | ForEach-Object { (Get-ItemProperty $_.PSPath).FriendlyName }
    } | Where-Object { $_ } | Sort-Object -Unique)
    if ($usb) { Add-Finding 'INFO' "$($usb.Count) USB storage device(s) have been connected to this PC - check BAM/Prefetch for anything run from a non-C: drive" ($usb -join "`n") }
    $removable = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Removable' -and $_.IsReady })
    if ($removable) { Add-Finding 'WARN' "Removable drive(s) plugged in right now: $(($removable | ForEach-Object Name) -join ', ')" }
}

function Test-Misc {
    Add-Section 'Defender, recycle bin, recent files, running software'
    # Defender exclusions
    $mp = Get-MpPreference
    if ($mp) {
        $ex = @()
        $ex += $mp.ExclusionPath | Where-Object { $_ -and $_ -notmatch '(?i)^C:\\SSTools\\?$' -and $_ -ne $Script:ToolDir }
        $ex += $mp.ExclusionProcess | ForEach-Object { "process: $_" }
        $ex += $mp.ExclusionExtension | ForEach-Object { "extension: $_" }
        $ex = $ex | Where-Object { $_ }
        if ($ex) {
            $lvl = 'WARN'; if (($ex -join ' ') -match '(?i)minecraft|\.jar|jar$|javaw|appdata|temp|downloads') { $lvl = 'FLAG' }
            Add-Finding $lvl 'Windows Defender exclusions set (cheats often add these)' ($ex -join "`n")
        } else { Add-Finding 'OK' 'No Defender exclusions (other than SS tools)' }
        $st = Get-MpComputerStatus
        if ($st -and -not $st.RealTimeProtectionEnabled) { Add-Finding 'WARN' 'Defender real-time protection is off (normal if another antivirus is installed)' }
    }

    # Recycle bin
    $shell = New-Object -ComObject Shell.Application
    $rb = $shell.Namespace(10)
    if ($rb) {
        $items = @()
        foreach ($i in $rb.Items()) {
            if ($i.Name -match '(?i)\.(jar|exe|dll|ahk|bat|ps1)$' -or $i.Path -match '(?i)\.(jar|exe|dll|ahk|bat|ps1)$') {
                $items += ('{0}  {1}' -f $i.ExtendedProperty('System.Recycle.DateDeleted'), $i.Name)
            }
        }
        if ($items) { Add-Finding 'WARN' 'Executables/jars/scripts in the Recycle Bin' ($items -join "`n") }
        else { Add-Finding 'OK' 'No jars or executables in the Recycle Bin' }
    }

    # Recent executables in Downloads / Desktop / Temp
    $since = (Get-Date).AddHours(-$Script:RecentHrs)
    $places = @((Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('Desktop'), $env:TEMP)
    $recent = foreach ($p in $places) {
        Get-ChildItem $p -Recurse -Depth 2 -File -Force -Include *.jar, *.exe, *.dll, *.ahk, *.bat, *.ps1, *.vbs |
            Where-Object { $_.LastWriteTime -gt $since -or $_.CreationTime -gt $since }
    }
    if ($recent) {
        $kw = @($recent | Where-Object { Test-CheatWord $_.FullName })
        Add-Finding 'INFO' "Jars/executables/scripts created or changed in Downloads, Desktop or Temp in the last $($Script:RecentHrs)h" (($recent | Sort-Object LastWriteTime -Descending | ForEach-Object { '{0}  {1}' -f $_.LastWriteTime, $_.FullName }) -join "`n")
        if ($kw) { Add-Finding 'WARN' 'Recent files with suspicious names' (($kw | ForEach-Object FullName) -join "`n") }
    }

    # Running software
    $procs = Get-Process | Select-Object Name, Id, Path -Unique
    $sus = @()
    foreach ($p in $procs) {
        $w = Test-CheatWord "$($p.Name) $($p.Path)"
        if ($w) { $sus += "$($p.Name) (PID $($p.Id)) $($p.Path)   matched '$w'" }
        elseif ($p.Name -match '(?i)autohotkey|^ahk|macro|tinytask|jitbit|pulover') { $sus += "$($p.Name) (PID $($p.Id)) $($p.Path)   macro/automation software" }
        elseif ($p.Name -match '(?i)^bloody\d*$|bloody7') { $sus += "$($p.Name) (PID $($p.Id))   Bloody mouse software (heavy macro support)" }
    }
    if ($sus) { Add-Finding 'WARN' 'Running programs worth asking about' ($sus -join "`n") }
    else { Add-Finding 'OK' 'No running clickers, macro tools or keyword matches' }
    $mice = @($procs | Where-Object { $_.Name -match '(?i)razer|synapse|lghub|logi|steelseries|corsair|icue|glorious|roccat|swarm|hyperx|ngenuity' } | ForEach-Object Name | Sort-Object -Unique)
    if ($mice) { Add-Finding 'INFO' "Mouse/peripheral software running (check for macros): $($mice -join ', ')" }
}

# =====================================================================
#  EXTERNAL TOOLS
# =====================================================================

function Get-Tool([string]$Url, [string]$Name) {
    New-Item -ItemType Directory -Path $Script:ToolDir -Force | Out-Null
    $dest = Join-Path $Script:ToolDir $Name
    Write-Host "Downloading $Name..." -ForegroundColor DarkGray
    try { Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing -ErrorAction Stop; return $dest }
    catch { Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red; return $null }
}

# Download the newest .exe from a GitHub repo's releases
function Get-GitHubReleaseExe([string]$Repo) {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
        if (-not $asset) { throw 'no .exe in the latest release' }
        Write-Host "Latest release: $($rel.tag_name)" -ForegroundColor DarkGray
        return (Get-Tool $asset.browser_download_url $asset.name)
    } catch {
        Write-Host "Could not get the release automatically ($($_.Exception.Message)). Opening the releases page instead." -ForegroundColor Yellow
        Start-Process "https://github.com/$Repo/releases"
        return $null
    }
}

# Download a zip (NirSoft tools), extract it, return the exe inside
function Get-ZipTool([string]$Url, [string]$Name) {
    $zip = Get-Tool $Url "$Name.zip"
    if (-not $zip) { return $null }
    $dir = Join-Path $Script:ToolDir $Name
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    return (Get-ChildItem $dir -Filter '*.exe' -Recurse | Select-Object -First 1).FullName
}

function Start-RemoteScript([string]$Url, [string]$Title) {
    Write-Host "Opening $Title in a new window..." -ForegroundColor DarkGray
    $cmd = "`$host.UI.RawUI.WindowTitle = '$Title'; Invoke-Expression (Invoke-RestMethod '$Url')"
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

function Invoke-ExternalTool([string]$key) {
    switch ($key) {
        'S' { Start-RemoteScript $Script:Url.Services 'Services check (lilith)' }
        'M' { Start-RemoteScript $Script:Url.ModAnalyzer 'Yarp Mod Analyzer' }
        'J' {
            if (-not (Get-Process javaw)) { Write-Host 'Minecraft (javaw) is not running - the memory scan needs the game open.' -ForegroundColor Yellow }
            $p = Get-Tool $Script:Url.P1AE 'P1AE.Javaw.exe'; if ($p) { Start-Process $p -Verb RunAs }
        }
        'P' { $p = Get-GitHubReleaseExe $Script:Url.PrefetchParserRepo; if ($p) { Start-Process $p -Verb RunAs } }
        'A' { $p = Get-GitHubReleaseExe $Script:Url.BamParserRepo; if ($p) { Start-Process $p -Verb RunAs } }
        'W' { $p = Get-ZipTool $Script:Url.WinPrefetchView 'WinPrefetchView'; if ($p) { Start-Process $p -Verb RunAs } }
        'L' { $p = Get-ZipTool $Script:Url.LastActivityView 'LastActivityView'; if ($p) { Start-Process $p -Verb RunAs } }
        'K' {
            Write-Host 'Only take/analyze a kernel dump if you know how to read it.' -ForegroundColor Yellow
            $p = Get-GitHubReleaseExe $Script:Url.SystemInformerRepo
            if ($p) {
                $sig = Get-AuthenticodeSignature -LiteralPath $p
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Winsider') { Start-Process $p -Verb RunAs }
                else { Write-Host "Not running it: the download is not validly signed by Winsider ($($sig.Status)). Deleting it." -ForegroundColor Red; Remove-Item $p -Force }
            }
        }
        'C' {
            Remove-Item $Script:ToolDir -Recurse -Force
            Write-Host 'Cleanup done: tools downloaded by Tonytheboi Auto Screenshare were removed.' -ForegroundColor Green
            # Leftover from the old SSTools folder download (removed from this tool)
            if ((Get-MpPreference).ExclusionPath -contains 'C:\SSTools') {
                Remove-MpPreference -ExclusionPath 'C:\SSTools'
                Write-Host 'Also removed an old Defender exclusion for C:\SSTools.' -ForegroundColor Green
            }
        }
    }
}

# =====================================================================
#  MENU
# =====================================================================

$Script:Checks = [ordered]@{
    '2'  = @{ Name = 'System and Minecraft processes'; Fn = { Test-SystemInfo } }
    '3'  = @{ Name = 'Services';                       Fn = { Test-Services } }
    '4'  = @{ Name = 'Secure Boot and boot config';    Fn = { Test-SecureBoot } }
    '5'  = @{ Name = 'Event logs (cleared?)';          Fn = { Test-EventLogs } }
    '6'  = @{ Name = 'PowerShell history';             Fn = { Test-PSHistory } }
    '7'  = @{ Name = 'Prefetch';                       Fn = { Test-Prefetch } }
    '8'  = @{ Name = 'BAM';                            Fn = { Test-BAM } }
    '9'  = @{ Name = 'USN journal (deleted files)';    Fn = { Test-Usn } }
    '10' = @{ Name = 'Executed jars';                  Fn = { Test-Jars } }
    '11' = @{ Name = 'Mods folders';                   Fn = { Test-Mods } }
    '12' = @{ Name = 'Defender, recycle bin, recent files, running software'; Fn = { Test-Misc } }
    '13' = @{ Name = 'Startup entries, autoclicker natives, USB devices';     Fn = { Test-Extra } }
}

function Show-Menu {
    Clear-Host
    Write-Host "  Welcome to Tonytheboi Auto Screenshare Tool" -ForegroundColor Cyan
    Write-Host "  v$Script:Version" -ForegroundColor DarkGray
    Write-Host '  -------------------------------------------'
    Write-Host '  [1]  Run ALL checks + report (recommended)' -ForegroundColor Green
    foreach ($k in $Script:Checks.Keys) { Write-Host ('  [{0}] {1}' -f $k.PadRight(3), $Script:Checks[$k].Name) }
    Write-Host ''
    Write-Host '  External tools' -ForegroundColor Cyan
    Write-Host '  [S]  Services script (lilith)'
    Write-Host '  [M]  Yarp mod analyzer'
    Write-Host '  [J]  P1AE javaw memory scanner (game must be open)'
    Write-Host '  [P]  Prefetch Parser (spokwn) - prefetch + signatures + YARA'
    Write-Host '  [A]  BAM parser (spokwn)'
    Write-Host '  [W]  WinPrefetchView (NirSoft)'
    Write-Host '  [L]  LastActivityView (NirSoft) - timeline of everything run/opened'
    Write-Host '  [K]  System Informer, official signed build (kernel dump - experienced only)'
    Write-Host '  [C]  Cleanup (remove downloaded tools + Defender exclusion)'
    Write-Host '  [Q]  Quit'
    Write-Host ''
}

$host.UI.RawUI.WindowTitle = 'Tonytheboi Auto Screenshare'
Clear-Host
Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '    Welcome to Tonytheboi Auto Screenshare Tool' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''
Start-Sleep -Seconds 2

while ($true) {
    Show-Menu
    $choice = (Read-Host '  Choose').Trim().ToUpper()
    if ($choice -eq 'Q') { break }
    $Script:Report.Clear()
    if ($choice -eq '1') {
        foreach ($k in $Script:Checks.Keys) { & $Script:Checks[$k].Fn }
        Save-Report
        Write-Host ''
        Write-Host 'Next: run [J] memory scan and [M] mod analyzer, then go through the report.' -ForegroundColor Cyan
    } elseif ($Script:Checks.Contains($choice)) {
        & $Script:Checks[$choice].Fn
        Save-Report
    } elseif ('S', 'M', 'J', 'P', 'A', 'W', 'L', 'K', 'C' -contains $choice) {
        Invoke-ExternalTool $choice
    } else {
        Write-Host 'Unknown option.' -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host '  Press Enter to return to the menu' | Out-Null
}
