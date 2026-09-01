# iMac G3: no picture, no sound — triage guide

---

## 1. What the evidence already tells us

**The honest headline: the machine is probably still getting power, but we cannot yet tell whether it is booting, and "no sound" may be a red herring. Nothing so far distinguishes a recoverable stuck state from a dead power/video board.**

### What the ethernet link proves

The PC reports Status=Up, Connected, 100 Mbps on a direct cable with nothing else on it. Ethernet link negotiation is done in hardware by the PHY chip as soon as it has power — no CPU, no firmware, no OS. So:

**It proves:** something in the iMac is drawing power and driving fast-link pulses at 100 Mbps, which is exactly what the iMac's own 10/100 PHY would negotiate. The mains lead, the fuse, and at least part of the power supply are alive. "Completely dead, nothing at all" is unlikely.

**It does NOT prove:**
- That the machine has booted. It doesn't even prove it has been switched on. Apple documents a +5 V *trickle* rail that is live on the logic board the moment the cord is plugged in, machine off. Whether the ethernet PHY sits on that rail on this model is **not documented anywhere I could find** — so the link may be telling you only "the cord is in the wall."
- That the OS is running. No ARP reply just means no TCP/IP stack is answering.
- That the PC's reading is even current. Some NICs latch a stale link state.

**And "no ARP reply" does not prove it failed to boot.** A fully booted OS 9 machine can go silent on the wire because: the crash corrupted the TCP/IP Preferences file and it has dropped off the static address; TCP/IP is set to "Load only when needed" so the stack isn't resident; or — most likely of all — after an unclean shutdown OS 9 puts up a modal disk-check dialog early in startup and sits there, blind, waiting for someone to press Return before extensions (including networking) load.

**This single ambiguity is resolvable in two minutes and is Step 1 below. Do not build a diagnosis on the link until you have run it.**

### Ranked causes, before Step 1 reshuffles them

| Likelihood | Cause | Notes |
|---|---|---|
| ~40% | **Alive but stuck, asleep, or blank** | Includes the documented "warm restart after a crash → green LED, blank screen, no chime" state, cured by pulling the mains cord; and a display asleep with the processor awake. Free to exclude. |
| ~30% | **Power/analog/video (PAV) board failure** | The single most failure-prone module in an iMac G3 and the usual reason one is dead in 2026 — fanless, 25-year-old electrolytics. Apple's own power flow runs *AC inlet → power/analog board → video neck board → down converter → logic board*, so a dead PAV kills the chime **and** the picture. Technician-only. |
| ~15% | **Not completing power-on self test** — RAM, processor module, logic board | Caveat that cuts against this: RAM faults on these machines are **audible**. Apple's POST replaces the chime with beeps (1 = no RAM, 2 = wrong RAM type, 3 = no bank passed, 4–5 = bad boot ROM). Total silence argues *against* RAM. |
| ~10% | **Stuck front power button** (slot-loading only) | Apple documented this: a misaligned power LED jams the inner button, giving "will not start from the front button or the keyboard" plus random sleep/shutdown. Ranked second in Apple's own No Power chart. |
| ~5% | **Dead PRAM battery** (slot-loading only) | On slot-loaders a flat battery genuinely blocks power-on. Apple states flatly that on **tray-loading** iMacs "the battery does not affect power at startup." Not reachable without opening the case either way. |
| ~0% | **The hard drive** | A dead drive gives a normal chime and a flashing question mark on a working screen. It cannot cause a black, silent machine. Strike it. |

### One important caveat on "no sound"

The iMac's startup chime volume is **software-controlled and stored in PRAM** (Apple TIL 58044). A muted volume setting, or PRAM scrambled by the crash, produces a completely silent but perfectly healthy machine. So "no sound" is weaker evidence than it feels.

### About the GIF

The crash needs no hardware explanation. Mac OS 9 has no memory protection and cooperative multitasking; a period browser re-decoding a 135 KB GIF every two seconds into a fixed memory partition taking the whole machine down is ordinary behaviour. **There is no mechanism by which that workload damaged the display.** What it did was force an unclean shutdown and a warm restart — and a power cycle is simply the moment tired 25-year-old capacitors, flybacks and switching devices tend to give out. Workload caused the crash; the crash caused the restart; the restart is when it went dark. Coincidence is a fully adequate explanation and probably the correct one.

---

## 2. The single most useful thing to observe

Stand at the machine, in a quiet room, and cold-start it (mains cord out for 30 seconds first — the self-test only runs after a full power-off, not a restart). Then answer:

> **"When I press the button once and leave it alone: does the round light on the front come on, is it green or amber, is it steady or slowly pulsing — and in the first ten seconds do I hear a 'bong', a series of countable beeps, a hard drive spinning up, or absolutely nothing?"**

That one observation splits the entire problem three ways:

- **No light, no drive noise, nothing** → Apple's "No Power" branch. Power supply / PAV board. Technician.
- **Light on (green), drive spins, but silent and black** → the machine has power and is probably running or trying to. Recoverable-state and display-path causes lead.
- **Pulsing amber light** → **it is asleep, not dead.** Press a keyboard key, not the power button.
- **Countable beeps instead of a chime** → the machine is fully powered and executing its boot ROM, and the count names the fault. Beeps are the most informative thing available without opening anything.

Count the beeps. A non-technician will usually describe beeps as "a noise" or not register them at all, so listen deliberately with an ear near the speakers below the screen.

---

## 3. Which machine is it? (do this first — 30 seconds)

Almost every instruction below forks here, and **getting it wrong wastes time or sends you somewhere unsafe.**

**Use the CD drive. It is the only reliable external tell.**

- **TRAY-LOADING** (model M4984, Bondi Blue or the five fruit colours, 233/266/333 MHz, 1998–99): the disc goes onto a **pop-out drawer** with a physical eject button; the drive front is rectangular/flat.
- **SLOT-LOADING** (model M5521, 350–700 MHz, 1999–2003, includes all DV / DV SE / Indigo / Graphite / Snow / Flower Power / Blue Dalmatian): the disc goes into a thin **slot**, no drawer, no eject button; the lower front is rounded.

Secondary confirmation: the tray-loader's side ports sit behind a **hinged door**; the slot-loader's sit in an open recess.

**Tells that are commonly repeated and are WRONG — ignore them:**
- ❌ "Flip-out foot = slot-loading." Both generations have a foot.
- ❌ "Access door on the bottom = slot-loading." Both have a bottom cover. Only the **small door with a coloured coin-turn latch** is slot-loading-specific — and that distinction matters for safety, because on a tray-loader the bottom panel is step one of a full teardown onto the logic board and CRT chassis. **Never remove a bottom panel on a tray-loading machine.**
- ❌ "No FireWire = tray-loading." The base slot-loading 350 MHz models have no FireWire either.

**Then, if it is slot-loading, check one more thing:** open the side port recess and look for **two 6-pin FireWire sockets** (small rectangles with one bevelled corner). Two FireWire ports = this machine also has a VGA mirroring output, which unlocks the single best test in this whole guide (Step 7). No FireWire on a slot-loader = base 350, no video out.

Do **not** go looking for the VGA socket in the side ports — it isn't there. It's on the bottom/rear near the flip foot, behind a snap-on plastic vented cover, and Apple shipped some machines with a *blank* cover over it. A missing VGA socket in the side panel proves nothing.

---

## 4. Ordered checklist — safe, no-open procedures

Ordered by information gained per unit of effort. Nothing in steps 1–8 opens the main case.

### Step 1 — Settle what the ethernet link actually means (free, decisive, 2 min)

Both generations. Leave the cable connected and poll the PC's adapter (`Get-NetAdapter | Select Name,Status,LinkSpeed`) through four states:

1. iMac as it is now → note the reading.
2. **Pull the iMac's mains cord.** Does the link drop to Disconnected?
3. Mains cord back in, **power button NOT pressed.** Does the link come back?
4. Press the power button. Does the link change?

**Interpretation:**
- Link never drops in (2) → the PC's reading is stale and worthless. Discard it entirely.
- Link returns in (3), machine still off → the PHY runs on standby power. The 100 Mbps link proves only that the cord is in the wall. Discard the inference.
- Link stays down through (3) and only appears after (4) → **the iMac's main rails come up every time you press power.** That is strong: you can strike "completely dead PSU/PAV" off the list, and the problem is a video path, a POST failure, or software.

Also unplug the ethernet cable once and confirm the PC correctly reports Disconnected — that validates the instrument.

While you're there: run `arp -a` on the PC. A stale entry from the working session gives you the iMac's MAC address for free, which is useful in Step 6.

### Step 2 — Stop mashing the button, and check it

**Slot-loading:** the front power button **cannot switch the machine off** — on a running machine it puts it to **sleep**. Repeated jabbing on a hung-but-alive machine just toggles sleep, which is indistinguishable from dead. Press **once**, then leave it alone for 30 seconds. Pulsing amber LED = asleep and alive → press a *keyboard key* to wake it.

**Both generations:** press the button several times and feel it. Does it click and spring back cleanly, or is it mushy, sunken, tilted, sticky, or silent? Apple documented a stuck inner power button (caused by a misaligned power LED, TIL 58622) producing exactly "will not start from the front button or the keyboard" plus random shutdowns/sleep. Try gently pressing around its edge to free it. The fix requires opening the case — but the *diagnosis* is free.

### Step 3 — Unplug the USB keyboard and everything else

Apple's own first-line fix: *"If the unit will not power up from the keyboard, first, unplug the keyboard from the computer. Then, using a known-good power cord, power-on the system using the power button on the front of the computer."* A failed USB keyboard genuinely blocks power-on on both generations.

Also unplug **the ethernet cable** for restart attempts. Apple explicitly documents that heavy network traffic can stop an iMac starting: *"Your computer may not start up because of heavy network traffic. Disconnect the Ethernet cable, then start up again."* Given the machine died mid-download-loop, this costs nothing.

Unplug everything else too: printer, hub, speakers, and the phone line from the modem port.

### Step 4 — Deep cold power cycle

There is a documented failure state that matches this story exactly: after a crash and a warm restart, the machine comes up with a **green LED, blank screen, and usually no chime** — and the cure is simply pulling the mains cord for a while before restarting. Apple's own minimum is 30 seconds. For a stuck CRT iMac, give it **10 minutes**, and overnight is not unreasonable.

Everything unplugged, cord out of the machine itself. Then plug in **only** the power cord, and press the front button once.

> Note: there is **no** "hold the power button while unplugged to drain it" procedure for an iMac G3. That ritual belongs to later Macs. Don't bother.

### Step 5 — External reset button

**Slot-loading:** two small buttons in the port recess on the right side, below the modem port. The **reset** is the **front-most** of the two, marked with a small triangle. Press it briefly. (The other is the interrupt/programmer's switch — useless here, don't press it.)

**Tray-loading:** open the port door; the reset is a **pinhole** between the Ethernet and modem sockets, marked with a triangle. Straightened paperclip, push **gently** — Apple: *"Do not use excessive force."* Not every tray-loading revision has it; if there's no triangle-marked hole, skip to the keyboard combination.

**Both:** also try **Control + Command + Power button**.

This is a hardware restart only. It clears nothing.

### Step 6 — Use the PC as a proper instrument (better than ping)

Run a packet capture (Wireshark) on the PC for three minutes from power-on, and look for **any** frame with an Apple OUI source MAC — ARP, DHCP, AppleTalk AARP, anything.

- **Any traffic at all** → the machine is booting and executing code. This is a *display* problem.
- **Total silence over three minutes** → it is not reaching a running OS.

Two things to try alongside: press **Return** blind two or three times about 90 seconds after power-on (in case it's stuck at the post-crash disk-check dialog), then re-test. And send a Wake-on-LAN magic packet to the MAC you got from `arp -a` — if it then answers ping, the logic board is proven good and this is display-only. (A WoL failure proves nothing; it depends on a setting you can't now check.)

### Step 7 — External VGA monitor (slot-loading with FireWire only) — **the decisive test**

This is the highest-value test in the guide when it's available. It bypasses the CRT, the deflection stage and the entire video section of the PAV board in one move.

1. Machine face down on a soft cloth.
2. On the bottom housing, near the flip foot, find the small plastic **vented cover**. Prise it off with a plastic flat-blade tool — insert into the slot on the top of the cover and push forward gently. *(This is external plastic on the bottom housing, alongside the RAM door. It does not open the case. Remove no screws.)*
3. Plug a VGA cable into the port behind it, and into a monitor.
4. Power on the iMac, then the monitor.

**Two gotchas that cause false negatives:**
- Apple shipped **two** vented covers — one with a VGA opening, one solid. If the cover is blank, the port may still be there underneath; you need the VGA-cut cover (part 922-3886), often lost after 25 years. A concealed port is not an absent port.
- The output is **hardware mirroring only**, so it reproduces the internal panel's timings: 640×480 @ **117 Hz**, 800×600 @ **95 Hz**, 1024×768 @ 75 Hz. Most modern LCDs and all VGA-input TVs top out around 60–75 Hz and will say "out of range" or stay black. **Use an old multisync VGA CRT if you can get one.** A black modern LCD here is inconclusive, not diagnostic.

**Interpretation:** picture appears → logic board, RAM, ROM, GPU and boot are all fine; the fault is confined to the CRT or the video section of the PAV. The machine is immediately usable on an external monitor with no repair at all. Picture nowhere, but chime and drive spin-up heard → rule out the two gotchas above first, then it's technician work.

**No tray-loading iMac can do this.** Apple: *"The db-15 port on the iMac was not designed to support an external monitor... no video-out port to connect a second display."*

### Step 8 — Blind liveness tests (both generations)

- **Hold the mouse button down from power-on.** Apple: *"If you wish to eject a bootable CD-ROM disc at startup, simply hold down the mouse button until it ejects."* If the drive ejects, the machine is powered, running its ROM, and servicing USB — which eliminates "dead PAV / not POSTing" outright.
- **Slot-loading emergency eject pinhole**, right of the CD slot, with a paperclip. Apple notes *"the power must be on to eject a CD using this method"* — so a successful eject is direct proof the machine is powered. (Caveat: after using it you must restart to restore the drive.)
- **Press Caps Lock** on the USB keyboard and watch the key's own LED. If it toggles, USB is being serviced.

### Step 9 — RAM reseat, **slot-loading only**

Worth doing only if you heard 1, 2 or 3 beeps — or as a cheap final elimination. Apple designates this door as customer-serviceable; it exposes no CRT voltages.

1. Shut down. Unplug everything **except** the power cord. **Disconnect the phone line from the modem port first if one is fitted** — Apple flags this as a shock risk.
2. Machine face down on a towel (it's 15–17 kg; clear the table, two hands).
3. Coin or flat-blade screwdriver, turn the coloured latch counter-clockwise. Open the door.
4. **Touch the metal shield visible inside the recessed latch area** to discharge static — *then* unplug the power cord.
5. Push the plastic ejector tabs down/outward, lift each DIMM out, push it firmly back until it snaps.
6. If two DIMMs are fitted, try booting on **each one alone**, and try each in the other slot.
7. Latch the door shut before powering on. Apple: *"Never turn your computer on unless all of its internal and extra parts are in place."*

**On a TRAY-LOADING machine, do not do this.** The RAM sits on the processor card under a shield, reached only after removing the bottom cover, unplugging the internal DB-15 video connector, the power cable and the front-panel connector, and drawing the entire logic-board chassis out. That is opening the case. Stop instead.

### Step 10 — What I am NOT recommending, and why

**PMU reset.** Apple's standard first move for a machine that won't power up — press switch S1 **once**, cord disconnected, wait ten seconds, never press it twice (*"it could crash the PMU chip"*). Two independent users report the button is reachable at a sideways-downward angle through the open RAM door on slot-loaders. **But Apple's own procedure reaches the logic board only after removing the bottom housing *and* the EMI cover**, and Apple never documents S1 as a customer-accessible control. If you can look through the open door and *positively identify* a ~3 mm button on a ~7 mm chip below and left of the memory slots — and press it with a plastic spudger or wooden stick, touching nothing else — it is within the safety envelope. If you cannot see it clearly, **do not go hunting.** Skip it and treat the machine as a technician job.

**PRAM reset (Command-Option-P-R).** Usually the first thing anyone suggests. Two reasons it's the wrong opening move here:
1. It cannot work or be verified on a silent machine. The only success signal is hearing the chime a second time. The key combination is trapped by the boot ROM, which only runs once the machine reaches POST.
2. The long-standing CRT-iMac reference documents it as **actively harmful** on a blank-screen machine whose firmware is out of date: *"AVOID resetting the PRAM at all costs unless you are sure you have the latest firmware version"* — it can escalate a blank screen into a machine that powers itself off 7–10 seconds after power-on. You cannot check the firmware version without a working screen.

**Do it only if a chime or beeps come back**, with an Apple USB keyboard plugged directly in (not through a hub), Caps Lock off, held from power-on until the second chime.

**Booting from CD (hold C).** Not a diagnostic for this fault — the chime and the raster both come up *before* the machine touches the hard disk. Worth doing only after video or sound returns.

---

## 5. Decision tree

```
COLD START (mains out 30 s+, keyboard and ethernet unplugged), listen and watch
│
├─ NO light, NO drive noise, NO fan (tray-load), NO beeps, NO chime
│   └─ Apple's "No Power" branch.
│      → Check the front button isn't jammed (Step 2), try a known-good mains lead.
│      → Confirm with Step 1: if the ethernet link tracks the power button, the rails
│        ARE coming up and this reading is wrong — re-listen more carefully.
│      → Otherwise: power supply / PAV board / logic board. ***TECHNICIAN.***
│
├─ LED PULSING AMBER
│   └─ It's asleep, not dead. Press a KEYBOARD key. Move the mouse.
│      Still black after waking? → treat as the "green LED, black screen" branch below.
│
├─ BEEPS instead of a chime — count them
│   ├─ 1 or 3 beeps → RAM. Slot-load: reseat (Step 9). Tray-load: ***TECHNICIAN.***
│   ├─ 2 beeps      → wrong RAM type installed. Slot-load needs PC-100 SDRAM DIMMs.
│   └─ 4 or 5 beeps → bad boot ROM / processor module. ***TECHNICIAN or scrap.***
│      (Any beeps at all = the machine is fully powered and executing ROM.
│       That eliminates a dead PAV outright.)
│
├─ LIGHT ON + drive spins/chatters, but SILENT and BLACK
│   ├─ Did the CD eject on the held mouse button, or any packets appear in Step 6?
│   │   ├─ YES → the machine is alive and running. This is a DISPLAY problem
│   │   │        (or a muted chime in PRAM — remember chime volume is software).
│   │   │        → Step 7 external VGA if the model has it.
│   │   │           Picture there   → CRT/PAV video section only. Usable as-is
│   │   │                             on an external monitor. Repair optional.
│   │   │           No picture      → internal RGB cable / logic-board video /
│   │   │                             PAV. ***TECHNICIAN.***
│   │   └─ NO  → not reaching a running OS. Reset button, deep cold cycle,
│   │            RAM reseat (slot-load only). If still nothing: ***TECHNICIAN.***
│   └─ (Also try: brief power-button press to sleep it, then space bar to wake —
│      a documented trick that has restored blank-but-booted iMac displays.)
│
└─ NORMAL CHIME, drive spins, but screen black
    └─ Straightforward video-path fault: internal RGB cable, CRT neck board,
       bent neck pins, PAV video section, or the CRT itself. All inside the
       enclosure. ***TECHNICIAN*** — or, on a DV model, just use external VGA.
```

**Extra sensory checks worth collecting at power-on, in a dark quiet room:** a "thunk" from the deflection and degauss coils about a second in; a crackle of static if you bring the back of your hand near the glass (arm hairs moving, dust attracted); a faint high-pitched whine; any grey glow at all. **Any thunk, crackle or whine = the CRT high-voltage section is at least trying to start**, which points at the video/CRT side rather than a dead power supply. Total absence of all of them is *not* diagnostic on its own — it happens both when the PAV video section is dead and when the machine simply never started.

---

## 6. Hard stops

**Unplug at the wall immediately and do not power it on again** if you observe any of:

- Burning, fishy, or ozone smell
- Any smoke or haze
- Crackling, ticking, arcing, or a sharp snapping sound — especially from the upper rear near the CRT
- A rising whine that then cuts out
- Clicking on-off-on-off in a loop (the supply going into overcurrent protection)
- The house breaker or RCD tripping
- Through the vents with a torch: bulged, domed, split or crusty-topped capacitors, brown scorch marks, melted plastic
- The case getting hot in one localised spot rather than warm overall

Also treat as a stop: a machine that was already intermittently misbehaving and is now dead. Repeated power-on attempts on a failing switch-mode supply are exactly how a repairable board becomes a scrapped one. And there's a documented pattern of these iMacs getting *worse* with repeated failed reboots — work the list deliberately rather than by repetition.

### The absolute line

**Do not open the main case. Do not remove the rear or top housing. Do not touch the anode cap (the thick suction-cup lead on the side of the tube). Do not go near the analog/video board.** The CRT anode retains a lethal charge indefinitely after unplugging. Apple prints the same warning on every relevant page of its own service manual: *"This product contains high voltage and a high-vacuum picture tube. To prevent serious injury, discharge the CRT."* Discharging it requires a specific tool and training.

Everything that would actually *confirm* the leading hardware diagnoses is behind that line: continuity of fuse F901, +5 V trickle at J9, DCO voltage at C4/C10, the ±12/5/3.3 V rails at J7, the CRT neck board, the battery at BT1. **If steps 1–9 don't restore video, the answer is "a technician, or write it off" — there is no clever workaround, and I'm not going to invent one.**

Two calibrations worth carrying into that conversation:
- The PAV board is the most failure-prone module in an iMac G3 **and** the most over-diagnosed part. Apple published a bulletin about it: *"Many of the power/analog/video boards returned to Apple as bad or DOA have no trouble found at the repair facility."* Three of the commonest causes of a "dead PAV" call are mechanical — bent CRT neck pins, a video board not fully seated on the neck, a damaged RGB connector.
- Don't let anyone charge you to replace the hard drive. A dead drive cannot produce a black, silent machine.

---

## 7. If the display is genuinely dead: running it headless

**Short answer: viable, and how hard depends entirely on which model it is. The blocker is not the network — it's that nothing needed for remote access is installed, and installing it normally needs a screen.**

The key insight is that a dead CRT doesn't stop the logic board rendering a framebuffer. Remote-screen software reads that framebuffer, so a machine with a dead display is fully controllable over ethernet — *provided it boots, and provided the software is already on it.*

### What exists for Mac OS 9

- **VNC server for classic Mac OS** — Macintosh Garden hosts VNC Server 3.5.0 with OS 9 patches. The PC-friendly choice: any Windows VNC viewer connects. *(I have not verified this specific build's stability on 9.2.2 — treat as promising, not proven.)*
- **Apple Remote Desktop 1.x / Apple Network Assistant** — client runs on Mac OS 8.1+, UDP 3283. But the admin console needs a Mac.
- **Timbuktu Pro** for OS 9.
- **Non-graphical fallbacks:** NetPresenz (FTP/HTTP server), Personal File Sharing over TCP/IP, Personal Web Sharing, and AppleScript with remote Apple Events for scripted control.

**Mac OS 9 ships no telnet and no SSH server.** There is no console-over-network route out of the box.

### The three routes, honestly ranked

**Route 1 — DV / FireWire model: just plug in a VGA monitor.** (Step 7.) You then have a display, headless is unnecessary, and this whole section is moot. This is the answer for the majority of slot-loading machines, and it's a £10 cable plus possibly a £-nothing vented cover from a parts bin.

**Route 2 — FireWire model, no spare monitor: Target Disk Mode.** Hold **T** at power-on, connect FireWire to a PC with a FireWire card and HFS+ driver software (MacDrive or similar), and edit the System Folder directly on the mounted volume: drop in pre-configured TCP/IP preferences and put a VNC server or NetPresenz into Startup Items. Reboot normally and it comes up serving.
> ⚠️ **I could not verify which iMac G3 revisions support Target Disk Mode, or what firmware/OS level it needs.** Confirm that for the specific model before relying on this route.

**Route 3 — tray-loader, or base 350 with no video out: build a bootable OS 9 CD.** On the PC, inside SheepShaver, build a Mac OS 9 boot CD image carrying pre-set TCP/IP settings and a VNC server in Startup Items, burn it, and boot the iMac blind by holding **C**. This is a real project, not an afternoon. I would not promise it works.

### The good news about doing it blind

Every route is **verifiable blind from the PC**. You watch for the iMac to start answering ping, then to open its service port. You always know whether it worked, so it's not guesswork — it's slow iteration with a clear success signal.

### The catch

All of this is moot until the machine actually boots. **Right now it is not answering ARP**, so it is not reaching a networked state at all. Headless is a plan for *after* the machine comes back, not an alternative to fixing it.

Also: the existing static IP is useful but not something to rely on. An unclean shutdown can corrupt the TCP/IP Preferences file and drop the machine back to DHCP — which is another reason to packet-capture (Step 6) rather than just ping the old address.

---

## 8. Is it worth fixing?

**Rule: repair it only if the fault is *outside* the CRT enclosure. If it's inside, buy another machine.**

### Rough UK figures, 2026 — **unverified, check eBay *sold* listings before acting**

| Item | Ballpark |
|---|---|
| Working, tested slot-loading iMac G3 | £70–£200 (rarer colours — Flower Power, Blue Dalmatian, graphite SE — at or above the top) |
| Untested / "spares or repair" | £20–£60 |
| PAV board as a standalone part | £30–£80 *when it surfaces at all* — availability, not price, is the binding constraint |
| Professional recap / board-level CRT-chassis repair | £80–£200 in labour, if you can find anyone who'll touch it |
| **Shipping** | **£20–£40+** — these are 15–17 kg and awkward; many sellers are collection-only |

Shipping is the dominant cost. **A locally collected donor machine beats every other option**, and a "spares or repair" unit with a good PAV and a dead drive is a perfectly good organ donor.

### The pragmatic pivot

Step back from this specific iMac. The goal is *a networked OS 9 box*, not *this* box. A **Power Mac G4** or a **Beige / Blue-and-White G3** tower:

- boots OS 9 natively
- takes any monitor you already own — no CRT to fail
- has **no lethal high-voltage section**, and is trivially serviceable (the G4's side door swings open)
- is usually **cheaper** than a working iMac G3, because it has no collector premium
- is lighter to ship

For the bridge project it does the job better in every dimension except charm. If Step 7 doesn't produce a picture, that's the sensible move rather than a repair.

**Keep the iMac if:** it's a DV model and external VGA works (it's then a fully functional machine that happens to have a broken built-in monitor), or the fault turns out to be RAM, the power button, or a stuck state.

**Write it off if:** it's a tray-loader with no chime and no beeps, or the fault is confirmed inside the CRT enclosure, or you see any of the hazard signs in Section 6.

---

### Sources this is built on

Apple Service Source manuals for the tray-loading iMac and the slot-loading iMac / iMac DV / iMac DV SE / Early 2001 / Summer 2001 (Troubleshooting symptom charts, Power Flow, Power-On Self Test, Take Apart, Upgrades); the Apple iMac Emergency Handbook (1998); Apple slot-loading User's Guide Z034-0938-A and the Customer-Installable-Parts memory instructions; Apple TIL/KB articles 24532 (force restart), 25124 (network activity prevents deep sleep), 30705 (power supply specs), 58044 (no sound or startup chime), 58622 (sticking power button), 95007 (no video or unstable raster), 11751 (battery part numbers); Apple service bulletin 073-0593 Rev. A (verifying a defective PAV board); iFixit guides for M4984 and M5521; EveryMac model specifications; and the long-standing community "iMac CRT video/firmware problem" reference page.

Where sources conflicted — notably on whether the PAV can cause silence (it can), whether RAM faults are silent (they aren't, they beep), where the VGA port is (bottom/rear, not the side panel), and whether the flip foot or bottom cover identify the generation (neither does) — the corrected version is what's above.