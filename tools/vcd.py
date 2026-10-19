"""
vcd.py -- a small reader for value change dump (VCD) files.

Only what the atlas traces need: the scope tree, and every change of the
signals asked for, as (time, value) pairs. Values are kept as strings of
0/1/x/z, most significant bit first, so an X stays an X instead of silently
becoming a number.
"""
import re


def read(path, want, t_end=None):
    """Changes of the signals whose full dotted name matches one of the
    regexes in `want`. Returns ({name: {"width": w, "changes": [(t, bits)]}},
    timescale string, last time)."""
    pats = [re.compile(w) for w in want]
    ids, sigs, scope = {}, {}, []
    timescale, t = "", 0
    with open(path, errors="replace") as f:
        it = iter(f)
        for line in it:                       # header
            tok = line.split()
            if not tok:
                continue
            if tok[0] == "$timescale":
                body = tok[1:]
                while "$end" not in body:
                    body += next(it).split()
                timescale = " ".join(b for b in body if b != "$end")
            elif tok[0] == "$scope":
                scope.append(tok[2])
            elif tok[0] == "$upscope":
                scope.pop()
            elif tok[0] == "$var":
                width, code, name = int(tok[2]), tok[3], tok[4]
                full = ".".join(scope + [name])
                if any(p.fullmatch(full) for p in pats) and full not in sigs:
                    sigs[full] = {"width": width, "changes": []}
                    ids.setdefault(code, []).append(full)
            elif tok[0] == "$enddefinitions":
                break
        for line in it:                       # value changes
            if not line or line[0] in "$\n":
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
                if t_end is not None and t > t_end:
                    break
                continue
            if c in "bB":
                val, code = line[1:].split()
            elif c in "rR":
                continue
            else:
                val, code = c, line[1:].strip()
            for full in ids.get(code, ()):
                w = sigs[full]["width"]
                v = val.lower()
                if len(v) < w:                # VCD drops leading zeros (and pads x/z)
                    v = (v[0] if v[0] in "xz" else "0") * (w - len(v)) + v
                ch = sigs[full]["changes"]
                if not ch or ch[-1][1] != v:
                    ch.append((t, v))
    return sigs, timescale, t


def value_at(changes, t):
    """The value a signal holds at time t (the last change at or before t)."""
    lo, hi, v = 0, len(changes) - 1, None
    while lo <= hi:
        mid = (lo + hi) // 2
        if changes[mid][0] <= t:
            v = changes[mid][1]; lo = mid + 1
        else:
            hi = mid - 1
    return v


def as_int(bits):
    """An integer, or None if any bit is x or z."""
    if bits is None or any(b in "xz" for b in bits):
        return None
    return int(bits, 2)
