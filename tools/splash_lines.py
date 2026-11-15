#!/usr/bin/env python3
"""Regenerate the launch-animation assets from one image.

Usage:
    python3 tools/splash_lines.py <image> [--cutout] [--low 60] [--high 140] [--min-length 40] [--max-segments 3500]

--subject-lines keeps the full image as the artwork but traces only the subject:
the background is masked out (rembg) before edge detection, coordinates stay in
the full-image frame so the line art lines up with the full picture.

--cutout removes the background (rembg, isnet-anime model), crops to the
subject and writes a transparent PNG; the line art then only covers the subject.

Writes:
    BearMailbox/Resources/SplashArt.png      (transparent, with --cutout) or SplashArt.jpg (900 px wide, JPEG q82)
    BearMailbox/Resources/splash-lines.json  ({"aspect": w/h, "lines": [[[x, y], ...], ...]}, coords 0..1)
    /tmp/splash-lines-preview.png            (line-art preview for checking)

Requires: opencv-python, numpy, pillow; rembg[cpu] for --cutout.
Tuning: raise --low/--high or --min-length if the line art looks noisy;
lower them if detail (eyes, hair strands) is missing.
"""
import argparse, json, pathlib
import cv2
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "BearMailbox" / "Resources"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--low", type=float, default=60)
    ap.add_argument("--high", type=float, default=140)
    ap.add_argument("--min-length", type=float, default=40)
    ap.add_argument("--max-segments", type=int, default=3500)
    ap.add_argument("--cutout", action="store_true")
    ap.add_argument("--subject-lines", action="store_true")
    ap.add_argument("--drop-pale", type=int, default=0,
                    help="with --subject-lines: also drop bright low-saturation areas (HSV S below this, V>150), "
                         "e.g. 85 removes white bedding the segmentation model keeps")
    ap.add_argument("--preview", default="/tmp/splash-lines-preview.png")
    a = ap.parse_args()

    im = Image.open(a.image).convert("RGB")
    if a.cutout:
        from rembg import remove, new_session
        cut = remove(im, session=new_session("isnet-anime"), alpha_matting=True,
                     alpha_matting_foreground_threshold=240,
                     alpha_matting_background_threshold=15, alpha_matting_erode_size=6)
        cut = cut.crop(cut.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
        cut = cut.resize((720, round(720 * cut.height / cut.width)), Image.LANCZOS)
        cut.save(RES / "SplashArt.png", optimize=True)
        (RES / "SplashArt.jpg").unlink(missing_ok=True)
        # flat background so edge detection only sees the subject and its outline
        flat = Image.new("RGBA", cut.size, (253, 228, 238, 255))
        flat.alpha_composite(cut)
        im = flat.convert("RGB")
    else:
        im.resize((900, round(900 * im.height / im.width)), Image.LANCZOS).save(
            RES / "SplashArt.jpg", quality=82, optimize=True, progressive=True)
        (RES / "SplashArt.png").unlink(missing_ok=True)
        if a.subject_lines:
            from rembg import remove, new_session
            mask = np.array(remove(im, session=new_session("isnet-anime"), only_mask=True).convert("L")) > 128
            if a.drop_pale:
                hsv = cv2.cvtColor(np.array(im), cv2.COLOR_RGB2HSV)
                mask &= ~((hsv[..., 1] < a.drop_pale) & (hsv[..., 2] > 150))
            keep = mask.astype(np.uint8) * 255
            keep = cv2.morphologyEx(keep, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))
            keep = cv2.morphologyEx(keep, cv2.MORPH_CLOSE, np.ones((25, 25), np.uint8))
            n, lab, st, _ = cv2.connectedComponentsWithStats(keep)
            big = [i for i in range(1, n) if st[i, cv2.CC_STAT_AREA] > 0.01 * keep.size]
            keep = np.isin(lab, big).astype(np.uint8) * 255
            # fill only small interior holes (large enclosed areas are real background)
            n, lab, st, _ = cv2.connectedComponentsWithStats(cv2.bitwise_not(keep))
            for i in range(1, n):
                if st[i, cv2.CC_STAT_AREA] < 0.004 * keep.size:
                    keep[lab == i] = 255
            arr = np.array(im)
            arr[keep == 0] = (253, 228, 238)
            im = Image.fromarray(arr)
            im.save("/tmp/splash-subject-preview.jpg")

    img = cv2.cvtColor(np.array(im), cv2.COLOR_RGB2BGR)
    h0, w0 = img.shape[:2]
    W = 600
    H = round(h0 * W / w0)
    img = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
    g = cv2.bilateralFilter(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), 9, 60, 60)
    edges = cv2.Canny(g, a.low, a.high)
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)

    lines, segs = [], 0
    for c in sorted(contours, key=lambda c: -cv2.arcLength(c, False)):
        if cv2.arcLength(c, False) < a.min_length:
            continue
        poly = cv2.approxPolyDP(c, 1.6, False)
        if len(poly) < 2:
            continue
        pts = [[round(p[0][0] / W, 4), round(p[0][1] / H, 4)] for p in poly]
        if segs + len(pts) - 1 > a.max_segments:
            break
        segs += len(pts) - 1
        lines.append(pts)

    (RES / "splash-lines.json").write_text(
        json.dumps({"aspect": round(W / H, 4), "lines": lines}, separators=(",", ":")))

    canvas = np.full((H, W, 3), (36, 16, 26), np.uint8)
    for l in lines:
        pts = np.array([[p[0] * W, p[1] * H] for p in l], np.int32)
        cv2.polylines(canvas, [pts], False, (230, 200, 255), 1, cv2.LINE_AA)
    cv2.imwrite(a.preview, canvas)
    print(f"{len(lines)} polylines, {segs} segments -> {RES}; preview {a.preview}")


if __name__ == "__main__":
    main()
