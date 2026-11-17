-- =====================================================================
-- 30_contract_adapter_synth.sql：合成データ（SRC_SYNTH）→ CONTRACT（契約ビュー）
-- ノートブックと ML スキーマは CONTRACT だけを参照する。データの出どころを変えるときは、
-- このファイルの代わりに別のアダプター（31_contract_adapter_template.sql を参考）を実行する。
--
-- 【契約（CONTRACT）の仕様】列名・型・キーを変えないこと。NULL 可の列は「無ければ NULL」でよい
--   STORE         キー STORE_ID      STORE_NAME, STORE_FORMAT(NULL可), LAT/LON(NULL可), AREA_CODE/AREA_NAME(NULL可),
--                                    OPEN_DATE(NULL可=売上の初日), CLOSE_DATE(NULL可), WEATHER_STATION_ID
--   SALES_DAILY   キー STORE_ID, DS  SALES_AMOUNT(必須, 0以上), CUSTOMERS(NULL可), SALES_QTY(NULL可)
--                                    店ごとに初日〜最終日まで日付の抜けがないこと（休業日は 0）
--   CALENDAR      キー DS            IS_HOLIDAY, HOLIDAY_NAME, IS_SPECIAL_PERIOD, SPECIAL_PERIOD_NAME
--                                    売上の初日〜最終日＋30日をカバーすること
--   WEATHER_DAILY キー WEATHER_STATION_ID, DS  TEMP_AVG, PRECIP_MM（CALENDAR と同じ期間。未来分は予報値の想定）
--   PROMO_DAILY   キー STORE_ID, DS  IS_PROMO, PROMO_NAME（販促データが無ければ空でよい＝販促なし扱い）
--   DATASET_INFO  1行               SOURCE_NAME, IS_SYNTHETIC, DESCRIPTION
-- =====================================================================

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.STORE AS
SELECT store_id::STRING AS store_id, store_name::STRING AS store_name, store_format::STRING AS store_format,
       lat::FLOAT AS lat, lon::FLOAT AS lon, ward_code::STRING AS area_code, ward_name::STRING AS area_name,
       open_date::DATE AS open_date, close_date::DATE AS close_date, 'TOKYO'::STRING AS weather_station_id
FROM DF_HANDSON.SRC_SYNTH.STORE_MASTER;

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.SALES_DAILY AS
SELECT store_id::STRING AS store_id, ds::DATE AS ds, sales_amount::FLOAT AS sales_amount,
       customers::FLOAT AS customers, NULL::FLOAT AS sales_qty
FROM DF_HANDSON.SRC_SYNTH.SALES_DAILY;

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.CALENDAR AS
SELECT d.ds::DATE AS ds,
       h.ds IS NOT NULL AS is_holiday, h.holiday_name::STRING AS holiday_name,
       sp.mmdd IS NOT NULL AS is_special_period, sp.period_name::STRING AS special_period_name
FROM DF_HANDSON.SRC_SYNTH.DATES d
LEFT JOIN DF_HANDSON.REF.JP_HOLIDAY h ON h.ds = d.ds
LEFT JOIN DF_HANDSON.REF.JP_SPECIAL_PERIOD sp ON sp.mmdd = TO_CHAR(d.ds, 'MM-DD');

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.WEATHER_DAILY AS
SELECT weather_station_id::STRING AS weather_station_id, ds::DATE AS ds,
       temp_avg::FLOAT AS temp_avg, precip_mm::FLOAT AS precip_mm
FROM DF_HANDSON.SRC_SYNTH.WEATHER;

-- 合成データの販促はチェーン全体の施策なので、全店に展開する
CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.PROMO_DAILY AS
SELECT s.store_id::STRING AS store_id, p.ds::DATE AS ds, p.is_promo::BOOLEAN AS is_promo, p.promo_name::STRING AS promo_name
FROM DF_HANDSON.SRC_SYNTH.PROMO p CROSS JOIN DF_HANDSON.SRC_SYNTH.STORE_MASTER s;

CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.DATASET_INFO AS
SELECT 'SYNTHETIC'::STRING AS source_name, TRUE AS is_synthetic,
       '架空のカフェ・ベーカリーチェーン「SNOW BAKERY」の合成データ。店舗の位置と需要の強さは国土交通省の駅別乗降客数・メッシュ人口（実データ）から決めている。天気も現時点では合成。'::STRING AS description;
