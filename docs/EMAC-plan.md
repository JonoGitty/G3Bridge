# G3Bridge: adding the eMac

## 0. Corrections that override the researchers

Four adversarial checks refuted load-bearing claims. **The corrected versions below win.**

| Refuted claim | Correction that governs this plan |
|---|---|
| "Three of six eMac models cannot boot OS 9" | **Two** of the six EveryMac models cannot (1.25 USB 2.0, 1.42). A third — the 1.0 GHz ATI — splits *inside the model* by order number: only **M8950LL/A** boots OS 9; **three** of its SKUs cannot, and one of those (M8951LL/A SuperDrive) was a **launch-day** config, not a "later" one. |
| "The fork is settled by Model Identifier alone" | It is not. PowerMac4,4 at 1.0 GHz is undecidable from the model ID — `system_profiler` does not report the order number. And EveryMac records a **1.0 GHz education-only USB 2.0** variant, so CPU speed does not imply model ID either. Decide empirically (Startup Disk / Option-boot). |
| "Six eMac configurations" | Apple's own SP44 lists **four** configs under "eMac (2005)" including two **1.25 GHz EDU** units (M9832/M9833, Radeon 9200). Across Apple's four spec pages there are ≥15 SKUs. "Three logic-board generations" is an invented grouping used by no source. |
| "1024×768 is the native resolution of every eMac" / "all eMacs have 32 MB VRAM" | Apple SP44: **"Display Native Resolution: 1280 x 960"**. EveryMac: standard 1024×768, max 1280×960. And the **1.42 GHz has 64 MB** (Radeon 9600), not 32 MB. |
| "Four `-o` options are mandatory, not three" | Build-specific. Microsoft's inbox `ssh.exe` 9.5p2 strips `hmac-sha1` from its defaults, so **MACs is load-bearing there**; upstream OpenSSH (incl. this box's WSL 10.2p1) keeps it, so three suffice — but WSL's 10.2p1 has **removed ssh-dss entirely**. Ship five options and use `ssh.exe`, not WSL. |
| "The multi-device refactor is uncommitted" | It is **committed** as `6a00642 "Support more than one machine"`. `DEVICE_ARG` is on **10 of 11** tools, not 5. Confirmed again just now: HEAD = 6a00642, and `host/g3d.py` + `tools/fake_applet.py` are freshly modified with `docs/APPLESCRIPT-research.md` untracked — **another session is live in this repo right now.** Coordinate before touching `g3d.py` or `mcp_server.py`. |
| "External video-out is an eMac advantage over the iMac G3" | Half true. Slot-loading iMac G3s have VGA out (mirroring). Only tray-loading 233–333 MHz models lack it. |
| Agent requires "MacPython-OS9 2.3.5" | **2.3.5 has no classic Mac OS build.** MacPython-OS9 **2.3.3** (2 Apr 2004) is the last. `g3/g3agent.py` line 3 is wrong on both machines. |

---

## 1. What we need from the user first

Seven answers. Nothing else changes the build.

**Q1 — What OS is it actually running?** Power it on and read the Apple menu.
- OS X: *About This Mac* → version string.
- OS 9: *About This Computer* → version string.
This alone picks the tier. Capability ≠ what's booted; most surviving eMacs sit on Tiger.

**Q2 — Model Identifier and CPU speed.** OS X only: *About This Mac → More Info → Hardware*, or Terminal:
```
system_profiler SPHardwareDataType | grep -E 'Model Identifier|Machine Model|CPU Speed'; sw_vers
```
On OS 9 there is no `system_profiler` or `sw_vers` — use *Apple menu → Apple System Profiler*.

**Q3 — The bottom-of-case label: serial number AND the M-number** (e.g. `M8950LL/A`). The M-number is the **only** thing that resolves a 1.0 GHz machine. `A1002` is on every eMac and is useless. EMC 1903 = 2002 NVIDIA; EMC 1955 = 2003 ATI. **Type the serial into EveryMac's lookup on the Windows PC, never on the eMac.**

**Q4 — Does an OS 9 System Folder actually appear as bootable?** *System Preferences → Startup Disk*, or hold Option at the chime. This is the decisive empirical test and it overrides every table below.

**Q5 — Do you have the eMac's own restore/install discs?** OS 9 builds are machine-specific: cloning the iMac G3's System Folder will not boot the eMac, and Classic on an OS-X-only eMac needs *that machine's* 9.2.2 from *its* discs, not a retail OS 9 CD.

**Q6 — Is an AirPort card fitted, and is there a modem service enabled?** *Network Preferences → Show: Network Port Configurations*, or System Profiler. This is the single thing that can silently break the air gap (§6).

**Q7 — Will you buy a £10 5-port unmanaged switch?** The whole cabling recommendation rests on it.

---

## 2. Decision table

Read down until a row matches. Rows are ordered by decisiveness — Q4 beats everything.

| What the user reports | Can boot OS 9? | Bridge path | Control surface | Must be installed on the Mac |
|---|---|---|---|---|
| **Q4: an OS 9 System Folder is offered at boot** *(overrides all rows below)* | Yes, proven | **Tier 1** (existing agent, §4 fixes) + Tier 0 fallback | Agent TCP socket + AppleScript applet on `/cmd` | MacPython-OS9 **2.3.3**; CarbonLib ≥1.3 (9.2.2 already exceeds) |
| **Q4: no OS 9 volume offered** *(overrides all rows below)* | No | **Tier 2 (SSH)** + Tier 0 display | SSH / scp / osascript / VNC | **Nothing.** Two checkboxes. |
| PowerMac4,4, 700 MHz *(M8655/M8577/M8578/M8891)* | Yes | Tier 1 | as above | MacPython-OS9 2.3.3 |
| PowerMac4,4, 800 MHz *(M8892)* or 800 ATI *(M9150)* | Yes | Tier 1 | as above | MacPython-OS9 2.3.3 |
| PowerMac4,4, 1.0 GHz, **M8950LL/A** (orig. Combo, 60 GB) | Yes | Tier 1 | as above | MacPython-OS9 2.3.3 |
| PowerMac4,4, 1.0 GHz, **M8951LL/A** (SuperDrive) or **M9252LL/A** (Oct-2003 Combo, 40 GB) | **No** | Tier 2 | SSH etc. | Nothing |
| PowerMac4,4, 1.0 GHz, **M-number unknown** | **Unknown — do not guess** | Ask Q4 before writing anything | — | — |
| PowerMac6,4, 1.25 GHz *(M9425/M9461, 2004)* | No | Tier 2 | SSH etc. | Nothing |
| PowerMac6,4, 1.25 GHz **EDU 2005** *(M9832/M9833)* | No | Tier 2 | SSH etc. | Nothing |
| PowerMac6,4, 1.42 GHz *(M9834/M9835)* | No | Tier 2 | SSH etc. | Nothing |
| "1.0 GHz" but model ID **PowerMac6,4** (EDU USB 2.0 variant) | No | Tier 2 | SSH etc. | Nothing |

**Max OS X per row:** 700/800/800-ATI cap at **10.4.11** (Leopard needs 867 MHz). 1.0/1.25/1.42 reach **10.5.8**.

**Classic mode is not a third path.** Every eMac can run OS 9 *applications* under Classic on ≤10.4.11 (gone in 10.5). But whether Classic exposes the TCP sockets Tier 1 needs is **unverified**, and Classic on an OS-X-only eMac requires that machine's own restore discs. Do not plan around it.

**Apple-primary confirmation of the split** (SP98, footnote 7, verbatim): *"Startup in Mac OS 9 is available only with CD-ROM and Combo drive configurations. All configurations can run Mac OS 9 applications in Mac OS X Classic mode."* Note this covers the **May 2003 launch line-up**; EveryMac states the Oct 2003 M9252 Combo revision lost OS 9 boot. The two sources disagree on M9252 — which is exactly why Q4 governs.

---

## 3. If the eMac runs Mac OS X — Tier 2

**Decision: SSH is the control surface. It supersedes, not extends, the OS 9 design.**

### 3.1 SSH — it works, verified on the wire

Not from memory: the researcher stood up a stub server announcing `SSH-2.0-OpenSSH_3.6.1p1` offering only `diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1` / `ssh-dss` / `aes128-cbc,3des-cbc,...` / `hmac-md5,hmac-sha1,...`. The default `ssh.exe` **fails**: `kex: algorithm: (no match)` → `no matching key exchange method found`. With the flags below it **succeeds**: `kex: algorithm: diffie-hellman-group1-sha1`, `host key algorithm: ssh-dss`, `cipher: 3des-cbc MAC: hmac-sha1`, and it sends `SSH2_MSG_KEXDH_INIT`.

Ship this as `%USERPROFILE%\.ssh\config`, not a 300-character command line:

```
Host emac
    HostName 192.168.11.3
    User <shortname>
    KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
    HostKeyAlgorithms +ssh-rsa,ssh-dss
    PubkeyAcceptedAlgorithms +ssh-rsa
    Ciphers +aes128-cbc,3des-cbc
    MACs +hmac-sha1,hmac-md5
    StrictHostKeyChecking accept-new
    # RequiredRSASize 768   # only if the host key is under 1024 bits
```

The leading `+` **appends**, so modern algorithms stay preferred and a newer server still negotiates well.

Non-obvious points:
- **Use `C:\Windows\System32\OpenSSH\ssh.exe` (9.5p2), not WSL's ssh.** WSL 10.2p1 has removed DSA: `-o HostkeyAlgorithms=+ssh-dss` → `Bad key types '+ssh-dss'`.
- **Prefer the RSA host key.** OpenSSH 9.8 disabled DSA at compile time, 10.0 removed it. Do not design around ssh-dss.
- **`RequiredRSASize` defaults to 1024**, which exactly accommodates the 1024-bit RSA host key old sshd generates. This option did not exist before OpenSSH 9.1, so it appears in no old tutorial.
- **Pin the client.** Vendor a portable OpenSSH 9.x alongside G3Bridge rather than trusting the inbox client across Windows feature updates.
- **Probe before you pin flags.** First connection: `ssh -vv user@192.168.11.3` and read the *peer server KEXINIT proposal*. Have G3Bridge generate a minimal correct `-o` set from that rather than a guessed one. The OpenSSH version Apple shipped per OS X release **could not be verified from any primary source** — `opensource.apple.com/release/*` 404s and web.archive.org is blocked to the tool. Read it off the box with `ssh -V`.

**Enabling it:** *System Preferences → Sharing → Remote Login*. On 10.2–10.4 it's under a Services tab; on 10.5 it's a row in one list. Zero install. **File transfer:** `scp` works (modern scp speaks SFTP; old sshd has an sftp-server subsystem; `scp -O` is the legacy fallback) and **replaces the Tier 0 download/upload pages entirely**.

### 3.2 Screen capture — test this first, it is the biggest unknown

```
screencapture -x /tmp/shot.png
```
Always pass an explicit `.png` (10.3 and earlier default to PDF). Run `screencapture -h` on the machine and parse it — the modern flag list is far larger than a 10.4/10.5 build accepts.

**The trap:** an SSH session is not the console GUI session, so `screencapture` may not reach the WindowServer. The 10.5 workaround is `sudo launchctl bsexec <pid-in-console-session> screencapture -x /tmp/s.png`. **This is the single largest unverified assumption in the OS X plan. Test it in the first five minutes.**

**Fallback if it fails:** grab frames from the Screen Sharing/ARD VNC server, which renders the console session **by construction** and is immune to the namespace problem. Cost: a G4's VNC server is slow — stills and occasional control, not a video feed.

**VNC auth gotcha:** stock Apple Screen Sharing offers RFB security **type 30** ("Diffie-Hellman Authentication", AES-ECB over DH, 64-byte padded credentials); several Windows viewers do not implement it and fail *at authentication*, looking like a protocol bug. Tick **"VNC viewers may control screen with password"** (10.5: Sharing → Screen Sharing → Computer Settings…; 10.4: Sharing → Services → Apple Remote Desktop → Access Privileges…) to get standard **type 2**. Type 2 is DES-based and **truncates the password at 8 characters** — use exactly 8.

### 3.3 AppleScript — `osascript`, and the `/cmd` channel dies

`/usr/bin/osascript` exists on every PowerPC OS X. `ssh emac osascript -e '...'` gives real stdout, stderr and exit codes. The OS 9 poll-`GET /cmd` / POST-back applet exists solely because OS 9 has no shell; **on OS X the shell is the channel and the whole mechanism is deleted.** `do shell script` goes the other way.

Two caveats: GUI scripting via `System Events` (keystroke/click) needs *"Enable access for assistive devices"* in Universal Access; and `tell application "Safari"` from SSH hits the same console-session question as `screencapture`.

### 3.4 Graphics — decided

**Serve the existing Tier 0 canvas page to Safari and push frames with `osascript … do JavaScript`.** Replace `meta refresh` with a JS `img.src` swap or `multipart/x-mixed-replace` MJPEG.

```
ssh emac osascript -e 'tell application "Safari" to do JavaScript "drawFrame(...)" in document 1'
```

Why this and not the alternatives:
- **Zero install**, reuses the HTTP server and the Pillow rasteriser that already exist, works across 10.3–10.5, and Safari of that era allows `do JavaScript` with no modern opt-in.
- **PyObjC/Quartz** would be fastest (est. 12–25 fps full-frame) but whether it is bundled with the system Python is **unverified** — and the 700/800 MHz machines cap at 10.4.11 anyway. Test with `python -c 'import objc, Quartz'`; adopt only if it lands.
- **Tkinter**: Aqua Carbon Tk 8.4 is bundled from 10.4, so no X11 — but `-fullscreen` needs Tk 8.5 (use `overrideredirect(True)` + explicit geometry) and 8.4's `PhotoImage` reads **only GIF and PPM**, no PNG. Second choice.
- **X11 last.** It would need the eMac listening for remote X over TCP — the one option that reopens an inbound surface.
- **`scp` + `open -a Preview`**: reliable, ~0.3–1 fps, window flashing and focus stealing. Emergency only.

**No fullscreen exists.** Safari fullscreen arrived in 10.7 (Intel-only) and there is no `--kiosk` flag. A maximised window with the toolbar hidden is the ceiling. TenFourFox has F11 fullscreen and targets exactly this hardware, but it is abandonware and the slowest browser on a G4 — its staleness is a non-issue on an air-gapped machine, so it is a defensible install *if* true fullscreen is required.

**Frame-rate reality check:** the G3's "one frame per 20 seconds" was **never a network measurement**. 135 KB over 100BASE-TX is ~12 ms — 0.05% of the cycle. The 20 s was OS 9 cooperative scheduling plus full page reload. **The win comes from killing meta-refresh and from preemptive multitasking, not from MHz.** Only uncompressed pixels make the wire the constraint (1024×768×3 = 2.25 MB → ~4.9 fps cap). Estimates, not measurements: JS img-swap with a ~40 KB JPEG ≈ 5–12 fps at 700 MHz–1 GHz, 8–15 fps at 1.42 GHz, decode-bound.

### 3.5 Plainly: does this make the OS 9 agent unnecessary?

**On an OS X eMac, yes — most of it.** Dead on that machine: the `/cmd` AppleScript polling channel, the HTTP download/upload pages, the server-side image-map click input, and the Carbon/QuickDraw drawing agent. Also dead: the locked design decision *"the Mac dials out, avoids configuring inbound services"* — that was an OS 9 workaround, not a principle.

**What survives and must not be thrown away: the wire protocol and the host-side rasteriser.** Keep the drawing-command protocol; swap only the Mac-side renderer. For the content this bridge actually draws — RECT/OVAL/LINE/TEXT — **command replay beats image push on a G4**: a few hundred primitives repaint faster than 786k pixels decode, and native text at 12 pt is sharper than any JPEG of it. Image push only wins for dense/photographic content.

`host/protocol.py` already defines `BLIT x y w h <base64-rows>` and `FLUSH`. **Extend BLIT to carry a compressed payload plus dirty rects, and let the host choose per content.** One API surface, two backends — not a fork of the project.

---

## 4. If the eMac boots Mac OS 9 — what changes

Less than feared for QuickDraw; more than "nothing" for the code.

**What does not change.** Every call the agent makes — `Qd.RGBForeColor/RGBBackColor/PenSize/MoveTo/LineTo/PaintRect/FrameRect/PaintOval/FrameOval/EraseRect/TextFont/TextSize/TextFace/DrawString`, `Win.NewCWindow`, `Win.GetWindowPort`, `Qd.SetPort`, `Evt.WaitNextEvent` — is CarbonLib software API above the frame buffer. GeForce2 MX / Radeon 7500 changes the driver *under* QuickDraw, not its semantics. The G4 is a superset of the 750 for the 32-bit PowerPC user ISA, so the PEF/CFM MacPython binary runs natively. Both machines are 10/100Base-T; the direct-cable static-IP arrangement is untouched. *(Correction: the line is not uniformly 7441/7445 — the two OS-X-only models are 7447a. Irrelevant here, since those cannot boot OS 9.)*

**Five things that must change:**

1. **Canvas is hardcoded and must become runtime-detected.** `g3/g3agent.py:30-31` `CANVAS_W=800 / CANVAS_H=600`, `:228` `depth = 32`, both reported verbatim in the READY line at `:230`. Size the window from the main device's `gdRect` minus the menu bar, clamped to a configured max, and report the **actual window rect**. Host side: `_absorb_ready()` currently writes width/height into `Link.info` and **then ignores them** — compare to `dev.canvas`, resize `dev.mirror`, log it, cache to `run/devices.json`.
   *Geometry note:* the canvas is the **window**, not the screen. You cannot have a 1024×768 window plus `WINDOW_TOP = 40` on a 1024×768 display — either drop the menu-bar offset or run the CRT one mode up. eMac modes: 640×480, 800×600, 1024×768@89, 1152×864/870@80, 1280×960@72 (Apple SP74/SP98).
2. **Fix the header.** Line 3 says *"MacPython-OS9 2.3.x (2.3.5 preferred, 2.3.3 works)"*. **2.3.5 preferred is unachievable — there is no 2.3.5 OS 9 build.** 2.3.3 is the ceiling on both machines. Requirement is CarbonLib ≥1.3, which 9.2.2 exceeds, so it installs on a G4 cleanly.
3. **Click coordinates are global.** `:330` sends `EventRecord.where` straight through. On a different screen size with a different window origin the host's offset assumption breaks. Either `GlobalToLocal` on the Mac or send the window origin in READY.
4. **Install media.** The eMac needs its **own machine-specific 9.2.2**. Cloning the G3's disk is not a shortcut. A 1.0 GHz eMac additionally needs to be M8950LL/A or there is no OS 9 to boot at all.
5. **`REFRESH_SECONDS` should become per-device.** One global tuned for a 233–333 MHz G3 either punishes a 700 MHz–1.42 GHz eMac or destabilises the G3.

Harmless, noted for completeness: `:203-204` `QDIsPortBuffered()` / `QDFlushPortBuffer(None)` are Carbon buffered-port APIs, effectively no-ops under CarbonLib on OS 9 and already `try/except`-wrapped.

---

## 5. Multi-device refactor

### 5.1 API shape — optional `device`, already correct

Keep it. **Reject `g3_select`**: sticky invisible cross-turn state that appears in no tool result, survives into later turns, is lost by context compaction, and races between concurrent calls — a model screenshots one machine then draws on the other, silently. **Reject separate tool sets** (`g3_draw`/`emac_draw`): 9 → 18 tools, machine identity baked into names, a third machine costs nine more, cross-machine work becomes awkward.

Three rules make the optional parameter safe. **None is currently satisfied:**

1. **Every result must name the device it acted on.** `render_results()` emits only `"%d/%d commands succeeded"`. Only `g3_status` names the device. Prefix each daemon `OK` with `device=<name>` and print it in the header. ~10 lines. *This is the cheapest high-value fix in the whole refactor.*
2. **The default must be unambiguous or an error, never a silent guess.** `Registry.resolve()` uses `d.last_seen is not None` — monotonic, set by every agent connect **and every HTTP hit**, never cleared. Once the eMac has touched the bridge once, `len(seen)==2` forever and every device-less call falls through to `DEFAULT_DEVICE = "g3"`. Change to `d.link.alive`: exactly one live → use it; zero live → default; **two live and none named → `ERR` listing both**. ~5 lines.
3. **Descriptions must not assert one machine's properties.** `GRAMMAR` hardcodes *"The canvas is %d x %d"* from the global `config.CANVAS_W/H` (800×600) and is baked into `g3_draw`'s static schema at import — and the server advertises `capabilities.tools.listChanged = False`, so per-device regeneration is not available. **Enumerate every device's canvas instead** ("g3 is 800×600, emac is 1024×768; call `g3_devices` for the current list"). Replace *"iMac G3"* with *"vintage Mac"* everywhere including the `initialize` instructions, and put the device roster in those instructions so the model needs no `g3_devices` round-trip.

### 5.2 What becomes per-device

**Per-device:** `ip`, `label`, capability record, canvas (declared / learned / effective), mirror `Screen` + its lock, pen state, `frame_seq` + `frame_<name>.gif`, the `Link`, the `CommandQueue`, `last_seen`/`http_hits`, `REFRESH_SECONDS`, transfer folders, bootstrap directory.

**Global:** the three listeners (9990/9991/9980) and their bind addresses, the `Registry`, `protocol.py`/`raster.py`/`xfer.py` as pure modules, `isolation.py` (it is about the PC, not a machine), `MAX_UPLOAD_BYTES`, `RUN_DIR`.

**Replace the `os` string with a capability record** — `{tier1_agent, applescript_applet, http_display, ssh}` — because that is what actually branches. Today `g3_applescript` against an OS X eMac would poll for a nonexistent OS 9 applet and time out after 60 s; it should refuse in one line naming the reason.

**Canvas sources, ranked:** (1) the agent's READY line — authoritative, currently ignored; (2) the declared value in `config.DEVICES` — the seed, and the *only* source under Tier 0 where nothing reports anything; (3) a learned value cached to `run/devices.json` so Tier 0 gets the right size before an agent connects next session. **Do not** try to have the Tier 0 browser report its own size — that needs JavaScript, which is exactly what Netscape 4 / IE 5 on OS 9 cannot be trusted with.

**Bounds checking (currently absent).** `RawCanvas.point()` silently drops out-of-range pixels, `PilCanvas` delegates to Pillow which clips silently, `Screen.apply()` range-checks nothing, and QuickDraw clips to the port rect — all returning `OK`. The failure this project will hit constantly is an 800×600 layout aimed at the eMac, or vice versa, with **no diagnostic at all**. Rule: partially outside → clip, return `OK` with a `clipped` warning (a line running off the edge is legitimate); **entirely** outside → hard `ERR` naming the canvas — `RECT 900 700 1100 900 is entirely outside the 800x600 canvas of 'g3'`. Validate in `raster.Screen.apply()` so Tier 0 and Tier 1 behave identically. An LLM given that sentence self-corrects; a silent clip teaches it nothing.

**Transfer folders.**
```
transfer/to-mac/_all/        staged for whichever machine collects it
transfer/to-mac/<device>/    staged for one machine
transfer/from-mac/<device>/  ALWAYS per-device, no shared inbox
```
The decisive argument is **inbound provenance**: `/upload` is written by whoever POSTs, so with one folder the eMac's `notes.txt` silently overwrites the G3's and `g3_read_received` cannot say which machine sent it. No filename convention fixes that without encoding the device in the path anyway. Second: `xfer.classify()` does LF→CR for classic Mac OS, which is **wrong for an OS X eMac** — conversion happens at serve time, so it is fixable once the serving path consults the device's OS. Make `device` **optional** on `g3_send_file` (omitted → `_all/`), and show each device's `/files` page as `_all/` merged with its own folder.

### 5.3 Addressing and cabling — one cheap unmanaged switch, one subnet

```
PC "Ethernet"  192.168.11.10 / 255.255.255.0 / NO gateway, NO DNS
iMac G3        192.168.11.2  / 255.255.255.0 / Router blank, Name Server blank
eMac           192.168.11.3  / 255.255.255.0 / Router blank, DNS blank
.4 - .9 reserved. Keep 192.168.11.0/24 permanently distinct from the WiFi LAN.
```

**Do this before plugging the switch in (admin PowerShell):**
```
Remove-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress 192.168.1.10 -Confirm:$false
```
`Get-NetIPAddress` shows the Ethernet adapter carrying a manual **192.168.1.10/24** — the *same subnet as WiFi* (192.168.1.103/24 DHCP). `Get-NetRoute -DestinationPrefix 192.168.1.0/24` returns **two rows**, both RouteMetric 256 / InterfaceMetric 35, and the single default route (→192.168.1.1) resolves through that now-ambiguous /24. Today Ethernet is Disconnected so it is inert; **a permanently-up switch makes it permanent** and risks the PC's own LAN traffic being sent down the vintage cable and black-holed. The other decoy statics are harmless.

**Why a switch over two NICs:** `g3d` already binds a *list*, so two NICs is a config change — but it needs a second `SUGGESTED_PC_IP`, a second subnet in `netcheck` and `isolation`, per-device bind bookkeeping and a USB-Ethernet adapter, all to buy layer-2 separation between two of the user's own offline machines. **Why over one-at-a-time:** the G3's thermal fault means the user needs to fall back mid-session without re-cabling, and the code has already gone multi-device. Two non-obvious bonuses: a switch keeps the PC's link up permanently so 192.168.11.10 persists (see §5.4 item 0), and it moots the crossover question entirely.

**Cable type is a non-issue.** `Get-NetAdapter` shows a **Realtek Gaming 2.5GbE Family Controller** with *Speed & Duplex = Auto Negotiation*; auto-MDI-X is mandatory in 1000BASE-T. Apple's SP44 lists *"Auto-MDIX: yes"* for the 2005 eMac; the 2002/2003/2004 spec pages do not state it — with a switch it never comes up.

### 5.4 Minimum viable vs clean — and the order

**Already landed** in `6a00642`: `config.DEVICES` + `DEFAULT_DEVICE`; `devices.Device`/`Registry`; per-device `Link`/`CommandQueue` with `AgentHandler`/`DisplayHandler` resolving from `client_address` and 403-ing unknown peers; control verbs `USE <name>` and `DEVICES`; optional `device` on 10 of 11 MCP tools plus `g3_devices`.

**MINIMUM VIABLE — remaining (~55 lines + one purchase):**

0. **Fix `bind_addresses()`.** It falls back to `0.0.0.0` and gates on `local_ipv4()` = `getaddrinfo(gethostname())`, which **measured on this PC returns `['192.168.1.103']` only** — none of the six manual Ethernet addresses. So `192.168.11.10` is never found, the daemon binds all interfaces, and 9990/9980 are listening on the house WiFi LAN right now. The IP allowlist still holds (`for_peer` → `None` → 403), so this is defence-in-depth surviving, **not a breach — but the documented guarantee is currently false.** Fix deterministically: attempt `socket.bind(SUGGESTED_PC_IP)` and fall back only on `OSError`. A switch also fixes it as a side effect.
1. Buy the switch; delete Ethernet's 192.168.1.10; set the eMac to 192.168.11.3.
2. Echo the acting device in every tool result (~10 lines).
3. `resolve()` on `link.alive`; `ERR` when two are live and none named (~5 lines).
4. Strip 800×600 out of `GRAMMAR`; enumerate all devices' canvases (~5 lines).
5. "iMac G3" → "vintage Mac" throughout the descriptions (~10 edits).
6. Adopt READY's width/height into `dev.canvas`, resize the mirror (~10 lines).
7. **`tools/fake_g3.py --canvas WxH --bind <addr>`, plus a `sim_ip` per device** (`127.0.0.2` / `127.0.0.3` — verified bindable as source addresses on this box) registered in `Registry._by_ip`. Today `fake_g3.py` hardcodes `800, 600, 32` and connects from `127.0.0.1`, which `for_peer()` collapses to the default device, so **two simulated Macs cannot coexist and none of the multi-device behaviour is testable.** Highest-value item on the list — nothing else here is provable today, and the G3's thermal fault makes hardware the unreliable way to find out.

**CLEAN VERSION, on top:** per-device transfer folders + `_all/`, with line-ending policy passed as a parameter rather than inferred from extension; per-OS bootstrap `g3/macos9/`, `g3/macosx/`, `g3/common/` with `/boot` filtered by device OS (today `/boot` serves the Carbon OS 9 agent to *anything* that asks and CR-converts `.txt`/`.scpt` unconditionally — an OS X eMac would be handed `g3agent.py`); the capability record replacing the `os` string, with `g3_applescript` refusing fast; bounds validation with the clipped/entirely-outside distinction; learned-canvas persistence in `run/devices.json`; per-device `REFRESH_SECONDS`; `netcheck.py` iterating `DEVICES`, pinging each, ARP-scanning the cable segment and flagging unknown addresses; `isolation.py` asserting the cable interface has no default gateway; and a Tier 2 SSH transport as a `Link` subclass so `device.link` is polymorphic.

**Order: 0 → 3 before both machines are ever powered on at once.** Items 2 and 3 together are the fifteen lines that stop a wrong-machine draw going unnoticed. Then 4–7. Then §3 or §4 depending on the answer to Q1.

**Coordination warning:** `host/g3d.py` and `tools/fake_applet.py` are modified *right now* by another session, with `docs/APPLESCRIPT-research.md` untracked. Do not stash, reset, or check out — `6a00642` is committed work. Diff `e598d4c..HEAD` to see the refactor.

---

## 6. Isolation with a second machine

**A switch changes almost nothing that matters.** "Never reaches the internet" is a **routing** property. Neither Mac has a default gateway or a name server; the PC has exactly one default route (via WiFi) and none on Ethernet. A switch is layer 2 — it adds no route and no gateway. **The requirement is unaffected.**

**What genuinely changes:** the two Macs can now see each other and each other's broadcasts. If either has File Sharing or Web Sharing on, the other can reach it. That is lateral movement between two offline machines both belonging to the user — negligible unless one is already compromised by a file carried in on media. Realistic nuisances are mundane: a duplicate IP if both get set to `.2`, and AppleTalk/NetBIOS chatter now visible to both.

**The one real new risk is topological, not technical.** An unmanaged switch has spare ports, and someone plugging the house router into it "for a minute" puts both vintage machines straight onto the internet-facing LAN. Mitigate by dedicating the switch, leaving nothing else in it, and having `netcheck.py` ARP-scan `192.168.11.0/24` and flag any address that is not the PC or a configured device.

**On OS X the air gap becomes provable, which OS 9 never allowed.** Run this as a pre-flight assertion on every connect:
```
netstat -rn | grep -w default      # must return nothing
route -n get default               # must fail
cat /etc/resolv.conf               # must list no nameserver
ifconfig                           # only Built-in Ethernet up
```
That is a positive test, not an absence of evidence.

**Three things could genuinely auto-configure a route — two are eMac hardware:**
- **A second interface.** Every eMac has a **built-in 56k modem**; AirPort (802.11b in 2002–03, AirPort Extreme + Bluetooth 1.1 in 2004–05) was a factory option. An AirPort card that joins any open network installs a default route and defeats the entire model. Turn AirPort off, clear the preferred-networks list, set "Ask before joining new networks", ideally **remove the card**. Disable the Internal Modem PPP service. Use *Network Preferences → Show: Network Port Configurations* to disable **every** port except Built-in Ethernet.
- **IPv6** defaults to "Automatically" on 10.4/10.5 and will accept Router Advertisements. Set it to **Off** under Network → Advanced.
- **DHCP.** Never leave Ethernet on DHCP — one lease hands over a router *and* DNS in a single step.

**Services to silence** (verify pane wording on the machine; Apple's archived KBs 404 and web.archive.org is blocked to the tool, so these were not re-confirmed against primary sources):
- Software Update — untick *Check for updates*; `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false`; on 10.5 also `sudo softwareupdate --schedule off`.
- Network time (`time.apple.com`) — untick *Set date & time automatically*; 10.4: `TIMESYNC=-NO-` in `/etc/hostconfig`; 10.5: `sudo launchctl unload -w /System/Library/LaunchDaemons/org.ntp.ntpd.plist`.
- Dashboard (Weather/Stocks fetch on open) — `defaults write com.apple.dashboard mcx-disabled -boolean YES; killall Dock`.
- .Mac/MobileMe, and Back to My Mac on 10.5 — leave signed out and unconfigured.
- **Not a leak:** mDNSResponder/Bonjour is link-local multicast to 224.0.0.251 and is never routed; wide-area Bonjour needs a DNS search domain that will not exist. It is actually *useful* — `emac.local` with no DNS. CrashReporter only uploads via an explicit dialog.

**Belt and braces:** `ipfw` is present through OS X 10.9, so it exists on every version in scope; the 10.5 Security pane firewall is inbound/application-based only and is **not** the tool for this.
```
sudo ipfw add 100 allow ip from any to any via lo0
sudo ipfw add 200 allow ip from any to 192.168.11.10
sudo ipfw add 210 allow ip from 192.168.11.10 to any
sudo ipfw add 400 deny ip from any to any
```
Install via a script with a **timed self-flush on first run** — a wrong IP here locks you out of the machine.

---

## 7. Honest assessment: is the eMac the better target?

**Yes, with two caveats. Make it the primary once identified; keep the G3 as a first-class second path, not a legacy one.**

**Why the eMac wins:**

- **Reliability, which is the whole point.** The G3's thermal fault stops it starting when warm. For a bridge whose entire value is *reachable on demand*, that means every session begins with a coin flip and any long session ends in a lockout. No amount of software quality compensates.
- **Control surface, if it runs OS X.** SSH, scp, `osascript`, `screencapture` and a VNC server for two checkboxes and **zero installs on the vintage machine**. The OS 9 apparatus — the polling `/cmd` channel, the HTTP file pages, the server-side image map — exists entirely because OS 9 has no shell and no usable inbound service. All of it becomes unnecessary (§3.5).
- **Provable isolation.** On OS X you *assert* the air gap from the command line instead of trusting a control panel. That is the difference between a claim and a test.
- **Headroom.** 700 MHz–1.42 GHz G4 vs 233–333 MHz G3; 32–64 MB VRAM vs 2–6 MB; 1024×768 or 1280×960 vs 800×600. And the display path stops being hostage to a cooperative scheduler — which was the actual cause of the 20-second frame, more than clock speed.
- **Video out.** Mini-VGA on every eMac (mirroring only, Apple adapter required), so a dying CRT does not end the project. *Correction to the brief's premise: this is not eMac-exclusive — slot-loading iMac G3s have VGA out too; only tray-loading 233–333 MHz models lack it.*

**Why the G3 keeps its place:**

- It is the only machine on which Tier 1 is **proven**, and native QuickDraw on real Mac OS 9 is the point of the exercise for some uses — it is also genuinely *faster* than image push for vector content.
- If the eMac turns out to be PowerMac6,4, the G3 becomes the **only** OS 9 target, which makes the existing agent a permanent, justified G3-only artefact rather than dead code.

**The two caveats:**

1. **The eMac's advantage is contingent on it working.** It is a 20+ year old CRT machine from a line with well-known analogue-board and capacitor failures. Do not retire or unplug the G3 until the eMac has run a session end to end.
2. **If the eMac boots OS 9, the gain is real but modest** — a faster, cooler machine running the same cooperative OS and the same agent, with a bigger canvas and a lower `REFRESH_SECONDS`. **The step change is Mac OS X, not the eMac as such.** If Q1 comes back "Mac OS 9.2.2", expect an incremental improvement, and reconsider whether an OS X install on that same machine (every OS 9-capable eMac also runs 10.4.11 or better) is worth more than the OS 9 authenticity.

**Concrete recommendation:** once §1 is answered, set `DEFAULT_DEVICE = "emac"`, keep `g3` configured and cabled, and treat the OS 9 path as supported rather than primary.