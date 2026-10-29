import json, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_pairing.py")).read().split("mac = row(MAC")[0])

# Now the app is the Open Home Foundation's, it can carry the Sendspin mark. Options for the app
# icon (which the driver's device icon follows: make-app-icon.swift draws both) and the menu bar
# icon, next to the speaker as built.
ROOT = os.path.join(HERE, "..", "..", "..")
# Sendspin's logo, as make-app-icon.swift draws it, 115 × 94.
LOGO = open(os.path.join(ROOT, "App", "sendspin-logo.svg")).read()
PATHS = re.findall(r'<path d="([^"]+)"', LOGO)
S_PARTS, WAVES = (0, 1, 6, 7), (2, 3, 4, 5)
CREAM, CORAL = '#F5F4EC', '#E25C4C'
GREY = '#6e6e73'


def mark(width, colour, waves=1.0):
    """The mark, `width` px wide; `waves` is the waves' opacity (0 leaves them out, the S stays put)."""
    parts = ''.join(f'<path d="{PATHS[i]}"/>' for i in S_PARTS)
    if waves:
        parts += f'<g opacity="{waves}">' + ''.join(f'<path d="{PATHS[i]}"/>' for i in WAVES) + '</g>'
    return (f'<svg width="{width:.1f}" height="{width * 94 / 115:.1f}" viewBox="0 0 115 94" fill="{colour}" '
            f'aria-hidden="true" style="display: block">{parts}</svg>')


def tile(size, background, ink):
    """On the macOS icon grid, as make-app-icon.swift draws it: the tile is 80% of the canvas,
    its corner radius 18%, with a soft shadow."""
    t = size * 0.8
    return (f'<div style="width: {size}px; height: {size}px; display: flex; align-items: center; justify-content: center; flex: none">'
            f'<div style="width: {t:.1f}px; height: {t:.1f}px; border-radius: {size * 0.18:.1f}px; background: {background}; '
            f'box-shadow: 0 {size * 0.008:.1f}px {size * 0.02:.1f}px rgba(0, 0, 0, 0.3); display: flex; align-items: center; justify-content: center">'
            f'{mark(t * 0.7, ink)}</div></div>')


# The speaker icon of 0.10.x, uploaded to the canvas from the asset catalogue (boards can't carry
# data: URIs): icon_128x128@2x.png, icon_128x128.png, icon_32x32@2x.png and icon_16x16@2x.png.
BUILT = {128: '/_blob/904fcfb2ca1599bf947d55d0df322bf7', 64: '/_blob/e8f3817bf31ba72d0bad6fa4ec244cb7',
         32: '/_blob/36639be879563dd8fe4a6054065d0167', 16: '/_blob/10b1cc1c0fd04e17db1e62f536b03fcf'}


def built(size):
    return f'<img src="{BUILT[size]}" width="{size}" height="{size}" alt="" style="display: block">'


GRAPHITE = 'linear-gradient(#3A3F48, #1D2025)'
APP = [
    ('Before (0.10.x)', 'A bookshelf speaker on a graphite tile.', 'Drawn without the mark while the app wasn’t the OHF’s.', built),
    ('A1 · The Sendspin tile', 'Coral mark on cream, as sendspin-audio.com’s own icon.',
     'The website’s own icon; light, so it stands out in a dark Dock.',
     lambda s: tile(s, CREAM, CORAL)),
    ('A2 · Coral tile (chosen)', 'Cream mark on coral.', 'The brand colour as the tile, as the Music Assistant and Home Assistant apps do.',
     lambda s: tile(s, CORAL, CREAM)),
    ('A3 · Graphite tile', 'Coral mark on the graphite as built.', 'Keeps today’s tile, so it still looks like the app people installed.',
     lambda s: tile(s, GRAPHITE, CORAL)),
]
DESKTOPS = [('Light', '#dfe3ea'), ('Dark', '#1e1f24')]


def cell(label, inner, background, width):
    return (f'<div style="display: flex; flex-direction: column; gap: 6px; width: {width}px">'
            f'<span style="font-size: 11px; font-weight: 600; color: {GREY}">{label}</span>'
            f'<div style="display: flex; align-items: center; justify-content: center; height: 148px; border-radius: 10px; background: {background}">{inner}</div></div>')


def description(title, look, why):
    return (f'<div style="display: flex; flex-direction: column; gap: 4px; width: 260px; flex: none"><b style="font-size: 14px">{title}</b>'
            f'<span style="font-size: 12px; line-height: 16px">{look}</span>'
            f'<span style="font-size: 12px; line-height: 16px; color: {GREY}">{why}</span></div>')


rows = []
for title, look, why, icon in APP:
    small = ''.join(icon(s) for s in (64, 32, 16))
    cells = (''.join(cell(f'{name} · 128', icon(128), bg, 160) for name, bg in DESKTOPS)
             + cell('Light · 64, 32, 16', f'<div style="display: flex; align-items: center; gap: 16px">{small}</div>', DESKTOPS[0][1], 200)
             + cell('Dark · 64, 32, 16', f'<div style="display: flex; align-items: center; gap: 16px">{small}</div>', DESKTOPS[1][1], 200))
    rows.append(f'<div style="display: flex; gap: 24px; align-items: end">{description(title, look, why)}{cells}</div>')
note = (f'<div style="max-width: 1000px; font-size: 12px; line-height: 17px; color: #3c3c43">The app icon shows in the Dock, Finder, Launchpad, '
        f'the disk image, the README and Login Items. The Sendspin device in Sound settings and Audio MIDI Setup gets the same icon '
        f'(<code>make-app-icon.swift</code> draws both). The mark is Sendspin’s logo unchanged; at 16 px its waves close up, '
        f'as on the website’s favicon.</div>')
APP_W = 260 + 2 * 160 + 2 * 200 + 4 * 24 + 40
APP_H = 4 * 172 + 120

# The menu bar icon: a template image, in the bar's own ink. In 0.10.x an outline speaker that
# filled while the Mac's sound went out; M1 is built (gen_status.py shows it).
SPEAKER = ('<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><rect x="4.25" y="1.75" width="9.5" height="14.5" rx="2" fill="none" stroke="#000000" stroke-width="1.5"/>'
           '<circle cx="9" cy="5.4" r="1.3" fill="#000000"/><circle cx="9" cy="11.1" r="2.9" fill="none" stroke="#000000" stroke-width="1.5"/></svg>')
SPEAKER_PLAYING = ('<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><path fill="#000000" fill-rule="evenodd" d="M6.1,1 H11.9 A2.6,2.6 0 0 1 14.5,3.6 V14.4 A2.6,2.6 0 0 1 11.9,17 H6.1 A2.6,2.6 0 0 1 3.5,14.4 V3.6 A2.6,2.6 0 0 1 6.1,1 Z '
                   'M7.7,5.4 a1.3,1.3 0 1 0 2.6,0 a1.3,1.3 0 1 0 -2.6,0 Z M5.35,11.1 a3.65,3.65 0 1 0 7.3,0 a3.65,3.65 0 1 0 -7.3,0 Z M6.85,11.1 a2.15,2.15 0 1 0 4.3,0 a2.15,2.15 0 1 0 -4.3,0 Z"/></svg>')


MENU = [
    ('Before (0.10.x)', 'A speaker: an outline, filled while it plays.', 'Says “speaker”, like the Sound menu’s icon.',
     lambda ink: SPEAKER.replace('#000000', ink), lambda ink: SPEAKER_PLAYING.replace('#000000', ink)),
    ('M1 · The waves appear (chosen)', 'The S alone; its waves appear while it plays.',
     'The mark tells what it does: it sends only while the Mac’s sound goes out. Recognisable as Sendspin.',
     lambda ink: mark(18, ink, waves=0), lambda ink: mark(18, ink)),
    ('M2 · The waves light up', 'The whole mark; its waves faint until it plays.',
     'The same shape in both states, but the faint waves look dirty.',
     lambda ink: mark(18, ink, waves=0.35), lambda ink: mark(18, ink)),
]
BARS = {'Light': dict(bar='rgba(246, 246, 248, 0.85)', ink='#1d1d1f', border='rgba(0, 0, 0, 0.16)'),
        'Dark': dict(bar='rgba(40, 40, 44, 0.85)', ink='#ffffff', border='rgba(255, 255, 255, 0.14)')}


def menu_bar(icon, theme):
    t = BARS[theme]
    others = ''.join(f'<span style="width: 15px; height: 12px; border-radius: 3px; border: 1.5px solid {t["ink"]}; opacity: 0.35"></span>' for _ in range(2))
    return (f'<div style="display: flex; align-items: center; justify-content: flex-end; gap: 14px; height: 26px; padding: 0 12px; '
            f'border-radius: 8px; background: {t["bar"]}; border: 0.5px solid {t["border"]}">'
            f'{others}<span style="display: flex; width: 18px; height: 18px; align-items: center; justify-content: center">{icon(t["ink"])}</span>'
            f'<span style="font-size: 12px; color: {t["ink"]}">Sun 20:35</span></div>')


def zoomed(icon):
    # Four times the size, to see the shapes; an 18 pt box, as the template image's.
    return (f'<div style="display: flex; align-items: center; justify-content: center; width: 72px; height: 72px; border-radius: 8px; '
            f'background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.12)"><div style="transform: scale(4); display: flex; '
            f'width: 18px; height: 18px; align-items: center; justify-content: center">{icon("#1d1d1f")}</div></div>')


def labelled(label, html):
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{label}</span>{html}</div>')


menu_rows = []
for title, look, why, idle, plays in MENU:
    cells = ''.join(labelled(f'{theme} · {state}', menu_bar(icon, theme))
                    for theme in BARS for state, icon in (('idle', idle), ('plays', plays)))
    zoom = labelled('×4 · idle, plays', f'<div style="display: flex; gap: 12px">{zoomed(idle)}{zoomed(plays)}</div>')
    menu_rows.append(f'<div style="display: grid; grid-template-columns: 260px repeat(4, 190px) 160px; gap: 24px; align-items: end">'
                     f'{description(title, look, why)}{cells}{zoom}</div>')
menu_note = (f'<div style="max-width: 1000px; font-size: 12px; line-height: 17px; color: #3c3c43">“Plays” is the rule as built '
             f'(<code>SpeakerMenu.sendspinPlays</code>); the dot in the menu stays as it is. The welcome window shows the idle icon, '
             f'to say where the app lives.</div>')
MENU_W = 260 + 4 * 190 + 160 + 5 * 24 + 40
MENU_H = 3 * 130 + 110

idx = json.load(open(f"{R}/project/canvas.json"))
Y = 24700
idx["notes"]["icons"] = {"kind": "title1", "maxW": max(APP_W, MENU_W), "w": 240, "x": 0, "y": Y,
                         "text": "Sendspin, the OHF’s app: the app icon and the menu bar icon"}
for name, title, html, w, h, y in [
        ('AppIcons.dc.html', 'The app icon (and the Sendspin device’s): options', board('The app icon', rows + [note], APP_H, APP_W), APP_W, APP_H, Y + 260),
        ('MenuBarIcons.dc.html', 'The menu bar icon: options, idle and playing, light and dark', board('The menu bar icon', menu_rows + [menu_note], MENU_H, MENU_W), MENU_W, MENU_H, Y + 260 + APP_H + 100)]:
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": 0, "y": y, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
