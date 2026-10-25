import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
code = open(os.path.join(HERE, "gen_inputs.py")).read()
exec(code.split("# I1 ·")[0])

# Paired, allowed (approved for unpaired playback) or new: the spec has the server tell them
# apart, so a new device can't pass for one of yours, with pairing clearly available for every
# speaker that isn't paired (pairing.md, Unpaired Access; the server guide). The menu only
# flags a speaker that isn't what you chose (ticking one is consent); Settings lists the rest
# that are on the network now, with Pair…, and no Remove: unticking is enough.
SMALL = 'height: 22px; padding: 0 10px; border-radius: 6px; font: inherit; font-size: 12px'
ORANGE = '#e8890c'
WARN = (f'<svg width="11" height="10" viewBox="0 0 11 10" aria-hidden="true"><path d="M5.5 0.6 10.6 9.4H0.4z" fill="{ORANGE}" stroke="{ORANGE}" stroke-width="0.8" stroke-linejoin="round"></path>'
        '<path d="M5.5 3.6v2.6" stroke="#ffffff" stroke-width="1.2" stroke-linecap="round"></path><circle cx="5.5" cy="7.8" r="0.65" fill="#ffffff"></circle></svg>')
GREY_CHECK = CHECK.replace(f'background: {BLUE}', 'background: rgba(60, 60, 67, 0.4)')


def status(text, warning=True):
    return (f'<span style="flex: none; display: flex; align-items: center; gap: 4px; font-size: 11px; color: {GREY}">'
            f'{WARN if warning else ""}{text}</span>')


IDENTITY = status('Identity changed')
mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
kitchen = row(SPEAKER, 'Kitchen', CHECK, slider=True)
living = row(SPEAKER, 'Living Room', CHECK, slider=True)
bedroom = row(SPEAKER, 'Bedroom', UNCHECK)


def menu(*rows):
    return mac + ''.join(rows)


# The menu: nothing new on a speaker that's fine; "Identity changed" where one isn't what you chose.
MENU1 = {
    'As today: Kitchen paired, Living Room allowed unpaired, Bedroom new':
        menu(kitchen, living, bedroom),
    'Another device under Kitchen’s name, without its pairing: Identity changed':
        menu(row(SPEAKER, 'Kitchen', IDENTITY + GREY_CHECK), living, bedroom),
    'Clicking it: you accept it, knowing it isn’t the Kitchen you paired; it plays':
        menu(row(SPEAKER, 'Kitchen', CHECK, slider=True), living, bedroom),
}
MENU2 = {
    'A new device calls itself Kitchen, next to yours':
        menu(kitchen, living, bedroom, row(SPEAKER, 'Kitchen', UNCHECK)),
    'Ticked, it plays: ticking is consent, as for any speaker':
        menu(kitchen, living, bedroom, row(SPEAKER, 'Kitchen', CHECK, slider=True)),
    'Kitchen forgotten in Settings: unticked, a new speaker again':
        menu(row(SPEAKER, 'Kitchen', UNCHECK), living, bedroom),
}


def grid3(states):
    cells = ''.join(f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{name}</span>'
                    f'<div style="box-sizing: border-box; padding: 6px 14px; display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.16); border-radius: 14px">{html}</div></div>'
                    for name, html in states.items())
    return f'<div style="display: grid; grid-template-columns: repeat(3, 348px); gap: 24px; align-items: start">{cells}</div>'


# Settings: a grouped form, as the app's (Form, .grouped).
def button(text, primary=False):
    style = f'border: 0; background: {BLUE}; color: #ffffff' if primary else 'border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; color: #1d1d1f'
    return f'<button type="button" style="{SMALL}; {style}; flex: none">{text}</button>'


def item(name, right='', sub='', below=''):
    title = (f'<span style="display: flex; flex-direction: column; line-height: 16px"><span>{name}</span>'
             f'<span style="font-size: 11px; color: {GREY}">{sub}</span></span>') if sub else f'<span>{name}</span>'
    return (f'<div style="display: flex; flex-direction: column; gap: 8px; padding: 8px 0">'
            f'<div style="display: flex; align-items: center; gap: 10px; min-height: 22px"><span style="flex: 1">{title}</span>{right}</div>{below}</div>')


def section(header, items, footer=''):
    rows = '<div style="height: 0.5px; background: rgba(0, 0, 0, 0.1)"></div>'.join(items)
    foot = f'<span style="padding: 0 10px; font-size: 11px; line-height: 15px; color: {GREY}">{footer}</span>' if footer else ''
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="padding: 0 10px; font-size: 13px; font-weight: 600">{header}</span>'
            f'<div style="padding: 0 10px; border-radius: 8px; background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.1)">{rows}</div>{foot}</div>')


def settings(*sections):
    return (f'<div style="box-sizing: border-box; width: 460px; padding: 16px 20px; display: flex; flex-direction: column; gap: 18px; '
            f'background: #f2f2f4; border-radius: 12px; border: 0.5px solid rgba(0, 0, 0, 0.16); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.15)">'
            + ''.join(sections) + '</div>')


FOOTER = 'Only a paired speaker is sure to be yours: another device with its name can’t take its place.'
FORGET, PAIR = button('Forget…'), button('Pair…')
music_assistant = item('Music Assistant', FORGET)
paired_kitchen = item('Kitchen', FORGET)
allowed_living = item('Living Room', PAIR, 'Plays unpaired')
new_bedroom = item('Bedroom', PAIR, 'New')
code = caption('<span>Enter the code that Bedroom shows:</span>' + slots('48'), button('Cancel')).replace('padding: 0 0 8px 36px', 'padding: 0')

SETTINGS = {
    'Not paired, under Paired: those on the network now, each with Pair…':
        settings(section('Paired', [music_assistant, paired_kitchen]),
                 section('Not paired', [allowed_living, new_bedroom], FOOTER)),
    'Pair… asks for the code under the speaker, as the menu does today':
        settings(section('Paired', [music_assistant, paired_kitchen]),
                 section('Not paired', [allowed_living, item('Bedroom', '', 'New', code)], FOOTER)),
    'Paired: Bedroom moves up':
        settings(section('Paired', [music_assistant, paired_kitchen, item('Bedroom', FORGET)]),
                 section('Not paired', [allowed_living], FOOTER)),
}
alert = (f'<div style="width: 260px; box-sizing: border-box; padding: 18px; border-radius: 12px; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.18); '
         f'box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2); display: flex; flex-direction: column; gap: 10px; align-items: center; text-align: center">'
         f'<b style="font-size: 13px">Forget Kitchen?</b>'
         f'<span style="font-size: 11px; line-height: 15px">Kitchen stops playing and becomes a new speaker: pair it again, or tick it in the menu to let it play unpaired.</span>'
         f'<div style="display: flex; flex-direction: column; gap: 6px; align-self: stretch">'
         f'<button type="button" style="height: 24px; border-radius: 6px; border: 0; background: {BLUE}; color: #ffffff; font: inherit; font-size: 13px">Forget</button>'
         f'<button type="button" style="height: 24px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 13px">Cancel</button></div></div>')


def column(name, html):
    return f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{name}</span>{html}</div>'


settings_row = ('<div style="display: flex; gap: 28px; align-items: flex-start">'
                + ''.join(column(n, h) for n, h in SETTINGS.items())
                + column('Forget… asks first', alert) + '</div>')

BOARDS = [
    ('TrustMenu.dc.html', 'In the menu: only “Identity changed”, where a speaker isn’t the one you chose',
     [grid3(MENU1), grid3(MENU2)], 520, 3 * 348 + 2 * 24 + 40),
    ('TrustSettings.dc.html', 'In Settings: every speaker that isn’t paired, under Paired, with Pair…',
     [settings_row], 420, 3 * 460 + 260 + 3 * 28 + 40),
]
idx = json.load(open(f"{R}/project/canvas.json"))
# T1–T3 put the difference in the menu; the menu stays as it is instead.
for old in ['TrustCaptions.dc.html', 'TrustSection.dc.html', 'TrustBadges.dc.html']:
    idx["boards"].pop(old, None)
    if old in idx["order"]: idx["order"].remove(old)
    if os.path.exists(f"{R}/project/{old}"): os.remove(f"{R}/project/{old}")
y = 21480
for name, title, rows, h, w in BOARDS:
    open(f"{R}/project/{name}", "w").write(board(title, rows, h, w))
    idx["boards"][name] = {"x": 0, "y": y, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
    y += h + 120
idx["notes"]["trust"] = {"kind": "title1", "maxW": max(b[4] for b in BOARDS),
                         "text": "Paired, allowed or new: the menu flags an impostor, Settings offers Pair…",
                         "w": 240, "x": 0, "y": 21220}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
