import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_pairing.py")).read().split("mac = row(MAC")[0])
mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
untick = f'<button type="button" aria-label="Remove Pair Speaker, cancelling pairing" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer"><span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: rgba(60, 60, 67, 0.4)"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span></button>'
GREEN = "#2fbf5f"; ORANGE = "#ff9f0a"

def qr(size):
    # A drawn stand-in for the leaflet's QR code: three finder squares and some modules.
    cells = [(3,0),(5,1),(4,3),(6,4),(3,5),(5,6),(4,7),(0,4),(1,6),(2,3),(7,3),(8,5),(9,4),(10,6),(8,8),(9,9),(10,10),(4,9),(6,10),(5,8),(3,10),(7,7)]
    m = size / 11
    rects = ''.join(f'<rect x="{x*m:.1f}" y="{y*m:.1f}" width="{m:.1f}" height="{m:.1f}"></rect>' for x, y in cells)
    def finder(x, y):
        return (f'<rect x="{x*m:.1f}" y="{y*m:.1f}" width="{3*m:.1f}" height="{3*m:.1f}" fill="none" stroke="#111" stroke-width="{m*0.9:.1f}"></rect>'
                f'<rect x="{(x+1)*m:.1f}" y="{(y+1)*m:.1f}" width="{m:.1f}" height="{m:.1f}"></rect>')
    return f'<svg width="{size}" height="{size}" viewBox="0 0 {size} {size}" aria-hidden="true" fill="#111">{finder(0,0)}{finder(8,0)}{finder(0,8)}{rects}</svg>'

def brackets(color):
    c = f'position: absolute; width: 22px; height: 22px; border-color: {color}; border-style: solid'
    return (f'<span style="{c}; left: 0; top: 0; border-width: 3px 0 0 3px; border-radius: 6px 0 0 0"></span>'
            f'<span style="{c}; right: 0; top: 0; border-width: 3px 3px 0 0; border-radius: 0 6px 0 0"></span>'
            f'<span style="{c}; left: 0; bottom: 0; border-width: 0 0 3px 3px; border-radius: 0 0 0 6px"></span>'
            f'<span style="{c}; right: 0; bottom: 0; border-width: 0 3px 3px 0; border-radius: 0 0 6px 0"></span>')

def overlay(state):
    if state == 'look':
        icon, text = '', 'Hold the QR code on Pair Speaker or its leaflet up to the camera'
    elif state == 'read':
        icon = '<svg width="14" height="14" viewBox="0 0 22 22" aria-hidden="true"><g stroke="#ffffff" stroke-width="2.4" stroke-linecap="round"><path d="M11 3v4" opacity="0.95"></path><path d="M16.6 5.4l-2.8 2.8" opacity="0.75"></path><path d="M19 11h-4" opacity="0.55"></path><path d="M16.6 16.6l-2.8-2.8" opacity="0.4"></path><path d="M11 19v-4" opacity="0.3"></path><path d="M5.4 16.6l2.8-2.8" opacity="0.22"></path><path d="M3 11h4" opacity="0.16"></path><path d="M5.4 5.4l2.8 2.8" opacity="0.1"></path></g></svg>'
        text = 'Token read. Pairing with Pair Speaker…'
    elif state == 'ok':
        icon = f'<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="8" fill="{GREEN}"></circle><polyline points="4.5,8.3 7,10.7 11.5,5.5" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"></polyline></svg>'
        text = 'Paired with Pair Speaker'
    else:
        icon = f'<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="8" fill="{ORANGE}"></circle><path d="M8 4.2v4.6" stroke="#1d1d1f" stroke-width="1.8" stroke-linecap="round"></path><circle cx="8" cy="11.4" r="1" fill="#1d1d1f"></circle></svg>'
        text = "That token didn't match. Hold up Pair Speaker's own QR code."
    return (f'<div style="position: absolute; left: 10px; right: 10px; bottom: 10px; display: flex; align-items: center; gap: 7px; '
            f'padding: 7px 10px; border-radius: 9px; background: rgba(20, 20, 22, 0.72); color: #ffffff; font-size: 12px; line-height: 16px">'
            f'{icon}<span>{text}</span></div>')

def preview(w, h, state):
    frame = {'look': 'rgba(255, 255, 255, 0.9)', 'read': BLUE, 'ok': GREEN, 'bad': ORANGE}[state]
    q = int(h * 0.42)
    leaflet = (f'<div style="position: absolute; left: {w//2 - q//2 - 14}px; top: {int(h*0.12)}px; padding: 14px; background: #f4f1ea; border-radius: 4px; '
               f'transform: rotate(-4deg); box-shadow: 0 2px 6px rgba(0, 0, 0, 0.4)">{qr(q)}</div>')
    box = q + 44
    guide = f'<div style="position: absolute; left: {w//2 - box//2}px; top: {int(h*0.12) - 8}px; width: {box}px; height: {box}px">{brackets(frame)}</div>'
    return (f'<div role="img" aria-label="Camera preview" style="position: relative; flex: none; width: {w}px; height: {h}px; border-radius: 10px; overflow: hidden; '
            f'background: #3a3a3e">{leaflet}{guide}{overlay(state)}</div>')

LABELS = {'look': 'Looking', 'read': 'Token read', 'ok': 'Paired', 'bad': "Didn't match"}
STATES = ['look', 'read', 'ok', 'bad']
INPUT = 'flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 24px; padding: 0 7px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.25); background: #ffffff; font-family: ui-monospace, Menlo, monospace; font-size: 11px'

def grid(cells, w, h, title):
    body = '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px">' + ''.join(cells) + '</div>'
    return board(title, [body], h, w)

# A · bigger, in the menu
cells = []
for i, st in enumerate(STATES):
    check = CHECK if st == 'ok' else untick
    field = '' if st == 'ok' else f'<div style="display: flex"><label style="position: absolute; width: 1px; height: 1px; overflow: hidden" for="a{i}">Pairing token</label><input id="a{i}" type="text" placeholder="or paste the token: SP:0…" style="{INPUT}"></div>'
    cap = caption(f'{preview(296, 190, st)}{field}')
    cells.append(panel(mac + row(SPEAKER, 'Pair Speaker', check) + cap, LABELS[st]))
A = grid(cells, 840, 790, 'Camera in the menu')

# B · its own window
def window(st, i):
    field = '' if st == 'ok' else f'<div style="display: flex; flex-direction: column; gap: 4px"><label for="b{i}" style="font-size: 11px; color: #6e6e73">No camera at hand? Paste the token instead:</label><input id="b{i}" type="text" placeholder="SP:0…" style="{INPUT}"></div>'
    lights = ''.join(f'<span style="width: 12px; height: 12px; border-radius: 6px; background: {c}"></span>' for c in ['#ff5f57', '#febc2e', '#28c840'])
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: #6e6e73">{LABELS[st]}</span>'
            f'<div style="display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.2); border-radius: 12px; overflow: hidden; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18)">'
            f'<div style="position: relative; height: 28px; display: flex; align-items: center; padding: 0 10px; gap: 8px">{lights}'
            f'<span style="position: absolute; left: 0; right: 0; text-align: center; font-size: 13px; font-weight: 600">Pair Speaker</span></div>'
            f'<div style="display: flex; flex-direction: column; gap: 10px; padding: 0 14px 14px">{preview(392, 250, st)}{field}</div></div></div>')
B = grid([window(st, i) for i, st in enumerate(STATES)], 900, 820, 'Camera in its own window')

idx = json.load(open(f"{R}/project/canvas.json"))
for name, title, html, w, h, x in [('PairCameraMenu.dc.html', 'C1 · A bigger camera, in the menu', A, 840, 790, 0),
                                    ('PairCameraWindow.dc.html', 'C2 · The camera in its own window', B, 900, 820, 920)]:
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": x, "y": 5720, "w": w, "h": h, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["camera"] = {"kind": "title1", "maxW": 1820, "text": "Pairing with the camera", "w": 240, "x": 0, "y": 5460}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
