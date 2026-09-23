"""Sanity-check the generated language pack against the words that matter."""
import os
import sqlite3
import sys

PACK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "wordgloss_en.sqlite3")

LEVELS = {"初级": 1500, "中级": 3000, "高级": 5000}

SAMPLES = [
    ("the", 1), ("book", None), ("take", None), ("took", "take"),
    ("ubiquitous", 8148), ("ephemeral", 14116),
    ("running", 3252),
    # ECDICT 给部分变形词单独算了词频，这类词会作为独立词条保留，
    # 因此 base 为空（释义会按该变形词本身去翻，同样正确）。
    ("murdered", None),
]


def main():
    conn = sqlite3.connect("file:" + os.path.abspath(PACK).replace("\\", "/") + "?mode=ro", uri=True)
    total = conn.execute("select count(*) from lex").fetchone()[0]
    bases = conn.execute("select count(*) from lex where base is null").fetchone()[0]
    forms = total - bases
    print("lex 行数 %d（原形 %d，变形 %d）" % (total, bases, forms))

    problems = []
    for word, expected in SAMPLES:
        row = conn.execute("select rank, base from lex where word = ?", (word,)).fetchone()
        if row is None:
            print("  %-14s 不在包内（会被当作超纲生词）" % word)
            continue
        rank, base = row
        print("  %-14s rank=%-7s base=%s" % (word, rank, base))
        if isinstance(expected, int) and rank != expected:
            problems.append("%s 的 rank 应为 %s，实际 %s" % (word, expected, rank))
        if isinstance(expected, str) and base != expected:
            problems.append("%s 的 base 应为 %s，实际 %s" % (word, expected, base))

    for word in ("ubiquitous", "ephemeral"):
        row = conn.execute("select rank from lex where word = ?", (word,)).fetchone()
        if not row:
            continue
        rank = row[0]
        verdict = " / ".join(
            "%s(%d):%s" % (label, limit, "注释" if rank > limit else "不注释")
            for label, limit in LEVELS.items()
        )
        print("  rank=%d 的词在三级别下：%s" % (rank, verdict))

    # meta 表：pack 自描述
    for key, value in conn.execute("select key, value from meta").fetchall():
        print("  meta %-14s %s" % (key, value))

    conn.close()
    size = os.path.getsize(PACK) / 1024.0
    print("包大小 %.1f KB" % size)
    if problems:
        print("校验失败：")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
