#!/usr/bin/env python3
"""png-stats.py <file.png>: prints "distinct=<n> nondominant=<fraction> w=<w> h=<h>" using only the stdlib.
Used by ci/smoke.sh to tell a drawn page from a blank/uniform launch screen. Exit 3 if the PNG layout is unsupported."""
import struct, sys, zlib
from collections import Counter

def main(path):
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        print("not-a-png"); return 3
    p = 8; idat = b""; w = h = bd = ct = il = None
    while p < len(d):
        n, t = struct.unpack(">I4s", d[p:p+8]); body = d[p+8:p+8+n]; p += 12 + n
        if t == b"IHDR": w, h, bd, ct, _, _, il = struct.unpack(">IIBBBBB", body)
        elif t == b"IDAT": idat += body
    if bd != 8 or ct not in (2, 6) or il != 0:
        print("unsupported bd=%s ct=%s il=%s" % (bd, ct, il)); return 3
    bpp = 3 if ct == 2 else 4
    raw = zlib.decompress(idat); stride = w * bpp
    prev = bytearray(stride); cnt = Counter(); o = 0
    for _ in range(h):
        f = raw[o]; line = bytearray(raw[o+1:o+1+stride]); o += 1 + stride
        if f == 1:
            for i in range(bpp, stride): line[i] = (line[i] + line[i-bpp]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0; b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
                pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2*c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        for x in range(0, stride, bpp * 4):          # sample every 4th pixel
            cnt[bytes(line[x:x+3])] += 1
    total = sum(cnt.values()); top = cnt.most_common(1)[0][1]
    print("distinct=%d nondominant=%.4f w=%d h=%d" % (len(cnt), 1 - top / total, w, h))
    return 0

sys.exit(main(sys.argv[1]))
