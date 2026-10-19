# Two-way clipboard sync (text, images and files) between this PC and an iPhone over the local Wi-Fi.
#   PC -> iPhone: the iPhone shortcut GETs  http://<PC-IP>:38765/?key=<key> and receives the PC clipboard:
#                 text as text, a copied image as PNG, one copied file as itself, several files/folders as Files.zip.
#   iPhone -> PC: the iPhone shortcut POSTs to the same URL.
#                 Text becomes the PC clipboard. Files (raw body or multipart form) are saved to
#                 Downloads\From iPhone and put on the PC clipboard, ready to paste in Explorer or a chat.
#                 A single .txt item counts as text; add &as=file to the URL to save it as a file instead.
# Runs on the built-in Windows PowerShell 5.1 or on PowerShell 7 (pwsh). The server must run with -STA:
# the Windows clipboard API for files and images needs a single-threaded apartment (-Install takes care of it).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Install          start now and at every login, pair a first device
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Pair "iPad"      add a device (each device gets its own key)
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Devices          list paired devices and when each was last seen
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Info -Device "iPad"  show a device's URL and setup page again
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Revoke "iPad"    cut off one device; the others keep working
#   powershell -ExecutionPolicy Bypass -File clip-sync.ps1 -Uninstall        stop it and remove it from startup (devices are kept)

#Requires -Version 5.1
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Devices,
    [string]$Pair,
    [string]$Revoke,
    [switch]$Info,
    [string]$Device,   # with -Info: which device; may be left out when only one is paired
    [switch]$NoBrowser,   # don't open the setup page in the browser
    [int]$Port = 38765   # outside the ranges Windows/Hyper-V usually reserves (netsh int ipv4 show excludedportrange protocol=tcp)
)

$DevicesFile  = Join-Path $PSScriptRoot 'devices.json'     # name + key per paired device; edited by the commands above
$LastSeenFile = Join-Path $PSScriptRoot 'last-seen.json'   # written only by the server, so -Revoke never races with it
$KeyFile      = Join-Path $PSScriptRoot 'key.txt'          # single shared key of older versions, migrated on first run
$InboxDir     = Join-Path $env:USERPROFILE 'Downloads\From iPhone'
$StartupLink  = Join-Path ([Environment]::GetFolderPath('Startup')) 'iPhone Clipboard Sync.lnk'
$FirewallRule = 'iPhone Clipboard Sync'
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
$GuideUrl     = 'https://github.com/asayed18/apple-bridge/tree/main/iphone-clipboard'

# iCloud links of the ready-made shortcuts, shown on the phone setup page (/setup).
# Each shortcut asks for the sync URL when it is added. Empty = not published yet.
$ShortcutLinks = [ordered]@{
    'Get from PC'          = 'https://www.icloud.com/shortcuts/905f2537215e4b22b1980facda92d167'
    'Send Clipboard to PC' = 'https://www.icloud.com/shortcuts/ac4370954568405bae60844963c87b13'
    'Send File to PC'      = 'https://www.icloud.com/shortcuts/58df2f621976410e9bbfc29a0864adec'
}

# ---------- Paired devices ----------
# Every device sends its own secret key, so other devices on the network can't use the clipboard
# and one lost phone can be revoked without re-pairing the rest.

function New-DeviceKey {
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

# Throws if the file exists but can't be read or parsed: treating a damaged devices.json as
# "no devices" would let the next -Pair overwrite every paired device.
function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = [IO.File]::ReadAllText($path, $Utf8NoBom)
    if (-not $text.Trim()) { return $null }
    try { ConvertFrom-Json $text -ErrorAction Stop }
    catch { throw "Could not read $path ($($_.Exception.Message)). Fix or delete the file and try again." }
}

function Write-JsonFile([string]$path, $value) {
    # Write a temp file, then swap it in, so readers never see a half-written file.
    # The swap is retried because the other process may have the file open for a moment.
    $temp = "$path.$PID.tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $value -Depth 4), $Utf8NoBom)
    for ($attempt = 1; ; $attempt++) {
        try { Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop; return }
        catch {
            if ($attempt -ge 10) {
                Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
                throw "Could not save $path ($($_.Exception.Message))."
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Get-Devices {
    if (-not (Test-Path -LiteralPath $DevicesFile) -and (Test-Path -LiteralPath $KeyFile)) {
        # Older versions had one key for everyone: keep it working as the first device.
        $oldKey = [IO.File]::ReadAllText($KeyFile).Trim()
        Save-Devices @([pscustomobject]@{ name = 'iPhone'; key = $oldKey; added = (Get-Date).ToString('s') })
        Remove-Item -LiteralPath $KeyFile
    }
    # Windows PowerShell 5.1 emits a JSON array as one object, so enumerate it explicitly.
    $parsed = Read-JsonFile $DevicesFile
    @(@($parsed) | Where-Object { $_ -and $_.name -and $_.key })
}

function Save-Devices($paired) {
    Write-JsonFile $DevicesFile @($paired)
}

function Find-Device($paired, [string]$name) {
    $paired | Where-Object { $_.name -eq $name } | Select-Object -First 1   # -eq is case-insensitive
}

# ---------- Setup commands ----------

# The PC's address on the home network: a real (non-VPN, non-virtual) adapter that has a default gateway.
function Get-LanAddress {
    $physical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -in $physical.ifIndex } |
        Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4).InterfaceMetric }
    foreach ($route in $routes) {
        $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        if ($address) { return $address.IPAddress }
    }
    $null
}

function Get-ServerProcess {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$([IO.Path]::GetFileName($PSCommandPath))*" -and $_.ProcessId -ne $PID }
}

function Show-Info($device) {
    $ip = Get-LanAddress
    if (-not $ip) {
        Write-Warning 'Could not find this PC''s home-network address. Run ipconfig and use the IPv4 address of your Wi-Fi or Ethernet adapter.'
        $ip = '<PC-IP>'
    }
    $url = "http://${ip}:$Port/?key=$($device.key)"
    $setupUrl = "http://${ip}:$Port/setup?key=$($device.key)"
    # Not copied to the PC clipboard: every paired device can read that, so it would learn this device's key.
    Write-Host ''
    Write-Host "URL for the shortcuts on '$($device.name)':" -ForegroundColor Cyan
    Write-Host "  $url" -ForegroundColor Green
    Write-Host ''
    Write-Host "Setup page (opening in your browser now; scan its QR code with the camera on '$($device.name)'):" -ForegroundColor Cyan
    Write-Host "  $setupUrl"
    if ($ip -ne '<PC-IP>' -and -not $NoBrowser) { Start-Process $setupUrl }
    Write-Host ''
    Write-Host 'Received files are saved to:' -ForegroundColor Cyan
    Write-Host "  $InboxDir"

    if (-not (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host 'If the iPhone cannot connect, allow it through Windows Firewall once.' -ForegroundColor Yellow
        Write-Host 'Run this in PowerShell opened as Administrator (skip it if you already clicked "Allow" in a firewall pop-up):'
        Write-Host "  New-NetFirewallRule -DisplayName '$FirewallRule' -Direction Inbound -Protocol TCP -LocalPort $Port -Profile Private -Action Allow"
        Write-Host 'Your Wi-Fi must be set to the Private network profile (Settings > Network & internet).'
    }
}

function Show-Devices($paired) {
    # A one-item list arrives as a single object (no .Count on 5.1), an empty one as $null.
    $paired = @($paired | Where-Object { $_ })
    $lastSeen = Read-JsonFile $LastSeenFile
    if (-not $paired.Count) {
        Write-Host 'No devices are paired. Add one with:  -Pair "iPhone"'
        return
    }
    $paired | ForEach-Object {
        $seen = if ($lastSeen -and $lastSeen.($_.key)) { $lastSeen.($_.key) } else { 'never' }
        [pscustomobject]@{ Device = $_.name; Added = $_.added; 'Last seen' = $seen }
    } | Format-Table -AutoSize | Out-String | Write-Host
}

# The device a command refers to: the named one, or the only one when no name is given.
function Resolve-Device($paired, [string]$name) {
    $paired = @($paired | Where-Object { $_ })
    if ($name) {
        $device = Find-Device $paired $name
        if (-not $device) { throw "No device named '$name'. Run -Devices to list them." }
        return $device
    }
    if ($paired.Count -eq 1) { return $paired[0] }
    if (-not $paired.Count) { throw 'No devices are paired. Add one with:  -Pair "iPhone"' }
    throw "Several devices are paired; name one, e.g. -Info `"$($paired[0].name)`". Run -Devices to list them."
}

if ($Uninstall) {
    Get-ServerProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Remove-Item -LiteralPath $StartupLink -ErrorAction SilentlyContinue
    Write-Host 'Stopped and removed from startup. Paired devices are kept for a later -Install.'
    if (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue) {
        Write-Host "To remove the firewall rule, run as Administrator:  Remove-NetFirewallRule -DisplayName '$FirewallRule'"
    }
    exit
}

if ($Install) {
    $excluded = netsh int ipv4 show excludedportrange protocol=tcp | Select-String '^\s*(\d+)\s+(\d+)' |
        Where-Object { [int]$_.Matches[0].Groups[1].Value -le $Port -and $Port -le [int]$_.Matches[0].Groups[2].Value }
    if ($excluded) { throw "Windows reserves port $Port on this PC. Run -Install again with another port, e.g. -Port 38766." }

    $shell = (Get-Process -Id $PID).Path   # whichever PowerShell ran -Install: powershell.exe or pwsh.exe
    $arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLink)
    $shortcut.TargetPath = $shell
    $shortcut.Arguments = $arguments
    $shortcut.WindowStyle = 7   # minimized
    $shortcut.Save()

    Get-ServerProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $shell -ArgumentList $arguments -WindowStyle Hidden
    Write-Host 'Running in the background, and will start automatically at every login.' -ForegroundColor Green
    Start-Sleep -Seconds 3   # let the server start before the setup page opens

    $paired = @(Get-Devices)
    if (-not $paired.Count) {
        $paired = @([pscustomobject]@{ name = 'iPhone'; key = (New-DeviceKey); added = (Get-Date).ToString('s') })
        Save-Devices $paired
        Write-Host "Paired a first device named 'iPhone'. Add more with -Pair `"iPad`"."
    }
    if ($paired.Count -eq 1) { Show-Info $paired[0] } else { Show-Devices $paired }
    exit
}

if ($Pair) {
    $Pair = $Pair.Trim()
    if (-not $Pair) { throw 'Give the device a name, e.g. -Pair "iPad".' }
    $paired = @(Get-Devices)
    $existing = Find-Device $paired $Pair
    if ($existing) {
        # Re-showing the same key lets a reinstalled phone pick up its old URL.
        Write-Host "'$($existing.name)' is already paired; showing its URL again. Use -Revoke first to give it a new key." -ForegroundColor Yellow
        Show-Info $existing
        exit
    }
    $new = [pscustomobject]@{ name = $Pair; key = (New-DeviceKey); added = (Get-Date).ToString('s') }
    Save-Devices (@($paired) + $new)
    Write-Host "Paired '$($new.name)'." -ForegroundColor Green
    Show-Info $new
    exit
}

if ($Revoke) {
    $paired = @(Get-Devices)
    $revoked = Find-Device $paired $Revoke
    if (-not $revoked) { throw "No device named '$Revoke'. Run -Devices to list them." }
    Save-Devices @($paired | Where-Object { $_.key -ne $revoked.key })
    Write-Host "Revoked '$($revoked.name)'. It can no longer reach this PC; the other devices are not affected." -ForegroundColor Green
    exit
}

if ($Devices) {
    Show-Devices (Get-Devices)
    exit
}

if ($Info) {
    Show-Info (Resolve-Device (Get-Devices) $Device)
    exit
}

# ---------- Server ----------

# Only one copy of the script may run at a time.
$mutex = New-Object System.Threading.Mutex($false, "Global\iPhoneClipboardSync-$Port")
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

public class FormPart {
    public string FileName;
    public string EscapedFileName;   // percent-encoded name from filename*=UTF-8''...
    public string ContentType;
    public byte[] Data;
}

// Byte-level helpers that would be far too slow as PowerShell loops on large files.
public static class HttpBytes {
    static int IndexOf(byte[] haystack, byte[] needle, int start) {
        for (int i = start; i <= haystack.Length - needle.Length; i++) {
            int j = 0;
            while (j < needle.Length && haystack[i + j] == needle[j]) j++;
            if (j == needle.Length) return i;
        }
        return -1;
    }

    public static List<FormPart> ParseMultipart(byte[] body, string boundary) {
        var parts = new List<FormPart>();
        byte[] delimiter = Encoding.ASCII.GetBytes("--" + boundary);
        byte[] headerEnd = Encoding.ASCII.GetBytes("\r\n\r\n");
        int pos = IndexOf(body, delimiter, 0);
        while (pos >= 0) {
            int start = pos + delimiter.Length;
            if (start + 1 < body.Length && body[start] == '-' && body[start + 1] == '-') break;   // closing delimiter
            start += 2;   // CRLF after the delimiter
            int headersEnd = IndexOf(body, headerEnd, start);
            if (headersEnd < 0) break;
            int dataStart = headersEnd + headerEnd.Length;
            int next = IndexOf(body, delimiter, dataStart);
            if (next < 0) break;

            var part = new FormPart();
            foreach (string line in Encoding.UTF8.GetString(body, start, headersEnd - start).Split(new[] { "\r\n" }, StringSplitOptions.None)) {
                if (line.StartsWith("content-type:", StringComparison.OrdinalIgnoreCase)) part.ContentType = line.Substring(13).Trim();
                string star = HeaderParameter(line, "filename*=UTF-8''", ';');
                string plain = HeaderParameter(line, "filename=\"", '"');
                if (star != null) part.EscapedFileName = star.Trim();   // unescaped in PowerShell: Uri is unusable here on 5.1
                else if (plain != null) part.FileName = DecodeEncodedWord(plain);
            }
            int length = Math.Max(0, next - 2 - dataStart);   // the part ends with CRLF before the delimiter
            part.Data = new byte[length];
            Buffer.BlockCopy(body, dataStart, part.Data, 0, length);
            parts.Add(part);
            pos = next;
        }
        return parts;
    }

    // The text after `prefix` up to `end` (or the end of the line); null when the prefix is absent.
    // Plain string handling instead of Regex: on some Windows PowerShell 5.1 setups Add-Type cannot resolve System.dll types.
    static string HeaderParameter(string line, string prefix, char end) {
        int start = line.IndexOf(prefix, StringComparison.OrdinalIgnoreCase);
        if (start < 0) return null;
        start += prefix.Length;
        int stop = line.IndexOf(end, start);
        return stop < 0 ? line.Substring(start) : line.Substring(start, stop - start);
    }

    // Some clients send non-ASCII file names as RFC 2047 words: =?utf-8?B?...?=
    static string DecodeEncodedWord(string value) {
        if (!value.StartsWith("=?") || !value.EndsWith("?=")) return value;
        string[] pieces = value.Substring(2, value.Length - 4).Split(new[] { '?' }, 3);
        if (pieces.Length != 3) return value;
        try {
            Encoding encoding = Encoding.GetEncoding(pieces[0]);
            if (pieces[1].ToUpperInvariant() == "B") return encoding.GetString(Convert.FromBase64String(pieces[2]));
            var bytes = new List<byte>();
            string q = pieces[2].Replace('_', ' ');
            for (int i = 0; i < q.Length; i++) {
                if (q[i] == '=' && i + 2 < q.Length) { bytes.Add(Convert.ToByte(q.Substring(i + 1, 2), 16)); i += 2; }
                else bytes.Add((byte)q[i]);
            }
            return encoding.GetString(bytes.ToArray());
        } catch (Exception) {
            return value;
        }
    }

    public static bool LooksLikeText(byte[] data) {
        if (data.Length == 0 || Array.IndexOf(data, (byte)0) >= 0) return false;
        try { new UTF8Encoding(false, true).GetString(data); return true; }
        catch (ArgumentException) { return false; }
    }
}
'@

$MimeTypes = @{
    '.txt' = 'text/plain'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'
    '.heic' = 'image/heic'; '.webp' = 'image/webp'; '.pdf' = 'application/pdf'; '.zip' = 'application/zip'
    '.mp4' = 'video/mp4'; '.mov' = 'video/quicktime'; '.mp3' = 'audio/mpeg'; '.m4a' = 'audio/mp4'
}

# ---------- HTTP plumbing ----------

function Read-Exactly($stream, [long]$count) {
    $buffer = New-Object byte[] $count
    $offset = 0
    while ($offset -lt $count) {
        $read = $stream.Read($buffer, $offset, $count - $offset)
        if ($read -le 0) { break }
        $offset += $read
    }
    , $buffer   # the comma stops PowerShell from unrolling the array into millions of objects
}

function Read-Line($stream) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { break }
        if ($b -eq 10) { break }
        if ($b -ne 13) { $bytes.Add([byte]$b) }
    }
    $Utf8NoBom.GetString($bytes.ToArray())
}

function Read-Body($stream, $headers) {
    if ($headers['transfer-encoding'] -eq 'chunked') {
        $body = New-Object IO.MemoryStream
        while ($true) {
            $size = [Convert]::ToInt32((Read-Line $stream).Split(';')[0].Trim(), 16)
            if ($size -eq 0) {
                # Consume the trailer up to the final blank line; unread bytes make Close() reset the connection.
                while (Read-Line $stream) { }
                break
            }
            $chunk = Read-Exactly $stream $size
            $body.Write($chunk, 0, $chunk.Length)
            Read-Line $stream | Out-Null   # CRLF after each chunk
        }
        return , $body.ToArray()
    }
    $length = [long]$headers['content-length']
    if ($length -gt 0) { return , (Read-Exactly $stream $length) }
    return , [byte[]]@()
}

function Send-Response($stream, [string]$status, [byte[]]$body, [string]$contentType = 'text/plain; charset=utf-8', [string]$fileName) {
    $header = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n"
    if ($fileName) {
        $ascii = $fileName -replace '[^\x20-\x7E]|"', '_'
        $header += "Content-Disposition: attachment; filename=`"$ascii`"; filename*=UTF-8''$([Uri]::EscapeDataString($fileName))`r`n"
    }
    $headerBytes = [Text.Encoding]::ASCII.GetBytes("$header`r`n")
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
}

function Send-Text($stream, [string]$status, [string]$text) {
    Send-Response $stream $status $Utf8NoBom.GetBytes($text)
}

# ---------- Phone setup page ----------

# Opened on the PC it shows a QR code of its own address; scanned with the iPhone it shows the
# sync URL with a Copy button and the links to add the ready-made shortcuts.
# (Keep this file ASCII-only: Windows PowerShell 5.1 reads scripts without a BOM as ANSI.)
function Get-SetupPage([string]$syncUrl, [string]$deviceName) {
    $shortcuts = foreach ($entry in $ShortcutLinks.GetEnumerator()) { @{ name = $entry.Key; link = $entry.Value } }
    $html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Clipboard Sync setup</title>
<style>
  :root { --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --accent: #0071e3; --ok: #1a7f37; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --line: #38383a; --accent: #2997ff; --ok: #3fb950; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width: 560px; margin: 0 auto; padding: 32px 16px 48px; }
  h1 { font-size: 28px; margin: 0 0 4px; }
  .lead { color: var(--muted); margin: 0 0 24px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 20px; margin-bottom: 16px; }
  .card h2 { font-size: 17px; margin: 0 0 6px; }
  .step { display: inline-block; width: 24px; height: 24px; border-radius: 50%; background: var(--accent); color: #fff; font-size: 13px; text-align: center; line-height: 24px; margin-right: 8px; }
  p { margin: 0 0 12px; }
  a { color: var(--accent); word-break: break-all; }
  .muted { color: var(--muted); font-size: 14px; }
  .row { display: flex; gap: 8px; }
  input { flex: 1; min-width: 0; font: 14px ui-monospace, Consolas, monospace; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; background: var(--bg); color: var(--text); }
  button, .btn { font: 600 15px/1 inherit; font-family: inherit; padding: 11px 16px; border-radius: 10px; border: 0; background: var(--accent); color: #fff; text-decoration: none; white-space: nowrap; cursor: pointer; }
  .btn.off { background: var(--line); color: var(--muted); pointer-events: none; }
  .shortcut { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 0; border-top: 1px solid var(--line); }
  .shortcut:first-of-type { border-top: 0; }
  .shortcut b { display: block; }
  #qr { background: #fff; padding: 12px; border-radius: 12px; width: 240px; max-width: 100%; margin: 8px auto 0; }
  #qr svg { display: block; width: 100%; height: auto; }
  .ok { color: var(--ok); font-weight: 600; }
  .hidden { display: none; }
</style>
</head>
<body>
<main>
  <h1>Clipboard Sync</h1>
  <p class="lead">Setting up <b>{{DEVICE}}</b>. Copy on it, paste on this PC, and the other way round.</p>

  <section class="card hidden" id="scan">
    <h2>Scan with your iPhone camera</h2>
    <p class="muted">Your iPhone must be on the same Wi-Fi as this PC. The page opens there with the next steps.</p>
    <div id="qr"></div>
    <p class="muted hidden" id="qr-failed">The QR code needs an internet connection. Open this page's address on your iPhone instead.</p>
  </section>

  <section class="card">
    <h2><span class="step">1</span>Copy your PC's address</h2>
    <p class="muted">Each shortcut asks for it once, when you add it.</p>
    <div class="row">
      <input id="url" readonly>
      <button id="copy" type="button">Copy</button>
    </div>
  </section>

  <section class="card">
    <h2><span class="step">2</span>Add the shortcuts</h2>
    <p class="muted">Tap Add, then paste the address when Shortcuts asks for it.</p>
    <div id="shortcuts"></div>
  </section>

  <section class="card">
    <h2><span class="step">3</span>Make it one tap</h2>
    <p class="muted">Settings &rarr; Accessibility &rarr; Touch &rarr; Back Tap: set Double Tap to <b>Get from PC</b> and Triple Tap to <b>Send Clipboard to PC</b>. Turn on <b>Show in Share Sheet</b> for <b>Send File to PC</b>.</p>
    <p class="muted">Step-by-step guide and manual setup: <a href="{{GUIDE_URL}}">{{GUIDE_URL}}</a></p>
  </section>
</main>

<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js"
        integrity="sha512-ZDSPMa/JM1D+7kdg2x3BsruQ6T/JpJo3jWDWkCZsP+5yVyp1KfESqLI+7RqB5k24F7p2cV7i2YHh/890y6P6Sw=="
        crossorigin="anonymous" referrerpolicy="no-referrer"></script>
<script>
  var syncUrl = {{SYNC_URL}};
  var shortcuts = {{SHORTCUTS}};
  var descriptions = {
    'Get from PC': 'Puts the PC clipboard on your iPhone.',
    'Send Clipboard to PC': 'Sends your iPhone clipboard to the PC.',
    'Send File to PC': 'Share photos and files from the Share Sheet.'
  };

  document.getElementById('url').value = syncUrl;

  var list = document.getElementById('shortcuts');
  shortcuts.forEach(function (s) {
    var row = document.createElement('div');
    row.className = 'shortcut';
    var text = document.createElement('div');
    var name = document.createElement('b');
    name.textContent = s.name;
    var note = document.createElement('span');
    note.className = 'muted';
    note.textContent = descriptions[s.name] || '';
    text.appendChild(name);
    text.appendChild(note);
    var add = document.createElement('a');
    add.className = s.link ? 'btn' : 'btn off';
    add.textContent = s.link ? 'Add' : 'Coming soon';
    if (s.link) add.href = s.link;
    row.appendChild(text);
    row.appendChild(add);
    list.appendChild(row);
  });

  // The page is plain http on the local network, where navigator.clipboard is unavailable,
  // so copy through a temporary selection (this also works in iOS Safari).
  document.getElementById('copy').addEventListener('click', function () {
    var input = document.getElementById('url');
    var button = this;
    input.readOnly = false;
    input.focus();
    input.setSelectionRange(0, input.value.length);
    var copied = false;
    try { copied = document.execCommand('copy'); } catch (e) {}
    input.readOnly = true;
    input.blur();
    if (!copied && navigator.clipboard) { navigator.clipboard.writeText(syncUrl); copied = true; }
    button.textContent = copied ? 'Copied' : 'Select and copy';
    setTimeout(function () { button.textContent = 'Copy'; }, 2000);
  });

  // On the PC, show a QR code of this page so the iPhone camera can open it.
  if (!/iPhone|iPad|iPod/.test(navigator.userAgent)) {
    document.getElementById('scan').classList.remove('hidden');
    if (window.qrcode) {
      var qr = qrcode(0, 'M');
      qr.addData(location.href);
      qr.make();
      document.getElementById('qr').innerHTML = qr.createSvgTag(4, 0);
    } else {
      document.getElementById('qr').classList.add('hidden');
      document.getElementById('qr-failed').classList.remove('hidden');
    }
  }
</script>
</body>
</html>
'@
    $html.Replace('{{SYNC_URL}}', (ConvertTo-Json $syncUrl -Compress)).
        Replace('{{SHORTCUTS}}', (ConvertTo-Json @($shortcuts) -Compress)).
        Replace('{{DEVICE}}', [Net.WebUtility]::HtmlEncode($deviceName)).
        Replace('{{GUIDE_URL}}', $GuideUrl)
}

# ---------- Clipboard and files ----------

function Get-UniquePath([string]$fileName) {
    if (-not (Test-Path $InboxDir)) { New-Item -ItemType Directory -Path $InboxDir | Out-Null }
    $fileName = [IO.Path]::GetFileName($fileName)
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $fileName = $fileName.Replace($c, '_') }
    if (-not $fileName) { $fileName = 'file' }
    $base = [IO.Path]::GetFileNameWithoutExtension($fileName)
    $ext = [IO.Path]::GetExtension($fileName)
    $path = Join-Path $InboxDir $fileName
    for ($i = 1; Test-Path -LiteralPath $path; $i++) { $path = Join-Path $InboxDir "$base ($i)$ext" }
    $path
}

function Get-ExtensionFor([string]$contentType, [byte[]]$data) {
    $mime = "$contentType".Split(';')[0].Trim().ToLower()
    foreach ($entry in $MimeTypes.GetEnumerator()) { if ($entry.Value -eq $mime) { return $entry.Key } }
    # Fall back to the file signature.
    if ($data.Length -ge 4) {
        $hex = [BitConverter]::ToString($data, 0, 4)
        switch -Wildcard ($hex) {
            '89-50-4E-47' { return '.png' }
            'FF-D8-FF-*'  { return '.jpg' }
            '25-50-44-46' { return '.pdf' }
            '50-4B-03-04' { return '.zip' }
            '47-49-46-38' { return '.gif' }
        }
    }
    if ($data.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($data, 4, 4) -eq 'ftyp') {
        if ([Text.Encoding]::ASCII.GetString($data, 8, 4) -match 'hei|mif') { return '.heic' }
        return '.mp4'
    }
    '.bin'
}

function Set-ClipboardFiles([string[]]$paths) {
    $data = New-Object Windows.Forms.DataObject
    $list = New-Object Collections.Specialized.StringCollection
    foreach ($p in $paths) { [void]$list.Add($p) }
    $data.SetFileDropList($list)
    # A single picture also goes on the clipboard as an image, so it pastes straight into chats and documents.
    if ($paths.Count -eq 1 -and $paths[0] -match '\.(png|jpe?g|gif|bmp)$') {
        try {
            $image = [Drawing.Image]::FromFile($paths[0])
            $data.SetImage((New-Object Drawing.Bitmap($image)))
            $image.Dispose()   # release the file lock
        } catch { }
    }
    [Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
}

function Set-ClipboardText([string]$text) {
    [Windows.Forms.Clipboard]::SetDataObject($text, $true, 10, 100)
}

function Save-Files($parts) {
    $paths = foreach ($part in $parts) {
        $name = $part.FileName
        if (-not $name) { $name = 'iPhone ' + (Get-Date -Format 'yyyy-MM-dd HHmmss') + (Get-ExtensionFor $part.ContentType $part.Data) }
        $path = Get-UniquePath $name
        [IO.File]::WriteAllBytes($path, $part.Data)
        $path
    }
    Set-ClipboardFiles @($paths)
    @($paths).Count
}

# What the iPhone receives for the current PC clipboard.
function Get-ClipboardPayload {
    if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = @([Windows.Forms.Clipboard]::GetFileDropList())
        if ($files.Count -eq 1 -and (Test-Path -LiteralPath $files[0] -PathType Leaf)) {
            return @{ Name = [IO.Path]::GetFileName($files[0]); Bytes = [IO.File]::ReadAllBytes($files[0]) }
        }
        $zip = Join-Path $env:TEMP 'clip-sync-Files.zip'
        Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
        Compress-Archive -LiteralPath $files -DestinationPath $zip
        $bytes = [IO.File]::ReadAllBytes($zip)
        Remove-Item -LiteralPath $zip
        return @{ Name = 'Files.zip'; Bytes = $bytes }
    }
    if ([Windows.Forms.Clipboard]::ContainsImage()) {
        $stream = New-Object IO.MemoryStream
        [Windows.Forms.Clipboard]::GetImage().Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return @{ Name = 'Clipboard.png'; Bytes = $stream.ToArray() }
    }
    @{ Text = [Windows.Forms.Clipboard]::GetText() }
}

# ---------- Device keys ----------

$script:DeviceCache = @()
$script:DeviceStamp = 'not loaded'   # never equals a real stamp, so the first request loads (and migrates key.txt)
$script:LastSeen    = @{}            # device key -> last visit, seeded from last-seen.json so a restart keeps history
$script:SavedKeys   = @{}            # device keys already present in last-seen.json
$script:LastSaved   = [datetime]::MinValue

function Write-ErrorLog([string]$message) {
    "$(Get-Date -Format s)  $message" | Add-Content (Join-Path $PSScriptRoot 'error.log')
}

try {
    $saved = Read-JsonFile $LastSeenFile
    if ($saved) {
        foreach ($p in $saved.PSObject.Properties) { $script:LastSeen[$p.Name] = $p.Value; $script:SavedKeys[$p.Name] = $true }
    }
} catch { Write-ErrorLog $_.Exception.Message }

# The paired device that owns this key, or $null. devices.json is re-read whenever it changes,
# so -Pair and -Revoke take effect on the next request without restarting the server.
function Find-DeviceByKey([string]$key) {
    $stamp = if (Test-Path -LiteralPath $DevicesFile) { (Get-Item -LiteralPath $DevicesFile).LastWriteTimeUtc } else { $null }
    if ($stamp -ne $script:DeviceStamp) {
        try {
            $script:DeviceCache = @(Get-Devices)
            $script:DeviceStamp = $stamp
        } catch {
            # Keep serving the devices we already know; try again on the next request.
            Write-ErrorLog $_.Exception.Message
        }
    }
    if (-not $key) { return $null }
    $script:DeviceCache | Where-Object { $_.key -ceq $key } | Select-Object -First 1   # keys are case-sensitive
}

function Update-LastSeen($device) {
    $script:LastSeen[$device.key] = (Get-Date).ToString('s')
    # Save at once for a device not in the file yet; otherwise at most once a minute,
    # so a busy clipboard doesn't rewrite the file on every copy.
    $isNew = -not $script:SavedKeys[$device.key]
    if (-not $isNew -and ((Get-Date) - $script:LastSaved).TotalSeconds -lt 60) { return }
    $live = @{}
    foreach ($d in $script:DeviceCache) { if ($script:LastSeen[$d.key]) { $live[$d.key] = $script:LastSeen[$d.key] } }
    Write-JsonFile $LastSeenFile $live
    $script:SavedKeys = @{}
    foreach ($k in $live.Keys) { $script:SavedKeys[$k] = $true }
    $script:LastSaved = Get-Date
}

# ---------- Requests ----------

function Invoke-Request($client) {
    $client.ReceiveTimeout = 15000
    $client.SendTimeout = 15000
    $stream = $client.GetStream()

    $method, $target, $null = (Read-Line $stream).Split(' ')
    $headers = @{}
    while ($line = Read-Line $stream) {
        $name, $value = $line.Split(':', 2)
        $headers[$name.Trim().ToLower()] = "$value".Trim()
    }

    $key = if ($target -match '[?&]key=([^&]+)') { $Matches[1] } else { '' }
    $device = Find-DeviceByKey $key
    if (-not $device) {
        Send-Text $stream '403 Forbidden' 'Forbidden: unknown or revoked device key'
        return
    }
    try { Update-LastSeen $device } catch { Write-ErrorLog $_.Exception.Message }   # bookkeeping must not block a copy

    switch ($method) {
        'GET' {
            if ($target -like '/setup*') {
                $hostName = $headers['host']
                if (-not $hostName) { $hostName = "$(Get-LanAddress):$Port" }
                $page = Get-SetupPage "http://$hostName/?key=$($device.key)" $device.name
                Send-Response $stream '200 OK' $Utf8NoBom.GetBytes($page) 'text/html; charset=utf-8'
                return
            }
            $payload = Get-ClipboardPayload
            if ($payload.ContainsKey('Text')) {
                Send-Text $stream '200 OK' $payload.Text
            } else {
                $mime = $MimeTypes[[IO.Path]::GetExtension($payload.Name).ToLower()]
                if (-not $mime) { $mime = 'application/octet-stream' }
                Send-Response $stream '200 OK' $payload.Bytes $mime $payload.Name
            }
        }
        'POST' {
            $body = Read-Body $stream $headers
            $contentType = "$($headers['content-type'])"
            if ($contentType -match 'multipart/form-data.*boundary="?([^";]+)"?') {
                $parts = @([HttpBytes]::ParseMultipart($body, $Matches[1]) | Where-Object { $_.Data.Length -gt 0 })
                foreach ($part in $parts) {
                    if ($part.EscapedFileName) { $part.FileName = [Uri]::UnescapeDataString($part.EscapedFileName) }
                }
                # Shortcuts wraps copied text in a file like "Clipboard 19. Oct 2026 at 15.20.txt",
                # so a single plain-text item counts as text unless the URL asks for &as=file.
                $textParts = @($parts | Where-Object {
                    [HttpBytes]::LooksLikeText($_.Data) -and
                    (-not $_.FileName -or "$($_.ContentType)" -like 'text/plain*' -or $_.FileName -like '*.txt')
                })
                if ($parts.Count -eq 1 -and $textParts.Count -eq 1 -and $target -notmatch '[?&]as=file') {
                    Set-ClipboardText $Utf8NoBom.GetString($parts[0].Data)
                    Send-Text $stream '200 OK' 'Text copied'
                } else {
                    Send-Text $stream '200 OK' "Saved $(Save-Files $parts) file(s)"
                }
            } elseif ($body.Length -eq 0) {
                Send-Text $stream '400 Bad Request' 'Nothing was sent'
            } elseif (($contentType -eq '' -or $contentType -like 'text/*') -and [HttpBytes]::LooksLikeText($body) -and $target -notmatch '[?&]as=file') {
                Set-ClipboardText $Utf8NoBom.GetString($body)
                Send-Text $stream '200 OK' 'Text copied'
            } else {
                $part = New-Object FormPart
                $part.ContentType = $contentType
                $part.Data = $body
                if ($target -match '[?&]name=([^&]+)') { $part.FileName = [Uri]::UnescapeDataString($Matches[1]) }
                Send-Text $stream '200 OK' "Saved $(Save-Files @($part)) file(s)"
            }
        }
        default {
            Send-Text $stream '405 Method Not Allowed' 'Use GET or POST'
        }
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
$listener.Start()

while ($true) {
    $client = $listener.AcceptTcpClient()
    try { Invoke-Request $client }
    catch { Write-ErrorLog $_.Exception.Message }
    finally { $client.Close() }
}
