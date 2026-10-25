import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
code = open(os.path.join(HERE, "gen_inputs.py")).read()
exec(code.split("# I1 ·")[0])
exec(code[code.index("def grid(states):"):code.index("# Allowing:")])
src3 = open(os.path.join(HERE, "gen_sources3.py")).read()
exec(src3[src3.index("SMALL = "):src3.index("needs = ")])

SERVER = '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" aria-hidden="true"><rect x="2.5" y="2" width="11" height="5" rx="1.2"></rect><rect x="2.5" y="9" width="11" height="5" rx="1.2"></rect><circle cx="5.2" cy="4.5" r="0.7" fill="currentColor"></circle><circle cx="5.2" cy="11.5" r="0.7" fill="currentColor"></circle></svg>'
BLUE_ICON = f'display: flex; align-items: center; justify-content: center; flex: none; width: 26px; height: 26px; border-radius: 13px; background: {BLUE}; color: #ffffff'
needs = '<span style="flex: none; font-size: 11px; color: #6e6e73">Needs pairing</span>'

def line(icon, name, right='', blue=False, slider=False):
    r = row(icon, name, right, slider=slider)
    return r.replace(ICON, BLUE_ICON, 1) if blue else r

def menu(state):
    ma = state == 'ma'
    # The speakers: checks while what plays can be grouped; none while Music Assistant plays.
    spk = (line(MAC, 'MacBook Pro Speakers', '' if ma else CHECK, slider=not ma)
           + line(SPEAKER, 'Kitchen', '' if ma else CHECK, slider=not ma)
           + line(SPEAKER, 'Living Room', '' if ma else UNCHECK))
    server = line(SERVER, 'Music Assistant', blue=ma)
    if ma:
        return spk + divider() + server
    plays = {'mac': 'This Mac', 'tt': 'Turntable', 'ask': 'This Mac'}[state]
    sources = label('Source') + line(MAC, 'This Mac', blue=plays == 'This Mac')
    for name in ['Turntable', 'TV']:
        sources += line(INPUT, name, blue=plays == name)
        if state == 'ask' and name == 'TV':
            sources += ask('TV')
    sources += line(INPUT, 'Desk Microphone', needs)
    return spk + divider() + server + divider() + sources

STATES = {
    'mac': 'The Mac’s sound plays on the speakers',
    'tt': 'Turntable plays on them: click its name',
    'ask': 'Clicking TV the first time asks',
    'ma': 'Music Assistant chosen: it picks what plays, so no Source',
}
W = 4 * 348 + 3 * 24 + 40
html = board('Source by the menu’s rule', [grid({STATES[k]: menu(k) for k in STATES})], 640, W)
idx = json.load(open(f"{R}/project/canvas.json"))
name = 'SourcesBlue.dc.html'
open(f"{R}/project/{name}", "w").write(html)
idx["boards"][name] = {"x": 0, "y": 17360, "w": W, "h": 640,
                       "title": "P5 · No selectbox, so pick one: the blue icon, as for Music Assistant"}
if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["sourcesblue"] = {"kind": "title1", "maxW": W, "text": "Source, by the menu’s own rule", "w": 240, "x": 0, "y": 17100}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
