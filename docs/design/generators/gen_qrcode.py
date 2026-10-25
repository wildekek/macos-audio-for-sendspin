import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_scanwin.py")).read().split("alert = (")[0])

# A speaker that shows its dynamic code as a QR code only (pairing.md, Dynamic Pairing Code
# Flow, qr_code): a new code every attempt, the same for its rounds, on its screen, scanned in the same window as a
# printed token. Servers MUST implement every method, and the Mac has a camera. A speaker that
# offers digits too gets digits: typing six digits beats holding a Mac up to a speaker.
OVERLAY = {
    'look': 'Point the camera at the code on Kitchen’s screen',
    'read': 'Code read. Pairing with Kitchen…',
    'ok': 'Paired with Kitchen',
    'bad': 'That code didn’t match. Scan the code Kitchen shows now.',
}
OLD = {
    'look': 'Hold the QR code on Kitchen or its leaflet up to the camera',
    'read': 'Token read. Pairing with Kitchen…',
    'ok': 'Paired with Kitchen',
    'bad': 'That token didn’t match. Hold up Kitchen’s own QR code.',
}


def screen_cam(state):
    # Its screen, not a leaflet: white on a dark bezel, upright.
    html = cam(state).replace(OLD[state].replace('’', "'"), OVERLAY[state]).replace(OLD[state], OVERLAY[state])
    return (html.replace('background: #f4f1ea; border-radius: 4px; transform: rotate(-4deg)',
                         'background: #ffffff; border-radius: 6px; border: 7px solid #1d1d1f; transform: none'))


def win(inner, cancel=True):
    return scanwin(inner, cancel).replace('Scan Kitchen’s QR code', 'Scan the code Kitchen shows')


scan = f'<button type="button" style="{SMALLPRIMARY}">{CAM}Scan the Code</button>'
menu_before = panel(mac + kitchen + caption('<span>Kitchen shows its pairing code as a QR code on its screen.</span>'
                                            f'<div style="display: flex">{scan}</div>'), 'The menu, or Settings: before scanning')
menu_during = panel(mac + kitchen + caption('<a href="#" style="text-decoration: none">Scanning in a window…</a>'),
                    'While the window is open')
menu_wrong = panel(mac + kitchen + caption('<span>That code didn’t match. Scan the code Kitchen shows now.</span>'
                                           f'<div style="display: flex">{scan}</div>'), 'A wrong code after the window was closed: scan again')
states = [('Looking', win(screen_cam('look'))), ('Code read', win(screen_cam('read'))),
          ('Didn’t match: it keeps scanning; the code stays the same for the attempt', win(screen_cam('bad'))),
          ('Paired: closes a moment later', win(screen_cam('ok'), cancel=False))]
cells = ''.join(f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: #6e6e73">{l}</span>{w}</div>'
                for l, w in states)
menus = f'<div style="display: grid; grid-template-columns: repeat(3, 424px); gap: 24px; align-items: start">{menu_before}{menu_during}{menu_wrong}</div>'
wins = f'<div style="display: grid; grid-template-columns: repeat(4, 424px); gap: 24px; align-items: start">{cells}</div>'
notes = ('<div style="max-width: 900px; font-size: 12px; line-height: 17px; color: #3c3c43">'
         'No paste link: the code is new each attempt and only on the speaker’s screen. '
         'A speaker that offers digits too is asked for digits. Without a camera, a speaker that offers its code only as a QR code can’t be paired by it '
         '(the spec lets a server pick <code>qr_code</code> only when it can scan one); it pairs by token if it has one.</div>')
W, H = 4 * 424 + 3 * 24 + 40, 660
html = board('A code shown as a QR code', [menus, wins, notes], H, W)
idx = json.load(open(f"{R}/project/canvas.json"))
name = 'PairQRCode.dc.html'
open(f"{R}/project/{name}", "w").write(html)
idx["boards"][name] = {"x": 0, "y": 22920, "w": W, "h": H,
                       "title": "A dynamic code the speaker shows only as a QR code: scanned in the same window"}
if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["qrcode"] = {"kind": "title1", "maxW": W, "text": "Pairing by a code the speaker shows as a QR code",
                          "w": 240, "x": 0, "y": 22660}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
