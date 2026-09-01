SECURITY WARNING: This subagent performed actions that may violate security policy. Reason: Blocked by classifier. Review the subagent's actions carefully before acting on its output.

# Mac OS 9.2 → PC Remote-Admin Applet ("PC Link")

Stock software only: AppleScript, Standard Additions, and `System Folder:Scripting Additions:URL Access Scripting`. No `do shell script`, no POSIX paths, no System Events, no downloads.

**Transport design in one line:** the Mac is always the HTTP *client*. It fetches the next command with `download`, and returns the result by **smuggling percent-encoded output into GET query strings** and throwing the response body away. `upload` is not used — every attested working example of it targets `ftp://`, and the underlying Carbon primitive (`URLSimpleUpload`) has no room for a form field or multipart boundary, so it is at best a raw PUT and cannot be relied on.

---

## 1. The applet source

Paste this whole thing into Script Editor. It contains **no `¬` continuation characters** deliberately, so a copy/paste cannot be corrupted by a lost Option-L glyph. Lines are long; that is fine.

```applescript
-- ==========================================================================
-- PC LINK  --  Mac OS 9.2 remote-administration agent
-- CLASSIC AppleScript dialect only.
--
-- Save from Script Editor as:
--     Kind / Format : application
--     [x] Stay Open
--     [x] Never Show Startup Screen
--     (NEVER "Save As Run-Only")
--
-- What it does, once every few seconds, forever:
--   1. asks the PC  GET http://192.168.11.10:9980/cmd   for a command
--   2. if there is one, compiles and runs it with "run script"
--   3. sends the output back to the PC in GET query strings
--
-- It is written so that NOTHING can ever put a dialog on the screen.
-- On Mac OS 9 a modal dialog stops every other program on the machine,
-- so an unattended agent that can raise one is an agent that can freeze
-- the Mac while you are not sitting at it.
-- ==========================================================================


-- ---------- SETTINGS YOU MAY WANT TO CHANGE -------------------------------
-- A "property" is a setting that survives between polls and is written back
-- into the applet file when it quits normally. WARNING: editing and re-saving
-- this script in Script Editor RESETS every property to the value below.

property baseURL : "http://192.168.11.10:9980"   -- the PC. no trailing slash.
property pollSeconds : 2        -- seconds between polls. MUST be a whole number.
property netTimeout : 60        -- give up on one HTTP call after this many seconds
property cmdTimeout : 120       -- give up on one command after this many seconds
property maxChunk : 140         -- encoded characters per result URL. See note (A).
property maxResultChars : 2000  -- longest result we will send back. See note (B).
property useCompileProbe : false -- see note (C). Leave false until you test it.

-- Note (A): nobody has ever documented how long a URL Mac OS 9's URL Access
--   Scripting will accept. 140 keeps the whole URL under about 200 bytes,
--   which is safe even if there is an old 255-byte limit hiding in there.
--   Once the PC log shows long queries arriving intact, raise this.
-- Note (B): classic AppleScript throws error -2721 on text over 32K, and the
--   applet lives in a fixed memory partition. Big results are truncated, not
--   streamed. Raise carefully.
-- Note (C): the "compile probe" (below) is the ONLY unsourced trick in here.
--   With it false, compile errors are still caught and still labelled
--   correctly by their error number. Turn it on only after testing it.


-- ---------- WORKING STATE (do not edit) -----------------------------------
property seq : 0          -- command counter. The PC sees this; it resets to 0
                          -- whenever this script is re-saved, so let the PC
                          -- keep the authoritative numbering and treat this
                          -- as an echo only.
property pollCount : 0    -- poll counter, used to make every URL unique
property runTag : 0       -- random per-launch number, also to make URLs unique
property workFolder : ""  -- resolved at launch
property cmdPath : ""     -- scratch file the fetched command lands in
property ackPath : ""     -- scratch file the ignored replies land in
property logPath : ""     -- plain text log on the Mac


-- ==========================================================================
-- RUN  --  happens once, at launch
-- ==========================================================================
on run
	try
		set runTag to (random number from 1000 to 9999)
	on error
		set runTag to 1234
	end try
	set workFolder to my ResolveFolder()
	-- These names are DELIBERATELY short. URL Access Scripting uses the old
	-- Carbon file manager: a destination filename of 32 characters silently
	-- writes a CORRUPT file, and 33 throws error -1700.
	set cmdPath to workFolder & "PCcmd.txt"
	set ackPath to workFolder & "PCack.txt"
	set logPath to workFolder & "PCLink.log"
	my LogLine("--- PC Link started. folder=" & workFolder & " tag=" & (runTag as string))
	my WakeTransport()
	-- tell the PC we are alive. If the PC is off, this fails silently.
	try
		my FetchTo(baseURL & "/hello?t=" & (runTag as string), ackPath)
	end try
end run


-- ==========================================================================
-- IDLE  --  happens over and over, including while you are using other apps
-- The ENTIRE body is inside "try". An error that escapes an idle handler
-- stops the script and puts a dialog on the screen, which is exactly the
-- failure we must never have.
-- ==========================================================================
on idle
	try
		set pollCount to pollCount + 1
		set cmdText to my FetchCommand()
		if cmdText is not "" then
			set seq to seq + 1
			if cmdText is "__QUIT__" then
				my SendResult(seq, "OK", "quitting")
				try
					tell me to quit
				end try
				return pollSeconds
			end if
			if cmdText is "__PING__" then
				my SendResult(seq, "OK", "PC Link alive. seq=" & (seq as string) & " polls=" & (pollCount as string) & " folder=" & workFolder)
				return pollSeconds
			end if
			set r to my RunCommandText(cmdText)
			my SendResult(seq, item 1 of r, item 2 of r)
		end if
	on error errMsg number errNum
		-- -609 / -600 mean URL Access Scripting is no longer running.
		-- -1712 means an Apple event timed out. All three are recoverable.
		if errNum is -609 or errNum is -600 or errNum is -1712 then my WakeTransport()
		-- Report the failure. Nested try, so the reporter itself cannot throw.
		try
			my SendResult(seq, "XE", (errNum as string) & ": " & errMsg)
		on error
			try
				my LogLine("XE " & (errNum as string) & ": " & errMsg)
			end try
		end try
	end try
	-- MUST be an explicit positive whole number. A handler returns the value
	-- of its last statement, so falling off the end here would silently set a
	-- random polling interval.
	return pollSeconds
end idle


-- ==========================================================================
-- QUIT  --  Command-Q, or "tell application \"PC Link\" to quit"
-- "continue quit" is MANDATORY. Without it the applet REFUSES to quit and
-- the only way out is a force quit.
-- ==========================================================================
on quit
	try
		my LogLine("--- PC Link stopping. seq=" & (seq as string))
	end try
	try
		tell application "URL Access Scripting" to quit
	end try
	continue quit
end quit


-- ==========================================================================
-- THE EXECUTOR
-- "run script" is a Standard Additions command that compiles and runs a
-- piece of AppleScript text at run time. It is the whole point of this agent.
--
-- CRITICAL: run script must NEVER appear inside a "tell application ..."
-- block. Inside one, the addition gets dispatched to that application and
-- you get "Finder got an error: Can't make some data into the expected type".
-- Everything below is at handler level, which is correct.
-- ==========================================================================
on RunCommandText(cmdText)
	-- Mac OS 9 lines end with CR (character 13). A PC daemon will usually send
	-- LF or CRLF. Convert, or the compiler may reject the source.
	set src to my NormalizeReturns(cmdText)

	if useCompileProbe then
		-- Wrapping the text in "script ... end script" compiles it but does
		-- not run it, giving a clean split between "your command is malformed"
		-- and "your command ran and failed". Caveat: a "property x : <expr>"
		-- line inside the payload WOULD be evaluated here.
		try
			run script ("script __probe__" & return & src & return & "end script")
		on error errMsg number errNum
			return {"CE", (errNum as string) & ": " & errMsg}
		end try
	end if

	set theResult to ""
	try
		with timeout of cmdTimeout seconds
			set theResult to run script src
		end timeout
	on error errMsg number errNum
		-- -2740 through -2763 is AppleScript's documented syntax/compile band.
		-- Anything else happened while the command was actually running.
		if (errNum is less than or equal to -2740) and (errNum is greater than or equal to -2763) then
			return {"CE", (errNum as string) & ": " & errMsg}
		end if
		return {"RE", (errNum as string) & ": " & errMsg}
	end try

	return {"OK", my FlattenResult(theResult)}
end RunCommandText


-- Turn whatever the command handed back into plain text.
-- Classic AppleScript wants text item delimiters set to a LIST.
-- The old value is always restored, including on the error path.
on FlattenResult(theValue)
	set savedTID to AppleScript's text item delimiters
	try
		set AppleScript's text item delimiters to {return}
		set s to theValue as string
		set AppleScript's text item delimiters to savedTID
		return s
	on error
		set AppleScript's text item delimiters to savedTID
	end try
	try
		return "<" & ((class of theValue) as string) & ": cannot be turned into text>"
	on error
		return "<unrepresentable result>"
	end try
end FlattenResult


-- ==========================================================================
-- TRANSPORT
-- URL Access Scripting is an APPLICATION that happens to live in the
-- Scripting Additions folder. Every call must be inside a tell block for it.
-- ==========================================================================

on WakeTransport()
	-- "launch", not "activate". activate would bring it to the front and
	-- steal your keyboard focus on every single poll.
	try
		tell application "URL Access Scripting" to launch
	end try
end WakeTransport


-- The one and only network primitive.
--   direct parameter : the URL, as a plain STRING
--   to               : a FILE REFERENCE -- file "Disk:Folder:name" -- a bare
--                      string here gives error -1700 or -1703
--   replacing yes    : an enumeration, NOT the boolean true. Overwrites.
-- Deliberately NO "with progress"       (opens a modal progress window)
-- Deliberately NO "with authentication" (opens a modal password window)
on FetchTo(theURL, destPath)
	with timeout of netTimeout seconds
		tell application "URL Access Scripting"
			download theURL to file destPath replacing yes
		end tell
	end timeout
end FetchTo


on FetchCommand()
	set u to baseURL & "/cmd?t=" & (runTag as string) & "&q=" & (pollCount as string)
	my FetchTo(u, cmdPath)
	set t to my TrimText(my ReadTextFile(cmdPath))
	if t is "NONE" then return ""
	return t
end FetchCommand


-- Send the result home. The output is percent-encoded, cut into pieces that
-- fit in a URL, and each piece is sent as its own GET. The reply body is
-- downloaded to a scratch file and never looked at.
on SendResult(jobID, statusCode, bodyText)
	set b to bodyText
	try
		if (count characters of b) > maxResultChars then
			set b to (text 1 thru maxResultChars of b) & return & "[truncated by PC Link]"
		end if
	end try
	set chunks to my PackChunks(my EncodeTokens(b), maxChunk)
	set n to (count of chunks)
	repeat with k from 1 to n
		set u to baseURL & "/r?i=" & (jobID as string) & "&p=" & (k as string) & "&n=" & (n as string) & "&s=" & statusCode & "&t=" & (runTag as string) & "&d=" & (item k of chunks)
		my FetchTo(u, ackPath)
	end repeat
end SendResult


-- ==========================================================================
-- PERCENT-ENCODING
-- Classic AppleScript has no built-in URL encoder, so here is one.
--
-- It returns a LIST of tokens -- each token is either one safe character or a
-- three-character "%XX" escape -- so that the chunker below can never cut a
-- "%0D" in half across two requests.
--
-- Note it tests the character's NUMBER, not "if safeChars contains c".
-- AppleScript text comparison ignores case AND accents, so a "contains" test
-- would wrongly let accented characters through unescaped.
-- ==========================================================================
on EncodeTokens(s)
	set hexChars to "0123456789ABCDEF"
	set outList to {}
	repeat with i from 1 to (count characters of s)
		set c to character i of s
		set b to ASCII number c
		if ((b is greater than or equal to 48) and (b is less than or equal to 57)) or ((b is greater than or equal to 65) and (b is less than or equal to 90)) or ((b is greater than or equal to 97) and (b is less than or equal to 122)) or (b is 45) or (b is 46) or (b is 95) or (b is 126) then
			set end of outList to c
		else
			set end of outList to ("%" & (character ((b div 16) + 1) of hexChars) & (character ((b mod 16) + 1) of hexChars))
		end if
	end repeat
	return outList
end EncodeTokens


on PackChunks(tokenList, maxLen)
	set chunks to {}
	set cur to {}
	set curLen to 0
	repeat with i from 1 to (count of tokenList)
		set tok to item i of tokenList
		set tl to (count characters of tok)
		if ((curLen + tl) > maxLen) and (curLen > 0) then
			set end of chunks to my JoinList(cur)
			set cur to {}
			set curLen to 0
		end if
		set end of cur to tok
		set curLen to curLen + tl
	end repeat
	-- always append, so an empty result still sends exactly one chunk
	set end of chunks to my JoinList(cur)
	return chunks
end PackChunks


on JoinList(aList)
	set savedTID to AppleScript's text item delimiters
	try
		set AppleScript's text item delimiters to {""}
		set s to aList as string
		set AppleScript's text item delimiters to savedTID
		return s
	on error
		set AppleScript's text item delimiters to savedTID
		return ""
	end try
end JoinList


-- ==========================================================================
-- TEXT HELPERS
-- ==========================================================================

-- Turn CRLF and LF into the Mac's CR.
on NormalizeReturns(t)
	set lf to (ASCII character 10)
	set cr to (ASCII character 13)
	set savedTID to AppleScript's text item delimiters
	try
		set AppleScript's text item delimiters to {cr & lf}
		set parts to text items of t
		set AppleScript's text item delimiters to {cr}
		set s to parts as string
		set AppleScript's text item delimiters to {lf}
		set parts to text items of s
		set AppleScript's text item delimiters to {cr}
		set s to parts as string
		set AppleScript's text item delimiters to savedTID
		return s
	on error
		set AppleScript's text item delimiters to savedTID
		return t
	end try
end NormalizeReturns


-- Strip spaces, tabs, CR and LF from both ends.
on TrimText(t)
	set s to t
	set cr to (ASCII character 13)
	set lf to (ASCII character 10)
	set tb to (ASCII character 9)
	repeat while (count characters of s) > 0
		set c to character 1 of s
		if (c is cr) or (c is lf) or (c is tb) or (c is " ") then
			if (count characters of s) is 1 then
				set s to ""
			else
				set s to text 2 thru -1 of s
			end if
		else
			exit repeat
		end if
	end repeat
	repeat while (count characters of s) > 0
		set c to character -1 of s
		if (c is cr) or (c is lf) or (c is tb) or (c is " ") then
			if (count characters of s) is 1 then
				set s to ""
			else
				set s to text 1 thru -2 of s
			end if
		else
			exit repeat
		end if
	end repeat
	return s
end TrimText


-- ==========================================================================
-- FILES  (Standard Additions "File Read/Write". Colon paths. No shell.)
-- ==========================================================================

on ReadTextFile(hfsPath)
	set t to ""
	set fRef to (open for access file hfsPath)
	try
		if (get eof fRef) > 0 then set t to (read fRef)
	on error
		-- fall through; we still must close the access or every later
		-- poll will fail with "file is already open"
	end try
	try
		close access fRef
	end try
	return t
end ReadTextFile


on LogLine(theText)
	if logPath is "" then return
	try
		set fRef to (open for access file logPath with write permission)
		try
			-- "starting at eof" means append
			write ((current date as string) & "  " & theText & return) to fRef starting at eof
		end try
		close access fRef
	on error
		try
			close access file logPath
		end try
	end try
end LogLine


-- Work out where to keep the three scratch files.
-- Tries: <startup disk>:PC Link:  ->  <startup disk>:
on ResolveFolder()
	set d to "Macintosh HD:"
	try
		set d to (path to startup disk as string)
	on error
		try
			tell application "Finder" to set d to ((name of startup disk) & ":")
		end try
	end try
	set f to d & "PC Link:"
	try
		tell application "Finder"
			if not (exists folder f) then make new folder at disk (text 1 thru -2 of d) with properties {name:"PC Link"}
		end tell
	end try
	-- prove the folder is really writable; if not, fall back to the disk root
	try
		set probe to (open for access file (f & "PCack.txt") with write permission)
		close access probe
	on error
		try
			close access file (f & "PCack.txt")
		end try
		set f to d
	end try
	return f
end ResolveFolder
```

---

## 2. Click-by-click

### 2a. Before you type anything — four checks on the machine (5 minutes, saves hours)

1. **Open the Finder and go to `System Folder` → `Scripting Additions`.** You must see two items: **Standard Additions** and **URL Access Scripting**. If URL Access Scripting is missing, nothing in this design works.
2. Click **URL Access Scripting** once and press **Command-I**. Note the version. (Classic builds are believed to be 2.x; this is not confirmed anywhere — just record what it says.)
3. Open **Script Editor**, choose **File → Open Dictionary…**, and select `System Folder:Scripting Additions:URL Access Scripting`. Read the `download` entry. This is the *authoritative* parameter list — confirm `to`, `replacing`, and check whether any form-data/POST parameter exists. If one does, it is a better result path than GET smuggling and worth switching to.
4. In the same dictionary window, open the **Finder** and confirm `empty trash`, `free space`, `capacity` and `process` really exist on this Finder. Nobody could produce an OS 9 Finder dictionary dump online; the Finder terms in the capability table below are inherited-from-classic terminology, not read off your machine.

### 2b. Creating the applet

1. **Find Script Editor.** Look in `Macintosh HD:Applications (Mac OS 9):AppleScript:Script Editor`. On some installs it is `Macintosh HD:Apple Extras:AppleScript:Script Editor` instead. If neither exists, press **Command-F** (Sherlock), search the boot volume for `Script Editor`, and double-click the result.
2. **Double-click Script Editor.** A window opens with a small *Description* box on top and a larger *script* box below.
3. **Click in the lower (script) box** and paste the entire script from section 1.
4. **Edit the first setting if needed.** `baseURL` is already `http://192.168.11.10:9980`. Leave it.
5. **Press Command-K** (or click *Check Syntax*). The text should reformat itself with keywords in bold. If Script Editor puts up a **"Where is URL Access Scripting?"** dialog, navigate to `System Folder → Scripting Additions → URL Access Scripting` and click Open. If you get a syntax error, the paste was damaged — do not proceed.
6. **File → Save As…** (Command-Shift-S).
7. In the save dialog: name it **`PC Link`**, and choose a destination **on the hard disk** (the desktop is fine). It must not be a locked disk or a CD, or its settings will never be written back.
8. **Set the popup menu at the bottom of the dialog** (labelled *Kind:* or *Format:* depending on your Script Editor version) to **`application`**. The other choices are *compiled script* and *text*.
9. **Two checkboxes become active. Tick BOTH:** **`Stay Open`** and **`Never Show Startup Screen`**. Stay Open is what makes it keep running; Never Show Startup Screen stops it from sitting on a splash screen waiting for a click.
10. **Click Save.** Do **not** ever use *File → Save As Run-Only* — that permanently destroys the editable source.
11. **Set its memory.** Quit the applet if it is running. Click its icon once in the Finder, press **Command-I**, set the **Show:** popup to **Memory**, and enter **Preferred Size 8000 K**, **Minimum Size 4000 K**. Close the window. A long-running poller that builds strings every cycle will otherwise fragment a small partition and eventually die with an out-of-memory error (-108).
12. **Turn off sleep.** **Apple menu → Control Panels → Energy Saver**, set system sleep to **Never**. A sleeping Mac stops polling. (Hard-disk spin-down is fine to leave on; it only adds spin-up delay.)
13. **Double-click `PC Link` to launch it.** Nothing visible happens — that is correct. Confirm it is alive by opening the **Application menu** (far right of the menu bar): `PC Link` should be listed. Confirm it is *working* by opening `Macintosh HD:PC Link:PCLink.log` in SimpleText — it should contain a start line, and the PC's server log should show a `/cmd` hit every 2 seconds.
14. **To re-edit it later:** drag the `PC Link` icon **onto the Script Editor icon**. Double-clicking it would just run it. Remember that re-saving resets `seq` to 0.
15. **Auto-start at boot (optional):** click `PC Link`, press **Command-M** to make an alias, then drag the alias into `Macintosh HD:System Folder:Startup Items`.

### 2c. Quitting it

- **Normal:** Application menu (far right of menu bar) → **PC Link** → then **Command-Q**. This runs `on quit`, `continue quit` fires, settings are written back.
- **From the PC (designed in):** queue the literal command `__QUIT__`. The applet acknowledges it and calls `tell me to quit`. *Low confidence that `tell me to quit` works in an OS 9 applet — it is wrapped in `try` so a failure is harmless, but test it before relying on it.*
- **From a second script:** in Script Editor, run `tell application "PC Link" to quit`. This is the most reliable route and also proves the applet is answering Apple events.
- **Last resort:** **Command-Option-Escape** force quit. This **skips `on quit`**, loses the sequence number, and leaves OS 9 unstable enough that you should restart the Mac afterwards.

---

## 3. The PC-side contract

The PC is at `192.168.11.10:9980`. Three endpoints. **All are GET. All must answer HTTP 200.**

### Global server rules (all endpoints)

| Rule | Why |
|---|---|
| **Always return status 200.** Never 204, 404, 301/302, or 401. | What URL Access Scripting does with a non-200 is undocumented and unverified. Making everything 200 removes the question entirely. Never use a status code as a signal. |
| **Body must never be zero bytes.** Minimum useful body is `NONE` or `OK`. | A zero-length download risks `kURLFileEmptyError` (-30783). |
| `Content-Type: text/plain` | The Mac writes the body straight to a file and reads it as text. |
| `Content-Length:` set explicitly. **No chunked transfer-encoding. No gzip/deflate. No keep-alive requirement — accept `Connection: close`.** | Assume an HTTP/1.0-era client. |
| `Pragma: no-cache` and `Cache-Control: no-cache` | Belt and braces; every URL also carries a unique `t`/`q` value. |
| **No HTTP authentication, ever.** | A 401 would make URL Access want a modal password dialog, and `with authentication` is deliberately not passed. |
| **Raise the server's max URL / query-string length** (many frameworks cap around 2–8 KB — fine, but check) and **log the received query length on every hit.** | That log is how you calibrate `maxChunk` upward from 140. |
| **Body encoding must be plain ASCII** (bytes 32–126 plus CR). | Classic AppleScript reads and writes **MacRoman**, not UTF-8. Anything above 127 will not round-trip. |

### `GET /cmd?t=<runTag>&q=<pollCount>`

Called every `pollSeconds`. `t` is a random per-launch number and `q` a poll counter; both exist only to make every URL unique. **Ignore them for routing.**

**Response body — exactly one of:**

- **Nothing queued:** the four bytes `NONE` (optionally followed by CR/LF; the Mac trims). An empty body also works but is riskier — prefer `NONE`.
- **A command:** raw AppleScript source, as plain text.

Line endings in the command body: **send CR (`\r`, 0x0D)**. LF and CRLF are also accepted — the applet normalises them to CR before compiling — but CR is what the Mac's compiler natively wants, so send it and remove the variable.

The command must **not** be percent-encoded, JSON-wrapped, or quoted. It is compiled verbatim.

Two reserved literal command strings the applet handles itself and never passes to `run script`:

| Command | Effect |
|---|---|
| `__PING__` | Replies `OK` with a liveness string. Use this as your health check. |
| `__QUIT__` | Replies `OK`, then attempts to shut the applet down. |

**Queue semantics you should implement:** mark a command *in flight* when `/cmd` serves it, and *complete* only when the matching `/r` chunks arrive. If a result never arrives, the Mac died mid-command — a human must intervene, since the Mac cannot be restarted remotely once the applet is gone.

### `GET /r?i=<seq>&p=<part>&n=<total>&s=<status>&t=<runTag>&d=<data>`

The result. Sent once per chunk, in order, `p` = 1…`n`.

| Param | Meaning |
|---|---|
| `i` | The Mac's sequence number for this command. **Advisory only** — it resets to 0 whenever the applet is re-saved in Script Editor, and is lost on a force quit. The PC must own the authoritative job id and must tolerate `i` jumping backwards. |
| `p` | 1-based chunk index. |
| `n` | Total chunk count. Always ≥ 1 — an empty result still sends exactly one chunk with `d=` empty. |
| `s` | Status. Applies to the whole result; identical on every chunk. See table below. |
| `t` | Per-launch random tag. Changes when the Mac's applet restarts — useful for detecting a restart. |
| `d` | Percent-encoded chunk of the output. May be empty. |

**Status values:**

| `s` | Meaning | `d` contains |
|---|---|---|
| `OK` | Compiled and ran. | The result, coerced to text. Lists are joined with CR. |
| `CE` | Compile / syntax error — **nothing was executed**. Error number is in the AppleScript syntax band −2740…−2763. | `<errNum>: <message>` |
| `RE` | Compiled fine, failed while running. | `<errNum>: <message>` |
| `XE` | The applet's own machinery failed (network, file, internal). | `<errNum>: <message>` |

**Decoding on the PC:**

1. Percent-decode `d` (standard `%XX`; the Mac escapes everything except `A–Z a–z 0–9 - . _ ~`).
2. Concatenate parts `p=1` through `p=n` **in order**. Chunks are split on token boundaries so a `%0D` is never cut in half — a naive concatenate-then-decode also works, but decode-then-concatenate is what is guaranteed.
3. The decoded bytes are **MacRoman with CR line endings**. Transcode: `bytes.decode('mac_roman').replace('\r', '\n')`.
4. Results longer than `maxResultChars` (2000) arrive with a literal trailing line `[truncated by PC Link]`.

**Response body:** the two bytes `OK` (plus CR). The Mac downloads it and throws it away, but it must not be empty.

**Idempotency:** a retried chunk arrives with identical `i`/`p`/`t`. Overwrite, do not append twice.

### `GET /hello?t=<runTag>`

Sent once at applet launch. Use it to detect that the Mac has rebooted or the applet has been restarted (new `t`). Respond `OK`.

### Optional: `/put` — one experiment worth running once

Add a catch-all endpoint at `/put/<anything>` that logs **method, path, all headers, and body length**. Then run this once from Script Editor on the Mac:

```applescript
tell application "URL Access Scripting"
	try
		upload file "Macintosh HD:PC Link:PCack.txt" to "http://192.168.11.10:9980/put/out.txt" replacing yes
		set r to "upload returned without error"
	on error m number n
		set r to "upload FAILED " & (n as string) & ": " & m
	end try
end tell
display dialog r
```

If the PC log shows a clean `PUT` with a body, promote `upload` to the return path for large outputs and keep GET smuggling as the fallback. If it errors or issues nothing, the design above is already correct and you have closed the last open question. (This is a one-off manual test — `display dialog` is fine here because a human is present. Never put `display dialog` in the applet.)

---

## 4. Capability table — what this actually gives you over the Mac

| Capability | Verdict | How, and what the limits are |
|---|---|---|
| **List files / folders** | ✅ Full | `list disks`, `list folder "Macintosh HD:System Folder:" without invisibles` (Standard Additions, no Finder needed), or `tell application "Finder" to name of every item of folder "…"`. Recursive listings of a big disk will blow past `maxResultChars` and can hit the 32K text limit (−2721) — walk one level at a time. |
| **Read files** | ✅ Full, for text | `set f to open for access file "Macintosh HD:x.txt"` / `read f` / `close access f`, or `read file "…" using delimiters {return}`. **Text only in practice**: the result comes back MacRoman through a percent-encoded URL, so binary files are impractical and large files hit the size cap. Metadata without the Finder: `info for file "…"` gives name, size, `file type`, `file creator`, dates, locked, visible. |
| **Write / create files** | ✅ Full | `open for access … with write permission`, `write … to f starting at eef`/`starting at eof`, `set eof f to 0` to truncate. `open for access` creates the file if it does not exist. Writing binary content is impractical — the command text arrives as ASCII. **Every write must `close access` or every later operation on that file fails.** |
| **Move / copy / delete files** | ✅ Full | Finder only: `duplicate … to folder "…" with replacing`, `move … to folder "…"`, `delete …` (which **moves to the Trash**, it does not erase), `empty trash` (set `warns before emptying of trash` to `false` first, then restore it), `make new folder at disk "Macintosh HD" with properties {name:"New"}`. |
| **Launch apps** | ✅ Full | `tell application "SimpleText" to activate`, or `tell application "Finder" to open file "SimpleText" of folder "Applications" of disk "Macintosh HD"`. **This steals focus from whoever is sitting at the Mac.** |
| **Quit apps** | ⚠️ Cooperative only | `tell application "X" to quit` — a polite Apple event. A **responsive** app quits. An app showing an unsaved-changes dialog will sit there waiting for a human, and on OS 9 that modal dialog **blocks the whole machine including this applet**. Never send `quit` to an app with unsaved work. |
| **List running processes** | ✅ Full | `tell application "Finder" to get name of every process`. Also `if exists (some process whose name contains "SimpleText")`. This genuinely works on OS 9 — it is not an OS X-only feature. |
| **Restart / shut down / sleep** | ✅ Full | `tell application "Finder" to restart` / `shut down` / `sleep`. **One-way trip:** the reply never gets back to the PC, and unless you put an alias of the applet in `System Folder:Startup Items`, the agent does not come back. Any app with unsaved changes will veto the restart with a modal dialog and hang the machine. |
| **Read system info** | ⚠️ Partial, and version-dependent | `system attribute "sysv"` (system version, BCD) exists **only on Mac OS 9.2.2**. On 9.1 / 9.2.0 / 9.2.1 that command is absent and you must use the Finder's classic `computer "sysv"` instead — write it as `try system attribute "sysv" on error tell application "Finder" to computer "sysv" end try`. `"ascv"` gives the AppleScript version. Other selectors (`"ram "` with the trailing space, `"mach"`, `"sysa"`) are standard Gestalt codes but are **unverified on this machine**. All return raw integers the PC must decode. **`system info` does NOT exist on Mac OS 9** — do not use it. Free space needs the Finder: `{name, free space, capacity} of every disk`. |
| **Draw graphics** | ❌ No | Stock AppleScript has no drawing surface, no pixel access, no window of its own. The only route is scripting another application that draws (AppleWorks, Photoshop) if one is installed and scriptable — and none is guaranteed on a stock install. |
| **Capture the screen** | ❌ No | Command-Shift-3 writes `Picture 1` to the disk root, but nothing in stock AppleScript can press it — there is no `keystroke`, no System Events, no GUI scripting on OS 9 (those are all OS X). Keystroke synthesis needs a third-party scripting addition (Akua Sweets, PreFab Player), which the no-install rule forbids. You can *read back* a `Picture 1` file's metadata via `info for`, but only a human can create it. |
| **Kill a hung process** | ❌ No | There is no `kill`, no signal, no Process Manager terminate exposed to AppleScript. You can *see* a hung app in the process list and you can *ask* it to quit, but a wedged app does not answer Apple events. Worse: under OS 9's cooperative multitasking a wedged app can starve this applet of CPU time, at which point **the PC stops getting replies at all**. Command-Option-Escape at the keyboard is the only recovery. |
| **Open a listening port / custom TCP** | ❌ No | No sockets anywhere in stock AppleScript. This is why the Mac must poll the PC and not the reverse. |
| **Run a shell command** | ❌ No such thing | There is no shell on Mac OS 9. `do shell script` is OS X only. |

**One escape hatch not used above, worth knowing:** Standard Additions contains a stock **`handle CGI request`** handler, and Mac OS 9 ships **Personal Web Sharing**. An applet saved as an `.acgi` can *be* an HTTP endpoint and return unbounded output in a response body, with the PC as the client — no percent-encoding, no URL length limit at all. That would be a strictly better return path. It is not the design here because it is unverified whether Web Sharing is installed on this machine and whether 9.2 still dispatches ACGI events. **Check for the Web Sharing control panel**; if it is there, this is worth building.

---

## 5. When to stop and install MacPython instead

The applet above is genuinely sufficient for file management, app launching, power control, and inspection. Reach for a real agent when the job is one of these:

1. **Anything needing a listening socket or the PC initiating a connection.** The poll-the-PC shape is *forced* by the absence of sockets. If you want push, low latency, a persistent connection, or the Mac to serve anything, stock AppleScript cannot do it.
2. **Force-terminating a hung application.** This is the single most likely thing you will want and cannot have. A wedged classic app can also starve the applet itself, so the remote agent goes deaf exactly when you most need it. Python with the Carbon Process Manager bindings can enumerate and terminate.
3. **Binary files, or files over a few kilobytes.** GET-smuggled percent-encoded MacRoman is a fine channel for a directory listing and a terrible one for a 4 MB file. Base64 through Python plus real HTTP POST is the answer.
4. **Text over ~32 K, or any regular expressions.** Classic AppleScript throws −2721 above 32 K and has no regex at all. Log parsing, grepping, diffing — all Python jobs.
5. **Screen capture, keystroke synthesis, or any GUI automation.** Impossible from stock AppleScript on OS 9 without a third-party osax. Python has the Toolbox bindings.
6. **Resource forks, file type/creator manipulation in bulk, checksums, hashing.** Python exposes the Carbon/Toolbox APIs AppleScript does not.
7. **Recursive walks of a large volume, or anything where speed matters.** AppleScript character-by-character loops on a G3 are slow enough that the percent-encoder in this applet is already the hot spot on a 2000-character result.
8. **Concurrency** — doing two things at once, or continuing to poll while a long job runs. AppleScript is single-threaded within the applet; a slow command simply postpones the next poll.

Keep AppleScript for what it is uniquely good at even after installing Python: driving the Finder and other applications by Apple event, and power state (`restart` / `shut down` / `sleep`). The best end state is Python as the agent, calling out to compiled AppleScript for the Apple-event work.

---

## Known-unverified assumptions (test these, do not trust them)

| Assumption | Status | Cheapest test |
|---|---|---|
| URL Access Scripting is present on *this* 9.2.2 install | Confirmed stock on 8.6 and on "a Mac OS 9 System Folder"; **no Apple installer manifest for 9.2.2 was locatable** | Open `System Folder:Scripting Additions` in the Finder |
| The exact `download` parameter list | Reconstructed from working scripts; **the verbatim dictionary could not be found anywhere online** | Script Editor → File → Open Dictionary → URL Access Scripting |
| Maximum URL length URL Access will accept | **Completely unsourced.** `maxChunk : 140` is a guess chosen to stay under a possible 255-byte ceiling | Log received query length on the PC, raise `maxChunk` in steps |
| What URL Access does with a non-200 response | Unverified; there is no HTTP-status error in its −307xx range | Designed around — the PC always returns 200 |
| The `script … end script` compile probe (`useCompileProbe`) | **Model reasoning, no source.** Shipped `false` | Set it `true`, send a payload of just `beep`. If the Mac beeps once it works; if twice, the probe is executing and must stay off |
| `tell me to quit` inside an OS 9 applet | Unverified | Send `__QUIT__` and see. Wrapped in `try`, so failure is harmless |
| Finder terms `empty trash`, `free space`, `capacity`, `creator type` on the OS 9 Finder | Inherited-from-classic terminology; **no OS 9 Finder dictionary dump exists online** | Open Dictionary on the Finder and read them |
| `path to startup disk` and `path to preferences` on classic Standard Additions | Listed under the guide's "Classic domain"; not read off a 9.2 dictionary | The code falls back to the Finder and then to a hard-coded `"Macintosh HD:"`, so a failure is not fatal |