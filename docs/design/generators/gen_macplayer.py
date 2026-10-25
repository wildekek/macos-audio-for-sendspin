import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
blue_src = open(os.path.join(HERE, "gen_sources_blue.py")).read()
exec(blue_src.split("def menu(state):")[0])

def named(name, status):
    return (f'<span style="display: flex; flex-direction: column; line-height: 15px"><span>{name}</span>'
            f'<span style="font-size: 11px; color: {GREY}">{status}</span></span>')

def menu(mac, source='This Mac', destination='speakers'):
    """mac: 'in' (in the group), 'ma' (Music Assistant took it), 'mixed' (played directly, Music
    Assistant too); destination 'speakers' or 'ma' (the Mac's sound goes to Music Assistant)."""
    to_ma = destination == 'ma'
    check = lambda on: '' if to_ma else (CHECK if on else UNCHECK)
    if mac == 'ma':
        macrow = line(MAC, named('MacBook Pro Speakers', 'Music Assistant'), check(False))
    elif mac == 'mixed':
        macrow = line(MAC, named('MacBook Pro Speakers', 'Music Assistant too'), CHECK, slider=True)
    else:
        macrow = line(MAC, 'MacBook Pro Speakers', check(True), slider=not to_ma)
    direct = mac == 'mixed'
    spk = (macrow + line(SPEAKER, 'Kitchen', check(not direct), slider=not direct and not to_ma)
           + line(SPEAKER, 'Living Room', check(False)))
    server = line(SERVER, 'Music Assistant', blue=to_ma)
    if to_ma:
        return spk + divider() + server
    sources = label('Source') + line(MAC, 'This Mac', blue=source == 'This Mac')
    for name in ['Turntable', 'TV']:
        sources += line(INPUT, name, blue=source == name)
    return spk + divider() + server + divider() + sources

STATES = {
    'As today: the Mac’s sound on the Mac and Kitchen': menu('in'),
    'Music Assistant plays on this Mac: it took the Mac’s speakers': menu('ma'),
    'The same, with Turntable as the source: it plays on Kitchen': menu('ma', source='Turntable'),
    'Checking the Mac’s speakers takes them back from Music Assistant': menu('in', source='Turntable'),
}
STATES2 = {
    'The Mac’s sound goes to Music Assistant, and it plays on this Mac too': menu('ma', destination='ma'),
    'The Mac plays directly, and Music Assistant plays here too: mixed': menu('mixed'),
}

# Settings: the switch, and what it says.
track = 'position: relative; flex: none; width: 38px; height: 22px; border-radius: 11px; background: #0a7aff'
knob = 'position: absolute; top: 2px; left: 18px; width: 18px; height: 18px; border-radius: 9px; background: #ffffff; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3)'
settings = (f'<div style="width: 420px; box-sizing: border-box; padding: 14px 18px; border-radius: 12px; background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.14); display: flex; flex-direction: column; gap: 8px">'
            f'<div style="display: flex; align-items: center; gap: 10px"><span style="flex: 1">Other servers can play on this Mac</span>'
            f'<span role="switch" aria-checked="true" style="{track}"><span style="{knob}"></span></span></div>'
            f'<span style="font-size: 11px; line-height: 15px; color: {GREY}">Music Assistant, or another Mac with this app, can list this Mac as a speaker. While one plays here, the Mac’s speakers leave your group.</span></div>')
mamock = (f'<div style="width: 420px; box-sizing: border-box; padding: 14px 18px; border-radius: 12px; background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.14); display: flex; flex-direction: column; gap: 8px; font-size: 13px">'
          f'<b>Music Assistant’s players</b>'
          f'<div style="display: flex; align-items: center; gap: 10px"><span style="{ICON}">{MAC}</span><span style="flex: 1">MacBook Pro</span><span style="font-size: 11px; color: {GREY}">Player · audio input</span></div>'
          f'<div style="display: flex; align-items: center; gap: 10px"><span style="{ICON}">{SPEAKER}</span><span style="flex: 1">Kitchen</span><span style="font-size: 11px; color: {GREY}">Player</span></div>'
          f'<span style="font-size: 11px; line-height: 15px; color: {GREY}">One Sendspin device with both roles, as a speaker with a line-in: Music Assistant plays on it, and can take its sound.</span></div>')
extras = (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">Settings</span>{settings}</div>'
          f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">How Music Assistant sees the Mac (a sketch, its own UI)</span>{mamock}</div>')

W = 4 * 348 + 3 * 24 + 40
row1 = grid(STATES)
row2 = grid(STATES2).replace('repeat(4, 348px)', 'repeat(2, 348px) repeat(2, auto)').replace('</div></div></div></div>', '</div></div></div></div>', 1)
# The second row: two menus, then Settings and how Music Assistant lists the Mac.
row2 = row2[:row2.rfind('</div>')] + extras + '</div>'
html = board('The Mac as a player', [row1, row2], 1080, W)
idx = json.load(open(f"{R}/project/canvas.json"))
name = 'MacPlayerSources.dc.html'
open(f"{R}/project/{name}", "w").write(html)
idx["boards"][name] = {"x": 0, "y": 18360, "w": W, "h": 1080,
                       "title": "A · Another server takes the Mac’s speakers (here Music Assistant), with Source (P5)"}
if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["macplayer"] = {"kind": "title1", "maxW": W, "text": "The Mac as a speaker for another server (Music Assistant, another Mac), with Source", "w": 240, "x": 0, "y": 18100}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
