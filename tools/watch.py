#!/usr/bin/env python3
"""通行止め情報のページを見に行き、前回から変わったものを知らせる。

  python3 tools/watch.py            # data/watch/sources.json のページをすべて確認
  python3 tools/watch.py --only tokyo-forestry

ページ本文（と、指定した PDF の本文）を文字にして data/watch/<id>.txt に保存する。
前回の保存内容と違えば data/watch/changes.md に差分を書く（GitHub Actions がこれを Issue にする）。
取得に失敗したときは前回の内容を残し、3日続けて失敗したら changes.md に書く。
"""
from __future__ import annotations

import argparse
import difflib
import html
import json
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WATCH = ROOT / "data" / "watch"
UA = "rindo-app/0.1 (github.com/minemurak/rindo-app; checks road-closure pages once a day)"
FAIL_LIMIT = 3


class TextAndLinks(HTMLParser):
    """本文の文字とリンクを取り出す。script・style・ヘッダー・フッター・メニューは除く"""
    SKIP = {"script", "style", "noscript", "header", "footer", "nav", "aside"}
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "section", "dd", "dt"}

    def __init__(self):
        super().__init__()
        self.skip_depth = 0
        self.parts: list[str] = []
        self.links: list[tuple[str, str]] = []
        self._href = None
        self._link_text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip_depth += 1
        if tag in self.BLOCK:
            self.parts.append("\n")
        if tag in ("td", "th"):
            self.parts.append(" | ")
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._link_text = []

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip_depth:
            self.skip_depth -= 1
        if tag == "a" and self._href:
            self.links.append((self._href, "".join(self._link_text).strip()))
            self._href = None

    def handle_data(self, data):
        if self._href is not None:
            self._link_text.append(data)
        if not self.skip_depth:
            self.parts.append(data)

    def text(self) -> str:
        raw = html.unescape("".join(self.parts))
        lines = [re.sub(r"[ \t　]+", " ", l).strip() for l in raw.splitlines()]
        return "\n".join(l for l in lines if l)


def fetch(url: str) -> bytes:
    url = urllib.parse.quote(url, safe=":/?&=%#()+,;@!~*'")  # 日本語を含む URL に備える
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as res:
        return res.read()


def decode(data: bytes) -> str:
    m = re.search(rb'charset=["\']?([\w-]+)', data[:2000], re.I)
    for enc in ([m.group(1).decode()] if m else []) + ["utf-8", "cp932"]:
        try:
            return data.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return data.decode("utf-8", errors="replace")


def pdf_text(data: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
        f.write(data)
        f.flush()
        out = subprocess.run(["pdftotext", "-layout", f.name, "-"], capture_output=True, check=True)
    lines = [re.sub(r"[ \t　]+", " ", l).strip() for l in out.stdout.decode("utf-8", "replace").splitlines()]
    return "\n".join(l for l in lines if l)


def snapshot(src: dict) -> str:
    page = TextAndLinks()
    page.feed(decode(fetch(src["url"])))
    text = page.text()
    # 本文のうち、start の行から end の行の手前までだけを見る（メニューやアンケート欄の変化で知らせないため）。
    # start・end は正規表現。見つからなければ切らずに全体を見る
    lines = text.splitlines()
    if src.get("start"):
        hit = next((i for i, l in enumerate(lines) if re.search(src["start"], l)), None)
        if hit is not None:
            lines = lines[hit:]
    if src.get("end"):
        hit = next((i for i, l in enumerate(lines) if i > 0 and re.search(src["end"], l)), None)
        if hit is not None:
            lines = lines[:hit]
    text = "\n".join(lines)
    parts = [f"# {src['name']}\n# {src['url']}\n", text]
    if src.get("pdf_link"):
        pattern = re.compile(src["pdf_link"])
        seen = set()
        for href, label in page.links:
            if not href.lower().split("?")[0].endswith(".pdf"):
                continue
            if not (pattern.search(label) or pattern.search(urllib.parse.unquote(href))):
                continue
            url = urllib.parse.urljoin(src["url"], href)
            if url in seen:
                continue
            seen.add(url)
            parts.append(f"\n# PDF：{label}\n# {url}\n" + pdf_text(fetch(url)))
    return "\n".join(parts).strip() + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    args = ap.parse_args(argv)
    cfg = json.loads((WATCH / "sources.json").read_text(encoding="utf-8"))
    fail_path = WATCH / "failures.json"
    failures = json.loads(fail_path.read_text(encoding="utf-8")) if fail_path.exists() else {}
    report: list[str] = []

    for src in cfg["sources"]:
        if args.only and src["id"] != args.only:
            continue
        path = WATCH / f"{src['id']}.txt"
        try:
            new = snapshot(src)
        except Exception as e:  # 取得失敗：前回の内容を残す
            prev = failures.get(src["id"], {})
            count = (prev.get("count", 0) if isinstance(prev, dict) else int(prev)) + 1
            failures[src["id"]] = {"count": count, "error": f"{type(e).__name__}: {str(e)[:300]}"}
            print(f"失敗：{src['id']}（{count}回目）{e}")
            if count == FAIL_LIMIT:
                report.append(f"## 取得できません：{src['name']}\n\n{FAIL_LIMIT}日続けて取得に失敗しました。"
                              f"ページの場所が変わった可能性があります。\n\n- {src['url']}\n- エラー：`{str(e)[:200]}`\n")
            continue
        failures.pop(src["id"], None)
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old == new:
            print(f"変化なし：{src['id']}")
            continue
        path.write_text(new, encoding="utf-8")
        if old is None:
            print(f"初回保存：{src['id']}")
            continue
        diff = list(difflib.unified_diff(old.splitlines(), new.splitlines(), "前回", "今回", lineterm="", n=1))
        shown = "\n".join(diff[:150]) + ("\n…（以下省略）" if len(diff) > 150 else "")
        print(f"変化あり：{src['id']}（{len(diff)}行）")
        report.append(f"## {src['name']}\n\n- ページ：{src['url']}\n- 関係する林道の設定：" +
                      "、".join(f"`{r}`" for r in src.get("roads", [])) +
                      f"\n\n```diff\n{shown}\n```\n")

    fail_path.write_text(json.dumps(failures, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    changes = WATCH / "changes.md"
    if report:
        changes.write_text("通行止め情報のページが更新されました。内容を確認し、必要なら `data/roads/` の設定を直して "
                           "`python3 tools/road.py build` と `bundle` を実行し、Supabase で all-roads.sql を実行してください。\n\n"
                           + "\n".join(report), encoding="utf-8")
    elif changes.exists():
        changes.unlink()


if __name__ == "__main__":
    sys.exit(main())
