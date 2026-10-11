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


def join_ways(ways: list[list[list[float]]]) -> list[list[float]]:
    """複数の線（OSM の way）を、端点のつながりをたどって1本にする。
    枝分かれや離れた線があればエラーにする。"""
    if not ways:
        raise SystemExit("エラー：対象の線が1本もありません。osm_name と OSM ファイルを確認してください")
    remaining = [list(map(tuple, w)) for w in ways]

    def near(p, q):
        return dist_m(p, q) <= JOIN_TOLERANCE_M

    # 端点のうち、ほかの線とつながっていないものを始点の候補にする
    ends = []
    for i, w in enumerate(remaining):
        for p in (w[0], w[-1]):
            touching = sum(1 for j, v in enumerate(remaining) if j != i and (near(p, v[0]) or near(p, v[-1])))
            if touching == 0:
                ends.append(p)
    if len(ends) != 2:
        raise SystemExit(
            f"エラー：線の端が{len(ends)}か所あり、1本の道につなげられません（枝分かれや途切れの可能性）。"
            "QGIS などで線を確認し、不要な way を osm_exclude に書いてください")

    start = min(ends)  # 経度が小さい方（西側）から始める。向きは設定の reverse で反転できる
    chain = [start]
    current = start
    while remaining:
        for i, w in enumerate(remaining):
            if near(current, w[0]):
                piece = w
                break
            if near(current, w[-1]):
                piece = w[::-1]
                break
        else:
            raise SystemExit("エラー：途中で線がつながりません。osm_exclude や JOIN_TOLERANCE_M を見直してください")
        remaining.pop(i)
        chain.extend(piece[1:])
        current = piece[-1]
    return [list(p) for p in chain]


def nearest_index(coords, point) -> tuple[int, float]:
    best = min(range(len(coords)), key=lambda k: dist_m(coords[k], point))
    return best, dist_m(coords[best], point)


# ---------- コマンド ----------

def overpass_link(name: str, bbox=DEFAULT_BBOX) -> str:
    s, w, n, e = bbox
    query = f'[out:json][timeout:90];\nway["name"~"{name}"]({s},{w},{n},{e});\nout geom;'
    return "https://overpass-turbo.eu/?Q=" + urllib.parse.quote(query) + "&R"


def cmd_link(args):
    print(overpass_link(args.name))
    print("\n開いたら Export → GeoJSON → download で保存し、data/osm/<slug>.geojson に置く。")
    print("混雑エラーのときは、設定のサーバーを https://overpass.kumi.systems/api/ に変える。")


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
    ways = [f["geometry"]["coordinates"] for f in osm["features"]
            if f.get("geometry", {}).get("type") == "LineString"
            and f.get("properties", {}).get("name") == cfg["osm_name"]
            and f.get("properties", {}).get("@id") not in exclude]
    print(f"OSM から「{cfg['osm_name']}」の線を {len(ways)} 本読み込み")

    coords = join_ways(ways)
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
    for i, seg in enumerate(seg_cfgs):
        part = coords[bounds[i]:bounds[i + 1] + 1]
        features.append({
            "type": "Feature",
            "properties": {
                "road": road, "administrator": admin["name"], "note": seg["note"],
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
        f"insert into administrators (name, kind) values ({sql_text(admin['name'])}, {sql_text(admin['kind'])})",
        "on conflict (name) do nothing;",
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
            f"where r.name = {sql_text(road)} and a.name = {sql_text(admin['name'])};", "",
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


def main(argv=None):
    parser = argparse.ArgumentParser(description="林道データ整備ツール")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("link", help="OSM から線を取る Overpass Turbo のリンクを出す")
    p.add_argument("name", help="林道名の一部（例：城峰）")
    p.set_defaults(func=cmd_link)
    p = sub.add_parser("place", help="国土地理院の地名検索のリンクを出す")
    p.add_argument("name", help="地名（例：風早峠）")
    p.set_defaults(func=cmd_place)
    p = sub.add_parser("build", help="設定ファイルから区間データと SQL を作る")
    p.add_argument("config", help="data/roads/<slug>.json")
    p.set_defaults(func=cmd_build)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
