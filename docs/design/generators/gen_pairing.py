import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
BLUE = "#0a7aff"
SPEAKER = '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><rect x="3" y="1" width="8" height="12" rx="1.5"></rect><circle cx="7" cy="8.5" r="2"></circle><circle cx="7" cy="4" r="0.6"></circle></svg>'
MAC = '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="10" height="7.5" rx="1"></rect><path d="M1 12.5h14"></path></svg>'
SPIN = '<svg width="22" height="22" viewBox="0 0 22 22" aria-hidden="true"><g stroke="#3c3c43" stroke-width="2" stroke-linecap="round"><path d="M11 4v3.2" opacity="0.9"></path><path d="M15.95 6.05l-2.26 2.26" opacity="0.78"></path><path d="M18 11h-3.2" opacity="0.66"></path><path d="M15.95 15.95l-2.26-2.26" opacity="0.54"></path><path d="M11 18v-3.2" opacity="0.42"></path><path d="M6.05 15.95l2.26-2.26" opacity="0.32"></path><path d="M4 11h3.2" opacity="0.24"></path><path d="M6.05 6.05l2.26 2.26" opacity="0.16"></path></g></svg>'
XCIRCLE = '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="7" fill="rgba(60, 60, 67, 0.45)"></circle><path d="M4.6 4.6l4.8 4.8M9.4 4.6l-4.8 4.8" stroke="#ffffff" stroke-width="1.4" stroke-linecap="round"></path></svg>'
CHECK = f'<span style="display: flex; align-items: center; justify-content: center; flex: none; width: 22px; height: 22px; border-radius: 11px; background: {BLUE}"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span>'
ICON = 'display: flex; align-items: center; justify-content: center; flex: none; width: 26px; height: 26px; border-radius: 13px; background: rgba(0, 0, 0, 0.08); color: #1d1d1f'

def row(icon, name, right, slider=False):
    s = ''
    if slider:
        s = '<span aria-hidden="true" style="position: relative; flex: none; width: 80px; height: 16px"><span style="position: absolute; left: 0; right: 0; top: 6px; height: 4px; border-radius: 2px; background: rgba(60, 60, 67, 0.18)"></span><span style="position: absolute; left: 0; width: 55%; top: 6px; height: 4px; border-radius: 2px; background: rgba(60, 60, 67, 0.7)"></span><span style="position: absolute; left: calc(55% - 11px); top: 1px; width: 22px; height: 14px; border-radius: 7px; background: #ffffff; box-shadow: 0 0.5px 2px rgba(0, 0, 0, 0.35)"></span></span>'
    return f'<div style="display: flex; align-items: center; gap: 10px; height: 38px"><span style="{ICON}">{icon}</span><span style="flex: 1 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{name}</span>{s}{right}</div>'

def slots(digits, length=6):
    out = []
    for i in range(length):
        if i == length // 2:
            out.append('<span style="color: #6e6e73">–</span>')
        d = digits[i] if i < len(digits) else ''
        current = i == len(digits)
        border = f'1.5px solid {BLUE}' if current else '1.5px solid transparent'
        out.append(f'<span style="display: flex; align-items: center; justify-content: center; width: 20px; height: 26px; box-sizing: border-box; border-radius: 5px; background: rgba(60, 60, 67, 0.12); border: {border}; font-family: ui-monospace, Menlo, monospace; font-size: 13px; font-weight: 500">{d}</span>')
    return '<div role="group" aria-label="Pairing code" style="display: flex; align-items: center; gap: 4px">' + ''.join(out) + '</div>'

def xbutton():
    return f'<button type="button" aria-label="Cancel pairing" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer">{XCIRCLE}</button>'

def spin_button(label="Cancel pairing"):
    return f'<button type="button" aria-label="{label}" title="Cancel pairing" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer">{SPIN}</button>'

def caption(inner, right=''):
    return f'<div style="display: flex; align-items: flex-start; gap: 8px; padding: 0 0 8px 36px; font-size: 11px; line-height: 15px"><div style="flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 6px">{inner}</div>{right}</div>'

def panel(rows, label):
    return f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: #6e6e73">{label}</span><div style="box-sizing: border-box; padding: 6px 14px; display: flex; flex-direction: column; background: #f5f5f7; border: 0.5px solid rgba(0, 0, 0, 0.16); border-radius: 14px">{rows}</div></div>'

def board(title, panels, h, w=388):
    body = ''.join(panels)
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
body{{margin:0}}
a{{color:{BLUE}}}a:hover{{color:#0060d0}}
</style>
</helmet>
<div style="width: {w}px; height: {h}px; box-sizing: border-box; padding: 20px; display: flex; flex-direction: column; gap: 18px; background: #e3e6ec; font-family: {FONT}; font-size: 13px; color: #1d1d1f">
{body}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{w},"height":{h}}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{}};
  }}
}}
</script>
</body>
</html>
'''

mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
prompt = 'Enter the code that Pair Speaker shows now:'
wrong = "That code didn't match. Enter the code that Pair Speaker shows now:"
H = 330

boards = {}
# 1. today
p = lambda text, digits: panel(mac + row(SPEAKER, 'Pair Speaker', f'<span aria-hidden="true" style="display: flex">{SPIN}</span>') + caption(f'<span>{text}</span>{slots(digits)}', xbutton()), '')
boards['PairCodeX.dc.html'] = ('1 · Today: a ⓧ beside the caption', board('Pairing code, ⓧ beside the caption', [
    panel(mac + row(SPEAKER, 'Pair Speaker', f'<span aria-hidden="true" style="display: flex">{SPIN}</span>') + caption(f'<span>{prompt}</span>{slots("369")}', xbutton()), 'Entering the code'),
    panel(mac + row(SPEAKER, 'Pair Speaker', f'<span aria-hidden="true" style="display: flex">{SPIN}</span>') + caption(f'<span>{wrong}</span>{slots("")}', xbutton()), 'After a wrong code')], H))
# 2. the spinner cancels
boards['PairCodeSpinner.dc.html'] = ('2 · The spinner cancels, as when joining', board('Pairing code, the spinner cancels', [
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f'<span>{prompt}</span>{slots("369")}'), 'Entering the code'),
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f'<span>{wrong}</span>{slots("")}'), 'After a wrong code')], H))
# 3. a cancel link
link = '<a href="#" style="text-decoration: none">Cancel</a>'
boards['PairCodeLink.dc.html'] = ('3 · A Cancel link, as the server captions link', board('Pairing code, a Cancel link', [
    panel(mac + row(SPEAKER, 'Pair Speaker', f'<span aria-hidden="true" style="display: flex">{SPIN}</span>') + caption(f'<span>{prompt}</span><div style="display: flex; align-items: center; gap: 12px">{slots("369")}{link}</div>'), 'Entering the code'),
    panel(mac + row(SPEAKER, 'Pair Speaker', f'<span aria-hidden="true" style="display: flex">{SPIN}</span>') + caption(f'<span>{wrong}</span><div style="display: flex; align-items: center; gap: 12px">{slots("")}{link}</div>'), 'After a wrong code')], H))
# 4. untick cancels, with the check staying a check
untick = f'<button type="button" aria-label="Remove Pair Speaker, cancelling pairing" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer"><span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: rgba(60, 60, 67, 0.4)"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span></button>'
boards['PairCodeUntick.dc.html'] = ('4 · A grey check: unticking cancels', board('Pairing code, unticking cancels', [
    panel(mac + row(SPEAKER, 'Pair Speaker', untick) + caption(f'<span>{prompt}</span>{slots("369")}'), 'Entering the code'),
    panel(mac + row(SPEAKER, 'Pair Speaker', untick) + caption(f'<span>{wrong}</span>{slots("")}'), 'After a wrong code')], H))
# 5. token: field + pair, spinner cancels
field = '<div style="display: flex; gap: 6px; align-items: center"><label style="position: absolute; width: 1px; height: 1px; overflow: hidden" for="tok">Pairing token</label><input id="tok" type="text" placeholder="SP:0…" style="flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 24px; padding: 0 7px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.25); background: #ffffff; font-family: ui-monospace, Menlo, monospace; font-size: 11px"><button type="button" style="flex: none; height: 24px; padding: 0 10px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 12px">Pair</button></div>'
boards['PairTokenField.dc.html'] = ('5 · Token: a field, the spinner cancels', board('Pairing token, a field', [
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f'<span>Paste the pairing token of Pair Speaker:</span>{field}'), 'Pasting the token'),
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f"<span>That token didn't match. Paste the pairing token of Pair Speaker again:</span>{field}"), 'After a wrong token')], H))
# 6. token: one paste button
paste = '<button type="button" style="align-self: flex-start; height: 24px; padding: 0 12px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 12px">Paste Token</button>'
boards['PairTokenPaste.dc.html'] = ('6 · Token: one Paste button, no field', board('Pairing token, one Paste button', [
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f'<span>Copy the pairing token of Pair Speaker, then paste it here.</span>{paste}'), 'Waiting for the token'),
    panel(mac + row(SPEAKER, 'Pair Speaker', spin_button()) + caption(f"<span>That token didn't match. Copy it again, then paste it here.</span>{paste}"), 'After a wrong token')], H))

idx = json.load(open(f"{R}/project/canvas.json"))
x = 0
for name, (title, html) in boards.items():
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": x, "y": 4560, "w": 388, "h": H, "title": title}
    if name not in idx["order"]:
        idx["order"].append(name)
    x += 388 + 80
idx["notes"]["pairing"] = {"kind": "title1", "maxW": x - 80, "text": "Pairing a speaker: code and token", "w": 240, "x": 0, "y": 4300}
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print(list(boards))
