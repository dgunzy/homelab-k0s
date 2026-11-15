"""Generates the hero illustration (src/assets/hero.svg): three isometric
layers (hosts, clusters, workloads) with node tiles and flows between them.
Colours are CSS variables, so the inlined SVG follows the site theme.
Run: python3 scripts/hero.py --write   (updates the svg and the home page's
inline copy, which Starlight renders as the hero image)."""
import re
import sys
from pathlib import Path

CX = 210
LAYERS = [  # (key, cy, half-width, half-depth, label, sub)
    ("hosts", 338, 165, 82, "Hosts", "VMs · GPU passthrough"),
    ("clusters", 222, 132, 66, "Clusters", "control planes · node pools"),
    ("workloads", 116, 100, 50, "Workloads", "inference · agents"),
]
T = 14  # slab thickness


def slab(cx, cy, hw, hd, t, cls):
    top = f"M{cx},{cy-hd} L{cx+hw},{cy} L{cx},{cy+hd} L{cx-hw},{cy} Z"
    left = f"M{cx-hw},{cy} L{cx},{cy+hd} L{cx},{cy+hd+t} L{cx-hw},{cy+t} Z"
    right = f"M{cx+hw},{cy} L{cx},{cy+hd} L{cx},{cy+hd+t} L{cx+hw},{cy+t} Z"
    return (f'<path class="hx-side-l {cls}" d="{left}"/>'
            f'<path class="hx-side-r {cls}" d="{right}"/>'
            f'<path class="hx-top {cls}" d="{top}"/>')


def tiles(cx, cy, spacing, cells, special=None):
    out = []
    for a, b in cells:
        x = cx + (a - b) * spacing
        y = cy + (a + b) * spacing / 2
        cls = "hx-tile hx-gpu" if (a, b) == special else "hx-tile"
        out.append(slab(round(x, 1), round(y, 1), 15, 7.5, 5, cls))
    return "".join(out)


def bottom_edge_y(cy, hw, hd, dx):
    # y of a slab's front bottom edge at horizontal offset dx from centre
    return cy + T + hd * (1 - abs(dx) / hw)


parts = []
parts.append('<ellipse class="hx-glow" cx="%d" cy="%d" rx="190" ry="60"/>' % (CX, LAYERS[0][1] + 40))
groups = {}
for key, cy, hw, hd, label, sub in LAYERS:
    g = [slab(CX, cy, hw, hd, T, f"hx-{key}")]
    if key == "hosts":
        g.append(tiles(CX, cy, 30, [(-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)], special=(1, 1)))
    elif key == "clusters":
        g.append(tiles(CX, cy, 30, [(-1, -1), (0, -1), (-1, 0), (0, 0), (1, 0), (0, 1)]))
    else:
        g.append(tiles(CX, cy, 28, [(-1, 0), (0, 0), (0, -1)]))
    groups[key] = "".join(g)

# flows: vertical connectors with dots travelling up, between each pair of layers
def flows(lower, upper, xs, delay0):
    out = []
    (_, lcy, lhw, lhd, *_), (_, ucy, uhw, uhd, *_) = lower, upper
    for i, dx in enumerate(xs):
        x = CX + dx
        y1 = lcy + lhd * 0.15          # on the lower slab's top face
        y2 = bottom_edge_y(ucy, uhw, uhd, dx) - 2
        out.append(f'<line class="hx-link" x1="{x}" y1="{y1}" x2="{x}" y2="{y2}"/>')
        d = delay0 + i * 0.9
        out.append(
            f'<circle class="hx-dot" cx="{x}" cy="{y1}" r="3.2">'
            f'<animate attributeName="cy" values="{y1};{y2}" dur="2.4s" begin="{d}s" repeatCount="indefinite"/>'
            f'<animate attributeName="opacity" values="0;1;1;0" keyTimes="0;0.15;0.8;1" dur="2.4s" begin="{d}s" repeatCount="indefinite"/>'
            f'</circle>')
    return "".join(out)

body = [parts[0], f'<g class="hx-float hx-f3">{groups["hosts"]}</g>',
        flows(LAYERS[0], LAYERS[1], [-70, 70], 0),
        f'<g class="hx-float hx-f2">{groups["clusters"]}</g>',
        flows(LAYERS[1], LAYERS[2], [-48, 48], 0.5),
        f'<g class="hx-float hx-f1">{groups["workloads"]}</g>']

# labels with leader lines from each slab's right corner
for key, cy, hw, hd, label, sub in LAYERS:
    x0, x1 = CX + hw + 6, 392
    body.append(f'<path class="hx-leader" d="M{x0},{cy} L{x1-8},{cy}"/><circle class="hx-leader-dot" cx="{x1-8}" cy="{cy}" r="2.5"/>')
    body.append(f'<text class="hx-label" x="{x1}" y="{cy-3}">{label}</text>')
    body.append(f'<text class="hx-sub" x="{x1}" y="{cy+19}">{sub}</text>')

style = """
.hx-top{fill:color-mix(in srgb,var(--sl-color-accent) 22%,var(--sl-color-black));stroke:color-mix(in srgb,var(--sl-color-accent) 70%,transparent);stroke-width:1}
.hx-side-l{fill:color-mix(in srgb,var(--sl-color-accent) 12%,var(--sl-color-black));stroke:color-mix(in srgb,var(--sl-color-accent) 45%,transparent);stroke-width:1}
.hx-side-r{fill:color-mix(in srgb,var(--sl-color-accent) 6%,var(--sl-color-black));stroke:color-mix(in srgb,var(--sl-color-accent) 45%,transparent);stroke-width:1}
.hx-workloads.hx-top{fill:color-mix(in srgb,var(--sl-color-accent) 34%,var(--sl-color-black))}
.hx-tile.hx-top{fill:color-mix(in srgb,var(--sl-color-accent) 55%,var(--sl-color-black));stroke:var(--sl-color-accent-high);stroke-width:.8}
.hx-tile.hx-side-l{fill:color-mix(in srgb,var(--sl-color-accent) 35%,var(--sl-color-black))}
.hx-tile.hx-side-r{fill:color-mix(in srgb,var(--sl-color-accent) 25%,var(--sl-color-black))}
.hx-gpu.hx-top{fill:#fbbf24;stroke:#fde68a;animation:hx-pulse 2.6s ease-in-out infinite}
.hx-gpu.hx-side-l{fill:#b45309}.hx-gpu.hx-side-r{fill:#92400e}
.hx-glow{fill:var(--sl-color-accent);opacity:.18;filter:blur(28px)}
.hx-link{stroke:color-mix(in srgb,var(--sl-color-accent) 55%,transparent);stroke-width:1.4;stroke-dasharray:3 4}
.hx-dot{fill:var(--sl-color-accent-high);filter:drop-shadow(0 0 4px var(--sl-color-accent))}
.hx-leader{stroke:var(--sl-color-gray-4);stroke-width:1;stroke-dasharray:2 3;fill:none}
.hx-leader-dot{fill:var(--sl-color-accent)}
.hx-label{font-family:var(--heading-font,var(--sl-font));font-size:21px;font-weight:600;fill:var(--sl-color-white)}
.hx-sub{font-family:var(--sl-font);font-size:14px;fill:var(--sl-color-gray-3)}
.hx-float{animation:hx-float 6s ease-in-out infinite}
.hx-f2{animation-delay:-2s}.hx-f1{animation-delay:-4s}
@keyframes hx-float{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
@keyframes hx-pulse{0%,100%{opacity:1}50%{opacity:.6}}
@media (prefers-reduced-motion: reduce){.hx-float,.hx-gpu{animation:none}.hx-dot{display:none}}
"""
svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="30 50 580 410" role="img" '
       'aria-label="Three stacked layers: hypervisor hosts with a GPU, clusters, and workloads, with flows between them">'
       f"<style>{' '.join(style.split())}</style>" + "".join(body) + "</svg>")
if "--write" in sys.argv:
    root = Path(__file__).resolve().parent.parent
    (root / "src/assets/hero.svg").write_text(svg + "\n")
    page = root / "src/content/docs/index.mdx"
    text = page.read_text()
    new, n = re.subn(r"^    html: '.*'$", lambda _: f"    html: '{svg}'", text, count=1, flags=re.M)
    if n != 1:
        sys.exit("index.mdx: no `    html: '...'` hero line found")
    page.write_text(new)
else:
    print(svg)
