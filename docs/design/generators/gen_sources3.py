import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
code = open(os.path.join(HERE, "gen_inputs.py")).read()
exec(code.split("# I1 ·")[0])
exec(code[code.index("def grid(states):"):code.index("# Allowing:")])

SMALL = 'height: 22px; padding: 0 10px; border-radius: 6px; font: inherit; font-size: 12px'
def ask(name):
    return caption(f'<span>Let {name} send its audio to this Mac? Your speakers then play whatever it picks up. For a microphone, pair it instead.</span>'
                   f'<div style="display: flex; gap: 8px"><button type="button" style="{SMALL}; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff">Don’t Allow</button>'
                   f'<button type="button" style="{SMALL}; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff">Pair Instead</button>'
                   f'<button type="button" style="{SMALL}; border: 0; background: {BLUE}; color: #ffffff">Allow</button></div>')

needs = '<span style="flex: none; font-size: 11px; color: #6e6e73">Needs pairing</span>'
RADIO_ON = f'<span style="flex: none; display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: {BLUE}"><span style="width: 8px; height: 8px; border-radius: 4px; background: #ffffff"></span></span>'
RADIO_OFF = UNCHECK
RADIO_ASK = RADIO_ON.replace(f'background: {BLUE}"><span', 'background: rgba(10, 122, 255, 0.35)"><span')
SOURCES = ['Turntable', 'TV', 'Desk Microphone']

def src(name, right, playing=False):
    return row(INPUT, f'{name}{LEVEL}' if playing else name, right)

# P1 · Today's design: a play button per source.
def p1(state):
    rows = ''
    for name in SOURCES:
        if name == 'Desk Microphone':
            rows += src(name, needs)
        elif state == 'tt' and name == 'Turntable':
            rows += src(name, stop, True)
        elif state == 'ask' and name == 'TV':
            rows += src(name, round_button('Cancel', PLAY, False).replace('rgba(60, 60, 67, 0.16)', 'rgba(10, 122, 255, 0.35)')) + ask('TV')
        else:
            rows += src(name, play)
    return speakers + divider() + label('Source') + rows

# P2 · Pick one: This Mac is in the list, one is always chosen.
def p2(state):
    on = {'mac': 'This Mac', 'tt': 'Turntable', 'ask': 'This Mac'}[state]
    rows = row(MAC, 'This Mac', RADIO_ON if on == 'This Mac' and state != 'ask' else (RADIO_OFF if state == 'ask' else RADIO_OFF))
    if state == 'mac':
        rows = row(MAC, 'This Mac', RADIO_ON)
    for name in SOURCES:
        if name == 'Desk Microphone':
            rows += src(name, needs)
        elif state == 'ask' and name == 'TV':
            rows += src(name, RADIO_ASK) + ask('TV')
        else:
            rows += src(name, RADIO_ON if on == name else RADIO_OFF, on == name)
    if state == 'ask':
        rows = rows.replace(row(MAC, 'This Mac', RADIO_OFF), row(MAC, 'This Mac', RADIO_ON), 1)
    return speakers + divider() + label('Source') + rows

# P3 · Click a source to play it, click it again to go back to the Mac's sound.
def p3(state):
    rows = ''
    for name in SOURCES:
        if name == 'Desk Microphone':
            rows += src(name, needs)
        elif state == 'tt' and name == 'Turntable':
            rows += src(name, CHECK, True)
        elif state == 'ask' and name == 'TV':
            rows += src(name, CHECK.replace(f'background: {BLUE}', 'background: rgba(10, 122, 255, 0.35)')) + ask('TV')
        else:
            rows += src(name, UNCHECK)
    return speakers + divider() + label('Source') + rows

# P4 · One popup in the Source row, listing This Mac and the sources.
CHEVRON = '<svg width="9" height="9" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 3.5 5 6.5l3-3"></path></svg>'
def popup(name, glyph, playing=False):
    return (f'<div style="display: flex; align-items: center; gap: 10px; height: 38px"><span style="{ICON}">{glyph}</span>'
            f'<span style="flex: 1 1 auto; color: #1d1d1f">Source</span>'
            f'<button type="button" style="display: flex; align-items: center; gap: 6px; height: 24px; padding: 0 8px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.18); background: #ffffff; font: inherit; font-size: 13px">'
            f'{name}{LEVEL if playing else ""}{CHEVRON}</button></div>')
def opened(selected):
    def item(text, on, right=''):
        style = f'background: {BLUE}; color: #ffffff' if on else ''
        return (f'<div style="display: flex; align-items: center; gap: 8px; height: 24px; padding: 0 8px; border-radius: 5px; {style}">'
                f'<span style="width: 12px">{"✓" if text == selected else ""}</span><span style="flex: 1">{text}</span>{right}</div>')
    return (f'<div style="margin: 0 0 8px auto; width: 210px; padding: 5px; border-radius: 8px; background: #ffffff; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.2); border: 0.5px solid rgba(0, 0, 0, 0.12); font-size: 13px">'
            f'{item("This Mac", False)}{item("Turntable", False)}{item("TV", True)}'
            f'<div style="height: 0.5px; margin: 4px 8px; background: rgba(0, 0, 0, 0.12)"></div>'
            f'{item("Desk Microphone", False, "<span style=\'font-size: 11px; color: #6e6e73\'>Pair…</span>")}</div>')
def p4(state):
    if state == 'mac':
        return speakers + divider() + popup('This Mac', MAC)
    if state == 'tt':
        return speakers + divider() + popup('Turntable', INPUT, True)
    if state == 'menu':
        return speakers + divider() + popup('This Mac', MAC) + opened('This Mac')
    return speakers + divider() + popup('TV', INPUT) + ask('TV')

STATES = {'mac': 'The Mac’s sound plays', 'tt': 'Turntable plays', 'ask': 'Choosing TV the first time asks'}
P4_STATES = {'mac': 'The Mac’s sound plays', 'menu': 'Choosing a source', 'tt': 'Turntable plays', 'ask': 'Choosing TV the first time asks'}
W3 = 3 * 348 + 2 * 24 + 40
W4 = 4 * 348 + 3 * 24 + 40
boards = {
    'SourcesPlay.dc.html': ('P1 · A play button per source (as now)', board('Play buttons, three sources', [grid({STATES[k]: p1(k) for k in STATES})], 500, W3)),
    'SourcesRadio.dc.html': ('P2 · Pick one: This Mac is one of the sources', board('Pick one, with This Mac', [grid({STATES[k]: p2(k) for k in STATES})], 540, W3)),
    'SourcesToggle.dc.html': ('P3 · Click a source to play it, again to go back to the Mac', board('Click to play, click again to stop', [grid({STATES[k]: p3(k) for k in STATES})], 500, W3)),
    'SourcesPopup.dc.html': ('P4 · One Source row with a popup', board('One Source popup', [grid({P4_STATES[k]: p4(k) for k in P4_STATES})], 420, W4)),
}
# The grid helper lays out four columns; three-state boards need three.
for name in list(boards)[:3]:
    title, html = boards[name]
    boards[name] = (title, html.replace('repeat(4, 348px)', 'repeat(3, 348px)'))

idx = json.load(open(f"{R}/project/canvas.json"))
y = 14560
for name, (title, html) in boards.items():
    h = int(html.split('"height":')[1].split('}')[0])
    w = int(html.split('"width":')[1].split(',')[0])
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": 0, "y": y, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
    y += h + 120
idx["notes"]["sources3"] = {"kind": "title1", "maxW": W4, "text": "Three sources: without play buttons", "w": 240, "x": 0, "y": 14300}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print({k: idx["boards"][k]["y"] for k in boards})
