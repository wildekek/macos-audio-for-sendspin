import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_camera.py")).read().split("LABELS = {")[0])
INPUT = 'flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 26px; padding: 0 8px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.25); background: #ffffff; font-family: ui-monospace, Menlo, monospace; font-size: 12px'
PRIMARY = f'height: 26px; padding: 0 12px; border-radius: 6px; border: 0; background: {BLUE}; color: #ffffff; font: inherit; font-size: 13px; font-weight: 500; display: flex; align-items: center; gap: 6px'
CAM = '<svg width="14" height="12" viewBox="0 0 16 13" fill="none" stroke="#ffffff" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><path d="M1.5 4a1.5 1.5 0 0 1 1.5-1.5h1.8L6 1h4l1.2 1.5H13A1.5 1.5 0 0 1 14.5 4v6.5A1.5 1.5 0 0 1 13 12H3a1.5 1.5 0 0 1-1.5-1.5z"></path><circle cx="8" cy="7" r="2.6"></circle></svg>'
SPIN_SMALL = '<svg width="16" height="16" viewBox="0 0 22 22" aria-hidden="true"><g stroke="#3c3c43" stroke-width="2.2" stroke-linecap="round"><path d="M11 3v4" opacity="0.95"></path><path d="M16.6 5.4l-2.8 2.8" opacity="0.75"></path><path d="M19 11h-4" opacity="0.55"></path><path d="M16.6 16.6l-2.8-2.8" opacity="0.4"></path><path d="M11 19v-4" opacity="0.3"></path><path d="M5.4 16.6l2.8-2.8" opacity="0.22"></path><path d="M3 11h4" opacity="0.16"></path><path d="M5.4 5.4l2.8 2.8" opacity="0.1"></path></g></svg>'

def big_slots(digits, length):
    out = []
    for i in range(length):
        if i == length // 2:
            out.append('<span style="color: #6e6e73; font-size: 18px">–</span>')
        d = digits[i] if i < len(digits) else ''
        border = f'2px solid {BLUE}' if i == len(digits) else '2px solid transparent'
        out.append(f'<span style="display: flex; align-items: center; justify-content: center; width: 30px; height: 40px; box-sizing: border-box; border-radius: 7px; background: rgba(60, 60, 67, 0.1); border: {border}; font-family: ui-monospace, Menlo, monospace; font-size: 20px; font-weight: 600">{d}</span>')
    return '<div role="group" aria-label="Pairing code" style="display: flex; align-items: center; gap: 6px">' + ''.join(out) + '</div>'

link = lambda t: f'<a href="#" style="font-size: 13px">{t}</a>'
cam = lambda st: preview(392, 250, st).replace('Pair Speaker', 'Kitchen')

STATES = [
    ('Dynamic code', f'<p style="margin: 0">Enter the code that Kitchen shows now:</p>{big_slots("369", 6)}'),
    ('Wrong code', f'<p style="margin: 0">That code didn’t match. Enter the code that Kitchen shows now:</p>{big_slots("", 6)}'),
    ('Static code', f'<p style="margin: 0">Enter the 8-digit code on Kitchen or its leaflet:</p>{big_slots("", 8)}'),
    ('Waiting', '<p style="margin: 0">“Press the pairing button on the back.”</p><p style="margin: 0; color: #6e6e73">— Kitchen</p>'
                f'<div style="display: flex; align-items: center; gap: 8px; color: #6e6e73">{SPIN_SMALL}<span>Waiting for Kitchen…</span></div>'),
    ('Token, before scanning', '<p style="margin: 0">The pairing token is the QR code on Kitchen or its leaflet.</p>'
                f'<div style="display: flex; align-items: center; gap: 14px"><button type="button" style="{PRIMARY}">{CAM}Scan the QR Code</button>{link("Or paste a token")}</div>'),
    ('Token, scanning', cam('look') + link('Or paste a token')),
    ('Token, didn’t match', cam('bad') + link('Or paste a token')),
    ('Paired', f'<div style="display: flex; align-items: center; gap: 10px; font-size: 15px; font-weight: 600"><svg width="22" height="22" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="8" fill="{GREEN}"></circle><polyline points="4.5,8.3 7,10.7 11.5,5.5" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"></polyline></svg>Paired with Kitchen</div><p style="margin: 0; color: #6e6e73">Kitchen plays now. This window closes by itself.</p>'),
]

LIGHTS = ''.join(f'<span style="width: 12px; height: 12px; border-radius: 6px; background: {c}"></span>' for c in ['#ff5f57', '#febc2e', '#28c840'])

def titled(content):
    return (f'<div style="display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.2); border-radius: 12px; overflow: hidden; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18)">'
            f'<div style="position: relative; height: 28px; display: flex; align-items: center; padding: 0 10px; gap: 8px">{LIGHTS}'
            f'<span style="position: absolute; left: 0; right: 0; text-align: center; font-size: 13px; font-weight: 600; pointer-events: none">Pair Kitchen</span></div>'
            f'<div style="display: flex; flex-direction: column; gap: 12px; padding: 8px 16px 18px; min-height: 250px; font-size: 13px; line-height: 18px">{content}</div></div>')

def glass(content, cancel=True):
    c = '<div style="display: flex; justify-content: flex-end"><button type="button" style="border: 0; background: none; padding: 0; font: inherit; font-size: 13px; color: #0a7aff">Cancel</button></div>' if cancel else ''
    return (f'<div style="display: flex; flex-direction: column; align-items: stretch; gap: 12px; padding: 18px 18px 14px; min-height: 280px; box-sizing: border-box; border-radius: 18px; '
            f'background: rgba(246, 246, 248, 0.86); border: 0.5px solid rgba(0, 0, 0, 0.14); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2); font-size: 13px; line-height: 18px">'
            f'<div style="display: flex; justify-content: center"><span style="{ICON}; width: 34px; height: 34px; border-radius: 17px">{SPEAKER}</span></div>'
            f'<div style="display: flex; flex-direction: column; gap: 12px; flex: 1 1 auto">{content}</div>{c}</div>')

def grid(make):
    cells = []
    for label, content in STATES:
        win = make(content) if make is titled else make(content, cancel=label != 'Paired')
        cells.append(f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: #6e6e73">{label}</span>{win}</div>')
    return '<div style="display: grid; grid-template-columns: repeat(4, 424px); gap: 24px; align-items: start">' + ''.join(cells) + '</div>'

W, H = 1808, 900
boards = {
    'PairWindowTitled.dc.html': ('W1 · A standard window: closing it cancels', board('Pairing window, standard', [grid(titled)], H, W)),
    'PairWindowGlass.dc.html': ('W2 · A glass panel, like the code window', board('Pairing window, glass', [grid(glass)], H, W)),
}
# The menu meanwhile
untick = f'<span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: rgba(60, 60, 67, 0.4)"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span>'
mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
menu = panel(mac + row(SPEAKER, 'Kitchen', f'<button type="button" aria-label="Remove Kitchen, cancelling pairing" style="border: 0; padding: 0; background: none; display: flex">{untick}</button>')
             + caption('<a href="#" style="text-decoration: none">Pairing in a window…</a>'), 'While the window is open')
boards['PairWindowMenu.dc.html'] = ('The menu meanwhile', board('The menu while pairing', [menu], 220))

idx = json.load(open(f"{R}/project/canvas.json"))
pos = {'PairWindowTitled.dc.html': (0, 8260, W, H), 'PairWindowGlass.dc.html': (0, 9280, W, H), 'PairWindowMenu.dc.html': (1888, 8260, 388, 220)}
for name, (title, html) in boards.items():
    open(f"{R}/project/{name}", "w").write(html)
    x, y, w, h = pos[name]
    idx["boards"][name] = {"x": x, "y": y, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["window"] = {"kind": "title1", "maxW": 2276, "text": "The pairing window", "w": 240, "x": 0, "y": 8000}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
