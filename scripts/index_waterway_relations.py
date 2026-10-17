#!/usr/bin/env python3
"""
Pre-indexes OSM waterway relations from Osmium OPL stream into a typed JSONL table.

Features:
- Decodes Osmium OPL hexadecimal Unicode code points (%HEX%) into UTF-8 text (unquote_opl).
- Associates member ways with parent relations, preserving member roles and relation tags.
- Deduplicates ways belonging to multiple relations deterministically (main_stream > side_stream > other).
- Outputs newline-delimited JSON (JSONL) ready for vectorized DuckDB read_json() ingestion.
"""

import sys
import re
import json

OPL_ESCAPE_RE = re.compile(r"%([0-9a-fA-F]{1,6})%")


def unquote_opl(val: str) -> str:
    """Decode an Osmium OPL escaped string into its original Unicode text."""
    if not val or "%" not in val:
        return val

    def _replace(match: re.Match) -> str:
        codepoint = int(match.group(1), 16)
        if codepoint > 0x10FFFF:
            return match.group(0)
        if 0xD800 <= codepoint <= 0xDFFF:
            return "\ufffd"
        return chr(codepoint)

    return OPL_ESCAPE_RE.sub(_replace, val)


def parse_opl_stream(input_stream):
    """
    Parses OPL lines for relations (r...) and yields (way_id, rank, record_dict).
    """
    # Role rank: main_stream (1) > side_stream (2) > named/other role (3) > empty/no role (4)
    role_priority = {
        "main_stream": 1,
        "side_stream": 2,
    }

    # way_id -> (rank_tuple, record_dict)
    ways_map = {}

    for line in input_stream:
        if not line or line[0] != "r":
            continue

        m_rel = re.match(r"^r(\d+)", line)
        if not m_rel:
            continue
        rel_id = int(m_rel.group(1))

        # Extract tags: ' Ttag1=val1,tag2=val2'
        m_tags = re.search(r" T([^ ]*)", line)
        rel_tags = {}
        if m_tags and m_tags.group(1):
            for tag_pair in m_tags.group(1).split(","):
                if "=" in tag_pair:
                    k, v = tag_pair.split("=", 1)
                    rel_tags[unquote_opl(k)] = unquote_opl(v)

        # Extract members: ' Mw123@role,w456@role'
        m_members = re.search(r" M([^ ]*)", line)
        if not m_members or not m_members.group(1):
            continue

        for member in m_members.group(1).split(","):
            if not member.startswith("w"):
                continue

            parts = member[1:].split("@", 1)
            try:
                way_id = int(parts[0])
            except ValueError:
                continue

            role = unquote_opl(parts[1]) if len(parts) > 1 and parts[1] else None

            # Priority rank
            if role in role_priority:
                prio = role_priority[role]
            elif role:
                prio = 3
            else:
                prio = 4

            # Rank tuple: (priority, rel_id)
            rank = (prio, rel_id)

            if way_id not in ways_map or rank < ways_map[way_id]["rank"]:
                ways_map[way_id] = {
                    "rank": rank,
                    "record": {
                        "way_id": way_id,
                        "relation_id": rel_id,
                        "member_role": role,
                        "rel_tags": rel_tags,
                    },
                }

    return ways_map


def main():
    input_stream = sys.stdin
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        input_stream = open(sys.argv[1], "r", encoding="utf-8", errors="replace")

    ways_map = parse_opl_stream(input_stream)

    for entry in ways_map.values():
        sys.stdout.write(json.dumps(entry["record"], ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
