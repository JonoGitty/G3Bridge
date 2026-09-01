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
