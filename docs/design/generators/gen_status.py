import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_pairing.py")).read().split("mac = row(MAC")[0])

# The menu bar icon and the dot by "Sendspin", as built (SpeakerMenu.sendspinPlays and .dot;
# MenuView's header; the MenuBarIcon and MenuBarIconPlaying template images).
ASSETS = os.path.join(HERE, "..", "..", "..", "App", "Sendspin", "Assets.xcassets")


def svg(name, file, colour):
    text = open(os.path.join(ASSETS, f"{name}.imageset", file)).read()
    return text.replace('#000000', colour).replace('width="18" height="18"', 'width="18" height="18" aria-hidden="true"')


THEMES = {
    # Menu bar, its ink; the menu, its text; the accent; .secondary.
    'light': dict(bar='rgba(246, 246, 248, 0.85)', ink='#1d1d1f', menu='#f5f5f7', text='#1d1d1f',
                  accent='#0a7aff', secondary=(60, 60, 67, 0.6), border='rgba(0, 0, 0, 0.16)'),
    'dark': dict(bar='rgba(40, 40, 44, 0.85)', ink='#ffffff', menu='#2c2c2e', text='#f5f5f7',
                 accent='#0a84ff', secondary=(235, 235, 245, 0.6), border='rgba(255, 255, 255, 0.14)'),
}


def secondary(theme, factor):
    r, g, b, a = THEMES[theme]['secondary']
    return f'rgba({r}, {g}, {b}, {a * factor:.2f})'


def dot(state, theme):
    t = THEMES[theme]
    if state == 'plays':
        # A tight, soft halo: 1 pt wider than the dot, blurred.
        return (f'<span style="position: relative; display: inline-block; width: 10px; height: 10px">'
                f'<span style="position: absolute; left: -1px; top: -1px; width: 12px; height: 12px; border-radius: 6px; '
                f'background: {t["accent"]}; opacity: 0.45; filter: blur(1.5px)"></span>'
                f'<span style="position: absolute; inset: 0; border-radius: 5px; background: {t["accent"]}"></span></span>')
    if state == 'inUse':
        # The grey of a grey check: in, but not doing anything.
        return f'<span style="display: inline-block; width: 10px; height: 10px; border-radius: 5px; background: {secondary(theme, 0.5)}"></span>'
    return (f'<span style="display: inline-block; width: 10px; height: 10px; box-sizing: border-box; border-radius: 5px; '
            f'border: 1.5px solid {secondary(theme, 0.7)}"></span>')


def menu_bar(state, theme):
    t = THEMES[theme]
    icon = svg('MenuBarIconPlaying', 'menubar-icon-playing.svg', t['ink']) if state == 'plays' \
        else svg('MenuBarIcon', 'menubar-icon.svg', t['ink'])
    others = ''.join(f'<span style="width: 15px; height: 12px; border-radius: 3px; border: 1.5px solid {t["ink"]}; opacity: 0.35"></span>' for _ in range(2))
    return (f'<div style="display: flex; align-items: center; justify-content: flex-end; gap: 14px; height: 26px; padding: 0 12px; '
            f'border-radius: 8px; background: {t["bar"]}; border: 0.5px solid {t["border"]}">'
            f'{others}<span style="display: flex">{icon}</span>'
            f'<span style="font-size: 12px; color: {t["ink"]}">Sun 20:35</span></div>')


def header(state, theme):
    t = THEMES[theme]
    return (f'<div style="display: flex; align-items: center; height: 34px; padding: 0 14px; border-radius: 12px; '
            f'background: {t["menu"]}; border: 0.5px solid {t["border"]}; color: {t["text"]}">'
            f'<b style="flex: 1">Sendspin</b><span style="padding-right: 6px; display: flex">{dot(state, theme)}</span></div>')


STATES = [
    ('plays', 'Plays', 'The mark’s waves show; the dot is blue, with a soft halo.',
     'The Mac’s sound reaches a Sendspin speaker, or Music Assistant streams it; or a source plays on the speakers.'),
    ('inUse', 'In use, nothing goes out', 'The S alone; the dot is grey, as a grey check.',
     'The Mac’s output is Sendspin, but it’s silent, or every speaker in the group is unavailable.'),
    ('notInUse', 'Not in use', 'The S alone; the dot is an empty ring.',
     'The Mac plays directly: its own speakers alone (they don’t count), headphones, or an AirPlay output.'),
]
GREY = '#6e6e73'


def column(label, html):
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{label}</span>{html}</div>')


rows = []
for state, title, look, when in STATES:
    # Light first, then dark: each theme's menu bar next to its menu.
    cells = ''.join(column(f'{theme.capitalize()} · menu bar', menu_bar(state, theme))
                    + column(f'{theme.capitalize()} · top of the menu', header(state, theme)) for theme in THEMES)
    rows.append(f'<div style="display: grid; grid-template-columns: 260px repeat(2, 230px) repeat(2, 230px); gap: 24px; align-items: end">'
                f'<div style="display: flex; flex-direction: column; gap: 4px"><b style="font-size: 14px">{title}</b>'
                f'<span style="font-size: 12px; line-height: 16px">{look}</span>'
                f'<span style="font-size: 12px; line-height: 16px; color: {GREY}">{when}</span></div>{cells}</div>')
note = (f'<div style="max-width: 900px; font-size: 12px; line-height: 17px; color: #3c3c43">The waves show only for Plays; '
        f'the dot tells In use from Not in use. Both follow one rule (<code>SpeakerMenu.sendspinPlays</code> and <code>.dot</code>). '
        f'The icon is a template image, in the menu bar’s own colour; the dot uses the accent colour and the grey of a grey check.</div>')
W, H = 260 + 4 * 230 + 4 * 24 + 40, 450
html = board('The menu bar icon and the dot', rows + [note], H, W)
idx = json.load(open(f"{R}/project/canvas.json"))
name = 'StatusStates.dc.html'
open(f"{R}/project/{name}", "w").write(html)
idx["boards"][name] = {"x": 0, "y": 23960, "w": W, "h": H, "title": "The menu bar icon and the dot, as built, light and dark"}
if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["status"] = {"kind": "title1", "maxW": W, "text": "The menu bar icon and the dot: every state, as built", "w": 240, "x": 0, "y": 23700}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
