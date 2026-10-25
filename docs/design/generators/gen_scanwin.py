import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_window.py")).read().split("W, H = 1808, 900")[0])
mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
untickbtn = '<button type="button" aria-label="Remove Kitchen, cancelling pairing" style="border: 0; padding: 0; background: none; display: flex"><span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: rgba(60, 60, 67, 0.4)"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span></button>'
kitchen = row(SPEAKER, 'Kitchen', untickbtn)
SMALLPRIMARY = f'height: 22px; padding: 0 10px; border-radius: 6px; border: 0; background: {BLUE}; color: #ffffff; font: inherit; font-size: 12px; font-weight: 500; display: flex; align-items: center; gap: 5px'
menu_before = panel(mac + kitchen + caption('<span>The pairing token is the QR code on Kitchen or its leaflet.</span>'
    f'<div style="display: flex; align-items: center; gap: 12px"><button type="button" style="{SMALLPRIMARY}">{CAM}Scan the QR Code</button><a href="#">Or paste a token</a></div>'), 'The menu: before scanning')
menu_during = panel(mac + kitchen + caption('<a href="#" style="text-decoration: none">Scanning in a window…</a>'), 'The menu: while the window is open')

def scanwin(inner, cancel=True):
    c = '<div style="display: flex; justify-content: flex-end"><button type="button" style="border: 0; background: none; padding: 0; font: inherit; font-size: 13px; color: #0a7aff">Cancel</button></div>' if cancel else ''
    return (f'<div style="display: flex; flex-direction: column; gap: 12px; padding: 16px 16px 12px; box-sizing: border-box; border-radius: 18px; '
            f'background: rgba(246, 246, 248, 0.86); border: 0.5px solid rgba(0, 0, 0, 0.14); box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2); font-size: 13px; line-height: 18px">'
            f'<div style="display: flex; align-items: center; gap: 10px"><span style="{ICON}; width: 30px; height: 30px; border-radius: 15px">{SPEAKER}</span>'
            f'<span style="font-weight: 600">Scan Kitchen’s QR code</span></div>{inner}{c}</div>')

alert = ('<div style="position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); width: 250px; padding: 14px; box-sizing: border-box; border-radius: 12px; '
         'background: #ececee; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45); display: flex; flex-direction: column; gap: 8px; text-align: center; font-size: 12px; line-height: 16px; color: #1d1d1f">'
         '<b>“macOS Audio for Sendspin” would like to access the camera.</b><span style="color: #3c3c43">macOS Audio for Sendspin reads the pairing QR code printed on a speaker or its leaflet.</span>'
         '<div style="display: flex; gap: 8px"><span style="flex: 1; padding: 4px 0; border-radius: 6px; background: #ffffff">Don’t Allow</span><span style="flex: 1; padding: 4px 0; border-radius: 6px; background: #0a7aff; color: #ffffff">Allow</span></div></div>')
asking = f'<div style="position: relative; width: 392px; height: 250px; border-radius: 10px; overflow: hidden; background: #2a2a2e">{alert}</div>'
refused = ('<div style="display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; width: 392px; height: 250px; box-sizing: border-box; padding: 24px; border-radius: 10px; background: rgba(60, 60, 67, 0.08); text-align: center">'
           '<span>The camera isn’t allowed for this app.</span><a href="#">Allow it in System Settings</a>'
           '<span style="color: #6e6e73">Or paste Kitchen’s token in the menu.</span></div>')
paired = cam('ok')
states = [('macOS asks, the first time', scanwin(asking)), ('Looking', scanwin(cam('look'))), ('Token read', scanwin(cam('read'))),
          ('Didn’t match', scanwin(cam('bad'))), ('Paired: closes a moment later', scanwin(paired, cancel=False)), ('Camera not allowed', scanwin(refused))]
cells = ''.join(f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: #6e6e73">{l}</span>{w}</div>' for l, w in states)
menus = f'<div style="display: grid; grid-template-columns: repeat(3, 424px); gap: 24px; align-items: start">{menu_before}{menu_during}<div></div></div>'
wins = f'<div style="display: grid; grid-template-columns: repeat(3, 424px); gap: 24px; align-items: start">{cells}</div>'
W, H = 1360, 1180
html = board('Scanning in a window', [menus, wins], H, W)
idx = json.load(open(f"{R}/project/canvas.json"))
name = 'PairScanWindow.dc.html'
open(f"{R}/project/{name}", "w").write(html)
idx["boards"][name] = {"x": 0, "y": 10560, "w": W, "h": H, "title": "Scanning in a glass window (W2), opened by Scan the QR Code"}
if name not in idx["order"]: idx["order"].append(name)
idx["notes"]["scanwindow"] = {"kind": "title1", "maxW": W, "text": "Scanning in a window", "w": 240, "x": 0, "y": 10300}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
