-- =====================================================================
-- 00_setup.sql：データベースとスキーマを作ります
--   REF       … 国土交通省などの公開データ（実データ。差し替えない）
--   SRC_SYNTH … 合成データ（売上・店舗・天気・販促）
--   CONTRACT  … ノートブックが参照する「契約」ビュー。データの出どころを切り替えるときはここだけ差し替える
--   ML        … 学習・予測の入力ビュー、モデル、結果
-- ロールとウェアハウスはノートブック側（または実行者）で指定してください（トライアルなら SYSADMIN か ACCOUNTADMIN）
-- =====================================================================

CREATE DATABASE IF NOT EXISTS DF_HANDSON;
CREATE SCHEMA IF NOT EXISTS DF_HANDSON.REF;
CREATE SCHEMA IF NOT EXISTS DF_HANDSON.SRC_SYNTH;
CREATE SCHEMA IF NOT EXISTS DF_HANDSON.CONTRACT;
CREATE SCHEMA IF NOT EXISTS DF_HANDSON.ML;
