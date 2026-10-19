# iPhone ⇄ Windows clipboard over Wi-Fi

A "Universal Clipboard" for iPhone and Windows: copy on one device, paste on the other.
It works with **text, images and files**, in both directions, with no app to install on the iPhone,
no iCloud and no cloud service: a small PowerShell script on the PC and three iPhone Shortcuts.

| You copy on… | The other side gets |
|---|---|
| PC: text | text |
| PC: a screenshot / copied image | `Clipboard.png` |
| PC: one file in Explorer | that file, with its name |
| PC: several files or a folder | `Files.zip` |
| iPhone: text | the PC clipboard, ready for Ctrl+V |
| iPhone: photos / files | saved to `Downloads\From iPhone` and put on the PC clipboard (Ctrl+V in Explorer or a chat) |

Both devices must be on the **same network** (e.g. your home Wi-Fi).

---

## 1. PC setup (once)

Nothing to install: it runs on the **Windows PowerShell 5.1** built into Windows 10/11 (PowerShell 7 works too).

1. Download [`clip-sync.ps1`](clip-sync.ps1) (or clone this repository) into a folder you'll keep, e.g. `C:\Users\<you>\Scripts\iPhoneClipboard\`.
2. Open PowerShell in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Install
   ```

   This:
   - starts the script hidden in the background and adds it to Windows startup,
   - pairs a first device named `iPhone` with its own random secret key (stored in `devices.json`, next to the script),
   - **detects your PC's local IP address** and prints the URL for the iPhone, e.g.
     `http://192.168.1.23:38765/?key=AbC123...` (it's also copied to your clipboard),
   - opens the **phone setup page** in your browser, with a QR code to scan with the iPhone camera.

3. If Windows Firewall shows a pop-up for PowerShell, click **Allow** (private networks).
   If the iPhone still can't connect, allow the port once (PowerShell **as Administrator**):

   ```powershell
   New-NetFirewallRule -DisplayName 'iPhone Clipboard Sync' -Direction Inbound -Protocol TCP -LocalPort 38765 -Profile Private -Action Allow
   ```

   Your Wi-Fi must use the **Private** network profile (Settings → Network & internet → your network).

### More devices

Every iPhone, iPad or other device gets **its own key**, so you can cut off one lost phone without touching the others.
All paired devices share the same PC clipboard.

```powershell
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Pair "iPad"           # add a device; opens its setup page
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Devices               # list devices and when each was last seen
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Info -Device "iPad"   # show a device's URL and setup page again
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Revoke "iPad"         # cut off that device right away
```

- Reinstalled a phone? Run `-Pair` with its existing name: you get the **same** URL back, so nothing else changes.
- Lost a phone? `-Revoke` it. The server picks the change up immediately; the other devices keep working.
  Pair it again later to give it a **new** key.
- Device names are not case-sensitive (`iPad` and `ipad` are the same device).

### Other commands

```powershell
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Info                  # print the URL again (when only one device is paired)
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Uninstall             # stop it and remove it from startup (devices are kept)
powershell -ExecutionPolicy Bypass -File .\clip-sync.ps1 -Install -Port 38766   # use another port
```

Add `-NoBrowser` to any command that would open the setup page if you only want the URL printed.

Upgrading from an older version with `key.txt`: the first run turns that key into a device named `iPhone`,
so your existing shortcuts keep working.

> **Tip:** the URL contains your PC's IP. To stop it from changing, give the PC a fixed address in your router
> (often called "DHCP reservation" or "always assign the same IPv4 address").

---

## 2. iPhone setup

### Quick way: the setup page

Scan the QR code on the setup page (opened by `-Install` or `-Info`) with the iPhone camera. On the iPhone the page lets you:

1. **Copy** your PC's address with one tap.
2. **Add** each ready-made shortcut; when Shortcuts asks for the address, paste it.
3. Set up Back Tap and the Share Sheet.

The setup page is at `http://<PC-IP>:38765/setup?key=<your-key>`, the same address as the sync URL with `/setup` added.

### Manual way: build the shortcuts yourself

Open the **Shortcuts** app and create these three shortcuts.
In each one, the first action is a **Text** action holding your URL from step 1, so you only have to paste it in one place.

#### A. Get from PC (PC → iPhone)

1. **Text**: `http://<PC-IP>:38765/?key=<your-key>`
2. **Get Contents of URL**: URL = *Text*, Method = **GET**
3. **Copy to Clipboard**: *Contents of URL*

Text, images and files all end up on the iPhone clipboard, so just paste.
(Optional: add **Save File** or **Quick Look** after step 2 for files.)

#### B. Send Clipboard to PC (iPhone → PC)

1. **Text**: your URL
2. **Get Clipboard**
3. **Get Contents of URL**: URL = *Text*, tap **Show More**:
   - Method: **POST**
   - Request Body: **File**
   - File: *Clipboard*

#### C. Send File to PC (from the Share Sheet)

1. Shortcut settings (ⓘ): turn on **Show in Share Sheet**, receiving Images, Files, Media and Text.
2. **Text**: your URL
3. **Get Contents of URL**: URL = *Text*, **Show More**:
   - Method: **POST**
   - Request Body: **Form**
   - Add a field of type **File**, key `file`, value *Shortcut Input*

Sharing several items at once sends them all, with their original names.

### Make it one tap

- **Back Tap**: Settings → Accessibility → Touch → Back Tap → Double Tap = *Get from PC*, Triple Tap = *Send Clipboard to PC*.
- Or put them on the **Action Button**, in **Control Center**, or on the Home Screen.
- Fully automatic option: Shortcuts → Automation → **App** → choose apps (WhatsApp, Notes, Mail…) → *Is Opened* → *Run Immediately* → run *Get from PC*.
  Opening those apps then always has your latest PC copy ready to paste.

---

## Publishing the ready-made shortcuts (maintainers)

The setup page's **Add** buttons use the iCloud links in `$ShortcutLinks` at the top of `clip-sync.ps1`.
To make a shortcut shareable without leaking your own address and key:

1. Build it as described above, but set the first **Text** action to the placeholder `http://PC-IP:38765/?key=KEY`.
2. Open the shortcut's details (ⓘ) → **Setup** → **Add Import Question**, pick that Text action, and ask
   *"Paste the address from the setup page"*. Everyone who adds the shortcut is asked for their own URL.
3. For *Send File to PC*, also turn on **Show in Share Sheet** (Images, Files, Media, Text).
4. **Share** → **Copy iCloud Link**, then paste the link into `$ShortcutLinks`.

This works the same in the Shortcuts app on iPhone or Mac.

---

## Notes

- **Security:** the server only answers requests carrying the key of a paired device. It runs on your local network only; don't expose the port to the internet. To change a device's key, `-Revoke` it and `-Pair` it again.
- A single `.txt` item from the iPhone is treated as **text** (Shortcuts wraps copied text in a `.txt` file). Add `&as=file` to the URL in shortcut C if you want to send real `.txt` files as files.
- Files are held in memory while transferring, so very large videos (several GB) are not a good fit.
- VPNs on the PC (e.g. NordVPN's "Invisibility on LAN") or on the iPhone can block local connections.
- The setup page draws its QR code in your browser with a small library from cdnjs. Your address and key never leave your network.
- Until the ready-made shortcuts are published, their buttons on the setup page show "Coming soon"; use the manual steps above.
- Errors are written to `error.log` next to the script.
- Port 38765 is used because Windows/Hyper-V often reserves lower ports. `-Install` warns you if your PC reserves it.
