#!/usr/bin/env python3
"""Write a minimal, uncompressed Microsoft Cabinet file (for the test kit).

    python3 -I tests/kit/mkcab.py out.cab NAME=PATH [NAME=PATH ...]

Each NAME is the file name stored in the cabinet, PATH the file to store.
Enough for cabextract to list and extract — the DirectX redistributable is
a cabinet of cabinets, so fake ones can be nested the same way.
"""
import struct
import sys

BLOCK = 32768


def build(entries):
    data = b"".join(blob for _, blob in entries)
    blocks = [data[i:i + BLOCK] for i in range(0, len(data), BLOCK)] or [b""]

    header_size = 36
    folder_size = 8
    files = b""
    offset = 0
    for name, blob in entries:
        files += struct.pack("<IIHHHH", len(blob), offset, 0, 0x5821, 0, 0x20)
        files += name.encode("ascii") + b"\0"
        offset += len(blob)

    coff_files = header_size + folder_size
    coff_data = coff_files + len(files)
    cfdata = b"".join(struct.pack("<IHH", 0, len(b), len(b)) + b for b in blocks)
    total = coff_data + len(cfdata)

    header = struct.pack("<4sIIIIIBBHHHHH", b"MSCF", 0, total, 0, coff_files, 0,
                         3, 1, 1, len(entries), 0, 0x1234, 0)
    folder = struct.pack("<IHH", coff_data, len(blocks), 0)
    return header + folder + files + cfdata


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    entries = []
    for spec in argv[2:]:
        name, _, path = spec.partition("=")
        with open(path, "rb") as f:
            entries.append((name, f.read()))
    with open(argv[1], "wb") as f:
        f.write(build(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
