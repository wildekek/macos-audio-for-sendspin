# Menu states

What the menu bar menu shows, what each state means, and why. The menu is
`App/MacOSAudioForSendspin/MenuView.swift`; the state behind it is `BridgeController`.
Change this file when you change what the menu shows.

## Rules

These hold across the menu. A new state should follow them, or change them here first.

1. **What you chose stays; what you didn't, leaves.** A speaker in the group or a paired Music
   Assistant that goes away stays in the list as **Unavailable** and comes back by itself. An
   speaker out of the group, or a Music Assistant that was never paired, leaves the list.
2. **One word for gone: Unavailable.** For a speaker and for Music Assistant. Not "Offline".
3. **Playing shows on the menu bar icon, not in the rows.** The icon fills while the Mac's
   sound is going out: to a connected speaker, or through Music Assistant's open stream
   (`isPlaying`: sound in the last 3 s). Otherwise it's the outline. Both are templates, in the
   menu bar's own colour (a coloured icon looked out of place on Liquid Glass). The rows don't say Playing or Idle: the Mac's own output couldn't (the app
   can't hear it), and a destination that works needs no word.
4. **A row only says why it can't play.** "Unavailable" on the right, or a caption saying what
   to set up (select the Mac as an input in Music Assistant). There's no
   "Ready" or "Idle".
5. **No automatic fallback.** When every speaker in the group is gone, the Mac's output stays on
   Sendspin. Switching output by itself would be unpredictable; the output only changes when
   the user adds, removes or picks a speaker.
7. **Choosing is all there is.** No switch: where the Mac plays follows from what's chosen, and
   the dot at the top only shows whether that goes through Sendspin.
8. **One indicator per row.** The icon shows what plays and is the control that adds or
   removes; nothing beside it repeats that.
6. **Show only what exists.** A destination appears once it's found (or chosen). Until
   anything is found, the menu says what it's looking for.

## Rows

From top to bottom.

| Row | Shown when |
|---|---|
| Sendspin, and the dot | Always. The dot is filled (accent) while the Mac plays through Sendspin, an empty ring while it plays directly; its help and VoiceOver say "In use: the Mac plays through Sendspin" or "Not in use: the Mac plays directly". |
| Notice | The driver is missing or outdated, or Local Network access is denied. One at a time, in that order. Without the driver there are no rows below. |
| The Mac's own output | Always (its built-in speakers when nothing else is there). First, as in AirPlay's list. |
| The Sendspin speakers | Each speaker found or in the group. |
| Looking for speakers… | No Sendspin speaker is found or in the group, and Music Assistant isn't connected or paired. Links to [which speakers work](https://www.sendspin-audio.com/#speakers). |
| Divider, then Music Assistant (or another server) | A server is connected to this Mac as its source, or paired with it (`offersMusicAssistant`). Named after the server; see below. The divider: servers play on what they choose and don't group with the speakers. |

## Sendspin or direct follows what's chosen

The Mac's own speakers only go through Sendspin while they play along with a Sendspin speaker:
on their own there's nothing to keep in sync with, so the Mac plays on them directly, without
the speaker buffer's delay.

| In the group | Mac's output | Dot | Delay |
|---|---|---|---|
| Only the Mac's own output (speakers, AirPods, AirPlay) | That output | Empty | None |
| Any Sendspin speaker, with or without the Mac's own output | Sendspin | Filled | The speaker buffer, 300 ms or more (longer when the Mac's own output needs it) |

Changing between the first two rows switches the Mac's output, which costs a moment of
silence, as any output switch in macOS does. In the menu:

- **The group shows what plays**, or will once an added speaker connects. While the Mac plays
  directly or Music Assistant plays, the Sendspin speakers show as not in it.
- **Adding a Sendspin speaker** (its icon's +) plays through Sendspin, starting from what plays
  now: the Mac's own output stays and plays along, in sync (unless it's AirPlay, see below).
- **Removing the last Sendspin speaker** (its icon's −) plays on the Mac's own output directly
  when it's in the group, and otherwise goes back to the Mac's own output anyway.
- **Adding the Mac's own output** joins the Sendspin speakers when one is in the group, and
  otherwise plays on it directly. What's all that plays can't be removed: it has no −.
- **Clicking a name** plays there only, as in the Sound menu: the Mac's own output directly,
  a Sendspin speaker on its own.
- **Music Assistant** plays through Music Assistant; adding a speaker plays on the speakers
  again.

## Menu bar icon

| Shows | Means |
|---|---|
| Filled (`MenuBarIconPlaying`) | The Mac's sound is going out: through Sendspin with a speaker in the group connected, or Music Assistant chosen with its stream open; and the Mac made sound in the last 3 s. VoiceOver: "Sendspin, playing". |
| Outline (`MenuBarIcon`) | Anything else, including while the Mac plays directly. |

## A speaker

Each speaker: its icon, its name, then a volume slider or a status. The icon is the control:

| Icon | Means | Clicking it |
|---|---|---|
| Filled (accent) | It plays. Hovering shows a − badge, unless it's all that plays. | Removes it. |
| Accent ring | In the group, not playing yet: connecting, or gone (the status says which). Hovering shows −. | Removes it. |
| Grey, with a + badge | It can join. Hovering tints it. | Adds it. |
| Grey, no badge | It can't join what plays: Music Assistant plays (every speaker then), or it's an AirPlay output. Like a server's row. | Plays there. |

Clicking the name plays there only. The Mac's own output has its icon from the macOS Sound
menu (laptop, desktop, AirPods, HomePod, AirPlay); every Sendspin speaker has the speaker icon,
since Sendspin doesn't say what kind of device it is. Hovering a playing speaker's name shows
the format it receives (e.g. FLAC · 48 kHz · 16-bit) in place of the name.

| Shows | Means | Until |
|---|---|---|
| Volume slider | It plays the Mac's sound (filled icon). | – |
| Connecting… | Added, the first connection is under way. | It's connected. |
| Unavailable | In the group and can't be reached: it lost power or the network, or isn't found. | It's back; the app keeps trying, at most 5 s apart. |
| In use elsewhere | Another server took it over (still in the group), or it's playing something else (shown out of it). | The user clicks its name or adds it: the protocol doesn't let the app take it back by itself. |
| Disconnected | Its user disconnected it from this Mac (`client/goodbye` with `user_request`). | The user removes it and adds it again. |
| Can't connect | It answers, but setting up the connection fails. | It works; the app retries, up to 30 s apart. |
| Needs pairing | It only plays for paired servers; the app can't pair speakers yet. | – |
| Identity changed | It presents a different identity than the one the user allowed. | The user clicks its name or this status (or removes it and adds it again), allowing the new one. |
| nothing | Not in the group (as every Sendspin speaker shows while the Mac plays directly or Music Assistant is chosen); also a speaker that connected to this Mac and waits to be allowed. | The user adds it. |

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

An AirPlay output is direct only: macOS has the device only while it's the Mac's output and
removes it once Sendspin is, so its icon has no badge. Adding a Sendspin speaker while the Mac
plays on AirPlay moves the sound to the Sendspin speakers, and the row falls back to the
built-in speakers.

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
| Music Assistant goes offline, paired | Unavailable, chosen or not. | Music Assistant connects to the Mac again by itself. |
| Music Assistant goes away, never paired | Its row leaves the list. | It appears again, ready to pair. |
| Its pairing is forgotten (Settings › Forget) | Connected: ready to pair again. Not connected: the row leaves, and the speakers become the destination. | Pairing again needs the token. |
