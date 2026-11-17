"""
国土数値情報の zip から東京23区の分を切り出し、sql/10_ref_mlit.sql（REF スキーマの DDL + INSERT）を作るスクリプト。
講師が事前に1回だけ実行する（受講者は実行しない）。生成された SQL を配布物に含める。

使い方（Python 3.10+、pip install shapely pyshp）:
    python tools/prepare_mlit.py --raw mlit_raw --out sql/10_ref_mlit.sql

mlit_raw/ に置く zip（ファイル名の先頭で判定）:
    S12-*.zip   駅別乗降客数（全国）
    N02-*.zip   鉄道（全国）
    N03-*.zip   行政区域（東京都）
    *fpop* / *500m* / *mesh* を含む zip   500mメッシュ別将来推計人口（東京都）
各 zip は GeoJSON があれば GeoJSON を、無ければ Shapefile を読む。

属性コードは版によって変わることがあるため、自動判定した列を最後に表示する。必ず目で確認すること。
判定が外れたときは --mesh-total-col などで列名を指定する。
"""
import argparse, glob, io, json, os, re, sys, zipfile
from collections import Counter, defaultdict

import shapefile  # pyshp
from shapely.geometry import shape, mapping, Point
from shapely.ops import unary_union

WARD_CODES = {f"131{n:02d}" for n in range(1, 24)}   # 13101〜13123 = 東京23区


# ---------------------------------------------------------------- 読み込み
def read_features(zpath, prefer=None):
    """zip 内の GeoJSON（無ければ Shapefile）を読み、[(props, geometry)] を返す。prefer はファイル名に含む文字列"""
    z = zipfile.ZipFile(zpath)
    names = z.namelist()
    gj = [n for n in names if n.lower().endswith(".geojson")]
    shp = [n for n in names if n.lower().endswith(".shp")]
    if prefer:
        gj = [n for n in gj if prefer in os.path.basename(n)] or gj
        shp = [n for n in shp if prefer in os.path.basename(n)] or shp
    if gj:
        n = sorted(gj, key=lambda x: -z.getinfo(x).file_size)[0]
        data = json.loads(z.read(n).decode("utf-8-sig"))
        return n, [(f.get("properties") or {}, f.get("geometry")) for f in data["features"] if f.get("geometry")]
    if shp:
        n = sorted(shp, key=lambda x: -z.getinfo(x).file_size)[0]
        base = n[:-4]
        enc = "utf-8"
        for ext in (".cpg", ".CPG"):
            if base + ext in names:
                enc = z.read(base + ext).decode("ascii", "ignore").strip() or enc
        def f(ext):
            for e in (ext, ext.upper()):
                if base + e in names:
                    return io.BytesIO(z.read(base + e))
        for e in (enc, "cp932", "utf-8"):
            try:
                r = shapefile.Reader(shp=f(".shp"), dbf=f(".dbf"), shx=f(".shx"), encoding=e)
                recs = [(dict(zip([fl[0] for fl in r.fields[1:]], sr.record)), sr.shape.__geo_interface__) for sr in r.iterShapeRecords()]
                return n, recs
            except UnicodeDecodeError:
                continue
    xml = [n for n in names if n.lower().endswith(".xml") and "KS-META" not in n]
    if xml:
        n = sorted(xml, key=lambda x: -z.getinfo(x).file_size)[0]
        return n, read_ksj_gml(z.open(n))
    raise SystemExit(f"{zpath}: GeoJSON も Shapefile も見つかりません: {names[:10]}")


def read_ksj_gml(fp):
    """国土数値情報の GML（Curve → Surface → 属性要素 の参照構造、座標は 緯度 経度 の順）を [(props, geometry)] にする"""
    import xml.etree.ElementTree as ET
    GML, KSJ, XL = "{http://schemas.opengis.net/gml/3.2.1/gml.xsd}", "{http://nlftp.mlit.go.jp/ksj/schemas/ksj-app}", "{http://www.w3.org/1999/xlink}"
    curves, surfaces, feats = {}, {}, []
    for _, el in ET.iterparse(fp, events=("end",)):
        tag = el.tag
        if tag == GML + "Curve":
            v = [float(x) for x in el.find(f".//{GML}posList").text.split()]
            curves[el.get(GML + "id")] = [(v[i + 1], v[i]) for i in range(0, len(v), 2)]
            el.clear()
        elif tag == GML + "Surface":
            surfaces[el.get(GML + "id")] = [m.get(XL + "href").lstrip("#").lstrip("_") for m in el.iter(GML + "curveMember")]
            el.clear()
        elif tag.startswith(KSJ) and el.find(KSJ + "bounds") is not None:
            props = {c.tag[len(KSJ):]: c.text for c in el if c.tag != KSJ + "bounds"}
            sid = el.find(KSJ + "bounds").get(XL + "href").lstrip("#")
            rings = [curves[c] for c in surfaces.get(sid, []) if c in curves]
            if rings:
                feats.append((props, {"type": "Polygon", "coordinates": rings}))
            el.clear()
    return feats


def find_zip(raw, patterns):
    for p in patterns:
        hits = sorted(glob.glob(os.path.join(raw, p)))
        if hits:
            return hits[-1]
    raise SystemExit(f"{raw} に {patterns} の zip がありません")


def q(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def num(v):
    return "NULL" if v is None else repr(round(float(v), 6))


# ---------------------------------------------------------------- 23区の境界（N03）
def build_wards(path, tol):
    name, feats = read_features(path)
    groups = defaultdict(list)
    names = {}
    code_key = None
    for props, geom in feats:
        if code_key is None:
            code_key = next((k for k in props if re.fullmatch(r"N03_007", k)), None) or \
                       next(k for k, v in props.items() if isinstance(v, str) and re.fullmatch(r"13\d{3}", v or ""))
        code = props.get(code_key)
        if code in WARD_CODES:
            groups[code].append(shape(geom))
            names[code] = props.get("N03_004") or names.get(code)
    wards = {}
    for code, geoms in sorted(groups.items()):
        g = unary_union(geoms)
        wards[code] = dict(name=names[code], geom=g, simple=g.simplify(tol, preserve_topology=True))
    print(f"[N03] {name}: 区コード列={code_key}, 23区 {len(wards)} 区")
    if len(wards) != 23:
        print("  !! 23区がそろっていません。ファイルを確認してください")
    return wards


def ward_of(pt, wards):
    for code, w in wards.items():
        if w["geom"].contains(pt):
            return code, w["name"]
    return None, None


# ---------------------------------------------------------------- 駅別乗降客数（S12）
def build_stations(path, wards, buffer_deg):
    name, feats = read_features(path)
    keys = list(feats[0][0].keys())
    # 乗降客数の列：S12_009, S12_013, ... の4列おき（年度ごとに 重複/有無/備考/乗降客数 の4列）を数値で判定
    idx = {k: int(m.group(1)) for k in keys if (m := re.fullmatch(r"S12_0*(\d+)", k))}
    pax_keys = sorted([k for k, i in idx.items() if i >= 9 and (i - 9) % 4 == 0], key=lambda k: idx[k])
    if not pax_keys:
        raise SystemExit(f"[S12] 乗降客数の列を判定できません: {keys}")
    group_key = next((k for k in keys if k.lower().endswith("g") and k.startswith("S12_001")), None)
    latest = pax_keys[-1]
    year = 2011 + (idx[latest] - 9) // 4
    area = unary_union([w["geom"] for w in wards.values()]).buffer(buffer_deg)
    groups = defaultdict(list)
    for props, geom in feats:
        g = shape(geom)
        c = g.centroid if g.geom_type != "Point" else g
        if not area.contains(c):
            continue
        # 最新年度が 0・空なら、さかのぼって直近の値を使う
        pax, pyear = None, None
        for k in reversed(pax_keys):
            v = props.get(k)
            try:
                v = float(v)
            except (TypeError, ValueError):
                v = None
            if v and v > 0:
                pax, pyear = v, 2011 + (idx[k] - 9) // 4
                break
        gid = str(props.get(group_key) or props.get("S12_001c") or props.get("S12_001"))
        groups[gid].append(dict(name=props.get("S12_001"), op=props.get("S12_002"), line=props.get("S12_003"),
                                lat=c.y, lon=c.x, pax=pax, year=pyear))
    rows = []
    for gid, ms in groups.items():
        lat = sum(m["lat"] for m in ms) / len(ms)
        lon = sum(m["lon"] for m in ms) / len(ms)
        code, wname = ward_of(Point(lon, lat), wards)
        paxes = [m["pax"] for m in ms if m["pax"]]
        rows.append(dict(id=gid, name=Counter(m["name"] for m in ms).most_common(1)[0][0],
                         ops="・".join(sorted({m["op"] for m in ms if m["op"]})),
                         lines="・".join(sorted({m["line"] for m in ms if m["line"]})),
                         pax=sum(paxes) if paxes else None,
                         year=max((m["year"] for m in ms if m["year"]), default=None),
                         lat=lat, lon=lon, ward=code, wname=wname))
    inside = [r for r in rows if r["ward"]]
    print(f"[S12] {name}: グループ列={group_key}, 乗降客数の列={pax_keys[0]}〜{latest}（最新 {year} 年度）")
    print(f"  駅グループ {len(rows)}（うち23区内 {len(inside)}）。乗降客数の上位5：",
          [(r["name"], int(r["pax"] or 0)) for r in sorted(inside, key=lambda r: -(r["pax"] or 0))[:5]])
    return rows, year


# ---------------------------------------------------------------- 鉄道路線（N02）
def build_rail(path, wards, tol, buffer_deg):
    name, feats = read_features(path, prefer="RailroadSection")
    area = unary_union([w["geom"] for w in wards.values()]).buffer(buffer_deg)
    by = defaultdict(list)
    for props, geom in feats:
        g = shape(geom)
        if g.geom_type not in ("LineString", "MultiLineString") or not g.intersects(area):
            continue
        by[(props.get("N02_004"), props.get("N02_003"))].append(g.intersection(area))
    rows = []
    for (op, line), gs in sorted(by.items(), key=lambda x: (str(x[0][0]), str(x[0][1]))):
        g = unary_union(gs).simplify(tol, preserve_topology=False)
        if not g.is_empty:
            rows.append(dict(op=op, line=line, geojson=json.dumps(mapping(g), separators=(",", ":"))))
    print(f"[N02] {name}: 路線 {len(rows)}")
    return rows


# ---------------------------------------------------------------- 500m メッシュ人口
def build_mesh(path, wards, total_col, old_col):
    name, feats = read_features(path)
    keys = list(feats[0][0].keys())
    mesh_key = next((k for k in keys if "MESH" in k.upper()), keys[0])
    city_key = next((k for k in keys if k.upper() in ("SHICODE", "CITYCODE", "CITY_CODE", "ADMINISTRATIVEAREACODE")), None)
    total_col = total_col or next((k for k in keys if re.fullmatch(r"PTN_?2020|TOTALPOPULATIONOF2020", k.upper())), None)
    # GML 版には 2020 年の65歳以上が無いので、いちばん近い 2025 年の推計値で代用する
    old_col = old_col or next((k for k in keys if k.upper() in ("PTC_2020", "OVER65YEARSOLDPOPULATIONIN2025")), None)
    if total_col is None:
        print("[MESH] 列名を判定できません。--mesh-total-col / --mesh-old-col で指定してください。列：", keys)
        raise SystemExit(1)
    rows = []
    for props, geom in feats:
        g = shape(geom)
        c = g.centroid
        code = str(props.get(city_key)) if city_key else None
        if code not in WARD_CODES:
            code, _ = ward_of(c, wards)
        if code not in WARD_CODES:
            continue
        def val(k):
            try:
                return float(props.get(k)) if k else None
            except (TypeError, ValueError):
                return None
        rows.append(dict(mesh=str(props.get(mesh_key)), lat=c.y, lon=c.x, pop=val(total_col), old=val(old_col),
                         ward=code, wname=wards[code]["name"]))
    print(f"[MESH] {name}: メッシュ列={mesh_key}, 市区町村列={city_key}, 2020総人口={total_col}, 2020高齢者(65+)={old_col}")
    print(f"  23区のメッシュ {len(rows)}、2020年人口の合計 {sum(r['pop'] or 0 for r in rows):,.0f}")
    return rows


# ---------------------------------------------------------------- SQL 出力
def inserts(table, cols, rows, chunk=400):
    out = []
    for i in range(0, len(rows), chunk):
        vals = ",\n".join("(" + ", ".join(r) + ")" for r in rows[i:i + chunk])
        out.append(f"INSERT INTO {table} ({', '.join(cols)}) VALUES\n{vals};\n")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default="mlit_raw")
    ap.add_argument("--out", default="sql/10_ref_mlit.sql")
    ap.add_argument("--simplify", type=float, default=0.0003, help="区境界・路線の単純化（度。0.0003 ≒ 30m）")
    ap.add_argument("--buffer", type=float, default=0.02, help="駅・路線を23区の外にどれだけ広げて含めるか（度。0.02 ≒ 2km）")
    ap.add_argument("--mesh-total-col")
    ap.add_argument("--mesh-old-col", help="2020年の65歳以上人口の列名")
    ap.add_argument("--license-note", default="要確認（国土数値情報ダウンロードサイトの各データの利用条件を記入）")
    a = ap.parse_args()

    wards = build_wards(find_zip(a.raw, ["N03*.zip"]), a.simplify)
    stations, year = build_stations(find_zip(a.raw, ["S12*.zip"]), wards, a.buffer)
    rail = build_rail(find_zip(a.raw, ["N02*.zip"]), wards, a.simplify, a.buffer)
    mesh = build_mesh(find_zip(a.raw, ["*fpop*.zip", "*500m*.zip", "*mesh*.zip", "*Mesh*.zip"]), wards, a.mesh_total_col, a.mesh_old_col)

    L = ["-- =====================================================================",
         "-- 10_ref_mlit.sql：国土交通省「国土数値情報」から作った REF テーブル（tools/prepare_mlit.py で自動生成。手で編集しない）",
         f"-- 駅別乗降客数（S12、乗降客数は最新 {year} 年度。0・欠損は直近年度の値）／鉄道（N02）／行政区域（N03）／500mメッシュ別将来推計人口",
         "-- 出典：国土交通省 国土数値情報（https://nlftp.mlit.go.jp/ksj/）を加工して作成",
         "-- =====================================================================", ""]
    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.WARD_RAW (WARD_CODE STRING, WARD_NAME STRING, GEOJSON STRING);\n")
    L += inserts("DF_HANDSON.REF.WARD_RAW", ["WARD_CODE", "WARD_NAME", "GEOJSON"],
                 [[q(c), q(w["name"]), q(json.dumps(mapping(w["simple"]), separators=(",", ":")))] for c, w in wards.items()], chunk=4)
    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.WARD AS\nSELECT WARD_CODE, WARD_NAME, GEOJSON, TO_GEOGRAPHY(GEOJSON, TRUE) AS GEO FROM DF_HANDSON.REF.WARD_RAW;\n")
    L.append("DROP TABLE DF_HANDSON.REF.WARD_RAW;\n")

    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.STATION_RAW (STATION_ID STRING, STATION_NAME STRING, OPERATORS STRING, LINES STRING, "
             "PASSENGERS NUMBER, PASSENGERS_YEAR NUMBER, LAT FLOAT, LON FLOAT, WARD_CODE STRING, WARD_NAME STRING);\n")
    L += inserts("DF_HANDSON.REF.STATION_RAW", ["STATION_ID", "STATION_NAME", "OPERATORS", "LINES", "PASSENGERS", "PASSENGERS_YEAR", "LAT", "LON", "WARD_CODE", "WARD_NAME"],
                 [[q(r["id"]), q(r["name"]), q(r["ops"]), q(r["lines"]), "NULL" if r["pax"] is None else str(int(r["pax"])),
                   "NULL" if r["year"] is None else str(r["year"]), num(r["lat"]), num(r["lon"]), q(r["ward"]), q(r["wname"])] for r in stations])
    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.STATION AS\nSELECT *, ST_MAKEPOINT(LON, LAT) AS GEO FROM DF_HANDSON.REF.STATION_RAW;\n")
    L.append("DROP TABLE DF_HANDSON.REF.STATION_RAW;\n")

    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.RAIL (OPERATOR STRING, LINE_NAME STRING, GEOJSON STRING);\n")
    L += inserts("DF_HANDSON.REF.RAIL", ["OPERATOR", "LINE_NAME", "GEOJSON"], [[q(r["op"]), q(r["line"]), q(r["geojson"])] for r in rail], chunk=20)

    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.MESH_POP_RAW (MESH_CODE STRING, LAT FLOAT, LON FLOAT, POP_2020 FLOAT, POP_65PLUS_2020 FLOAT, WARD_CODE STRING, WARD_NAME STRING);\n")
    L += inserts("DF_HANDSON.REF.MESH_POP_RAW", ["MESH_CODE", "LAT", "LON", "POP_2020", "POP_65PLUS_2020", "WARD_CODE", "WARD_NAME"],
                 [[q(r["mesh"]), num(r["lat"]), num(r["lon"]), num(r["pop"]), num(r["old"]), q(r["ward"]), q(r["wname"])] for r in mesh])
    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.MESH_POP AS\nSELECT *, ST_MAKEPOINT(LON, LAT) AS GEO FROM DF_HANDSON.REF.MESH_POP_RAW;\n")
    L.append("DROP TABLE DF_HANDSON.REF.MESH_POP_RAW;\n")

    L.append("CREATE OR REPLACE TABLE DF_HANDSON.REF.SOURCE (DATASET STRING, FILE STRING, PROVIDER STRING, LICENSE STRING);\n")
    srcs = [(d, os.path.basename(find_zip(a.raw, p))) for d, p in
            [("駅別乗降客数", ["S12*.zip"]), ("鉄道", ["N02*.zip"]), ("行政区域", ["N03*.zip"]),
             ("500mメッシュ別将来推計人口", ["*fpop*.zip", "*500m*.zip", "*mesh*.zip", "*Mesh*.zip"])]]
    L += inserts("DF_HANDSON.REF.SOURCE", ["DATASET", "FILE", "PROVIDER", "LICENSE"],
                 [[q(d), q(f), q("国土交通省 国土数値情報"), q(a.license_note)] for d, f in srcs])

    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print(f"→ {a.out}（{os.path.getsize(a.out) / 1024:,.0f} KB）")


if __name__ == "__main__":
    main()
