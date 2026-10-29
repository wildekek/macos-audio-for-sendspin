# Menu states

What the menu bar menu shows, what each state means, and why. The menu is
`App/Sendspin/MenuView.swift`; the state behind it is `BridgeController`.

How a speaker's or a server's row shows its state, and what a choice in the menu leads to, are
`SpeakerMenu` in `Packages/SendspinServerKit`, and its rules are the tests in
`SpeakerMenuTests`: one test per rule, named after it, with why it is so. This file doesn't
repeat them; it holds the rest of the menu, and the rules the whole menu follows. Change a
rule here, or a test there, together with the code.

How a row looks is `OutputRow` in `SendspinMenuUI`, for speakers and servers alike, and
`RowSnapshotTests` holds an image of every state, light and dark, rendered from the rules and
that view, plus a sheet of them all. They're recorded and compared on a Mac, not in CI: `SNAPSHOT_RECORD=1 swift test` records them again.

## Rules

These hold across the menu. A new state should follow them, or change them here first.

1. **What you chose stays; what you didn't, leaves.** A speaker in the group or a paired Music
   Assistant that goes away stays in the list as **Unavailable** and comes back by itself. A
   speaker out of the group, or a server that was never paired, leaves the list.
2. **One word for gone: Unavailable.** For a speaker and for a server. Not "Offline".
3. **Playing shows on the menu bar icon, not in the rows.** Sendspin's S gets its waves while the Mac's
   sound is going out: to a connected Sendspin speaker, or through the server's open stream
   (`isPlaying`: sound in the last 3 s). Otherwise it's the S alone. Both are templates, in the
   menu bar's own colour (a coloured icon looked out of place on Liquid Glass). The rows don't say Playing or Idle: the Mac's own output couldn't (the app
   can't hear it), and a destination that works needs no word.
4. **A row only says why it can't play.** "Unavailable" on the right, or a caption saying what
   to set up (select the Mac as an input on the server). There's no
   "Ready" or "Idle".
5. **No automatic fallback.** When every speaker in the group is gone, the Mac's output stays on
   Sendspin. Switching output by itself would be unpredictable; the output only changes when
   the user adds, removes or picks a speaker.
6. **Show only what exists.** A destination appears once it's found (or chosen). Until
   anything is found, the menu says what it's looking for.
7. **Choosing is all there is.** No switch: where the Mac plays follows from what's chosen, and
   the dot at the top shows whether that goes through Sendspin, in the checks' colours: blue
   while it plays, grey while it's in use but nothing goes out, an empty ring while it isn't
   in use.
8. **One indicator per row.** Where an output is groupable, the check on the right is the
   group, as in Apple's AirPlay picker, and the icon only says what kind of device it is. Where
   it isn't, there's no check, and the icon turns blue while it plays, as in the Sound menu.
9. **Every output is groupable or not, and one rule follows from it.** Every Sendspin speaker
   and the Mac's own output are groupable, unless that's AirPlay; an AirPlay output and Music
   Assistant aren't. While something that isn't groupable plays, nothing can join it.
10. **Something always plays after a choice.** When nothing left in the group could play, the
    Mac's own output takes over.

## Rows

From top to bottom.

| Row | Shown when |
|---|---|
| Sendspin, and the dot | Always. The dot is blue while Sendspin plays (when the menu bar icon has its waves), grey while the Mac's output is Sendspin but nothing goes out (silence, or every speaker in the group unavailable), an empty ring while the Mac plays directly. Its help and VoiceOver say which: "Playing: the Mac's sound goes through Sendspin", "In use: the Mac plays through Sendspin, but nothing goes out now" or "Not in use: the Mac plays directly". |
| Notice | The driver is missing or outdated, or Local Network access is denied. One at a time, in that order. Without the driver there are no rows below. |
| The Mac's own output | Always (its built-in speakers when nothing else is there). First, as in AirPlay's list. |
| The Sendspin speakers | Each speaker found or in the group. |
| Looking for speakers… | No Sendspin speaker is found or in the group, and no server is connected or paired. Links to [which speakers work](https://www.sendspin-audio.com/#speakers). |
| Divider, then the server (Music Assistant or another) | A server is connected to this Mac as its source, or paired with it (`offersServer`). Named after the server; see below. The divider: servers play on what they choose and don't group with the speakers. |

## Sendspin or direct follows what's chosen

The Mac's own speakers only go through Sendspin while they play along with a Sendspin speaker:
on their own there's nothing to keep in sync with, so the Mac plays on them directly, without
the speaker buffer's delay.

| In the group | Mac's output | Dot | Delay |
|---|---|---|---|
| Only the Mac's own output (speakers, AirPods, AirPlay) | That output | Empty | None |
| Any Sendspin speaker, with or without the Mac's own output | Sendspin | Blue, or grey while nothing goes out | The speaker buffer: what the speakers ask for (longer when the Mac's own output needs it) |

Changing between the two switches the Mac's output, which costs a moment of silence, as any
output switch in macOS does. What each choice leads to (adding, removing, clicking a name,
choosing a server) is in `SpeakerMenuTests`.

## Menu bar icon

| Shows | Means |
|---|---|
| The S with its waves (`MenuBarIconPlaying`) | The Mac's sound is going out: to a connected Sendspin speaker (the Mac's own speakers alone don't count), or a server chosen with its stream open; and the Mac made sound in the last 3 s. The dot is blue then. VoiceOver: "Sendspin, playing". |
| The S alone (`MenuBarIcon`) | Anything else, including while the Mac plays directly. |

Between the two, the S turns a half turn clockwise as the inner, then the outer waves fade in (0.7 s), and back as they fade out (`MenuBarIcon.swift`). The S is the same after a half turn, so it lands where it started. With Reduce Motion it switches at once.

## A speaker

Each speaker, as in Apple's AirPlay picker: its device icon, its name, then a volume slider or
a status, then a round check: filled while it plays, grey while it's in the group but can't
play, a spinner while it connects, an empty ring when it's out of the group. Which, and what
clicking it does, is in `SpeakerMenuTests`.

The Mac's own output has its icon from the macOS Sound menu (laptop, desktop, AirPods, HomePod, AirPlay); every Sendspin speaker has the speaker icon,
since Sendspin doesn't say what kind of device it is. Hovering a playing speaker's name shows
the format it receives (e.g. FLAC · 48 kHz · 16-bit) in place of the name.

What each status means, and until when it shows:

| Shows | Means | Until |
|---|---|---|
| Volume slider | It plays the Mac's sound. | – |
| Connecting… | The first connection is under way, where there's no check to turn into a spinner. | It's connected. |
| Unavailable | It can't be reached: it lost power or the network, or isn't found. | It's back; the app keeps trying, at most 5 s apart. |
| In use elsewhere | Another server took it over (still in the group), or it's playing something else (shown out of it). | The user clicks its name or adds it: the protocol doesn't let the app take it back by itself. |
| Disconnected | Its user disconnected it from this Mac (`client/goodbye` with `user_request`). | The user removes it and adds it again. |
| Can't connect | It answers, but setting up the connection fails. | It works; the app retries, up to 30 s apart. |
| Needs pairing | It only plays for paired servers; the app can't pair speakers yet. | – |
| Identity changed | It presents a different identity than the one the user allowed. | The user clicks its name or this status (or removes it and adds it again), allowing the new one. |
| nothing | Not in the group (as every Sendspin speaker shows while the Mac plays directly or a server is chosen); also a speaker that connected to this Mac and waits to be allowed. | The user adds it. |

A speaker keeps the name it gave in its hello while it's out of the group or away (mDNS often has only
an ID).

### The Mac's own speakers

The Mac's own output: the one it uses, or used last besides Sendspin (MacBook Pro Speakers,
AirPods, a USB DAC), or when that's gone its built-in speakers. Named and drawn as in the
macOS Sound menu. With a Sendspin speaker it plays along in sync: the app plays on it itself,
on the same clock (`LocalPlayer`), and it's in the group volume like any speaker; the group's
buffer grows to its output latency when that's longer. Alone, the Mac plays on it directly
(see above). Either way the slider is the device's own volume. Muting the Mac mutes it too,
without touching the device's own mute.

An AirPlay output isn't groupable: macOS has the device only while it's the Mac's output, and
removes it once Sendspin is. Choosing a Sendspin speaker moves the sound there, and the row
falls back to the built-in speakers.

## A Sendspin server, such as Music Assistant

The Mac is a Sendspin source for one server at a time, usually Music Assistant. The row is
the same for any server, with two Music Assistant extras: its logo, and links to its own pages.
The app knows it's Music Assistant when a `_mass._tcp` record on the network has the server's
name (it remembers the names it has seen, so an offline Music Assistant keeps its logo). Any
other server shows its own name with a generic icon (`server.rack`), and its captions have no
links.

Its row follows the same rules as a speaker's (`SpeakerMenuTests`): it isn't groupable, so its
icon turns blue while it plays, and "Unavailable", with its warning, while it's paired and
not connected. The caption under it:

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
typed. The code is on the clipboard at once: the digits lift and settle, and "Copied" fades in
with a bouncing clipboard icon; clicking the digits copies it again. Close only dismisses the
window (the pairing goes on, its code still in the menu). The window says "Paired with
[server]" for a moment once it's done, or "Pairing ended".

The pairing token is for automated pairing between systems, which a person never types, so
the app doesn't show it anywhere (the implementation guide: "Keep automated pairing out of
this menu"). The Pairing PSK method itself stays: every client must implement it.

## When something goes away, and comes back

| What happens | The menu shows | When it's back |
|---|---|---|
| A speaker in the group loses power or the network | Unavailable within about 6 s (the connection is pinged every 2 s). | It reconnects and plays by itself. |
| A speaker out of the group loses power or the network | It leaves the list within about 20 s: every speaker is checked every 15 s, and mDNS is asked to verify one that doesn't answer. | It appears as soon as it announces itself. |
| A speaker in the group shuts down properly | Unavailable while it's gone. | It reconnects once it announces itself again: a fresh start. |
| A speaker out of the group shuts down properly | It leaves the list at once. | It appears as soon as it announces itself. |
| A paired server goes offline | Unavailable, chosen or not. | The server connects to the Mac again by itself. |
| A server that was never paired goes away | Its row leaves the list. | It appears again, ready to pair. |
| Its pairing is forgotten (Settings › Forget) | Connected: ready to pair again. Not connected: the row leaves, and the speakers become the destination. | Pairing again needs the token. |
