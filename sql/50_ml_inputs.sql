-- =====================================================================
-- 50_ml_inputs.sql：学習・予測の入力（CONTRACT と REF だけを参照する。合成かどうかを知らない）
--   CONFIG            期間の設定（売上の最終日から自動で決まる）
--   STORE_FEATURES    立地特徴量（最寄り駅・乗降客数・1km圏の人口）… REF の実データから計算
--   DAILY             店舗 × 日の背骨（売上・カレンダー・天気・販促）。未来1か月分（売上なし）を含む
--   FC_*              ハンズオン①の FORECAST の入力
--   GLOBAL_FEATURES   ハンズオン②のグローバルモデルの入力
-- =====================================================================

-- 期間の設定（合成データの場合）：テスト月 2026-09、学習 〜2026-08-31、未来 2026-10
CREATE OR REPLACE VIEW DF_HANDSON.ML.CONFIG AS
WITH b AS (SELECT MIN(ds) AS data_start, MAX(ds) AS data_end FROM DF_HANDSON.CONTRACT.SALES_DAILY),
t AS (SELECT data_start, data_end,
             IFF(data_end = LAST_DAY(data_end), data_end, DATEADD(day, -DAY(data_end), data_end)) AS test_end FROM b),
cal AS (SELECT MAX(ds) AS cal_end FROM DF_HANDSON.CONTRACT.CALENDAR),
w AS (SELECT MIN(max_ds) AS weather_end
      FROM (SELECT weather_station_id, MAX(ds) AS max_ds FROM DF_HANDSON.CONTRACT.WEATHER_DAILY GROUP BY 1))
SELECT t.data_start, t.data_end,
       DATE_TRUNC('month', t.test_end)::DATE AS test_start,
       t.test_end,
       DATEADD(day, -1, DATE_TRUNC('month', t.test_end))::DATE AS train_end,
       DATEADD(day, 1, t.data_end) AS future_start,
       LEAST(LAST_DAY(DATEADD(day, 1, t.data_end)), cal.cal_end, w.weather_end) AS future_end
FROM t CROSS JOIN cal CROSS JOIN w;


-- 立地特徴量（店の位置 × 国土交通省の実データ）。LAT/LON が無い店は NULL
CREATE OR REPLACE TABLE DF_HANDSON.ML.STORE_FEATURES AS
WITH s AS (
  SELECT store_id, IFF(lat IS NULL OR lon IS NULL, NULL, ST_MAKEPOINT(lon, lat)) AS geo FROM DF_HANDSON.CONTRACT.STORE),
near AS (
  SELECT s.store_id, t.station_name AS nearest_station, ST_DISTANCE(s.geo, t.geo) AS dist_station_m,
         t.passengers AS nearest_station_passengers
  FROM s JOIN DF_HANDSON.REF.STATION t ON ST_DWITHIN(s.geo, t.geo, 5000)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.store_id ORDER BY ST_DISTANCE(s.geo, t.geo), t.station_id) = 1),
st1k AS (
  SELECT s.store_id, COUNT(*) AS n_stations_1km, SUM(t.passengers) AS passengers_1km
  FROM s JOIN DF_HANDSON.REF.STATION t ON ST_DWITHIN(s.geo, t.geo, 1000) GROUP BY 1),
pop1k AS (
  SELECT s.store_id, SUM(m.pop_2020) AS pop_1km, DIV0(SUM(m.pop_65plus_2020), SUM(m.pop_2020)) AS pop_65plus_ratio_1km
  FROM s JOIN DF_HANDSON.REF.MESH_POP m ON ST_DWITHIN(s.geo, m.geo, 1000) GROUP BY 1)
SELECT s.store_id, n.nearest_station, n.dist_station_m, n.nearest_station_passengers,
       IFF(s.geo IS NULL, NULL, COALESCE(a.n_stations_1km, 0)) AS n_stations_1km,
       IFF(s.geo IS NULL, NULL, COALESCE(a.passengers_1km, 0)) AS passengers_1km,
       IFF(s.geo IS NULL, NULL, COALESCE(p.pop_1km, 0)) AS pop_1km,
       p.pop_65plus_ratio_1km
FROM s
LEFT JOIN near n ON n.store_id = s.store_id
LEFT JOIN st1k a ON a.store_id = s.store_id
LEFT JOIN pop1k p ON p.store_id = s.store_id;


-- 店舗 × 日の背骨：開業日（無ければ売上の初日）から未来の最終日まで。売上は未来の日は NULL
CREATE OR REPLACE TABLE DF_HANDSON.ML.DAILY AS
WITH cfg AS (SELECT * FROM DF_HANDSON.ML.CONFIG),
first_sale AS (SELECT store_id, MIN(ds) AS first_ds FROM DF_HANDSON.CONTRACT.SALES_DAILY GROUP BY 1),
st AS (
  SELECT s.store_id, s.store_format, s.weather_station_id, s.close_date,
         COALESCE(s.open_date, f.first_ds) AS open_date_eff
  FROM DF_HANDSON.CONTRACT.STORE s LEFT JOIN first_sale f ON f.store_id = s.store_id)
SELECT st.store_id, st.store_format, c.ds,
       sd.sales_amount AS sales,
       c.is_holiday, c.is_special_period, COALESCE(p.is_promo, FALSE) AS is_promo,
       w.temp_avg, w.precip_mm,
       DATEDIFF(day, st.open_date_eff, c.ds) AS days_since_open
FROM st CROSS JOIN cfg
JOIN DF_HANDSON.CONTRACT.CALENDAR c
  ON c.ds BETWEEN GREATEST(st.open_date_eff, cfg.data_start) AND LEAST(cfg.future_end, COALESCE(st.close_date, cfg.future_end))
LEFT JOIN DF_HANDSON.CONTRACT.SALES_DAILY sd ON sd.store_id = st.store_id AND sd.ds = c.ds
LEFT JOIN DF_HANDSON.CONTRACT.WEATHER_DAILY w ON w.weather_station_id = st.weather_station_id AND w.ds = c.ds
LEFT JOIN DF_HANDSON.CONTRACT.PROMO_DAILY p ON p.store_id = st.store_id AND p.ds = c.ds
WHERE st.open_date_eff IS NOT NULL;


-- ===== ハンズオン①：FORECAST =====
-- 対象店：学習終了日までに1年以上の履歴がある店から、業態ごとに売上規模の違う店を選んで計12店程度
-- （全店で FORECAST することもできるが、学習時間を20分枠に収めるため。全店の予測はハンズオン②で行う）
CREATE OR REPLACE TABLE DF_HANDSON.ML.FC_TARGET_STORES AS
WITH cfg AS (SELECT * FROM DF_HANDSON.ML.CONFIG),
s AS (
  SELECT d.store_id, COALESCE(d.store_format, 'ALL') AS fmt, AVG(d.sales) AS avg_sales, MIN(d.ds) AS first_ds
  FROM DF_HANDSON.ML.DAILY d CROSS JOIN cfg
  WHERE d.ds <= cfg.train_end AND d.sales IS NOT NULL
  GROUP BY 1, 2),
e AS (SELECT s.* FROM s CROSS JOIN cfg WHERE s.first_ds <= DATEADD(day, -365, cfg.train_end)),
k AS (SELECT CEIL(12 / COUNT(DISTINCT fmt)) AS per_fmt FROM e),
r AS (
  SELECT e.*, LEAST(k.per_fmt - 1, FLOOR(PERCENT_RANK() OVER (PARTITION BY e.fmt ORDER BY e.avg_sales DESC) * k.per_fmt)) AS bucket
  FROM e CROSS JOIN k)
SELECT store_id, fmt AS store_format, ROUND(avg_sales) AS avg_sales, bucket
FROM r
QUALIFY ROW_NUMBER() OVER (PARTITION BY fmt, bucket ORDER BY avg_sales DESC, store_id) = 1;

-- 学習：対象店の日次売上（学習終了日まで）＋外生変数（販促・祝日・特別期間・気温・降水）
CREATE OR REPLACE VIEW DF_HANDSON.ML.FC_TRAIN AS
SELECT d.store_id, d.ds::TIMESTAMP_NTZ AS ts, d.sales,
       d.is_promo::INT AS is_promo, d.is_holiday::INT AS is_holiday, d.is_special_period::INT AS is_special,
       d.temp_avg, d.precip_mm
FROM DF_HANDSON.ML.DAILY d
JOIN DF_HANDSON.ML.FC_TARGET_STORES t ON t.store_id = d.store_id
CROSS JOIN DF_HANDSON.ML.CONFIG cfg
WHERE d.ds <= cfg.train_end AND d.sales IS NOT NULL;

-- 予測：テスト月の外生変数だけを渡す（売上は渡さない）
CREATE OR REPLACE VIEW DF_HANDSON.ML.FC_FUTURE AS
SELECT d.store_id, d.ds::TIMESTAMP_NTZ AS ts,
       d.is_promo::INT AS is_promo, d.is_holiday::INT AS is_holiday, d.is_special_period::INT AS is_special,
       d.temp_avg, d.precip_mm
FROM DF_HANDSON.ML.DAILY d
JOIN DF_HANDSON.ML.FC_TARGET_STORES t ON t.store_id = d.store_id
CROSS JOIN DF_HANDSON.ML.CONFIG cfg
WHERE d.ds BETWEEN cfg.test_start AND cfg.test_end;


-- ===== ハンズオン②：グローバルモデルの特徴量 =====
-- ポイント：最大1か月先（約30日先）まで予測するので、ラグは「35日以上前」だけを使う（予測時点で分かっている値だけ）
--   LAG_35〜56 …… 5〜8週前の同じ曜日の売上
--   MEAN_28_ENDING_31 … 31〜58日前の28日間の平均売上
-- 新店は履歴が無いのでラグが NULL になる。XGBoost は NULL をそのまま扱える
CREATE OR REPLACE VIEW DF_HANDSON.ML.GLOBAL_FEATURES AS
WITH d AS (
  SELECT d.*,
         LAG(sales, 35) OVER (PARTITION BY store_id ORDER BY ds) AS lag_35,
         LAG(sales, 42) OVER (PARTITION BY store_id ORDER BY ds) AS lag_42,
         LAG(sales, 49) OVER (PARTITION BY store_id ORDER BY ds) AS lag_49,
         LAG(sales, 56) OVER (PARTITION BY store_id ORDER BY ds) AS lag_56,
         AVG(sales) OVER (PARTITION BY store_id ORDER BY ds ROWS BETWEEN 58 PRECEDING AND 31 PRECEDING) AS mean_28_ending_31
  FROM DF_HANDSON.ML.DAILY d)
SELECT d.store_id, d.ds, d.sales,
       -- カレンダー・天気・販促
       DAYOFWEEKISO(d.ds) AS dow, d.is_holiday::INT AS is_holiday, d.is_special_period::INT AS is_special,
       d.is_promo::INT AS is_promo, MONTH(d.ds) AS month,
       SIN(2 * PI() * DAYOFYEAR(d.ds) / 365.25) AS doy_sin, COS(2 * PI() * DAYOFYEAR(d.ds) / 365.25) AS doy_cos,
       d.temp_avg, d.precip_mm,
       -- 店の属性
       LEAST(d.days_since_open, 730) AS days_since_open,
       IFF(d.store_format = 'STATION_IN', 1, 0) AS fmt_station_in,
       IFF(d.store_format = 'STATION_FRONT', 1, 0) AS fmt_station_front,
       IFF(d.store_format = 'RESIDENTIAL', 1, 0) AS fmt_residential,
       -- 立地（国土交通省の実データ）
       LN(1 + f.nearest_station_passengers) AS log_station_passengers,
       f.dist_station_m, f.n_stations_1km,
       LN(1 + f.passengers_1km) AS log_passengers_1km,
       LN(1 + f.pop_1km) AS log_pop_1km,
       f.pop_65plus_ratio_1km,
       -- 過去の売上（35日以上前だけ）
       d.lag_35, d.lag_42, d.lag_49, d.lag_56,
       (COALESCE(d.lag_35, 0) + COALESCE(d.lag_42, 0) + COALESCE(d.lag_49, 0) + COALESCE(d.lag_56, 0))
         / NULLIF(IFF(d.lag_35 IS NULL, 0, 1) + IFF(d.lag_42 IS NULL, 0, 1) + IFF(d.lag_49 IS NULL, 0, 1) + IFF(d.lag_56 IS NULL, 0, 1), 0)
         AS same_dow_mean_5_8w,
       d.mean_28_ending_31
FROM d LEFT JOIN DF_HANDSON.ML.STORE_FEATURES f ON f.store_id = d.store_id;
