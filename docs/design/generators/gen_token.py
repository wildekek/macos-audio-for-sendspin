import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
src = open(os.path.join(HERE, "gen_pairing.py")).read()
# Reuse the building blocks, without writing the first set again.
exec(src.split("mac = row(MAC")[0])
mac = row(MAC, 'MacBook Pro Speakers', CHECK, slider=True)
untick = f'<button type="button" aria-label="Remove Pair Speaker, cancelling pairing" style="flex: none; border: 0; padding: 0; background: none; display: flex; cursor: pointer"><span style="display: flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 11px; background: rgba(60, 60, 67, 0.4)"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5,6.5 5,9 9.5,3.5"></polyline></svg></span></button>'
speaker = lambda: row(SPEAKER, 'Pair Speaker', untick)
H = 330
INPUT = 'flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 24px; padding: 0 7px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.25); background: #ffffff; font-family: ui-monospace, Menlo, monospace; font-size: 11px'
BUTTON = 'flex: none; height: 24px; padding: 0 10px; border-radius: 6px; border: 0.5px solid rgba(0, 0, 0, 0.2); background: #ffffff; font: inherit; font-size: 12px'
def field(id, value='', button=True):
    v = f' value="{value}"' if value else ''
    b = f'<button type="button" style="{BUTTON}">Pair</button>' if button else ''
    return f'<div style="display: flex; gap: 6px; align-items: center"><label style="position: absolute; width: 1px; height: 1px; overflow: hidden" for="{id}">Pairing token</label><input id="{id}" type="text" placeholder="SP:0…"{v} style="{INPUT}">{b}</div>'
again = "That token didn't match. "
boards = {}
boards['PairTokenA.dc.html'] = ('T1 · A field and Pair', board('Token: a field and Pair', [
    panel(mac + speaker() + caption(f'<span>Paste the pairing token of Pair Speaker:</span>{field("a1")}'), 'Pasting the token'),
    panel(mac + speaker() + caption(f'<span>{again}Paste the pairing token of Pair Speaker again:</span>{field("a2")}'), 'After a wrong token')], H))
boards['PairTokenB.dc.html'] = ('T2 · A field that pairs on paste, as the slots do', board('Token: pairs on paste', [
    panel(mac + speaker() + caption(f'<span>Paste the pairing token of Pair Speaker:</span>{field("b1", button=False)}'), 'Pasting the token'),
    panel(mac + speaker() + caption(f'<span>{again}Paste the pairing token of Pair Speaker again:</span>{field("b2", button=False)}'), 'After a wrong token')], H))
paste = f'<button type="button" style="{BUTTON}; align-self: flex-start; padding: 0 12px">Paste Token</button>'
boards['PairTokenC.dc.html'] = ('T3 · One Paste Token button', board('Token: one Paste button', [
    panel(mac + speaker() + caption(f'<span>Copy the pairing token of Pair Speaker, then paste it here.</span>{paste}'), 'Waiting for the token'),
    panel(mac + speaker() + caption(f'<span>{again}Copy it again, then paste it here.</span>{paste}'), 'After a wrong token')], H))
chip = '<div style="display: flex; align-items: center; gap: 6px"><span style="flex: 1 1 auto; min-width: 0; box-sizing: border-box; height: 24px; padding: 0 8px; display: flex; align-items: center; border-radius: 6px; background: rgba(60, 60, 67, 0.12); font-family: ui-monospace, Menlo, monospace; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">SP:05A5K7…UKNTBWX4VQ</span></div>'
boards['PairTokenD.dc.html'] = ('T4 · Clipboard first: offered when you copied one', board('Token: from the clipboard', [
    panel(mac + speaker() + caption(f'<span>Pair Speaker pairs with the token you copied:</span>{chip}<button type="button" style="{BUTTON}; align-self: flex-start">Pair</button>'), 'A token on the clipboard'),
    panel(mac + speaker() + caption(f'<span>Copy the pairing token of Pair Speaker, or paste it here:</span>{field("d2", button=False)}'), 'None on the clipboard')], H))
idx = json.load(open(f"{R}/project/canvas.json"))
x = 0
for name, (title, html) in boards.items():
    open(f"{R}/project/{name}", "w").write(html)
    idx["boards"][name] = {"x": x, "y": 5010, "w": 388, "h": H, "title": title}
    if name not in idx["order"]: idx["order"].append(name)
    x += 468
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print(list(boards))
