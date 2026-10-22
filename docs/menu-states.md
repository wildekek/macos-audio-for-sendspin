# Menu states

What the menu bar menu shows, what each state means, and why. The menu is
`App/MacOSAudioForSendspin/MenuView.swift`; the state behind it is `BridgeController`.
Change this file when you change what the menu shows.

## Rules

These hold across the menu. A new state should follow them, or change them here first.

1. **What you chose stays; what you didn't, leaves.** A ticked speaker or a paired Music
   Assistant that goes away stays in the list as **Unavailable** and comes back by itself. An
   unticked speaker, or a Music Assistant that was never paired, leaves the list.
2. **One word for gone: Unavailable.** For a speaker, for the ticked speakers together, and
   for Music Assistant. Not "Offline".
3. **Playing shows on the menu bar icon, not in the rows.** The icon fills while the Mac's
   sound is going out: to a connected speaker, or through Music Assistant's open stream
   (`isPlaying`: sound in the last 3 s). Otherwise it's the outline. Both are templates, in the
   menu bar's own colour (a coloured icon looked out of place on Liquid Glass). The rows don't say Playing or Idle: the Mac's own output couldn't (the app
   can't hear it), and a destination that works needs no word.
4. **A row only says why it can't play.** "Unavailable" on the right, or a caption saying what
   to set up (tick a speaker, select the Mac as an input in Music Assistant). There's no
   "Ready" or "Idle".
5. **No automatic fallback.** When every ticked speaker is gone, the Mac's output stays on
   Sendspin. Switching output by itself would be unpredictable; the user chooses the Mac's own
   output when they want it.
6. **Show only what exists.** A destination appears once it's found (or chosen). Until
   anything is found, the menu says what it's looking for.

## Rows

From top to bottom; a notice can sit above them.

| Row | Shown when |
|---|---|
| Notice | The driver is missing or outdated, or microphone or Local Network access is denied. One at a time, in that order. Without the driver there are no rows. |
| Looking for speakers… | No speaker is found or ticked, Music Assistant isn't connected or paired, and Sendspin speakers isn't chosen. Closes as soon as either is found. Links to [which speakers work](https://www.sendspin-audio.com/#speakers). |
| Sendspin speakers | A speaker is found or ticked, or Sendspin speakers is chosen. The speakers are listed under it while it's chosen. |
| Music Assistant (or another server) | A server is connected to this Mac as its source, or paired with it (`offersMusicAssistant`). Named after the server; see below. |
| This Mac | Always: the Mac's own output, named after it (e.g. MacBook Pro Speakers). |

One destination is chosen at a time (blue icon, bold name): Sendspin speakers, Music Assistant
or this Mac. The first two make the Mac's output the Sendspin device; they aren't in sync with
each other, so they don't play together.

## Menu bar icon

| Shows | Means |
|---|---|
| Filled (`MenuBarIconPlaying`) | The Mac's sound is going out: Sendspin speakers chosen and a ticked speaker connected, or Music Assistant chosen with its stream open; and the Mac made sound in the last 3 s. VoiceOver: "Sendspin, playing". |
| Outline (`MenuBarIcon`) | Anything else, including while the Mac's own output is chosen. |

## Sendspin speakers

The right side:

| Shows | Means |
|---|---|
| Unavailable | Chosen, speakers are ticked, and none of them can be reached. |
| Speaker names | Not chosen: the ticked speakers, or until one is ticked, the speakers found (`speakersSummary`). |
| nothing | Chosen and nothing is wrong (playing or not), or nothing ticked yet (see the caption below). |

Under it, while chosen: "Looking for Sendspin speakers…" when there's none, and "Tick a
speaker to play on it." when none is ticked.

Choosing it with exactly one speaker and nothing ticked ticks that speaker. The Mac's output
switches to Sendspin once a ticked speaker connects.

### A speaker

Each speaker: its name, then a volume slider or a status, then a checkbox. Clicking the name
plays on that speaker only; the checkbox adds or removes it. Hovering a playing speaker's name
shows the format it receives (e.g. FLAC · 48 kHz · 16-bit) in place of the name.

| Shows | Means | Until |
|---|---|---|
| Volume slider | Ticked and connected. | – |
| Connecting… | Ticked, the first connection is under way. | It's connected. |
| Unavailable | Ticked and can't be reached: it lost power or the network, or isn't found. | It's back; the app keeps trying, at most 5 s apart. |
| In use elsewhere | Another server took it over (still ticked), or it's playing something else (shown unticked). | The user clicks its name or ticks it: the protocol doesn't let the app take it back by itself. |
| Disconnected | Its user disconnected it from this Mac (`client/goodbye` with `user_request`). | The user unticks and ticks it. |
| Can't connect | It answers, but setting up the connection fails. | It works; the app retries, up to 30 s apart. |
| Needs pairing | It only plays for paired servers; the app can't pair speakers yet. | – |
| Identity changed | It presents a different identity than the one the user allowed. | The user unticks and ticks it, allowing the new one. |
| nothing | Unticked; also a speaker that connected to this Mac and waits to be allowed. | The user ticks it. |

A speaker keeps the name it gave in its hello while it's unticked or away (mDNS often has only
an ID).

## Music Assistant, or another Sendspin server

The Mac is a Sendspin source for one server at a time, usually Music Assistant. The row is
the same for any server, with two Music Assistant extras: its logo, and links to its own pages.
The app knows it's Music Assistant when a `_mass._tcp` record on the network has the server's
name (it remembers the names it has seen, so an offline Music Assistant keeps its logo). Any
other server shows its own name with a generic icon (`server.rack`), and its captions have no
links.

The right side:

| Shows | Means |
|---|---|
| Unavailable | Paired, not connected (chosen or not). |
| nothing | Not paired yet (the caption says how), or paired and connected (chosen or not; while it's chosen, the caption says what's left to do). |

The caption under it:

| When | Caption |
|---|---|
| Not paired yet | Pair this Mac in **[server]**, then enter the code that appears here. Clicking the row opens the same page. |
| A code is showing | Enter 123-456 in **[server]**. |
| Chosen, not the input yet | Select [Mac] as an input source in **[server]** to start playing. |
| Chosen, the Mac is its input | Choose speakers, groups and volume in [server]. |
| Chosen, Unavailable | It reconnects by itself when it's back on the network. |

For Music Assistant, the server's name links to the URL it advertises over mDNS
(`internal_url`): pairing to its players waiting for setup (`#/settings/players?status=needs_setup`),
the input to Browse (`#/browse`). Without a URL, or for another server, the name is plain text.
While the speakers are chosen, the server gets silence, so its stream stays open for when it's
chosen again.

### Pairing: by a code shown on this Mac

Servers implement every pairing method, so the Mac pairs by code: in its hello it offers
`dynamic_pairing_code` (on its display, as digits), and `pairing_psk`, which every client
must implement. It never offers the static code too: a client offers exactly one code method
(the implementation guide).

When someone sets this Mac up on the server, the server sends a pairing activation and the
Mac shows a six-digit code: in the caption, and in a small floating window near the top of the
screen, without window controls, in the menu's glass, that doesn't take focus from where it's
typed. The window has Copy Code and Cancel, and says "Paired with [server]" for a moment once
it's done, or "Pairing ended".

The pairing token is for automated pairing between systems, which a person never types, so
the app doesn't show it anywhere (the implementation guide: "Keep automated pairing out of
this menu"). The Pairing PSK method itself stays: every client must implement it.

## When something goes away, and comes back

| What happens | The menu shows | When it's back |
|---|---|---|
| A ticked speaker loses power or the network | Unavailable within about 6 s (the connection is pinged every 2 s). Sendspin speakers: Unavailable once none of the ticked ones can be reached. | It reconnects and plays by itself. |
| An unticked speaker loses power or the network | It leaves the list within about 20 s: every speaker is checked every 15 s, and mDNS is asked to verify one that doesn't answer. | It appears as soon as it announces itself. |
| A ticked speaker shuts down properly | Unavailable while it's gone. | It reconnects once it announces itself again: a fresh start. |
| An unticked speaker shuts down properly | It leaves the list at once. | It appears as soon as it announces itself. |
| Music Assistant goes offline, paired | Unavailable, chosen or not. | Music Assistant connects to the Mac again by itself. |
| Music Assistant goes away, never paired | Its row leaves the list. | It appears again, ready to pair. |
| Its pairing is forgotten (Settings › Forget) | Connected: ready to pair again. Not connected: the row leaves, and the speakers become the destination. | Pairing again needs the token. |
