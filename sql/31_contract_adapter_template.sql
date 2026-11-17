-- =====================================================================
-- 31_contract_adapter_template.sql：実データ（Marketplace など）→ CONTRACT のひな形
-- ※ このファイルはそのままでは動きません。<...> を埋めてから、30 の代わりに実行してください。
-- ※ 実行後に 40_contract_check.sql → 50_ml_inputs.sql を実行すれば、ノートブックはそのまま動きます。
--
-- 切り替えの考え方
--   ・「店舗」は予測する系列の単位です。実店舗でなくても、地域・カテゴリ別の系列でかまいません
--     （その場合 LAT/LON は NULL。②の立地特徴量は NULL になり、モデルは他の特徴量だけで学習します）
--   ・天気は気象庁の過去データ（東京）を REF に入れて共通で使う想定。販促データが無ければ PROMO_DAILY は空のビューでよい
--   ・日付の範囲は ML.CONFIG が売上の最終日から自動で決めます（最後の満月をテスト月にする）
--
-- 例：東芝テック「(Sample)Japan supermarket sales panel data」を使う場合のイメージ
--   ※ 列名は公開記事（Classmethod）の記載に基づく。取得後に必ず実物で確認すること
--   ※ 店舗単位ではなく「地域 × 日 × 時間帯 × JAN」の購買指数・金額なので、系列＝地域（AREA_CODE2）にする
-- =====================================================================

-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.STORE AS
-- SELECT DISTINCT AREA_CODE2::STRING AS store_id, AREA_NAME2::STRING AS store_name, NULL::STRING AS store_format,
--        NULL::FLOAT AS lat, NULL::FLOAT AS lon, AREA_CODE2::STRING AS area_code, AREA_NAME2::STRING AS area_name,
--        NULL::DATE AS open_date, NULL::DATE AS close_date, 'TOKYO'::STRING AS weather_station_id
-- FROM <MARKETPLACE_DB>.IDP.V_SPOSPANEL_JAN_HOURS;

-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.SALES_DAILY AS
-- SELECT AREA_CODE2::STRING AS store_id, SALES_DAY::DATE AS ds, SUM(TOTAL_AMOUNT)::FLOAT AS sales_amount,
--        NULL::FLOAT AS customers, SUM(TOTAL_COUNT)::FLOAT AS sales_qty
-- FROM <MARKETPLACE_DB>.IDP.V_SPOSPANEL_JAN_HOURS
-- WHERE JANCODE IN (<対象カテゴリの JAN コード。商品マスタと結合して絞る>)
-- GROUP BY 1, 2;

-- CALENDAR：売上期間＋30日の日付を作り、REF の祝日と結合する（30 の CALENDAR と同じ形）
-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.CALENDAR AS
-- WITH r AS (SELECT MIN(ds) AS s, DATEADD(day, 30, MAX(ds)) AS e FROM DF_HANDSON.CONTRACT.SALES_DAILY),
-- g AS (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, r.s) AS ds, r.e
--       FROM TABLE(GENERATOR(ROWCOUNT => 3000)) CROSS JOIN r),
-- d AS (SELECT ds FROM g WHERE ds <= e)
-- SELECT d.ds, h.ds IS NOT NULL AS is_holiday, h.holiday_name, sp.mmdd IS NOT NULL AS is_special_period, sp.period_name AS special_period_name
-- FROM d LEFT JOIN DF_HANDSON.REF.JP_HOLIDAY h ON h.ds = d.ds
-- LEFT JOIN DF_HANDSON.REF.JP_SPECIAL_PERIOD sp ON sp.mmdd = TO_CHAR(d.ds, 'MM-DD');

-- WEATHER_DAILY：気象庁の過去データを REF.JMA_DAILY（WEATHER_STATION_ID, DS, TEMP_AVG, PRECIP_MM）に入れた想定
-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.WEATHER_DAILY AS
-- SELECT weather_station_id, ds, temp_avg, precip_mm FROM DF_HANDSON.REF.JMA_DAILY;

-- PROMO_DAILY：販促データが無い場合は空にする（ML 側で「販促なし」として扱う）
-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.PROMO_DAILY AS
-- SELECT NULL::STRING AS store_id, NULL::DATE AS ds, NULL::BOOLEAN AS is_promo, NULL::STRING AS promo_name WHERE FALSE;

-- CREATE OR REPLACE VIEW DF_HANDSON.CONTRACT.DATASET_INFO AS
-- SELECT '<リスティング名>' AS source_name, FALSE AS is_synthetic, '<出典・利用条件>' AS description;
