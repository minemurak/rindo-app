#!/usr/bin/env python3
"""林道データ整備ツール

林道1本ぶんの設定ファイル（data/roads/<slug>.json）から、区間に分けた GeoJSON と
Supabase に入れる SQL を作る。外部ライブラリは使わない（Python 3.9 以上）。

使い方
  1. OSM から線を取るリンクを出す
       python3 tools/road.py link 城峰
     → 表示されたリンクを開き、Export → GeoJSON → download で
       data/osm/<slug>.geojson として保存する
  2. 境目にする地名の座標を調べるリンクを出す（国土地理院の地名検索）
       python3 tools/road.py place 風早峠
  3. 設定ファイル data/roads/<slug>.json を書く（data/roads/joubu-chichibu.json が見本）
  4. 区間データと SQL を作る
       python3 tools/road.py build data/roads/<slug>.json
     → data/segments/<slug>.geojson と supabase/roads/<slug>.sql ができる
  5. Supabase の SQL Editor で supabase/roads/<slug>.sql を実行する

一般通行の可否・規制は、必ず管理者（自治体など）の公式情報で決めて設定ファイルに書く。
OSM のタグ（access など）は参考にとどめる。
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# MVP 対象（埼玉・東京・群馬）をおおまかに囲む範囲：南, 西, 北, 東
DEFAULT_BBOX = (35.45, 138.40, 37.10, 139.95)
JOIN_TOLERANCE_M = 30.0      # 端点がこの距離以内なら、つながっているとみなす
SPLIT_WARN_M = 100.0         # 境目の点が線からこれ以上離れていたら警告


# ---------- 距離と線の計算 ----------

def dist_m(a, b) -> float:
    """経緯度2点間のおおよその距離（メートル）。林道の長さ程度なら十分な精度。"""
    dx = (b[0] - a[0]) * 111_320 * math.cos(math.radians((a[1] + b[1]) / 2))
    dy = (b[1] - a[1]) * 110_540
    return math.hypot(dx, dy)


def line_length_m(coords) -> float:
    return sum(dist_m(a, b) for a, b in zip(coords, coords[1:]))


def join_ways(ways: list[list[list[float]]], report: bool = False,
              tolerance_m: float = JOIN_TOLERANCE_M) -> list[list[float]]:
    """複数の線（OSM の way）から、いちばん長くつながった1本の道を取り出す。

    線の頂点をつないだ網を作り、
      - 端どうしが tolerance_m（既定 JOIN_TOLERANCE_M）以内なら同じ点とみなしてつなぐ（小さな途切れ）
      - 枝道（行き止まりの支線）があれば、最も長い経路だけを残す
      - 同じ名前の離れた道があれば、いちばん長いまとまりだけを使う
    残さなかった部分の長さは report=True のとき表示する。"""
    import heapq
    if not ways:
        raise SystemExit("エラー：対象の線が1本もありません。osm_name と OSM ファイルを確認してください")

    key = lambda p: (round(p[0], 7), round(p[1], 7))
    # 端点どうしの近いものを1つの点にまとめる
    endpoints: list[tuple] = []
    alias: dict = {}
    for w in ways:
        for p in (w[0], w[-1]):
            k = key(p)
            if k in alias:
                continue
            for q in endpoints:
                if dist_m(k, q) <= tolerance_m:
                    alias[k] = q
                    break
            else:
                endpoints.append(k)
                alias[k] = k
    canon = lambda p: alias.get(key(p), key(p))

    graph: dict = {}
    for w in ways:
        pts = [canon(p) for p in w]
        for a, b in zip(pts, pts[1:]):
            if a == b:
                continue
            d = dist_m(a, b)
            graph.setdefault(a, {})[b] = d
            graph.setdefault(b, {})[a] = d

    # つながっているまとまりに分け、いちばん長いものを使う
    seen, comps = set(), []
    for n in graph:
        if n in seen:
            continue
        stack, comp = [n], []
        seen.add(n)
        while stack:
            u = stack.pop()
            comp.append(u)
            for v in graph[u]:
                if v not in seen:
                    seen.add(v)
                    stack.append(v)
        length = sum(d for u in comp for d in graph[u].values()) / 2
        comps.append((length, comp))
    comps.sort(key=lambda c: -c[0])
    total_len, comp = comps[0]

    def farthest(src):
        dist, prev = {src: 0.0}, {src: None}
        heap = [(0.0, src)]
        while heap:
            d, u = heapq.heappop(heap)
            if d > dist[u]:
                continue
            for v, w in graph[u].items():
                nd = d + w
                if nd < dist.get(v, float("inf")):
                    dist[v], prev[v] = nd, u
                    heapq.heappush(heap, (nd, v))
        far = max(dist, key=dist.get)
        return far, dist[far], prev

    # 最も遠い2点の間の経路（網の「直径」）を、その道の本線とみなす
    a, _, _ = farthest(min(comp))
    b, main_len, prev = farthest(a)
    path = []
    node = b
    while node is not None:
        path.append(node)
        node = prev[node]
    if path[0] > path[-1]:  # 経度が小さい方（西側）から始める
        path.reverse()

    if report:
        dropped_branch = total_len - main_len
        dropped_other = sum(c[0] for c in comps[1:])
        if dropped_branch > 50:
            print(f"  注意：枝道など {dropped_branch / 1000:.2f} km を除き、本線 {main_len / 1000:.2f} km を使います")
        if dropped_other > 0:
            print(f"  注意：離れた場所にある同名の線 {len(comps) - 1} まとまり（計 {dropped_other / 1000:.2f} km）を除きました")
    return [list(p) for p in path]


def nearest_index(coords, point) -> tuple[int, float]:
    best = min(range(len(coords)), key=lambda k: dist_m(coords[k], point))
    return best, dist_m(coords[best], point)


# ---------- コマンド ----------

def overpass_link(name: str | None, bbox=DEFAULT_BBOX) -> str:
    """name があれば名前で、なければ範囲内の車が通れる道（名前なしを含む）をすべて取る"""
    return "https://overpass-turbo.eu/?Q=" + urllib.parse.quote(overpass_query(name, bbox)) + "&R"


def parse_bbox(text: str):
    parts = [float(x) for x in text.split(",")]
    if len(parts) != 4:
        raise SystemExit("エラー：--bbox は 南,西,北,東 の4つの数で指定してください")
    return tuple(parts)


def cmd_link(args):
    bbox = parse_bbox(args.bbox) if args.bbox else DEFAULT_BBOX
    print(overpass_link(args.name, bbox))
    if not args.name:
        print("\n名前なしの道も含め、範囲内の道をすべて取ります。build では osm_ids で使う way を指定します。")
    print("\n開いたら Export → GeoJSON → download で保存し、data/osm/<slug>.geojson に置く。")
    print("混雑エラーのときは、設定のサーバーを https://overpass.kumi.systems/api/ に変える。")


OVERPASS_SERVERS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]


def overpass_query(name: str | None, bbox) -> str:
    s, w, n, e = bbox
    if name:
        sel = f'way["name"~"{name}"]({s},{w},{n},{e});'
    else:
        sel = f'way["highway"~"^(track|unclassified|service|tertiary)$"]({s},{w},{n},{e});'
    return f"[out:json][timeout:90];\n{sel}\nout geom;"


def to_geojson(osm: dict) -> dict:
    """Overpass の JSON（out geom）を、Overpass Turbo の書き出しと同じ形の GeoJSON にする"""
    features = []
    for el in osm.get("elements", []):
        if el.get("type") != "way" or "geometry" not in el:
            continue
        coords = [[p["lon"], p["lat"]] for p in el["geometry"]]
        closed = len(coords) > 3 and coords[0] == coords[-1] and not el.get("tags", {}).get("highway")
        geometry = {"type": "Polygon", "coordinates": [coords]} if closed else {"type": "LineString", "coordinates": coords}
        props = {"@id": f"way/{el['id']}", **el.get("tags", {})}
        features.append({"type": "Feature", "properties": props, "geometry": geometry, "id": f"way/{el['id']}"})
    return {"type": "FeatureCollection",
            "copyright": "The data included in this document is from www.openstreetmap.org. The data is made available under ODbL.",
            "features": features}


def cmd_fetch(args):
    """Overpass API から直接取得する。混雑していれば次のサーバーを試す"""
    import time
    import urllib.request
    bbox = parse_bbox(args.bbox) if args.bbox else DEFAULT_BBOX
    data = urllib.parse.urlencode({"data": overpass_query(args.name, bbox)}).encode()
    last_error = None
    for attempt in range(3):
        for server in OVERPASS_SERVERS:
            try:
                req = urllib.request.Request(server, data=data, headers={"User-Agent": "rindo-app/0.1 (github.com/minemurak/rindo-app)"})
                with urllib.request.urlopen(req, timeout=120) as res:
                    osm = json.loads(res.read().decode("utf-8"))
                if osm.get("remark") and not osm.get("elements"):
                    raise RuntimeError(osm["remark"][:200])
                geo = to_geojson(osm)
                out = ROOT / "data" / "osm" / f"{args.slug}.geojson"
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(json.dumps(geo, ensure_ascii=False, indent=1), encoding="utf-8")
                names = sorted({f["properties"].get("name", "（名前なし）") for f in geo["features"]})
                print(f"{server} から {len(geo['features'])} 件を取得 → {out.relative_to(ROOT)}")
                print("含まれる名前：" + "、".join(names[:40]) + ("…" if len(names) > 40 else ""))
                return
            except Exception as e:  # 混雑・タイムアウトなど。次のサーバーへ
                last_error = e
                print(f"失敗：{server}（{str(e)[:120]}）")
        time.sleep(20 * (attempt + 1))
    raise SystemExit(f"エラー：すべてのサーバーで取得できませんでした（最後のエラー：{last_error}）")


GSI_RDCL_URL = "https://cyberjapandata.gsi.go.jp/xyz/experimental_rdcl/{z}/{x}/{y}.geojson"


def cmd_gsi(args):
    """国土地理院の道路中心線（ベクトルタイル z16）を範囲で取り、data/gsi/<slug>.geojson に保存する。
    OSM で線が描かれていない部分を補うために使う。出典「国土地理院」の表示が必要。"""
    import urllib.request
    s, w, n, e = parse_bbox(args.bbox)
    z = 16

    def tile(lon, lat):
        x = int((lon + 180) / 360 * 2 ** z)
        y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * 2 ** z)
        return x, y

    x0, y0 = tile(w, n)
    x1, y1 = tile(e, s)
    if (x1 - x0 + 1) * (y1 - y0 + 1) > 400:
        raise SystemExit("エラー：範囲が広すぎます（タイル400枚まで）")
    features = []
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            url = GSI_RDCL_URL.format(z=z, x=x, y=y)
            req = urllib.request.Request(url, headers={"User-Agent": "rindo-app/0.1 (github.com/minemurak/rindo-app)"})
            try:
                with urllib.request.urlopen(req, timeout=60) as res:
                    tile_geo = json.loads(res.read().decode("utf-8"))
            except urllib.error.HTTPError as err:
                if err.code == 404:  # 道のないタイル
                    continue
                raise
            for f in tile_geo.get("features", []):
                if f.get("geometry", {}).get("type") != "LineString":
                    continue
                props = f.get("properties", {})
                props["@id"] = f"gsi/{props.get('rID', '')}/{x}/{y}/{len(features)}"
                features.append({"type": "Feature", "properties": props, "geometry": f["geometry"]})
    out = ROOT / "data" / "gsi" / f"{args.slug}.geojson"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"type": "FeatureCollection", "attribution": "国土地理院（道路中心線）",
                               "features": features}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{(x1 - x0 + 1) * (y1 - y0 + 1)} 枚のタイルから {len(features)} 本の線を取得 → {out.relative_to(ROOT)}")


def cmd_place(args):
    url = "https://msearch.gsi.go.jp/address-search/AddressSearch?q=" + urllib.parse.quote(args.name)
    print(url)
    print("\n開くと候補が [経度, 緯度] で出る。該当するものを設定ファイルの splits に書く。")


def sql_text(value) -> str:
    if value is None:
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


def cmd_build(args):
    cfg_path = Path(args.config)
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    slug = cfg["slug"]
    road = cfg["road"]
    admin = cfg["administrator"]

    osm = json.loads((ROOT / cfg["osm_file"]).read_text(encoding="utf-8"))
    exclude = set(cfg.get("osm_exclude", []))
    ids = set(cfg.get("osm_ids", []))
    lines_only = [f for f in osm["features"] if f.get("geometry", {}).get("type") == "LineString"]
    if ids:
        # 名前の付いていない道などは、OSM の way の番号で指定する
        picked = [f for f in lines_only if f.get("properties", {}).get("@id") in ids]
        missing = ids - {f["properties"]["@id"] for f in picked}
        if missing:
            raise SystemExit(f"エラー：OSM ファイルに見つからない way があります：{sorted(missing)}")
        label = f"指定した {len(ids)} 本の way"
    else:
        names = cfg["osm_name"] if isinstance(cfg["osm_name"], list) else [cfg["osm_name"]]
        picked = [f for f in lines_only if f.get("properties", {}).get("name") in names]
        label = "「" + "」「".join(names) + "」"
    ways = [f["geometry"]["coordinates"] for f in picked
            if f.get("properties", {}).get("@id") not in exclude]
    print(f"OSM から{label}の線を {len(ways)} 本読み込み")

    # 県境やOSMの描き方で線が少し離れている道は、config の join_tolerance_m で許す距離を広げる
    coords = join_ways(ways, report=True, tolerance_m=cfg.get("join_tolerance_m", JOIN_TOLERANCE_M))
    if cfg.get("reverse"):
        coords.reverse()
    total = line_length_m(coords)
    print(f"結合：{len(coords)} 点、全長 {total / 1000:.2f} km、始点 {coords[0]} → 終点 {coords[-1]}")

    # 境目で区切る
    cut_points = []
    for sp in cfg.get("splits", []):
        idx, off = nearest_index(coords, (sp["lon"], sp["lat"]))
        flag = "  ※線から離れています。位置を確認してください" if off > SPLIT_WARN_M else ""
        print(f"境目「{sp['name']}」：線から {off:.0f} m、始点から {line_length_m(coords[:idx + 1]) / 1000:.2f} km{flag}")
        cut_points.append(idx)
    if cut_points != sorted(cut_points):
        raise SystemExit("エラー：splits は始点に近い順に並べてください（または reverse を切り替える）")

    bounds = [0] + cut_points + [len(coords) - 1]
    seg_cfgs = cfg["segments"]
    if len(seg_cfgs) != len(bounds) - 1:
        raise SystemExit(f"エラー：segments は {len(bounds) - 1} 件必要です（splits の数 + 1）")

    features = []
    seg_admins = []  # 区間ごとの管理者（県境をまたぐ道は区間で管理者が変わる）
    for i, seg in enumerate(seg_cfgs):
        part = coords[bounds[i]:bounds[i + 1] + 1]
        seg_admin = seg.get("administrator", admin)
        seg_admins.append(seg_admin)
        features.append({
            "type": "Feature",
            "properties": {
                "road": road, "administrator": seg_admin["name"], "note": seg["note"],
                "surface": seg.get("surface"), "general_access": seg.get("general_access", "不明"),
                "difficulty": seg.get("difficulty"),
                "length_km": round(line_length_m(part) / 1000, 2),
            },
            "geometry": {"type": "LineString", "coordinates": part},
        })

    restrictions = cfg.get("restrictions", [])
    for r in restrictions:
        if not 0 <= r["segment"] < len(features):
            raise SystemExit(f"エラー：restrictions の segment {r['segment']} が範囲外です")

    # GeoJSON
    out_geo = ROOT / "data" / "segments" / f"{slug}.geojson"
    out_geo.parent.mkdir(parents=True, exist_ok=True)
    out_geo.write_text(json.dumps({"type": "FeatureCollection", "features": features},
                                  ensure_ascii=False), encoding="utf-8")

    # SQL
    lines = [
        f"-- {road}（{slug}）の区間データ。tools/road.py build {cfg_path.as_posix()} で生成。手で編集しない。",
        "-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。",
    ]
    for src in cfg.get("sources", []):
        lines.append(f"-- 出典：{src}")
    lines += [
        "", "set search_path = public, extensions;", "",
    ]
    for a in {a["name"]: a for a in [admin] + seg_admins}.values():
        lines += [
            f"insert into administrators (name, kind) values ({sql_text(a['name'])}, {sql_text(a['kind'])})",
            "on conflict (name) do nothing;",
        ]
    lines += [
        f"insert into roads (name, kind) values ({sql_text(road)}, {sql_text(cfg.get('kind', '林道'))})",
        "on conflict (name) do nothing;", "",
        f"delete from segments where road_id = (select id from roads where name = {sql_text(road)});", "",
    ]
    for f in features:
        p = f["properties"]
        geojson = json.dumps(f["geometry"], separators=(",", ":"))
        lines += [
            f"-- {p['note']}（約{p['length_km']:.1f}km）",
            "insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)",
            f"select r.id, a.id, {sql_text(p['surface'])}, {p['difficulty'] if p['difficulty'] else 'null'}, "
            f"{sql_text(p['general_access'])}, {sql_text(p['note'])},",
            f"  ST_SetSRID(ST_GeomFromGeoJSON('{geojson}'), 4326)",
            "from roads r, administrators a",
            f"where r.name = {sql_text(road)} and a.name = {sql_text(p['administrator'])};", "",
        ]
    for r in restrictions:
        note = features[r["segment"]]["properties"]["note"]
        lines += [
            f"-- 規制：{note}",
            "insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)",
            f"select s.id, {sql_text(r['kind'])}, {sql_text(r.get('reason'))}, {sql_text(r.get('starts_on'))}, "
            f"{sql_text(r.get('ends_on'))},",
            f"  {sql_text(r.get('source_url'))}, {sql_text(r.get('fetched_at'))}",
            "from segments s join roads r on r.id = s.road_id",
            f"where r.name = {sql_text(road)} and s.note = {sql_text(note)};", "",
        ]
    lines += [
        "-- 確認：この林道の区間と規制の数",
        "select s.note as 区間, count(x.id) as 規制数",
        "from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id",
        f"where r.name = {sql_text(road)} group by s.id, s.note order by s.id;",
    ]
    out_sql = ROOT / "supabase" / "roads" / f"{slug}.sql"
    out_sql.parent.mkdir(parents=True, exist_ok=True)
    out_sql.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("\n区間：")
    for i, f in enumerate(features):
        p = f["properties"]
        mark = "  規制あり" if any(r["segment"] == i for r in restrictions) else ""
        print(f"  {i}. {p['note']}  {p['length_km']:.2f} km  一般通行：{p['general_access']}{mark}")
    print(f"\n出力：{out_geo.relative_to(ROOT)}\n      {out_sql.relative_to(ROOT)}")


def cmd_bundle(args):
    """supabase/roads/*.sql を1つにまとめ、supabase/all-roads.sql を作る（SQL Editor で1回貼るだけで全林道を登録）"""
    files = sorted((ROOT / "supabase" / "roads").glob("*.sql"))
    if not files:
        raise SystemExit("エラー：supabase/roads に SQL がありません。先に build してください")
    parts = ["-- 全林道の区間データ。tools/road.py bundle で生成。手で編集しない。",
             "-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。", ""]
    for f in files:
        body = f.read_text(encoding="utf-8")
        # 各ファイル末尾の確認用 select は外し、最後にまとめて1つだけ置く
        body = body.split("-- 確認：")[0].rstrip()
        parts += [f"-- ===== {f.stem} =====", body, ""]
    parts += [
        "-- 確認：林道ごとの区間数と規制数",
        "select r.name as 林道, count(distinct s.id) as 区間数, count(x.id) as 規制数",
        "from roads r join segments s on s.road_id = r.id left join restrictions x on x.segment_id = s.id",
        "group by r.name order by r.name;",
    ]
    out = ROOT / "supabase" / "all-roads.sql"
    out.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"{len(files)} 本の林道をまとめました → {out.relative_to(ROOT)}（{out.stat().st_size / 1024:.0f} KB）")


def main(argv=None):
    parser = argparse.ArgumentParser(description="林道データ整備ツール")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("link", help="OSM から線を取る Overpass Turbo のリンクを出す")
    p.add_argument("name", nargs="?", help="林道名の一部。正規表現も可（例：城[峰峯]）。省略すると範囲内の道をすべて取る")
    p.add_argument("--bbox", help="範囲 南,西,北,東（例：36.05,138.98,36.13,139.08）。省略時は3都県全体")
    p.set_defaults(func=cmd_link)
    p = sub.add_parser("fetch", help="Overpass API から直接取得して data/osm/<slug>.geojson に保存する")
    p.add_argument("slug", help="保存名（例：jomine-1）")
    p.add_argument("name", nargs="?", help="林道名の一部。正規表現も可。省略すると範囲内の道をすべて取る")
    p.add_argument("--bbox", help="範囲 南,西,北,東。省略時は3都県全体")
    p.set_defaults(func=cmd_fetch)
    p = sub.add_parser("gsi", help="国土地理院の道路中心線を範囲で取得して data/gsi/<slug>.geojson に保存する")
    p.add_argument("slug")
    p.add_argument("--bbox", required=True, help="南,西,北,東")
    p.set_defaults(func=cmd_gsi)
    p = sub.add_parser("place", help="国土地理院の地名検索のリンクを出す")
    p.add_argument("name", help="地名（例：風早峠）")
    p.set_defaults(func=cmd_place)
    p = sub.add_parser("build", help="設定ファイルから区間データと SQL を作る")
    p.add_argument("config", help="data/roads/<slug>.json")
    p.set_defaults(func=cmd_build)
    p = sub.add_parser("bundle", help="全林道の SQL を supabase/all-roads.sql にまとめる")
    p.set_defaults(func=cmd_bundle)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
