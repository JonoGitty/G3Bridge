G3BRIDGE - WHAT TO DO ON THE MAC
================================

There are two ways in. Do TIER 0 first: it needs nothing installed and
proves the cable and the network before you touch anything else.


TIER 0 - NOTHING TO INSTALL
---------------------------

1. On the PC, run start.cmd.

2. On the PC, run:  tools\netcheck.py
   It prints the address to use. Do what it says.

3. On the Mac: Apple menu > Control Panels > TCP/IP
       Connect via:  Ethernet
       Configure:    Manually
       IP Address:   192.168.11.2
       Subnet mask:  255.255.255.0
       Router:       leave blank
       Name server:  leave blank
   Close the window and click Save.

4. Open the Mac's web browser and go to:

       http://192.168.11.10:9980/

   You should see a black screen. Anything Claude draws now appears there,
   refreshing every couple of seconds. Clicking the picture sends the click
   back to the PC.

That is the whole of Tier 0. It is a slideshow, roughly 1-3 frames a second,
but it needs no software on the Mac at all.

Before a long session, give the browser more memory: click its icon once in
the Finder, then File > Get Info > Show: Memory, and raise Preferred Size.
A multi-hour refresh loop will run out otherwise.


TIER 1 - REAL QUICKDRAW, NEEDS MACPYTHON
----------------------------------------

This draws with the Mac's own graphics calls instead of showing a picture of
them. Sharper, faster, and it can talk back.

1. Check you have CarbonLib 1.3 or newer:
   Apple menu > About This Computer, or look in the Extensions folder.
   CarbonLib 1.6 needs Mac OS 9.1 or later.

2. Get MacPython for Mac OS 9. Version 2.3.5 is the last one ever made.
   The original host (ftp.cwi.nl) is off the air. Use Macintosh Garden or
   the Internet Archive copy. The file is called MacPython235full.bin.
   MacPython 2.3.3 also works if 2.3.5 is awkward to find.

3. Install it, then download the agent from the PC. In the Mac's browser:

       http://192.168.11.10:9980/boot/g3agent.py

4. Open g3agent.py in the MacPython IDE and check the line near the top:

       HOST = "192.168.11.10"

   It must match what netcheck.py printed on the PC.

5. First, prove the graphics work with no network involved. In the
   MacPython IDE, run it with the argument:  selftest
   You should get a window with a blue oval and white text.

6. Then run it normally. It will dial the PC and say "connected".


IMPORTANT: LEAVE THE WINDOW IN FRONT
------------------------------------

Mac OS 9 does not properly multitask. If the agent window goes behind
another program its network connection stalls until you bring it back.
The PC copes with this and will not drop the link, but the picture freezes.

Press ESC in the agent window to quit it.


IF IT WILL NOT CONNECT
----------------------

Run tools\netcheck.py on the PC - it checks each link in the chain and tells
you which one is broken.

The most likely culprit on a direct PC-to-Mac cable is the cable itself. The
iMac G3's Ethernet port probably cannot flip the wires for you, so a direct
link may need a CROSSOVER cable. Putting any cheap network switch, or your
home router, between the two machines removes the question entirely and is
the recommended way to do it.
