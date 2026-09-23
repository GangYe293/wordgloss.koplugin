#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the compact English language pack shipped with wordgloss.koplugin.

The pack answers exactly one question for the plugin: "how common is this
word, and what is its base form?"  Meanings are NOT stored -- the plugin gets
those from the online Edge endpoint at runtime.  Keeping the pack to
rarity + base forms is what makes it a few hundred KB instead of the ~790 MB
dictionary it is derived from.

Sources
-------
test.db   ECDICT / StarDict sqlite (https://github.com/skywind3000/ECDICT).
          Column ``frq`` is a corpus frequency rank: 1 = "the".  Used for the
          rarity thresholds (初级 1500 / 中级 3000 / 高级 5000).
lemma.en.txt
          Stardict's lemma table, "stem/rank -> form1,form2,...".  Used to map
          inflected forms onto their base ("murdered" -> "murder").  Only
          forms whose base is itself inside the rank table are kept: anything
          else is rare by definition and needs no lookup.

Output
------
SQLite db with one table::

    lex(word TEXT PRIMARY KEY, rank INTEGER, base TEXT)

    rank rows : word is a base word, ``rank`` is its corpus rank, base NULL
    form rows : word is an inflection, ``rank`` is its base's rank, base = stem

Usage::

    python tools/build_en_db.py --dict test.db --lemma lemma.en.txt \\
        --out data/wordgloss_en.sqlite3
"""

import argparse
import os
import re
import sqlite3
import sys
import time

DEFAULT_MAX_RANK = 20000

ALPHA_RE = re.compile(r"^[a-z]{2,24}$")


def read_ranks(db_path, max_rank):
    """Return {word: rank} for single lowercase alphabetic words."""
    uri = "file:" + os.path.abspath(db_path).replace("\\", "/") + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    cur = conn.cursor()
    ranks = {}
    for word, rank in cur.execute(
            "select word, frq from stardict "
            "where frq > 0 and frq <= ? order by frq", (max_rank,)):
        if not word or not ALPHA_RE.match(word):
            continue
        # A word can appear once only (word column is unique), so no clash.
        ranks[word] = int(rank)
    conn.close()
    return ranks


def read_forms(path, ranks):
    """Return {form: stem} for forms whose stem sits inside the rank table."""
    forms = {}
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith(";"):
                continue
            split = line.find("->")
            if split <= 0:
                continue
            stem = line[:split].strip().split("/")[0].strip()
            if not ALPHA_RE.match(stem) or stem not in ranks:
                continue
            for raw in line[split + 2:].split(","):
                form = raw.split("/")[0].strip()
                if not ALPHA_RE.match(form) or form == stem:
                    continue
                if form in ranks:
                    continue  # already a row of its own with a real rank
                forms.setdefault(form, stem)
    return forms


def build(dict_path, lemma_path, out_path, max_rank):
    ranks = read_ranks(dict_path, max_rank)
    if not ranks:
        raise SystemExit("no ranks read from %s" % dict_path)
    forms = read_forms(lemma_path, ranks)

    if os.path.exists(out_path):
        os.remove(out_path)
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)

    conn = sqlite3.connect(out_path)
    conn.execute("PRAGMA journal_mode=OFF;")
    conn.execute("PRAGMA synchronous=OFF;")
    conn.execute("CREATE TABLE lex (word TEXT PRIMARY KEY, rank INTEGER, base TEXT);")
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")

    conn.executemany("INSERT INTO lex(word, rank, base) VALUES(?, ?, NULL);",
                     ((word, rank) for word, rank in ranks.items()))
    conn.executemany("INSERT INTO lex(word, rank, base) VALUES(?, ?, ?);",
                     ((form, ranks[stem], stem) for form, stem in forms.items()))
    conn.executemany("INSERT INTO meta(key, value) VALUES(?, ?);", [
        ("format", "1"),
        ("max_rank", str(max_rank)),
        ("base_words", str(len(ranks))),
        ("forms", str(len(forms))),
        ("built", time.strftime("%Y-%m-%d")),
        ("source_dict", "ECDICT (MIT) https://github.com/skywind3000/ECDICT"),
        ("source_lemma", "Stardict lemma.en.txt"),
        ("note", "frequency rank only; meanings are fetched live by the plugin"),
    ])
    conn.commit()
    # Shrink: the table is read-only at runtime.
    conn.execute("VACUUM;")
    conn.commit()
    count = conn.execute("select count(*) from lex").fetchone()[0]
    conn.close()

    size = os.path.getsize(out_path)
    print("base words : %d" % len(ranks))
    print("forms      : %d" % len(forms))
    print("lex rows   : %d" % count)
    print("written    : %s (%.1f KB)" % (out_path, size / 1024.0))
    for threshold, label in ((1500, "初级"), (3000, "中级"), (5000, "高级")):
        known = sum(1 for rank in ranks.values() if rank <= threshold)
        print("  %s(<=%d): 视为已掌握 %d 词" % (label, threshold, known))
    return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(here, "..", "data", "wordgloss_en.sqlite3")
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dict", required=True, help="ECDICT/StarDict test.db")
    parser.add_argument("--lemma", required=True, help="lemma.en.txt")
    parser.add_argument("--out", default=default_out)
    parser.add_argument("--max-rank", type=int, default=DEFAULT_MAX_RANK)
    args = parser.parse_args()
    return build(args.dict, args.lemma, os.path.abspath(args.out), args.max_rank)


if __name__ == "__main__":
    sys.exit(main())
