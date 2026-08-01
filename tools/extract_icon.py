"""Pull the game's own icon out of the user-supplied Balatro container.

Rule #1 applies to artwork as much as code: the icon is LocalThunk's and is
never committed to this repository. Like everything else Balatro, it arrives
at build time from the copy the user already owns, and the generated file
lands in a gitignored directory. A build without it simply keeps the stock
LOVE icon (see the ICON manifest placeholder in android/app/build.gradle).

Both container kinds carry the icon, in different wrappers:

  Balatro.app   Contents/Resources/GameIcon.icns -- an icns file, whose
                modern entries (ic07..ic14) are raw PNG. Take the largest.

  Balatro.exe   a PE file with RT_ICON resources, BMP-only in the Steam
                1.0.1o build, so the chosen DIB is converted to PNG here in
                pure stdlib (a PNG is just headers plus a zlib stream).

                THE LARGEST ICON IS THE WRONG ONE. The exe carries two
                RT_GROUP_ICONs: group 1 is love.exe's own pink/blue heart at
                up to 256 px, and a later group (736 in this build) holds
                Balatro's icon at up to 32 px. Picking the biggest entry
                shipped the LOVE heart. Groups added after the engine's own
                belong to the game packager, so the HIGHEST-numbered group
                wins -- at the cost of resolution, which is fine for pixel
                art scaled with nearest-neighbour.

Returns PNG bytes, or None with a reason on stderr. Never raises: the icon
is a nicety, and a weird container must not break the build.
"""

import os
import struct
import sys


def _log(msg):
    print("       icon: %s" % msg, file=sys.stderr)


PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _icon_from_icns(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"icns":
        _log("%s is not an icns file" % os.path.basename(path))
        return None
    best = None
    i = 8
    while i + 8 <= len(data):
        length = int.from_bytes(data[i + 4:i + 8], "big")
        if length < 8:
            break
        body = data[i + 8:i + length]
        if body[:8] == PNG_MAGIC and (best is None or len(body) > len(best)):
            best = body
        i += length
    return best


def _icon_from_exe(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        _log("not a PE executable")
        return None
    (pe_off,) = struct.unpack_from("<I", data, 0x3C)
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        _log("PE signature missing")
        return None

    n_sections, = struct.unpack_from("<H", data, pe_off + 6)
    opt_size, = struct.unpack_from("<H", data, pe_off + 20)
    opt = pe_off + 24
    magic, = struct.unpack_from("<H", data, opt)
    dd_off = opt + (0x60 if magic == 0x10B else 0x70)
    rsrc_rva, _rsrc_sz = struct.unpack_from("<II", data, dd_off + 2 * 8)
    if rsrc_rva == 0:
        _log("no resource directory")
        return None

    sections = []
    sec_off = opt + opt_size
    for i in range(n_sections):
        off = sec_off + 40 * i
        vsize, vaddr, raw_size, raw_ptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, max(vsize, raw_size), raw_ptr))

    def rva_to_off(rva):
        for vaddr, size, raw_ptr in sections:
            if vaddr <= rva < vaddr + size:
                return raw_ptr + (rva - vaddr)
        return None

    rsrc = rva_to_off(rsrc_rva)
    if rsrc is None:
        _log("resource section unmapped")
        return None

    def dir_entries(dir_off):
        n_named, n_id = struct.unpack_from("<HH", data, dir_off + 12)
        out = []
        for i in range(n_named + n_id):
            name, off = struct.unpack_from("<II", data, dir_off + 16 + 8 * i)
            out.append((name, off))
        return out

    RT_ICON, RT_GROUP_ICON = 3, 14

    def leaves_of(off, name):
        return ([(name, off)] if not (off & 0x80000000)
                else dir_entries(rsrc + (off & 0x7FFFFFFF)))

    def leaf_bytes(leaf_off):
        entry_rva, entry_size = struct.unpack_from("<II", data, rsrc + leaf_off)
        off = rva_to_off(entry_rva)
        return data[off:off + entry_size] if off is not None else None

    # Which icon do we actually want? Ask the groups, not the sizes.
    want_id, want_group, want_w = None, -1, -1
    for type_id, type_off in dir_entries(rsrc):
        if type_id != RT_GROUP_ICON or not (type_off & 0x80000000):
            continue
        for name, name_off in dir_entries(rsrc + (type_off & 0x7FFFFFFF)):
            group_id = name & 0x7FFFFFFF
            for _lang, leaf_off in leaves_of(name_off, name):
                if leaf_off & 0x80000000:
                    continue
                body = leaf_bytes(leaf_off)
                if not body or len(body) < 6:
                    continue
                count, = struct.unpack_from("<H", body, 4)
                for i in range(count):
                    e = 6 + 14 * i
                    if e + 14 > len(body):
                        break
                    w = body[e] or 256
                    icon_id, = struct.unpack_from("<H", body, e + 12)
                    if group_id > want_group or (group_id == want_group
                                                 and w > want_w):
                        if group_id > want_group:
                            want_w = -1
                        if w > want_w:
                            want_group, want_id, want_w = group_id, icon_id, w
    if want_id is None:
        _log("no icon group in the exe")
        return None
    _log("using group %d, icon id %d (%dpx)" % (want_group, want_id, want_w))

    for type_id, type_off in dir_entries(rsrc):
        if type_id != RT_ICON or not (type_off & 0x80000000):
            continue
        for name, name_off in dir_entries(rsrc + (type_off & 0x7FFFFFFF)):
            if (name & 0x7FFFFFFF) != want_id:
                continue
            for _lang, leaf_off in leaves_of(name_off, name):
                if leaf_off & 0x80000000:
                    continue
                body = leaf_bytes(leaf_off)
                if not body:
                    continue
                return body if body[:8] == PNG_MAGIC else _png_from_dib(body)

    _log("icon id %d not present" % want_id)
    return None


def _png_from_dib(dib):
    """A 32-bpp icon DIB (BITMAPINFOHEADER, height doubled for the AND mask,
    rows bottom-up, BGRA) re-encoded as PNG. Stdlib only: a PNG is IHDR +
    zlib-compressed filtered rows + IEND."""
    import zlib

    hdr_size, w, h2 = struct.unpack_from("<III", dib, 0)
    bpp, = struct.unpack_from("<H", dib, 14)
    if hdr_size != 40 or bpp != 32:
        _log("largest exe icon is %d-bpp with a %d-byte header; only 32-bpp"
             " BITMAPINFOHEADER DIBs are supported" % (bpp, hdr_size))
        return None
    h = h2 // 2                     # XOR image only; the AND mask follows it
    stride = w * 4

    rows = []
    for y in range(h - 1, -1, -1):  # bottom-up -> top-down
        off = 40 + y * stride
        row = bytearray(dib[off:off + stride])
        # BGRA -> RGBA
        row[0::4], row[2::4] = row[2::4], row[0::4]
        rows.append(b"\x00" + bytes(row))   # filter type 0 per row

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    idat = zlib.compress(b"".join(rows), 9)
    return (PNG_MAGIC + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat)
            + chunk(b"IEND", b""))


def extract_icon(container):
    """PNG bytes of the game's icon, or None. `container` is the same path
    the rest of the build takes: a Balatro.app directory or a Balatro.exe."""
    try:
        if os.path.isdir(container):
            icns = os.path.join(container, "Contents", "Resources",
                                "GameIcon.icns")
            if not os.path.exists(icns):
                _log("GameIcon.icns not found in the .app")
                return None
            return _icon_from_icns(icns)
        return _icon_from_exe(container)
    except Exception as e:  # noqa: BLE001 -- the icon must never kill a build
        _log("extraction failed: %s" % e)
        return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: extract_icon.py <Balatro.app|Balatro.exe> <out.png>")
        raise SystemExit(2)
    png = extract_icon(sys.argv[1])
    if png is None:
        raise SystemExit(1)
    with open(sys.argv[2], "wb") as f:
        f.write(png)
    print("wrote %s (%d bytes)" % (sys.argv[2], len(png)))
