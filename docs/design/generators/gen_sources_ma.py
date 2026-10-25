import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
blue_src = open(os.path.join(HERE, "gen_sources_blue.py")).read()
exec(blue_src.split("def menu(state):")[0])

DIM = 'opacity: 0.45'
LINK_ARROW = '<svg width="9" height="9" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 2h5v5M8 2 2.5 7.5"></path></svg>'

def speakers_ma():
    # Music Assistant chosen: what plays isn't groupable, so no checks (as today).
    return (line(MAC, 'MacBook Pro Speakers') + line(SPEAKER, 'Kitchen') + line(SPEAKER, 'Living Room')
            + divider() + line(SERVER, 'Music Assistant', blue=True))

def speakers_on():
    return (line(MAC, 'MacBook Pro Speakers', CHECK, slider=True) + line(SPEAKER, 'Kitchen', CHECK, slider=True)
            + line(SPEAKER, 'Living Room', UNCHECK) + divider() + line(SERVER, 'Music Assistant'))

def dim(html):
    return f'<div aria-disabled="true" style="{DIM}">{html}</div>'

def src_rows(blue_mac=True, right=''):
    return (line(MAC, 'This Mac', blue=blue_mac) + line(INPUT, 'Turntable', right) + line(INPUT, 'TV', right))

def hint(text):
    return f'<span style="font-size: 11px; font-weight: 400; color: {GREY}">{text}</span>'

def header(text, extra=''):
    return (f'<div style="display: flex; align-items: baseline; gap: 6px; padding: 8px 0 2px; font-size: 11px; font-weight: 600; color: {GREY}">'
            f'{text}{extra}</div>')

OPTIONS = [
    ('M1 · Greyed out, as a disabled menu item',
     {'Music Assistant chosen': speakers_ma() + divider() + dim(label('Source') + src_rows(blue_mac=False)),
      'Hovering a source: a tooltip says why': speakers_ma() + divider() + dim(label('Source') + src_rows(blue_mac=False))
         + f'<div style="margin: -40px 0 0 120px; align-self: flex-start; padding: 4px 8px; border-radius: 5px; background: #ffffff; box-shadow: 0 2px 8px rgba(0,0,0,0.2); font-size: 11px">Music Assistant picks what plays</div>'}),
    ('M2 · Greyed out, the heading says why; This Mac stays filled, as it’s what goes to Music Assistant (chosen)',
     {'Music Assistant chosen': speakers_ma() + divider() + header('Source', hint('· Music Assistant picks what plays'))
         + dim(src_rows(blue_mac=True))}),
    ('M3 · Live: choosing a source plays it on the speakers',
     {'Music Assistant chosen: sources as usual, none blue': speakers_ma() + divider() + label('Source') + src_rows(blue_mac=False),
      'After clicking Turntable: back to the speakers': speakers_on() + divider() + label('Source')
         + line(MAC, 'This Mac') + line(INPUT, 'Turntable', blue=True) + line(INPUT, 'TV')}),
    ('M4 · Live: a source plays through Music Assistant',
     {'Music Assistant chosen': speakers_ma() + divider() + label('Source') + src_rows(blue_mac=True),
      'Turntable chosen: Music Assistant gets it instead of the Mac’s sound': speakers_ma() + divider() + label('Source')
         + line(MAC, 'This Mac') + line(INPUT, 'Turntable', blue=True) + line(INPUT, 'TV')}),
    ('M5 · Listed, each opens it in Music Assistant',
     {'Music Assistant chosen': speakers_ma() + divider() + header('Source', hint('· in Music Assistant'))
         + line(INPUT, f'Turntable', f'<span style="display: flex; color: {BLUE}">{LINK_ARROW}</span>')
         + line(INPUT, 'TV', f'<span style="display: flex; color: {BLUE}">{LINK_ARROW}</span>')}),
]

W = 2 * 348 + 24 + 40
idx = json.load(open(f"{R}/project/canvas.json"))
y = 19840
for i, (title, states) in enumerate(OPTIONS):
    html = board(title, [grid(states).replace('repeat(4, 348px)', 'repeat(2, 348px)')], 520, W)
    name = f'SourcesMA{i + 1}.dc.html'
    open(f"{R}/project/{name}", "w").write(html)
    x = (i % 3) * (W + 80)
    yy = y + (i // 3) * 640
    idx["boards"][name] = {"x": x, "y": yy, "w": W, "h": 520, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["sourcesma"] = {"kind": "title1", "maxW": 3 * W + 160,
                             "text": "Source while Music Assistant is chosen: there, but not an option now", "w": 240, "x": 0, "y": 19580}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
