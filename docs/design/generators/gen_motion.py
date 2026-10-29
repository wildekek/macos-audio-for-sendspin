import json, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
# The canvas as published: its index and boards under project/.
R = os.environ.get("R", os.path.join(HERE, "..", "canvas"))
exec(open(os.path.join(HERE, "gen_pairing.py")).read().split("mac = row(MAC")[0])

# The menu bar icon (M1, built) in motion: how it could start and stop playing. One Play/Stop
# button drives every option at once, so they can be compared side by side.
ROOT = os.path.join(HERE, "..", "..", "..")
PATHS = re.findall(r'<path d="([^"]+)"', open(os.path.join(ROOT, "App", "sendspin-logo.svg")).read())
S_PARTS, INNER, OUTER = (0, 1, 6, 7), (3, 5), (2, 4)
GREY = '#6e6e73'

OPTIONS = [
    ('built', 'As built (M1)', 'The waves are there or not.', 'No motion: the switch is instant.'),
    ('fade', 'F · Fade in', 'The inner waves, then the outer, fade in; out in reverse.', 'Like a signal going out, once. Calm: nothing moves while it plays.'),
    ('pulse', 'P · Pulse', 'The waves ripple out and fade, over and over, while it plays.', 'Says “sending” all the time, but a menu bar that moves draws the eye.'),
    ('turn', 'T · Half turn (chosen)', 'The S turns a half turn clockwise as the waves fade in, and back as they go.',
     'The S is the same after a half turn, so it lands where it started: a spin for Sendspin, then still.'),
    ('spin', 'S · Spinning', 'The whole mark turns slowly while it plays.', 'The name, literally; but it never rests, like a busy cursor.'),
]
BARS = {'Light': dict(bar='rgba(246, 246, 248, 0.85)', ink='#1d1d1f', border='rgba(0, 0, 0, 0.16)'),
        'Dark': dict(bar='rgba(40, 40, 44, 0.85)', ink='#ffffff', border='rgba(255, 255, 255, 0.14)')}


def icon(key, ink, size):
    # The mark centred in a square box, as in the template images, so it turns about its centre.
    group = lambda parts: ''.join(f'<path d="{PATHS[i]}"></path>' for i in parts)
    return (f'<svg width="{size}" height="{size}" viewBox="0 -10.5 115 115" fill="{ink}" aria-hidden="true" style="{{{{ {key}.mark }}}}">'
            f'<g>{group(S_PARTS)}</g><g style="{{{{ {key}.inner }}}}">{group(INNER)}</g><g style="{{{{ {key}.outer }}}}">{group(OUTER)}</g></svg>')


def menu_bar(key, theme):
    t = BARS[theme]
    others = ''.join(f'<span style="width: 15px; height: 12px; border-radius: 3px; border: 1.5px solid {t["ink"]}; opacity: 0.35"></span>' for _ in range(2))
    return (f'<div style="display: flex; align-items: center; justify-content: flex-end; gap: 14px; height: 26px; padding: 0 12px; '
            f'border-radius: 8px; background: {t["bar"]}; border: 0.5px solid {t["border"]}">'
            f'{others}<span style="display: flex">{icon(key, t["ink"], 18)}</span>'
            f'<span style="font-size: 12px; color: {t["ink"]}">Sun 20:35</span></div>')


def labelled(label, html):
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-size: 11px; font-weight: 600; color: {GREY}">{label}</span>{html}</div>')


rows = []
for key, title, look, why in OPTIONS:
    zoom = (f'<div style="display: flex; align-items: center; justify-content: center; width: 88px; height: 88px; border-radius: 8px; '
            f'background: #ffffff; border: 0.5px solid rgba(0, 0, 0, 0.12)">{icon(key, "#1d1d1f", 72)}</div>')
    rows.append(f'<div style="display: grid; grid-template-columns: 280px repeat(2, 220px) 88px; gap: 24px; align-items: end">'
                f'<div style="display: flex; flex-direction: column; gap: 4px"><b style="font-size: 14px">{title}</b>'
                f'<span style="font-size: 12px; line-height: 16px">{look}</span>'
                f'<span style="font-size: 12px; line-height: 16px; color: {GREY}">{why}</span></div>'
                f'{labelled("Light", menu_bar(key, "Light"))}{labelled("Dark", menu_bar(key, "Dark"))}{labelled("×4", zoom)}</div>')

controls = (f'<div style="display: flex; align-items: center; gap: 12px">'
            f'<button type="button" onClick="{{{{ toggle }}}}" aria-pressed="{{{{ pressed }}}}" style="min-width: 88px; padding: 6px 14px; border: 1px solid rgba(60, 60, 67, 0.3); '
            f'border-radius: 7px; background: #ffffff; font: inherit; font-size: 13px; color: #1d1d1f; cursor: pointer">{{{{ label }}}}</button>'
            f'<span style="font-size: 12px; color: {GREY}">{{{{ status }}}}</span></div>')

W = 280 + 2 * 220 + 88 + 3 * 24 + 40
H = 60 + len(OPTIONS) * 132 + 40

SCRIPT = '''class Component extends DCLogic {
  renderVals() {
    const playing = this.state.playing ?? false;
    const on = playing ? 1 : 0;
    // Waves that fade: the inner first going in, the outer first going out.
    const fade = (first) => `opacity: ${on}; transition: opacity 220ms ease-out ${(playing === first) ? 0 : 140}ms`;
    const still = { mark: '', inner: `opacity: ${on}`, outer: `opacity: ${on}` };
    return {
      playing,
      label: playing ? 'Stop' : 'Play',
      pressed: playing ? 'true' : 'false',
      status: playing ? 'The Mac’s sound goes out to the speakers.' : 'Nothing goes out.',
      toggle: () => this.setState({ playing: !playing }),
      built: still,
      fade: { mark: '', inner: fade(true), outer: fade(false) },
      pulse: playing
        ? { mark: '', inner: 'animation: ssPulse 1.8s ease-in-out infinite', outer: 'animation: ssPulse 1.8s ease-in-out 0.25s infinite; opacity: 0' }
        : { mark: '', inner: 'opacity: 0', outer: 'opacity: 0' },
      turn: {
        mark: `transform: rotate(${playing ? 180 : 0}deg); transition: transform 700ms cubic-bezier(0.3, 0, 0.2, 1)`,
        inner: fade(true), outer: fade(false),
      },
      spin: playing
        ? { mark: 'animation: ssSpin 4s linear infinite', inner: 'opacity: 1', outer: 'opacity: 1' }
        : { mark: '', inner: 'opacity: 0', outer: 'opacity: 0' },
    };
  }
}'''

html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>The menu bar icon in motion</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
body{{margin:0}}
@keyframes ssPulse{{0%{{opacity:0}}25%{{opacity:1}}70%{{opacity:1}}100%{{opacity:0}}}}
@keyframes ssSpin{{from{{transform:rotate(0deg)}}to{{transform:rotate(360deg)}}}}
</style>
</helmet>
<div style="width: {W}px; height: {H}px; box-sizing: border-box; padding: 20px; display: flex; flex-direction: column; gap: 18px; background: #e3e6ec; font-family: {FONT}; font-size: 13px; color: #1d1d1f">
{controls}
{''.join(rows)}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{W},"height":{H}}}}}'>
{SCRIPT}
</script>
</body>
</html>
'''

idx = json.load(open(f"{R}/project/canvas.json"))
name = 'MenuBarMotion.dc.html'
open(f"{R}/project/{name}", "w").write(html)
menu = idx["boards"]["MenuBarIcons.dc.html"]
idx["boards"][name] = {"x": 0, "y": menu["y"] + menu["h"] + 120, "w": W, "h": H, "is_interactive": True,
                       "title": "The menu bar icon in motion: press Play and Stop (try it)"}
if name not in idx["order"]: idx["order"].append(name)
json.dump(idx, open(f"{R}/project/canvas.json", "w"), indent=2)
print("ok")
