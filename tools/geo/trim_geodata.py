#!/usr/bin/env python3
"""Rewrite a v2ray/xray geoip.dat or geosite.dat keeping only what the app uses.

The upstream dataset carries all 260 country blocks (~20 MB) while ChrNet only
ever emits `geoip:ru` rules -- see XrayConfigBuilder._ruDirectIpRules and
XrayVpnService.buildRuDirectIpRule. Keeping RU and PRIVATE brings the file down
to roughly 380 KB.

Both files share a wire shape -- a repeated length-delimited field 1 whose
entries start with a string key -- so one parser handles them:

    message CIDR        { bytes ip = 1; uint32 prefix = 2; }
    message GeoIP       { string country_code = 1; repeated CIDR cidr = 2; }
    message GeoIPList   { repeated GeoIP entry = 1; }

    message Domain      { Type type = 1; string value = 2; ... }
    message GeoSite     { string country_code = 1; repeated Domain domain = 2; }
    message GeoSiteList { repeated GeoSite entry = 1; }

In geosite.dat the key is a category name such as CATEGORY-RU rather than a
country code, but the traversal is identical.

Entries are copied through byte for byte, so no protobuf runtime is needed and
the surviving blocks are bit-identical to the originals.

Usage:
    python tools/geo/trim_geodata.py <input.dat> <output.dat> [CODE ...]
"""

import sys

DEFAULT_KEEP = ("RU", "PRIVATE")


def read_varint(buf, pos):
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def write_varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def iter_entries(data):
    """Yield (country_code, raw_entry_bytes) for every GeoIPList entry."""
    pos = 0
    while pos < len(data):
        tag, pos = read_varint(data, pos)
        field, wire_type = tag >> 3, tag & 7
        if field != 1 or wire_type != 2:
            raise ValueError(
                "unexpected top-level field %d (wire type %d)" % (field, wire_type)
            )
        length, pos = read_varint(data, pos)
        entry = data[pos:pos + length]
        pos += length
        if len(entry) != length:
            raise ValueError("truncated entry")

        # country_code is field 1 of GeoIP and is written first by the upstream
        # generator, so a single tag read is enough.
        inner_tag, inner_pos = read_varint(entry, 0)
        if inner_tag >> 3 != 1 or inner_tag & 7 != 2:
            raise ValueError("entry does not start with country_code")
        code_len, inner_pos = read_varint(entry, inner_pos)
        code = entry[inner_pos:inner_pos + code_len].decode("ascii")
        yield code, entry


def trim(data, keep):
    wanted = {code.upper() for code in keep}
    out = bytearray()
    found = set()
    total = 0
    for code, entry in iter_entries(data):
        total += 1
        if code.upper() not in wanted:
            continue
        found.add(code.upper())
        out += b"\x0a"  # field 1, wire type 2
        out += write_varint(len(entry))
        out += entry
    return bytes(out), total, found, wanted


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    src, dst = argv[1], argv[2]
    keep = argv[3:] or list(DEFAULT_KEEP)

    with open(src, "rb") as handle:
        data = handle.read()

    out, total, found, wanted = trim(data, keep)

    missing = wanted - found
    if missing:
        print("error: not found in %s: %s" % (src, ", ".join(sorted(missing))),
              file=sys.stderr)
        return 1

    with open(dst, "wb") as handle:
        handle.write(out)

    # Re-parse the result so a malformed write fails here and not inside Xray.
    verify = [code for code, _ in iter_entries(out)]
    if sorted(verify) != sorted(found):
        print("error: verification failed, wrote %s" % verify, file=sys.stderr)
        return 1

    print("%s: %d entries, %.1f MB" % (src, total, len(data) / 1024 / 1024))
    print("%s: %d entries (%s), %.0f KB" % (
        dst, len(verify), ", ".join(sorted(verify)), len(out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
