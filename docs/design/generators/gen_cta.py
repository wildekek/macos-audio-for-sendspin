import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
src = open(os.path.join(HERE, "gen_camera.py")).read()
exec(src.split("LABELS = {")[0])
INPUT = 'flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 24px; padding: 0 7px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.25); background: #ffffff; font-family: ui-monospace, Menlo, monospace; font-size: 11px'
PRIMARY = f'align-self: flex-start; height: 24px; padding: 0 12px; border-radius: 6px; border: 0; background: {BLUE}; color: #ffffff; font: inherit; font-size: 12px; font-weight: 500'
def field(id, placeholder):
    return f'<div style="display: flex"><label style="position: absolute; width: 1px; height: 1px; overflow: hidden" for="{id}">Pairing token</label><input id="{id}" type="text" placeholder="{placeholder}" style="{INPUT}"></div>'
speaker = row(SPEAKER, 'Pair Speaker', untick)
refused = caption('<span>Scan the QR code on Pair Speaker or its leaflet, then paste the token here:</span>'
                  + field('r', 'SP:0…')
                  + '<a href="#">Use the camera instead: allow it in System Settings</a>')
scanning = caption(preview(296, 190, 'look') + field('s', 'or paste the token: SP:0…'))

# S1: a button
CAM = '<svg width="13" height="11" viewBox="0 0 16 13" fill="none" stroke="#ffffff" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><path d="M1.5 4a1.5 1.5 0 0 1 1.5-1.5h1.8L6 1h4l1.2 1.5H13A1.5 1.5 0 0 1 14.5 4v6.5A1.5 1.5 0 0 1 13 12H3a1.5 1.5 0 0 1-1.5-1.5z"></path><circle cx="8" cy="7" r="2.6"></circle></svg>'
link = '<a href="#">Or paste a token</a>'
before1 = caption('<span>The pairing token is the QR code on Pair Speaker or its leaflet.</span>'
                  f'<button type="button" style="{PRIMARY}; display: flex; align-items: center; gap: 6px">{CAM}Scan the QR Code</button>'
                  + link)
scanning1 = caption(preview(296, 190, 'look') + link)
# S2: a link in the hint
before2 = caption('<span><a href="#">Scan the QR code</a> on Pair Speaker or its leaflet, or paste the token:</span>'
                  + field('b2', 'SP:0…'))

def three(before, w=1220, h=420, scan=None):
    cells = [panel(mac + speaker + before, 'Before scanning'),
             panel(mac + speaker + (scan or scanning), 'Scanning: after Allow'),
             panel(mac + speaker + refused, 'After Don’t Allow')]
    body = '<div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 20px; align-items: start">' + ''.join(cells) + '</div>'
    return body

S1 = board('Scan: a button', [three(before1, scan=scanning1)], 420, 1220)
S2 = board('Scan: a link in the hint', [three(before2)], 420, 1220)
idx = json.load(open(f"{R}/project/canvas.json"))
for name, title, html, y in [('PairScanButton.dc.html', 'S1 · A “Scan the QR Code” button (chosen)', S1, 6920)]:
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": 0, "y": y, "w": 1220, "h": 420, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["scan"] = {"kind": "title1", "maxW": 1220, "text": "Asking for the camera", "w": 240, "x": 0, "y": 6660}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
