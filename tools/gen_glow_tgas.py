#!/usr/bin/env python3
"""Generate multi-layer chamfered glow TGAs for the tutorial box.

Each layer is a rectangle ring at a specific signed distance from the
frame edge. Each layer's corner is chamfered (diagonally cut) at its
own outer boundary, so the layers stack inside-out and the corners form
a chamfered stair-step instead of hard 90 degree angles.

Produces three 32-bit BGRA textures (white color, alpha-encoded shape):

    textures/glow-corner.tga   (16x16)  full chamfered multi-layer corner
    textures/glow-edge-h.tga   (4x16)   horizontal-edge cross-section
    textures/glow-edge-v.tga   (16x4)   vertical-edge cross-section

Tune the look by editing LAYERS and CHAMFER below, then rerun this
script. No Lua changes are needed unless SIZE changes.
"""

import os

# Each entry: (offset, thickness, base_alpha). Offset is signed distance
# from the frame edge (negative = inside the frame, positive = outside).
# Alpha is 0..1 and becomes the layer's on-texture alpha (later further
# multiplied by the pulse animation at runtime).
LAYERS = [
    # Bright band sits OUTSIDE the frame (starting right at the edge),
    # so when the pulse dims it, the dark interior gradient isn't
    # revealed behind it. Outer glow then fades outward from there.
    ( 0, 3, 1.00),   # 3 px bright band, starts at frame edge
    ( 3, 1, 0.72),
    ( 4, 1, 0.52),
    ( 5, 1, 0.35),
    ( 6, 1, 0.22),
    ( 7, 1, 0.12),   # outermost, dimmest
]
# Chamfer sizes (each one is a single triangle cut across whichever
# layers it reaches). Separate knobs because the inner bright band is
# much thinner than the outer glow stack, so it needs a smaller cut
# to stay visible. Outer is 5 (not 4) so the cut also takes the
# corner pixel of each outer layer -- otherwise Layer 4's (5,5) and
# Layer 5's (6,4)/(4,6) stick out past the chamfer line as visible
# single-pixel triangles.
CHAMFER_OUTER = 6   # cut at the outermost corner of the whole stack
CHAMFER_INNER = 2   # cut at the innermost corner (inside the frame)
SIZE      = 16      # texture dimension (power of two)
FRAME_POS = 8       # position of the frame edge inside the texture
OUTER_MAX = LAYERS[-1][0] + LAYERS[-1][1]   # outermost layer boundary, px
INNER_MIN = LAYERS[0][0]                    # innermost layer offset, px


def _alpha_at(dx, dy):
    """Float-valued alpha at signed distances (dx, dy) from the frame
    edges. Used as the sampling kernel for anti-aliasing."""
    # Outer chamfer triangle
    if (OUTER_MAX - CHAMFER_OUTER + 1 <= dx <= OUTER_MAX
            and OUTER_MAX - CHAMFER_OUTER + 1 <= dy <= OUTER_MAX
            and dx + dy >= 2 * OUTER_MAX - CHAMFER_OUTER + 1):
        return 0.0

    # Inner chamfer triangle
    if (INNER_MIN <= dx <= INNER_MIN + CHAMFER_INNER - 1
            and INNER_MIN <= dy <= INNER_MIN + CHAMFER_INNER - 1
            and dx + dy <= 2 * INNER_MIN + CHAMFER_INNER - 1):
        return 0.0

    d = max(dx, dy)
    for off, th, alpha in LAYERS:
        if off <= d < off + th:
            return alpha * 255.0
    return 0.0


_AA_OFFSETS = (-0.375, -0.125, 0.125, 0.375)   # 4x4 sub-pixel grid


def _is_chamfer_cut(dx, dy):
    """True if the pixel at (dx, dy) is removed by either chamfer."""
    if (OUTER_MAX - CHAMFER_OUTER + 1 <= dx <= OUTER_MAX
            and OUTER_MAX - CHAMFER_OUTER + 1 <= dy <= OUTER_MAX
            and dx + dy >= 2 * OUTER_MAX - CHAMFER_OUTER + 1):
        return True
    if (INNER_MIN <= dx <= INNER_MIN + CHAMFER_INNER - 1
            and INNER_MIN <= dy <= INNER_MIN + CHAMFER_INNER - 1
            and dx + dy <= 2 * INNER_MIN + CHAMFER_INNER - 1):
        return True
    return False


def corner_alpha(x, y):
    """Alpha for pixel (x, y) in the TL corner texture.

    Layer assignment uses the integer Chebyshev distance (so layer-to-
    layer and layer-to-transparent boundaries stay SHARP -- no fuzzy
    yellow edge on the frame where the bright band meets the dark
    interior). AA only runs on the chamfer cut, where we want smoothing.
    """
    dx_int = FRAME_POS - x
    dy_int = FRAME_POS - y
    d_int  = max(dx_int, dy_int)

    base_alpha = 0.0
    for off, th, alpha in LAYERS:
        if off <= d_int < off + th:
            base_alpha = alpha * 255.0
            break

    if base_alpha == 0.0:
        return 0

    # Sub-sample only the chamfer cut decision. Each sub-sample either
    # contributes base_alpha (not cut) or 0 (cut); averaging gives a
    # soft chamfer diagonal without blurring layer interiors.
    cut_count = 0
    for sx in _AA_OFFSETS:
        for sy in _AA_OFFSETS:
            dx = FRAME_POS - (x + sx)
            dy = FRAME_POS - (y + sy)
            if _is_chamfer_cut(dx, dy):
                cut_count += 1
    kept = 16 - cut_count
    return int(round(base_alpha * kept / 16.0))


def _edge_alpha_at(d):
    """Float-valued edge alpha at signed distance d."""
    for off, th, alpha in LAYERS:
        if off <= d < off + th:
            return alpha * 255.0
    return 0.0


def edge_alpha(d):
    """Edge cross-section alpha. No AA: we want sharp layer bands and,
    importantly, a sharp boundary between Layer 0 and the transparent
    frame interior so the bright band doesn't bleed a faint strip into
    the frame."""
    return int(round(_edge_alpha_at(d)))


def write_tga(path, width, height, pixels):
    header = bytes([
        0, 0, 2,                              # no id, no colormap, uncompressed truecolor
        0, 0, 0, 0, 0,                        # colormap spec (unused)
        0, 0, 0, 0,                           # x/y origin
        width  & 0xFF, (width  >> 8) & 0xFF,  # width
        height & 0xFF, (height >> 8) & 0xFF,  # height
        32,                                   # 32 bits/pixel (BGRA)
        0x28,                                 # 8 alpha bits + top-to-bottom order
    ])
    with open(path, "wb") as f:
        f.write(header)
        f.write(pixels)


def gen_corner(path):
    data = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            a = corner_alpha(x, y)
            data.extend([255, 255, 255, a])
    write_tga(path, SIZE, SIZE, bytes(data))


def gen_edge_h(path, width=4):
    data = bytearray()
    for y in range(SIZE):
        a = edge_alpha(FRAME_POS - y)
        for _ in range(width):
            data.extend([255, 255, 255, a])
    write_tga(path, width, SIZE, bytes(data))


def gen_edge_v(path, height=4):
    data = bytearray()
    for _ in range(height):
        for x in range(SIZE):
            a = edge_alpha(FRAME_POS - x)
            data.extend([255, 255, 255, a])
    write_tga(path, SIZE, height, bytes(data))


def main():
    out_dir = os.path.join(os.path.dirname(__file__), "..", "textures")
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    gen_corner(os.path.join(out_dir, "glow-corner.tga"))
    gen_edge_h(os.path.join(out_dir, "glow-edge-h.tga"))
    gen_edge_v(os.path.join(out_dir, "glow-edge-v.tga"))

    print("Wrote:")
    for name in ("glow-corner.tga", "glow-edge-h.tga", "glow-edge-v.tga"):
        p = os.path.join(out_dir, name)
        print(f"  {p} ({os.path.getsize(p)} bytes)")


if __name__ == "__main__":
    main()
