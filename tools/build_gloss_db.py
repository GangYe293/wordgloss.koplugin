#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the offline Chinese gloss pack shipped inside wordgloss.koplugin.

Where ``tools/build_en_db.py`` answers "how common is this word, and what is
its base form?", this one answers "what does it mean, and what part of speech
is it?" -- the two columns the plugin used to fetch from the online Edge
endpoint.  With this pack the plugin can gloss a whole book without a network
connection, and online translation becomes a fallback for the words the pack
does not know.

Sources
-------
test.db          ECDICT / StarDict sqlite (https://github.com/skywind3000/ECDICT),
                 MIT licensed.  ``frq`` is a corpus rank (1 = "the"); we take
                 every single lowercase alphabetic word that has one.
lemma.en.txt     Stardict's lemma table, "stem/rank -> form1,form2,...".  Used
                 to map inflected forms onto the base word that carries the
                 meaning, so "murdered" resolves to "murder" offline too.

Output
------
SQLite db with three tables::

    gloss(word TEXT PRIMARY KEY, meaning TEXT, pos TEXT)
    form(form TEXT PRIMARY KEY, base TEXT)
    meta(key TEXT PRIMARY KEY, value TEXT)

  * ``meaning`` -- senses joined with a Chinese comma, part-of-speech prefixes
    and bracketed annotations already stripped, capped at --max-items senses.
  * ``pos``     -- the tag of the FIRST sense ("n.", "adj.", "vt." ...), or NULL.
    Kept separate so the plugin can show it on demand and stay quiet otherwise.

Usage::

    python tools/build_gloss_db.py --dict test.db --lemma lemma.en.txt \\
        --out data/wordgloss_gloss_en.sqlite3
"""

import argparse
import os
import re
import sqlite3
import sys
import time

ALPHA_RE = re.compile(r"^[a-z]{2,24}$")
POS_RE = re.compile(r"^\s*([A-Za-z]+)\.")
# Any CJK ideograph -- used to drop entries whose "translation" is not Chinese.
CJK_RE = re.compile(r"[\u4e00-\u9fff]")

# Same aliases as Gloss.POS_ALIASES in wordgloss_gloss.lua: collapse the
# spellings ECDICT uses onto the few tags worth showing in a margin gloss.
POS_ALIASES = {
    "n": "n.", "v": "v.", "vt": "vt.", "vi": "vi.",
    "adj": "adj.", "adv": "adv.", "prep": "prep.", "conj": "conj.",
    "pron": "pron.", "art": "art.", "num": "num.", "int": "int.",
    "aux": "aux.", "abbr": "abbr.", "det": "det.", "excl": "int.",
    "a": "adj.", "ad": "adv.", "pl": "n.", "pp": "v.",
    "adjs": "adj.", "advr": "adv.", "interj": "int.",
}

# "<<启示录>>" 必须排在 "<印尼>" 前面，否则只会吃掉一半尖括号。
BRACKET_PAIRS = (("<<", ">>"), ("<", ">"), ("[", "]"), ("(", ")"),
                 ("【", "】"), ("（", "）"))
SEPARATORS = (",", ";", "/", "|", "，", "；", "、", "。")
TRAILING = ".,;:!? \t…。，；：！？、"
# 剥掉括号后只剩助词的残渣（"天启的，<<启示录>>的" -> 后半截）。
JUNK_SENSES = frozenset(("的", "地", "得", "之", "了", "着", "过"))
# 语法说明不是释义："abide的过去式和过去分词"、"aerobic的变形"。
GRAMMAR_RE = re.compile(r"^[A-Za-z][A-Za-z\s'\-]*的(变形|过去式|过去分词|现在分词|"
                        r"第三人称单数|复数|比较级|最高级|所有格)")

DEFAULT_MAX_ITEMS = 6
DEFAULT_MAX_CHARS = 80


def remove_brackets(text):
    """Drop bracketed annotations such as "[医] 紧张" -> "紧张"."""
    out = []
    i = 0
    while i < len(text):
        matched = False
        for open_ch, close_ch in BRACKET_PAIRS:
            if text.startswith(open_ch, i):
                stop = text.find(close_ch, i + len(open_ch))
                # 闭合符可能是两个字符（">>"）：跳过整段，别留下半个尖括号。
                i = (stop + len(close_ch)) if stop != -1 else (i + len(open_ch))
                matched = True
                break
        if not matched:
            out.append(text[i])
            i += 1
    return "".join(out)


def take_pos(line):
    """Return (tag, rest) -- tag is "n." style, rest has the prefix removed."""
    match = POS_RE.match(line)
    if not match:
        return None, line
    tag = POS_ALIASES.get(match.group(1).lower())
    if not tag:
        return None, line
    return tag, line[match.end():]


def split_senses(text):
    """Split on the separators the Lua side recognises, keeping the order."""
    items, current = [], []
    for char in text:
        if char in SEPARATORS:
            items.append("".join(current))
            current = []
        else:
            current.append(char)
    items.append("".join(current))
    return items


def strip_leading_latin(sense):
    """Drop a leading English expansion, keeping the Chinese half.

    "American Association for the Advancement of the Humanities 美国人权促进会"
    -> "美国人权促进会".  Returns "" when nothing Chinese would be left.
    """
    match = re.match(r"^[A-Za-z][A-Za-z0-9\s'\-&.]*\s*(?=[\u4e00-\u9fff])", sense)
    if not match:
        return ""
    return sense[match.end():].strip()


def build_meaning(raw, max_items, max_chars):
    """Return (meaning, pos) for one ECDICT ``translation`` blob, or (None, None).

    ECDICT packs one part of speech per line::

        n. 熊
        vt. 忍受, 容忍
        n. 粗鲁的人

    We flatten every line into one sense list, so the plugin can show "熊，忍受"
    instead of only ever seeing the first sense.
    """
    if not raw:
        return None, None
    pos = None
    senses = []
    for line in raw.split("\n"):
        line = line.strip()
        if not line:
            continue
        tag, rest = take_pos(line)
        if tag and pos is None:
            pos = tag
        rest = remove_brackets(rest).strip()
        if not CJK_RE.search(rest):
            continue  # English-only "translation" -- useless as a Chinese gloss
        for sense in split_senses(rest):
            sense = sense.strip().strip(TRAILING).strip()
            if not sense or sense in senses:
                continue
            # 英文缩写全称（"American Association for ..."）不是中文释义。
            if not CJK_RE.search(sense):
                continue
            if sense in JUNK_SENSES or GRAMMAR_RE.match(sense):
                continue
            # 缩写全称夹带在中文释义里（"American Association ... 美国人文促进会"）：
            # 中文部分还在就把前面那段英文丢掉，行间注释没有它的位置。
            stripped = strip_leading_latin(sense)
            if stripped and stripped not in senses:
                senses.append(stripped)
                continue
            senses.append(sense)

    kept, used = [], 0
    for sense in senses:
        if len(kept) >= max_items:
            break
        if used + len(sense) > max_chars:
            break
        kept.append(sense)
        used += len(sense) + 1
    if not kept:
        return None, None
    return "，".join(kept), pos


def read_meanings(db_path, max_items, max_chars):
    """Return {word: (meaning, pos)} for every ranked lowercase word."""
    uri = "file:" + os.path.abspath(db_path).replace("\\", "/") + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    rows = {}
    for word, translation in conn.execute(
            "select word, translation from stardict "
            "where frq > 0 and translation is not null and translation <> ''"):
        if not word or not ALPHA_RE.match(word):
            continue
        meaning, pos = build_meaning(translation, max_items, max_chars)
        if meaning:
            rows[word] = (meaning, pos)
    conn.close()
    return rows


def read_forms(path, meanings):
    """Return {form: base} for inflections whose base carries a meaning."""
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
            if not ALPHA_RE.match(stem) or stem not in meanings:
                continue
            for raw in line[split + 2:].split(","):
                form = raw.split("/")[0].strip()
                if not ALPHA_RE.match(form) or form == stem:
                    continue
                if form in meanings:
                    continue  # has a meaning of its own, no need to redirect
                forms.setdefault(form, stem)
    return forms


def build(dict_path, lemma_path, out_path, max_items, max_chars):
    meanings = read_meanings(dict_path, max_items, max_chars)
    if not meanings:
        raise SystemExit("no meanings read from %s" % dict_path)
    forms = read_forms(lemma_path, meanings)

    if os.path.exists(out_path):
        os.remove(out_path)
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)

    conn = sqlite3.connect(out_path)
    conn.execute("PRAGMA journal_mode=OFF;")
    conn.execute("PRAGMA synchronous=OFF;")
    conn.execute("CREATE TABLE gloss (word TEXT PRIMARY KEY, meaning TEXT, pos TEXT);")
    conn.execute("CREATE TABLE form (form TEXT PRIMARY KEY, base TEXT);")
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")

    conn.executemany("INSERT INTO gloss(word, meaning, pos) VALUES(?, ?, ?);",
                     ((word, meaning, pos) for word, (meaning, pos) in meanings.items()))
    conn.executemany("INSERT INTO form(form, base) VALUES(?, ?);", forms.items())

    with_pos = sum(1 for _, pos in meanings.values() if pos)
    conn.executemany("INSERT INTO meta(key, value) VALUES(?, ?);", [
        ("format", "1"),
        ("words", str(len(meanings))),
        ("forms", str(len(forms))),
        ("with_pos", str(with_pos)),
        ("built", time.strftime("%Y-%m-%d")),
        ("source_dict", "ECDICT (MIT) https://github.com/skywind3000/ECDICT"),
        ("source_lemma", "Stardict lemma.en.txt"),
        ("note", "offline Chinese meanings; online translation is the fallback"),
    ])
    conn.commit()
    conn.execute("VACUUM;")
    conn.commit()
    conn.close()

    size = os.path.getsize(out_path)
    print("words      : %d  (with pos: %d, %.1f%%)"
          % (len(meanings), with_pos, 100.0 * with_pos / len(meanings)))
    print("forms      : %d" % len(forms))
    print("written    : %s (%.2f MB)" % (out_path, size / 1048576.0))
    return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(here, "..", "data", "wordgloss_gloss_en.sqlite3")
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dict", required=True, help="ECDICT/StarDict test.db")
    parser.add_argument("--lemma", required=True, help="lemma.en.txt")
    parser.add_argument("--out", default=default_out)
    parser.add_argument("--max-items", type=int, default=DEFAULT_MAX_ITEMS)
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    args = parser.parse_args()
    return build(args.dict, args.lemma, os.path.abspath(args.out),
                 args.max_items, args.max_chars)


if __name__ == "__main__":
    sys.exit(main())
