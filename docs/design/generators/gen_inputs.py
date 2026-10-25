import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_pairing.py")).read().split("mac = row(MAC")[0])
GREY = "#6e6e73"

# An input: a box with an arrow going in.
INPUT = '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="6.5" y="2.5" width="8" height="11" rx="1.5"></rect><path d="M1.5 8h7M6.2 5.6 8.6 8l-2.4 2.4"></path></svg>'
LEVEL = f'<span aria-label="Playing" style="display: inline-flex; align-items: flex-end; gap: 2px; height: 11px; margin-left: 6px">' + ''.join(
    f'<span style="width: 2.5px; height: {h}px; border-radius: 1px; background: {BLUE}"></span>' for h in (6, 11, 8)) + '</span>'

def round_button(label, glyph, on):
    bg = BLUE if on else 'rgba(60, 60, 67, 0.16)'
    fg = '#ffffff' if on else '#1d1d1f'
    return (f'<button type="button" aria-label="{label}" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer">'
            f'<span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: {bg}; color: {fg}">{glyph}</span></button>')

PLAY = '<svg width="9" height="10" viewBox="0 0 9 10" aria-hidden="true"><path d="M1.5 1v8l6.5-4z" fill="currentColor"></path></svg>'
STOP = '<svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true"><rect width="8" height="8" rx="1.5" fill="currentColor"></rect></svg>'
play = round_button('Play Turntable on your speakers', PLAY, False)
stop = round_button('Stop Turntable', STOP, True)
allow = '<button type="button" style="flex: none; height: 22px; padding: 0 10px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 12px">Allow…</button>'
UNCHECK = '<span style="flex: none; width: 22px; height: 22px; box-sizing: border-box; border-radius: 11px; border: 1.5px solid rgba(60, 60, 67, 0.35)"></span>'

def note(text):
    return caption(f'<span style="color: {GREY}">{text}</span>')

def label(text):
    return f'<div style="padding: 8px 0 2px; font-size: 11px; font-weight: 600; color: {GREY}">{text}</div>'

def divider():
    return '<div style="height: 0.5px; margin: 6px 0; background: rgba(0, 0, 0, 0.14)"></div>'

mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
kitchen = row(SPEAKER, 'Kitchen', CHECK, slider=True)
living = row(SPEAKER, 'Living Room', UNCHECK)
speakers = mac + kitchen + living
allow_note = note('Turntable can play its sound on your speakers once you allow it. Only an input you allow can.')
playing_note = note('Kitchen and MacBook Pro Speakers play Turntable. Your Mac’s own sound doesn’t go to them meanwhile.')
signal_note = note('No sound from Turntable now. It plays as soon as there is.')

# I1 · Inputs under the speakers, each with a play button.
sources = divider() + label('Source')
SMALL = 'height: 22px; padding: 0 10px; border-radius: 6px; font: inherit; font-size: 12px'
ask = caption('<span>Let Turntable send its audio to this Mac? Your speakers then play whatever it picks up. For a microphone, pair it instead.</span>'
              f'<div style="display: flex; gap: 8px"><button type="button" style="{SMALL}; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff">Don’t Allow</button>'
              f'<button type="button" style="{SMALL}; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff">Pair Instead</button>'
              f'<button type="button" style="{SMALL}; border: 0; background: {BLUE}; color: #ffffff">Allow</button></div>')
asking = round_button('Cancel', PLAY, False).replace('rgba(60, 60, 67, 0.16)', 'rgba(10, 122, 255, 0.35)')
i1 = {
    'Found, or allowed: a play button either way': speakers + sources + row(INPUT, 'Turntable', play),
    'The first play asks, once': speakers + sources + row(INPUT, 'Turntable', asking) + ask,
    'Playing': speakers + sources + row(INPUT, f'Turntable{LEVEL}', stop),
    'Playing, but no sound': speakers + sources + row(INPUT, 'Turntable', stop),
}
# I2 · A "Play" list on top: this Mac or an input, one at a time; the speakers below.
def source_list(selected, turntable_right=None, extra=''):
    macrow = row(MAC, 'This Mac', CHECK if selected == 'mac' else UNCHECK)
    tt = row(INPUT, f'Turntable{LEVEL}' if selected == 'tt' else 'Turntable',
             turntable_right or (CHECK if selected == 'tt' else UNCHECK))
    return label('Play') + macrow + tt + extra + label('On') + speakers
i2 = {
    'Found: allow it first': source_list('mac', allow, allow_note),
    'Allowed': source_list('mac'),
    'Playing': source_list('tt', extra=note('Your Mac’s own sound doesn’t go to the speakers meanwhile.')),
    'Playing, but no sound': source_list('tt', extra=signal_note).replace(LEVEL, ''),
}
# I3 · One line on top saying what plays, a menu to switch; inputs listed in that menu.
def picker(name, glyph, open_=False):
    chevron = '<svg width="9" height="9" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 3.5 5 6.5l3-3"></path></svg>'
    head = (f'<div style="display: flex; align-items: center; gap: 8px; height: 30px"><span style="color: {GREY}">Playing</span>'
            f'<button type="button" style="display: flex; align-items: center; gap: 6px; height: 24px; padding: 0 8px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.18); background: #ffffff; font: inherit; font-size: 13px">'
            f'<span style="display: flex; color: #1d1d1f">{glyph}</span>{name}{chevron}</button></div>')
    if open_:
        item = lambda g, t, on, right='': (f'<div style="display: flex; align-items: center; gap: 8px; height: 26px; padding: 0 8px; border-radius: 5px; {"background: " + BLUE + "; color: #ffffff" if on else ""}">'
                                           f'<span style="width: 12px">{"✓" if on else ""}</span><span style="display: flex">{g}</span><span style="flex: 1">{t}</span>{right}</div>')
        menu = (f'<div style="margin: 0 0 8px 62px; width: 230px; padding: 5px; border-radius: 8px; background: #ffffff; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.2); border: 0.5px solid rgba(0, 0, 0, 0.12); font-size: 13px">'
                f'{item(MAC, "This Mac’s sound", True)}{item(INPUT, "Turntable", False)}</div>')
        head += menu
    return head
i3 = {
    'Found: allow it first': picker('This Mac’s sound', MAC) + speakers + divider() + row(INPUT, 'Turntable', allow) + allow_note,
    'Choosing what plays': picker('This Mac’s sound', MAC, True) + speakers,
    'Playing': picker(f'Turntable{LEVEL}', INPUT) + note('Your Mac’s own sound doesn’t go to the speakers meanwhile.') + speakers,
    'Playing, but no sound': picker('Turntable', INPUT) + signal_note + speakers,
}

def grid(states):
    cells = ''.join(f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{name}</span>'
                    f'<div style="box-sizing: border-box; padding: 6px 14px; display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.16); border-radius: 14px">{html}</div></div>'
                    for name, html in states.items())
    return f'<div style="display: grid; grid-template-columns: repeat(4, 348px); gap: 24px; align-items: start">{cells}</div>'

# Allowing: the explicit question, and where it's undone.
dialog = (f'<div style="width: 300px; box-sizing: border-box; padding: 18px; border-radius: 12px; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.18); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2); display: flex; flex-direction: column; gap: 10px; align-items: center; text-align: center">'
          f'<span style="{ICON}; width: 40px; height: 40px; border-radius: 20px">{INPUT}</span>'
          f'<b style="font-size: 13px">Allow Turntable to play on your speakers?</b>'
          f'<span style="font-size: 11px; line-height: 15px">Anything Turntable picks up can then be heard on your speakers, when you play it from this menu. You can take this back in Settings.</span>'
          f'<div style="display: flex; gap: 8px; align-self: stretch"><button type="button" style="flex: 1; height: 24px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 13px">Don’t Allow</button>'
          f'<button type="button" style="flex: 1; height: 24px; border-radius: 6px; border: 0; background: {BLUE}; color: #ffffff; font: inherit; font-size: 13px">Allow</button></div></div>')
settings = (f'<div style="width: 420px; box-sizing: border-box; padding: 14px 18px; border-radius: 12px; background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.14); display: flex; flex-direction: column; gap: 8px">'
            f'<b style="font-size: 13px">Allowed sources</b>'
            f'<div style="display: flex; align-items: center; gap: 10px"><span style="{ICON}">{INPUT}</span><span style="flex: 1">Turntable</span><a href="#" style="font-size: 13px">Remove…</a></div>'
            f'<span style="font-size: 11px; color: {GREY}">A paired source needs no permission: pairing it was the permission.</span></div>')
mic = (row(INPUT, 'Desk Microphone', '<span style="font-size: 11px; color: #6e6e73">Needs pairing</span>')
       + note('Desk Microphone only plays for servers it’s paired with. Click its name to pair it, as for a speaker.'))
allowing = (f'<div style="display: flex; gap: 32px; align-items: flex-start">'
            f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">Settings, where it’s taken back</span>{settings}</div>'
            f'<div style="display: flex; flex-direction: column; gap: 6px; width: 348px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">A source that needs pairing (a microphone should)</span>'
            f'<div style="box-sizing: border-box; padding: 6px 14px; display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.16); border-radius: 14px">{mic}</div></div></div>')

W = 4 * 348 + 3 * 24 + 40
boards = {
    'InputsBelow.dc.html': ('I1 · Source under the speakers, with a play button (chosen)', board('Source under the speakers', [grid(i1)], 380, W)),
    'InputsList.dc.html': ('I2 · “Play” and “On”: one list for what plays, one for where', board('Play and On lists', [grid(i2)], 440, W)),
    'InputsPicker.dc.html': ('I3 · One line says what plays; a menu switches it', board('What plays, as a menu', [grid(i3)], 420, W)),
    'InputsAllow.dc.html': ('Taking it back, and a source that needs pairing', board('Taking an approval back', [allowing], 220, 860)),
}
idx = json.load(open(f"{R}/project/canvas.json"))
y = 12260
pos = {}
for name, (title, html) in boards.items():
    h = int(html.split('"height":')[1].split('}')[0])
    w = int(html.split('"width":')[1].split(',')[0])
    pos[name] = (0, y, w, h)
    y += h + 120
for name, (title, html) in boards.items():
    open(f"{R}/project/{name}", "w").write(html)
    x, yy, w, h = pos[name]
    idx["boards"][name] = {"x": x, "y": yy, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["inputs"] = {"kind": "title1", "maxW": W, "text": "Source: a turntable, a TV or a microphone playing on your speakers", "w": 240, "x": 0, "y": 12000}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print(pos)
