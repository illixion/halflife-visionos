#!/usr/bin/env python3
"""Rasterise a probe .tri dump to a PNG: side, front and top views.

    render_tri.py grip_v_9mmhandgun.tri [out.png]

Each line is "label|x y z|x y z|x y z" in GoldSrc space (X forward, Y left,
Z up). Labels pick the colour: body (skin), gun (grey), shell (orange), ray
(red), cut (dim red), anything else white. The back of a gun or shell face is
purple, so a hole in a one-sided model shows as a purple patch. Pure Python and `sips`, no dependencies, so it runs
on any Mac the probe does. Slow on big dumps; fine for one arm and a gun.
"""
import math, subprocess, sys

COLOURS = {"body": (214, 170, 120), "gun": (200, 200, 205), "ray": (235, 60, 50),
           "cut": (120, 40, 40), "floor": (70, 90, 70),
           "shell": (230, 150, 60)}
INTERIOR = {"gun": (90, 30, 90), "shell": (90, 30, 90)}

def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".png"
    tris = []
    for line in open(src):
        f = line.rstrip("\n").split("|")
        if len(f) >= 4:
            tris.append((f[0], [list(map(float, x.split())) for x in f[1:4]]))
    W, H = 1200, 420
    panel = W // 3
    img = bytearray(b"\x1c" * W * H * 3)
    zb = [-1e30] * (W * H)
    # (screen x, screen y, depth toward the viewer) per view
    views = [lambda v: (v[0], v[2], -v[1]),    # from the right side: forward is right
             lambda v: (-v[1], v[2], v[0]),    # from the front, facing the model
             lambda v: (-v[1], v[0], v[2])]    # from above: forward is up
    for vi, V in enumerate(views):
        pts = [V(p) for _, t in tris for p in t]
        lo = [min(p[i] for p in pts) for i in range(2)]
        hi = [max(p[i] for p in pts) for i in range(2)]
        s = min((panel - 20) / (hi[0] - lo[0] + 1e-6), (H - 20) / (hi[1] - lo[1] + 1e-6))
        for label, t in tris:
            col = COLOURS.get(label, (255, 255, 255))
            a, b, c = [(vi * panel + 10 + (V(p)[0] - lo[0]) * s, H - 10 - (V(p)[1] - lo[1]) * s, V(p)[2]) for p in t]
            e1 = [t[1][i] - t[0][i] for i in range(3)]
            e2 = [t[2][i] - t[0][i] for i in range(3)]
            n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]
            ln = math.sqrt(sum(x * x for x in n)) or 1
            shade = 0.35 + 0.65 * abs(V(n)[2] / ln)
            # GoldSrc fronts wind clockwise: the outward normal is -n. A gun
            # face turned away shows its back, drawn as the weapon pass
            # shades it — dark interior — so holes read as holes.
            if label in INTERIOR and V(n)[2] > 0:
                col = INTERIOR[label]
            px = bytes(int(x * shade) for x in col)
            den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            if abs(den) < 1e-9:
                continue
            for y in range(int(max(0, min(a[1], b[1], c[1]))), int(min(H - 1, max(a[1], b[1], c[1]))) + 1):
                for x in range(int(max(vi * panel, min(a[0], b[0], c[0]))),
                               int(min((vi + 1) * panel - 1, max(a[0], b[0], c[0]))) + 1):
                    l1 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / den
                    l2 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / den
                    l3 = 1 - l1 - l2
                    if l1 < 0 or l2 < 0 or l3 < 0:
                        continue
                    z = l1 * a[2] + l2 * b[2] + l3 * c[2]
                    k = y * W + x
                    if z > zb[k]:
                        zb[k] = z
                        img[k * 3:k * 3 + 3] = px
    ppm = out + ".ppm"
    with open(ppm, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (W, H) + bytes(img))
    subprocess.run(["sips", "-s", "format", "png", ppm, "--out", out], check=True, capture_output=True)
    subprocess.run(["rm", ppm])
    print(out)

main()
