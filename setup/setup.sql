-- =====================================================================
-- setup.sql：ハンズオンのデータを一発で作ります（ワークシートに貼り付けて「Run All」）
--   GitHub の公開リポジトリを Snowflake に接続し、sql/ の SQL を順に実行します（約2〜3分）
--   トライアルアカウントでそのまま動きます（API INTEGRATION の作成だけ ACCOUNTADMIN が必要です）
-- =====================================================================

-- リポジトリ：https://github.com/takimiko-gohan/snowvillage-dsde-3-handson

-- 1. Git への接続（公開リポジトリなので認証は不要）
USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE API INTEGRATION DSDE3_GIT_API
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/takimiko-gohan')
  ENABLED = TRUE;
GRANT USAGE ON INTEGRATION DSDE3_GIT_API TO ROLE SYSADMIN;

-- 2. 以降はノートブックと同じ SYSADMIN で作ります
USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
CREATE DATABASE IF NOT EXISTS DF_HANDSON;
CREATE OR REPLACE GIT REPOSITORY DF_HANDSON.PUBLIC.HANDSON_REPO
  API_INTEGRATION = DSDE3_GIT_API
  ORIGIN = 'https://github.com/takimiko-gohan/snowvillage-dsde-3-handson.git';
ALTER GIT REPOSITORY DF_HANDSON.PUBLIC.HANDSON_REPO FETCH;

-- 3. データを作る（順番に実行）
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/00_setup.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/10_ref_mlit.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/11_ref_holiday.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/20_src_synth.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/30_contract_adapter_synth.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/40_contract_check.sql;
EXECUTE IMMEDIATE FROM @DF_HANDSON.PUBLIC.HANDSON_REPO/branches/main/sql/50_ml_inputs.sql;

-- 4. 確認：0 行なら準備完了です
SELECT * FROM DF_HANDSON.CONTRACT.CHECK_RESULTS WHERE NOT passed AND severity = 'ERROR';
