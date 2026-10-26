"""Writes tiny.osm.pbf from tiny.osm, beside this script, for tests/osm2pgsql.sh.

    python -I tests/osm2pgsql/topbf.py

OSM's PBF format with nothing but the standard library: one header blob and
one data blob, zlib-compressed, the data's nodes, ways and relations in a
primitive group each (plain nodes, not dense ones; no metadata). The output
is committed, so the suite doesn't need Python; rerun this after editing
tiny.osm.
"""

import os
import struct
import xml.etree.ElementTree as ET
import zlib


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def zigzag(n):
    return (n << 1) ^ (n >> 63)


def key(field, wire):
    return varint(field << 3 | wire)


def f_varint(field, n):
    return key(field, 0) + varint(n)


def f_bytes(field, data):
    return key(field, 2) + varint(len(data)) + data


def f_packed(field, values):
    return f_bytes(field, b"".join(varint(v) for v in values))


def blob(kind, payload):
    data = f_varint(2, len(payload)) + f_bytes(3, zlib.compress(payload, 9))
    header = f_bytes(1, kind.encode()) + f_varint(3, len(data))
    return struct.pack(">I", len(header)) + header + data


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = ET.parse(os.path.join(here, "tiny.osm")).getroot()

    strings = [b""]
    index = {}

    def sid(s):
        b = s.encode()
        if b not in index:
            index[b] = len(strings)
            strings.append(b)
        return index[b]

    def tags(element):
        pairs = [(sid(t.get("k")), sid(t.get("v"))) for t in element.findall("tag")]
        return f_packed(2, [k for k, _ in pairs]) + f_packed(3, [v for _, v in pairs])

    nodes = b""
    for n in root.findall("node"):
        lat = round(float(n.get("lat")) * 10_000_000)
        lon = round(float(n.get("lon")) * 10_000_000)
        body = f_varint(1, zigzag(int(n.get("id")))) + tags(n) + f_varint(8, zigzag(lat)) + f_varint(9, zigzag(lon))
        nodes += f_bytes(1, body)

    ways = b""
    for w in root.findall("way"):
        refs, last = [], 0
        for nd in w.findall("nd"):
            ref = int(nd.get("ref"))
            refs.append(zigzag(ref - last))
            last = ref
        ways += f_bytes(3, f_varint(1, int(w.get("id"))) + tags(w) + f_packed(8, refs))

    relations = b""
    types = {"node": 0, "way": 1, "relation": 2}
    for r in root.findall("relation"):
        roles, ids, kinds, last = [], [], [], 0
        for m in r.findall("member"):
            ref = int(m.get("ref"))
            roles.append(sid(m.get("role")))
            ids.append(zigzag(ref - last))
            kinds.append(types[m.get("type")])
            last = ref
        body = f_varint(1, int(r.get("id"))) + tags(r) + f_packed(8, roles) + f_packed(9, ids) + f_packed(10, kinds)
        relations += f_bytes(4, body)

    table = f_bytes(1, b"".join(f_bytes(1, s) for s in strings))
    block = table + f_bytes(2, nodes) + f_bytes(2, ways) + f_bytes(2, relations)
    header = f_bytes(4, b"OsmSchema-V0.6") + f_bytes(16, b"zigsaw tests")

    with open(os.path.join(here, "tiny.osm.pbf"), "wb") as out:
        out.write(blob("OSMHeader", header) + blob("OSMData", block))


main()
