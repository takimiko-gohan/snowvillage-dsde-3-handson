-- =====================================================================
-- 40_contract_check.sql：CONTRACT が仕様を満たしているかを確かめるビュー
-- アダプターを差し替えたら、SELECT * FROM DF_HANDSON.CONTRACT.CHECK_RESULTS WHERE NOT passed; が 0 行になることを確認する
-- SEVERITY が ERROR のものは、ノートブックが正しく動かない。WARN は動くが一部の分析が省略される
-- =====================================================================

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.CHECK_RESULTS AS
WITH r AS (SELECT MIN(ds) AS s_min, MAX(ds) AS s_max FROM DF_HANDSON.CONTRACT.SALES_DAILY),
checks AS (
  SELECT 'STORE: STORE_ID が一意' AS check_name, 'ERROR' AS severity,
         (SELECT COUNT(*) - COUNT(DISTINCT store_id) FROM DF_HANDSON.CONTRACT.STORE) AS n_violations
  UNION ALL
  SELECT 'SALES_DAILY: (STORE_ID, DS) が一意', 'ERROR',
         (SELECT COUNT(*) FROM (SELECT store_id, ds FROM DF_HANDSON.CONTRACT.SALES_DAILY GROUP BY 1, 2 HAVING COUNT(*) > 1))
  UNION ALL
  SELECT 'SALES_DAILY: STORE_ID が STORE に存在する', 'ERROR',
         (SELECT COUNT(*) FROM DF_HANDSON.CONTRACT.SALES_DAILY sd
          WHERE NOT EXISTS (SELECT 1 FROM DF_HANDSON.CONTRACT.STORE s WHERE s.store_id = sd.store_id))
  UNION ALL
  SELECT 'SALES_DAILY: SALES_AMOUNT が NULL でも負でもない', 'ERROR',
         (SELECT COUNT(*) FROM DF_HANDSON.CONTRACT.SALES_DAILY WHERE sales_amount IS NULL OR sales_amount < 0)
  UNION ALL
  SELECT 'SALES_DAILY: 店ごとに日付の抜けがない', 'ERROR',
         (SELECT COUNT(*) FROM (SELECT store_id FROM DF_HANDSON.CONTRACT.SALES_DAILY GROUP BY 1
                                HAVING COUNT(*) <> DATEDIFF(day, MIN(ds), MAX(ds)) + 1))
  UNION ALL
  SELECT 'SALES_DAILY: 履歴が400日以上ある（FORECAST・異常検知に1年分以上使うため）', 'ERROR',
         IFF((SELECT DATEDIFF(day, s_min, s_max) FROM r) >= 400, 0, 1)
  UNION ALL
  SELECT 'CALENDAR: DS が一意', 'ERROR',
         (SELECT COUNT(*) - COUNT(DISTINCT ds) FROM DF_HANDSON.CONTRACT.CALENDAR)
  UNION ALL
  SELECT 'CALENDAR: 売上の初日〜最終日＋30日を抜けなくカバー', 'ERROR',
         (SELECT DATEDIFF(day, s_min, s_max) + 31 FROM r)
         - (SELECT COUNT(DISTINCT c.ds) FROM DF_HANDSON.CONTRACT.CALENDAR c, r WHERE c.ds BETWEEN r.s_min AND DATEADD(day, 30, r.s_max))
  UNION ALL
  SELECT 'WEATHER_DAILY: 店舗が参照する地点ごとに、売上の初日〜最終日＋30日をカバー', 'ERROR',
         (SELECT COUNT(*) FROM (SELECT DISTINCT weather_station_id FROM DF_HANDSON.CONTRACT.STORE) st
          CROSS JOIN DF_HANDSON.CONTRACT.CALENDAR c CROSS JOIN r
          WHERE c.ds BETWEEN r.s_min AND DATEADD(day, 30, r.s_max)
            AND NOT EXISTS (SELECT 1 FROM DF_HANDSON.CONTRACT.WEATHER_DAILY w
                            WHERE w.weather_station_id = st.weather_station_id AND w.ds = c.ds
                              AND w.temp_avg IS NOT NULL AND w.precip_mm IS NOT NULL))
  UNION ALL
  SELECT 'PROMO_DAILY: (STORE_ID, DS) が一意', 'ERROR',
         (SELECT COUNT(*) FROM (SELECT store_id, ds FROM DF_HANDSON.CONTRACT.PROMO_DAILY GROUP BY 1, 2 HAVING COUNT(*) > 1))
  UNION ALL
  SELECT 'DATASET_INFO: ちょうど1行', 'ERROR',
         ABS((SELECT COUNT(*) FROM DF_HANDSON.CONTRACT.DATASET_INFO) - 1)
  UNION ALL
  SELECT 'STORE: LAT/LON がある（無い店は地図と立地特徴量が省略される）', 'WARN',
         (SELECT COUNT(*) FROM DF_HANDSON.CONTRACT.STORE WHERE lat IS NULL OR lon IS NULL)
  UNION ALL
  SELECT 'STORE: STORE_FORMAT がある（無い店は業態別の集計で ALL 扱い）', 'WARN',
         (SELECT COUNT(*) FROM DF_HANDSON.CONTRACT.STORE WHERE store_format IS NULL))
SELECT check_name, severity, n_violations, n_violations = 0 AS passed FROM checks;
