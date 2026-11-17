-- =====================================================================
-- 20_src_synth.sql：合成データ（架空チェーン「SNOW BAKERY」の店舗・売上・天気・販促）
--   ・店舗の位置と需要の強さは、国土交通省の実データ（REF.STATION の乗降客数、REF.MESH_POP の人口）から決める
--   ・売上は「客数 × 客単価」。曜日・祝日・季節・天気・販促・新店効果・成長・イベントの要因を掛け合わせる
--   ・HASH() を乱数代わりに使うので、何度実行しても同じデータになる
--   ・期間：売上 2024-10-01〜2026-09-30、カレンダー・天気・販促は 2026-10-31 まで（10月は「未来」として予測に使う）
-- Marketplace などの実データに切り替えるときは、このファイルは実行せず 30 番台のアダプターを差し替える
-- =====================================================================

-- 日付の背骨（2024-10-01〜2026-10-31 の 761日）
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.DATES AS
SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2024-10-01'::DATE) AS ds
FROM TABLE(GENERATOR(ROWCOUNT => 761));


-- 天気（合成。東京の平年の気温・降水の傾向を近似）。気象庁の過去データに差し替える前提の仮データ
-- 2026-08-25 は台風の接近（降水 120mm）を仕込む
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.WEATHER AS
WITH c AS (
  SELECT ds, DAYOFYEAR(ds) AS doy,
         (MOD(ABS(HASH(ds, 't1')), 1000000) + 0.5) / 1e6 AS u1,
         MOD(ABS(HASH(ds, 't2')), 1000000) / 1e6 AS u2,
         MOD(ABS(HASH(ds, 'rain')), 1000000) / 1e6 AS u_rain,
         MOD(ABS(HASH(ds, 'pamt')), 1000000) / 1e6 AS u_amt
  FROM DF_HANDSON.SRC_SYNTH.DATES)
SELECT 'TOKYO' AS weather_station_id, ds,
       ROUND(16.1 + 10.8 * COS(2 * PI() * (doy - 217) / 365.25)
             + 1.8 * SQRT(-2 * LN(u1)) * COS(2 * PI() * u2), 1) AS temp_avg,
       CASE WHEN ds = '2026-08-25'::DATE THEN 120.0
            WHEN u_rain < 0.30 + 0.10 * COS(2 * PI() * (doy - 190) / 365.25) THEN ROUND(-12 * LN(1 - u_amt * 0.999), 1)
            ELSE 0.0 END AS precip_mm
FROM c;


-- 販促カレンダー（チェーン全体）：毎月第2金曜からの3日間「ポイント2倍」＋ランダムに約3%の日「新商品フェア」
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.PROMO AS
WITH fri AS (
  SELECT ds AS fri FROM DF_HANDSON.SRC_SYNTH.DATES
  WHERE DAYOFWEEKISO(ds) = 5 AND DAY(ds) BETWEEN 8 AND 14)
SELECT d.ds,
       CASE WHEN f.fri IS NOT NULL THEN 'ポイント2倍'
            WHEN MOD(ABS(HASH(d.ds, 'promo')), 1000000) / 1e6 < 0.03 THEN '新商品フェア' END AS promo_name,
       promo_name IS NOT NULL AS is_promo
FROM DF_HANDSON.SRC_SYNTH.DATES d
LEFT JOIN fri f ON d.ds BETWEEN f.fri AND DATEADD(day, 2, f.fri);


-- 店舗マスタ（約100店＋開業予定2店）
--   駅ナカ（STATION_IN）    ：乗降客数の上位25駅の構内
--   駅前（STATION_FRONT）   ：乗降客数 11〜150位の駅から約40%を抽出し、駅から 80〜250m の位置（最大45店）
--   住宅街（RESIDENTIAL）   ：最寄り駅から600m以上離れた人口の多いメッシュから30店
--   開業予定（2026年10月）  ：乗降客数 151〜400位の駅から2店（売上の履歴なし。②で予測する）
--   開業日：15店は 2025-03〜2026-08 に開業した新店、残りは 2015〜2024 年開業
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.STORE_MASTER AS
WITH st AS (
  SELECT station_id, station_name, lat, lon, ward_code, ward_name,
         ROW_NUMBER() OVER (ORDER BY passengers DESC NULLS LAST, station_id) AS rk
  FROM DF_HANDSON.REF.STATION
  WHERE ward_code IS NOT NULL),   -- 23区の中の駅だけ（REF.STATION には区境の外の駅も含む）
in_store AS (
  SELECT 'STATION_IN' AS store_format, station_id AS anchor_id, station_name || '駅ナカ店' AS store_name,
         lat, lon, ward_code, ward_name, FALSE AS is_planned
  FROM st WHERE rk <= 25),
front_cand AS (
  SELECT st.*,
         80 + 170 * MOD(ABS(HASH(station_id, 'fd')), 1000000) / 1e6 AS d_m,
         2 * PI() * MOD(ABS(HASH(station_id, 'fb')), 1000000) / 1e6 AS bearing
  FROM st
  WHERE rk BETWEEN 11 AND 150 AND MOD(ABS(HASH(station_id, 'front')), 1000000) / 1e6 < 0.40
  QUALIFY ROW_NUMBER() OVER (ORDER BY rk) <= 45),
front_store AS (
  SELECT 'STATION_FRONT', station_id, station_name || '駅前店',
         lat + d_m * SIN(bearing) / 111320,
         lon + d_m * COS(bearing) / (111320 * COS(RADIANS(lat))),
         ward_code, ward_name, FALSE
  FROM front_cand),
mesh_d AS (
  SELECT m.mesh_code, m.lat, m.lon, m.pop_2020, m.ward_code, m.ward_name, MIN(ST_DISTANCE(m.geo, s.geo)) AS d_st
  FROM DF_HANDSON.REF.MESH_POP m
  JOIN DF_HANDSON.REF.STATION s ON ST_DWITHIN(m.geo, s.geo, 5000)
  GROUP BY m.mesh_code, m.lat, m.lon, m.pop_2020, m.ward_code, m.ward_name),
res_cand AS (
  SELECT * FROM mesh_d WHERE d_st >= 600
  QUALIFY ROW_NUMBER() OVER (ORDER BY pop_2020 DESC, mesh_code) <= 150),
res_pick AS (
  SELECT * FROM res_cand WHERE MOD(ABS(HASH(mesh_code, 'res')), 1000000) / 1e6 < 0.25
  QUALIFY ROW_NUMBER() OVER (ORDER BY pop_2020 DESC, mesh_code) <= 30),
res_store AS (
  SELECT 'RESIDENTIAL', mesh_code,
         REPLACE(ward_name, '区', '') || '住宅街' || ROW_NUMBER() OVER (PARTITION BY ward_code ORDER BY pop_2020 DESC, mesh_code) || '号店',
         lat, lon, ward_code, ward_name, FALSE
  FROM res_pick),
planned_store AS (
  SELECT 'STATION_FRONT', station_id, station_name || '駅前店', lat + 120 / 111320, lon, ward_code, ward_name, TRUE
  FROM st
  WHERE rk BETWEEN 151 AND 400 AND MOD(ABS(HASH(station_id, 'plan')), 1000000) / 1e6 < 0.05
  QUALIFY ROW_NUMBER() OVER (ORDER BY rk) <= 2),
all_s AS (
  SELECT * FROM in_store UNION ALL SELECT * FROM front_store UNION ALL
  SELECT * FROM res_store UNION ALL SELECT * FROM planned_store),
numbered AS (
  SELECT a.*,
         'S' || LPAD(ROW_NUMBER() OVER (ORDER BY CASE store_format WHEN 'STATION_IN' THEN 1 WHEN 'STATION_FRONT' THEN 2 ELSE 3 END,
                                                 is_planned, anchor_id), 3, '0') AS store_id
  FROM all_s a),
opened AS (
  SELECT n.*,
         ROW_NUMBER() OVER (ORDER BY MOD(ABS(HASH(store_id, 'open')), 1000000), store_id) AS open_rank,
         ROW_NUMBER() OVER (PARTITION BY is_planned ORDER BY store_id) AS planned_rank,
         MOD(ABS(HASH(store_id, 'od')), 1000000) / 1e6 AS u_od
  FROM numbered n)
SELECT store_id, store_name, store_format, ROUND(lat, 6) AS lat, ROUND(lon, 6) AS lon, ward_code, ward_name,
       CASE WHEN is_planned THEN IFF(planned_rank = 1, '2026-10-01'::DATE, '2026-10-15'::DATE)
            WHEN open_rank <= 15 THEN DATEADD(day, FLOOR(u_od * 532), '2025-03-01'::DATE)
            ELSE DATEADD(day, FLOOR(u_od * 3300), '2015-04-01'::DATE) END AS open_date,
       NULL::DATE AS close_date,
       anchor_id
FROM opened;


-- 店舗ごとの「隠れた需要パラメータ」（教材では見せない。②の特徴量は ML スキーマで REF から別途計算する）
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.STORE_DRIVERS AS
WITH s AS (
  SELECT store_id, store_format, ST_MAKEPOINT(lon, lat) AS geo FROM DF_HANDSON.SRC_SYNTH.STORE_MASTER),
near AS (
  SELECT s.store_id, ST_DISTANCE(s.geo, t.geo) AS dist_st, t.passengers
  FROM s JOIN DF_HANDSON.REF.STATION t ON ST_DWITHIN(s.geo, t.geo, 5000)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.store_id ORDER BY ST_DISTANCE(s.geo, t.geo), t.station_id) = 1),
pop AS (
  SELECT s.store_id, COALESCE(SUM(m.pop_2020), 0) AS pop750
  FROM s LEFT JOIN DF_HANDSON.REF.MESH_POP m ON ST_DWITHIN(s.geo, m.geo, 750)
  GROUP BY s.store_id),
c AS (
  SELECT s.store_id, s.store_format, COALESCE(n.dist_st, 5000) AS dist_st, n.passengers, p.pop750,
         120 * LN(GREATEST(COALESCE(n.passengers, 2500), 2500) / 2000) AS station_comp,   -- 駅の人の流れ
         60 * LN(1 + p.pop750 / 5000) AS resident_comp,                                    -- 周辺の住民
         CASE s.store_format WHEN 'STATION_IN' THEN 1.3
                             WHEN 'STATION_FRONT' THEN 1.0 * EXP(-COALESCE(n.dist_st, 5000) / 800)
                             ELSE 0.4 * EXP(-COALESCE(n.dist_st, 5000) / 800) END AS sw,
         CASE s.store_format WHEN 'STATION_IN' THEN 0.2 WHEN 'STATION_FRONT' THEN 0.6 ELSE 1.4 END AS rw
  FROM s LEFT JOIN near n ON n.store_id = s.store_id JOIN pop p ON p.store_id = s.store_id)
SELECT store_id, store_format, dist_st, passengers, pop750,
       sw * station_comp + rw * resident_comp AS base_customers,                 -- 平日の基準客数
       sw * station_comp / (sw * station_comp + rw * resident_comp) AS office_index,   -- 1に近いほど通勤客中心
       EXP(0.15 * SQRT(-2 * LN((MOD(ABS(HASH(store_id, 'sc1')), 1000000) + 0.5) / 1e6))
                * COS(2 * PI() * MOD(ABS(HASH(store_id, 'sc2')), 1000000) / 1e6)) AS store_scale,   -- 店の実力差（観測できない）
       0.03 * (2 * MOD(ABS(HASH(store_id, 'drift')), 1000000) / 1e6 - 1) AS store_drift          -- 店ごとの成長率の差
FROM c;


-- 日次売上（店舗 × 日）
CREATE OR REPLACE TABLE DF_HANDSON.SRC_SYNTH.SALES_DAILY AS
WITH sd AS (
  SELECT m.store_id, m.store_format, m.open_date, d.ds,
         dr.base_customers, dr.office_index AS oi, dr.store_scale, dr.store_drift,
         DAYOFWEEKISO(d.ds) AS dow, TO_CHAR(d.ds, 'MM-DD') AS mmdd, MONTH(d.ds) AS mon,
         h.ds IS NOT NULL AS is_holiday, sp.period_name, w.temp_avg, w.precip_mm, p.is_promo
  FROM DF_HANDSON.SRC_SYNTH.STORE_MASTER m
  JOIN DF_HANDSON.SRC_SYNTH.STORE_DRIVERS dr ON dr.store_id = m.store_id
  JOIN DF_HANDSON.SRC_SYNTH.DATES d ON d.ds BETWEEN GREATEST(m.open_date, '2024-10-01'::DATE) AND '2026-09-30'::DATE
  JOIN DF_HANDSON.SRC_SYNTH.WEATHER w ON w.ds = d.ds
  JOIN DF_HANDSON.SRC_SYNTH.PROMO p ON p.ds = d.ds
  LEFT JOIN DF_HANDSON.REF.JP_HOLIDAY h ON h.ds = d.ds
  LEFT JOIN DF_HANDSON.REF.JP_SPECIAL_PERIOD sp ON sp.mmdd = TO_CHAR(d.ds, 'MM-DD')),
f AS (
  SELECT sd.*,
         -- 曜日：通勤客中心の店は平日に強く、住宅街の店は週末に強い
         CASE WHEN dow = 7 OR is_holiday THEN 1.2 - 0.7 * oi
              WHEN dow = 6 THEN 1.25 - 0.65 * oi
              ELSE (1 + 0.2 * oi) * IFF(dow = 5, 1.03, 1.0) END AS f_dow,
         -- 年末年始・お盆：通勤客中心の店ほど落ち込む
         CASE period_name WHEN '年末年始' THEN 0.35 + 0.5 * (1 - oi)
                          WHEN 'お盆' THEN 0.9 - 0.25 * oi ELSE 1.0 END AS f_special,
         -- 季節：12月は高く、1〜2月と8月は低め。クリスマスはケーキ・パンで大きく伸びる
         CASE mon WHEN 12 THEN 1.08 WHEN 1 THEN 0.95 WHEN 2 THEN 0.95 WHEN 3 THEN 1.02 WHEN 8 THEN 0.96 ELSE 1.0 END
           * CASE mmdd WHEN '12-24' THEN 1.35 WHEN '12-25' THEN 1.2 ELSE 1.0 END AS f_season,
         -- 天気：雨の日は路面店ほど客が減り、駅ナカは雨宿りの客で少し増える。猛暑・厳寒も路面店は少し減る
         IFF(precip_mm >= 1,
             1 - CASE store_format WHEN 'STATION_IN' THEN -0.05 WHEN 'STATION_FRONT' THEN 0.18 ELSE 0.25 END * LEAST(precip_mm, 30) / 30,
             1.0)
           * IFF(store_format <> 'STATION_IN' AND temp_avg > 30, 1 - 0.015 * (temp_avg - 30), 1.0)
           * IFF(store_format <> 'STATION_IN' AND temp_avg < 5, 1 - 0.01 * (5 - temp_avg), 1.0) AS f_weather,
         IFF(is_promo, 1.15, 1.0) AS f_promo,
         -- 新店効果：開業1週間は 1.6倍、その後 0.75倍から約4か月かけて定常に戻る
         CASE WHEN DATEDIFF(day, open_date, ds) < 7 THEN 1.6
              ELSE 0.75 + 0.25 * LEAST(1, (DATEDIFF(day, open_date, ds) - 7) / 113) END AS f_ramp,
         -- 成長：チェーン全体で年 +4%、店ごとに ±3% の差
         1 + (0.04 + store_drift) * DATEDIFF(day, '2024-10-01'::DATE, ds) / 365.25 AS f_trend,
         -- 仕込んだイベント：2026-08-25（火）台風の接近。前日はやや買いだめ
         CASE WHEN ds = '2026-08-25'::DATE THEN CASE store_format WHEN 'STATION_IN' THEN 0.6 WHEN 'STATION_FRONT' THEN 0.35 ELSE 0.3 END
              WHEN ds = '2026-08-24'::DATE THEN 1.05 ELSE 1.0 END AS f_event,
         -- ばらつき：店×日の個別ノイズ（約7%）＋全店共通の日ごとの揺れ（約3%）
         EXP(0.07 * SQRT(-2 * LN((MOD(ABS(HASH(store_id, ds, 'cn1')), 1000000) + 0.5) / 1e6))
                  * COS(2 * PI() * MOD(ABS(HASH(store_id, ds, 'cn2')), 1000000) / 1e6)
             + 0.03 * SQRT(-2 * LN((MOD(ABS(HASH(ds, 'cm1')), 1000000) + 0.5) / 1e6))
                    * COS(2 * PI() * MOD(ABS(HASH(ds, 'cm2')), 1000000) / 1e6)) AS f_noise,
         -- 客単価：約620円。住宅街は週末にまとめ買いで高め、販促日はやや下がる、12月は高め
         620 * CASE store_format WHEN 'STATION_IN' THEN 0.95 WHEN 'STATION_FRONT' THEN 1.0 ELSE 1.08 END
             * IFF(store_format = 'RESIDENTIAL' AND (dow >= 6 OR is_holiday), 1.05, 1.0)
             * IFF(is_promo, 0.97, 1.0) * IFF(mon = 12, 1.06, 1.0)
             * EXP(0.04 * SQRT(-2 * LN((MOD(ABS(HASH(store_id, ds, 'tn1')), 1000000) + 0.5) / 1e6))
                        * COS(2 * PI() * MOD(ABS(HASH(store_id, ds, 'tn2')), 1000000) / 1e6)) AS ticket,
         (mmdd = '01-01' AND store_format <> 'STATION_IN') AS is_closed   -- 元日は路面店が休業
  FROM sd)
SELECT store_id, ds,
       IFF(is_closed, 0,
           ROUND(base_customers * store_scale * f_dow * f_special * f_season * f_weather
                 * f_promo * f_ramp * f_trend * f_event * f_noise)) AS customers,
       ROUND(customers * ticket) AS sales_amount
FROM f;
