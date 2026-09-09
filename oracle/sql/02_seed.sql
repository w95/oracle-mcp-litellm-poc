-- =====================================================================
-- BIR PoC : seed data for the intraday liquidity use case
-- Business date = TRUNC(SYSDATE) so the demo always looks "live".
-- Deterministic: DBMS_RANDOM is seeded before every generation block.
-- =====================================================================
SET ECHO ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CURRENT_SCHEMA = bir;

-- ---------------------------------------------------------------------
-- Currencies
-- ---------------------------------------------------------------------
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('USD','US Dollar',2,'FEDWIRE','America/New_York');
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('EUR','Euro',2,'TARGET2','Europe/Frankfurt');
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('GBP','Pound Sterling',2,'CHAPS','Europe/London');
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('CHF','Swiss Franc',2,'SIC','Europe/Zurich');
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('JPY','Japanese Yen',0,'BOJNET','Asia/Tokyo');
INSERT INTO currencies (ccy_code, ccy_name, minor_units, rtgs_system, tz_name) VALUES ('SGD','Singapore Dollar',2,'MEPS','Asia/Singapore');

-- ---------------------------------------------------------------------
-- Correspondent banks
-- ---------------------------------------------------------------------
INSERT INTO correspondents VALUES (1,'CHASUS33XXX','JPMorgan Chase Bank N.A.','US','TIER1','A+',DATE '2009-03-16','Y');
INSERT INTO correspondents VALUES (2,'CITIUS33XXX','Citibank N.A.','US','TIER1','A+',DATE '2011-07-01','Y');
INSERT INTO correspondents VALUES (3,'DEUTDEFFXXX','Deutsche Bank AG','DE','TIER1','A',DATE '2007-11-05','Y');
INSERT INTO correspondents VALUES (4,'BARCGB22XXX','Barclays Bank PLC','GB','TIER1','A',DATE '2013-02-18','Y');
INSERT INTO correspondents VALUES (5,'UBSWCHZH80A','UBS Switzerland AG','CH','TIER2','A-',DATE '2016-05-30','Y');
INSERT INTO correspondents VALUES (6,'BOTKJPJTXXX','MUFG Bank Ltd.','JP','TIER2','A',DATE '2018-09-10','Y');
INSERT INTO correspondents VALUES (7,'DBSSSGSGXXX','DBS Bank Ltd.','SG','TIER2','AA-',DATE '2019-04-02','Y');
INSERT INTO correspondents VALUES (8,'RZBAATWWXXX','Raiffeisen Bank International AG','AT','TIER3','BBB+',DATE '2021-01-11','N');

-- ---------------------------------------------------------------------
-- Nostro / vostro accounts
--   account_id, no, type, corr, ccy, opening, min_bal, target_buffer, credit_limit
-- ---------------------------------------------------------------------
INSERT INTO accounts VALUES (101,'NOS-USD-CHASUS33-0001','NOSTRO',1,'USD', 185000000, 25000000,  60000000, 150000000,'Y');
INSERT INTO accounts VALUES (102,'NOS-USD-CITIUS33-0002','NOSTRO',2,'USD',  92000000, 15000000,  40000000,  75000000,'Y');
INSERT INTO accounts VALUES (103,'NOS-EUR-DEUTDEFF-0003','NOSTRO',3,'EUR', 128000000, 20000000,  50000000, 100000000,'Y');
INSERT INTO accounts VALUES (104,'NOS-GBP-BARCGB22-0004','NOSTRO',4,'GBP',  64000000, 10000000,  25000000,  50000000,'Y');
INSERT INTO accounts VALUES (105,'NOS-CHF-UBSWCHZH-0005','NOSTRO',5,'CHF',  38000000,  8000000,  18000000,  30000000,'Y');
INSERT INTO accounts VALUES (106,'NOS-JPY-BOTKJPJT-0006','NOSTRO',6,'JPY',4200000000,800000000,1800000000,3000000000,'Y');
INSERT INTO accounts VALUES (107,'NOS-SGD-DBSSSGSG-0007','NOSTRO',7,'SGD',  27000000,  5000000,  12000000,  20000000,'Y');
INSERT INTO accounts VALUES (108,'VOS-USD-RZBAATWW-0008','VOSTRO',8,'USD',  14000000,        0,   5000000,         0,'Y');
INSERT INTO accounts VALUES (109,'VOS-EUR-RZBAATWW-0009','VOSTRO',8,'EUR',   9500000,        0,   4000000,         0,'Y');
INSERT INTO accounts VALUES (110,'NOS-EUR-BARCGB22-0010','NOSTRO',4,'EUR',  46000000,  9000000,  20000000,  40000000,'Y');

-- ---------------------------------------------------------------------
-- FX rates to USD for the business date
-- ---------------------------------------------------------------------
INSERT INTO fx_rates VALUES ('USD','USD',TRUNC(SYSDATE),1);
INSERT INTO fx_rates VALUES ('EUR','USD',TRUNC(SYSDATE),1.08420000);
INSERT INTO fx_rates VALUES ('GBP','USD',TRUNC(SYSDATE),1.26750000);
INSERT INTO fx_rates VALUES ('CHF','USD',TRUNC(SYSDATE),1.11380000);
INSERT INTO fx_rates VALUES ('JPY','USD',TRUNC(SYSDATE),0.00662000);
INSERT INTO fx_rates VALUES ('SGD','USD',TRUNC(SYSDATE),0.74310000);

-- ---------------------------------------------------------------------
-- Cut-off calendar
-- ---------------------------------------------------------------------
DECLARE
  TYPE t_types IS VARRAY(5) OF VARCHAR2(12);
  v_types t_types := t_types('RTGS','SWIFT','SECURITIES','FX','INTERNAL');
  TYPE t_cut IS VARRAY(5) OF VARCHAR2(5);
  v_cut   t_cut   := t_cut('17:00','16:30','15:30','16:00','18:00');
  v_id    NUMBER := 0;
BEGIN
  FOR a IN (SELECT account_id FROM accounts ORDER BY account_id) LOOP
    FOR i IN 1 .. v_types.COUNT LOOP
      v_id := v_id + 1;
      INSERT INTO cutoff_times (cutoff_id, account_id, payment_type, cutoff_local, warning_lead_min)
      VALUES (v_id, a.account_id, v_types(i), v_cut(i), CASE WHEN v_types(i) = 'RTGS' THEN 45 ELSE 30 END);
    END LOOP;
  END LOOP;
END;
/

-- ---------------------------------------------------------------------
-- Payment instructions: one business day of traffic, 08:00 - 17:00.
-- Account 102 and 105 are deliberately stressed (heavy outflow bias).
-- ---------------------------------------------------------------------
DECLARE
  v_pid        NUMBER := 0;
  v_n          PLS_INTEGER;
  v_dir        VARCHAR2(3);
  v_type       VARCHAR2(12);
  v_amt        NUMBER;
  v_sub        TIMESTAMP;
  v_settle     TIMESTAMP;
  v_status     VARCHAR2(10);
  v_scale      NUMBER;
  v_out_bias   NUMBER;
  v_minute     PLS_INTEGER;
  v_r          NUMBER;
  v_bics       SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST(
                 'HSBCGB2LXXX','BNPAFRPPXXX','SOGEFRPPXXX','UNCRITMMXXX','INGBNL2AXXX',
                 'SCBLSG22XXX','ANZBAU3MXXX','NDEAFIHHXXX','CRESCHZZ80A','MIDLGB22XXX');
  TYPE t_types IS VARRAY(5) OF VARCHAR2(12);
  v_types t_types := t_types('RTGS','SWIFT','SECURITIES','FX','INTERNAL');
BEGIN
  DBMS_RANDOM.SEED(20260907);
  FOR a IN (SELECT account_id, ccy_code, opening_ledger_bal FROM accounts ORDER BY account_id) LOOP
    -- traffic volume and ticket size scale with the size of the account
    v_scale    := a.opening_ledger_bal / 2000;
    -- stressed accounts also trade in bigger tickets
    IF a.account_id IN (102, 105) THEN
      v_scale := v_scale * 5;
    END IF;
    v_n        := 30 + TRUNC(DBMS_RANDOM.VALUE(0, 20));
    v_out_bias := CASE WHEN a.account_id IN (102,105) THEN 0.78   -- stressed accounts
                       WHEN a.account_id IN (108,109) THEN 0.35   -- vostro: mostly inbound
                       ELSE 0.50 END;

    FOR i IN 1 .. v_n LOOP
      v_pid    := v_pid + 1;
      v_r      := DBMS_RANDOM.VALUE(0,1);
      v_dir    := CASE WHEN v_r < v_out_bias THEN 'OUT' ELSE 'IN' END;
      v_type   := v_types(1 + TRUNC(DBMS_RANDOM.VALUE(0, 5)));
      -- log-ish distribution: many small tickets, a few very large ones
      v_amt    := ROUND(v_scale * POWER(10, DBMS_RANDOM.VALUE(0, 2)), 2);
      v_minute := TRUNC(DBMS_RANDOM.VALUE(0, 540));                    -- 08:00 .. 17:00
      v_sub    := CAST(TRUNC(SYSDATE) + INTERVAL '8' HOUR AS TIMESTAMP) + NUMTODSINTERVAL(v_minute,'MINUTE');

      v_r := DBMS_RANDOM.VALUE(0,1);
      IF v_r < 0.80 THEN
        v_status := 'SETTLED';
        v_settle := v_sub + NUMTODSINTERVAL(TRUNC(DBMS_RANDOM.VALUE(1, 25)), 'MINUTE');
      ELSIF v_r < 0.90 THEN
        v_status := 'QUEUED';   v_settle := NULL;
      ELSIF v_r < 0.95 THEN
        v_status := 'PENDING';  v_settle := NULL;
      ELSIF v_r < 0.98 THEN
        v_status := 'HELD';     v_settle := NULL;
      ELSE
        v_status := 'REJECTED'; v_settle := NULL;
      END IF;

      INSERT INTO payment_instructions (
        payment_id, uetr, account_id, direction, payment_type, amount, ccy_code,
        value_date, submitted_ts, settled_ts, status, priority, counterparty_bic, client_ref)
      VALUES (
        v_pid,
        LOWER(RAWTOHEX(SYS_GUID())),
        a.account_id, v_dir, v_type,
        CASE WHEN a.ccy_code = 'JPY' THEN ROUND(v_amt, 0) ELSE v_amt END,
        a.ccy_code,
        TRUNC(SYSDATE), v_sub, v_settle, v_status,
        CASE WHEN v_amt > 20 * v_scale THEN 1 + TRUNC(DBMS_RANDOM.VALUE(0,3))
             ELSE 4 + TRUNC(DBMS_RANDOM.VALUE(0,6)) END,
        v_bics(1 + TRUNC(DBMS_RANDOM.VALUE(0, v_bics.COUNT))),
        'REF' || LPAD(v_pid, 8, '0'));
    END LOOP;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('payments generated: ' || v_pid);
END;
/

-- ---------------------------------------------------------------------
-- Deterministic stress events: two large outflows that push accounts 102
-- (USD/Citi) and 105 (CHF/UBS) into daylight overdraft mid-morning, each
-- followed by a partial recovery inflow later in the day. These drive the
-- intraday breach and credit-utilisation alerts.
-- ---------------------------------------------------------------------
DECLARE
  v_pid NUMBER;
  PROCEDURE add_leg(p_acct NUMBER, p_dir VARCHAR2, p_amt NUMBER, p_ccy VARCHAR2,
                    p_hour NUMBER, p_min NUMBER, p_ref VARCHAR2) IS
    v_ts TIMESTAMP := CAST(TRUNC(SYSDATE) AS TIMESTAMP)
                      + NUMTODSINTERVAL(p_hour * 60 + p_min, 'MINUTE');
  BEGIN
    v_pid := v_pid + 1;
    INSERT INTO payment_instructions (
      payment_id, uetr, account_id, direction, payment_type, amount, ccy_code,
      value_date, submitted_ts, settled_ts, status, priority, counterparty_bic, client_ref)
    VALUES (v_pid, LOWER(RAWTOHEX(SYS_GUID())), p_acct, p_dir, 'RTGS', p_amt, p_ccy,
            TRUNC(SYSDATE), v_ts - INTERVAL '10' MINUTE, v_ts, 'SETTLED', 1,
            'HSBCGB2LXXX', p_ref);
  END;
BEGIN
  SELECT MAX(payment_id) INTO v_pid FROM payment_instructions;
  add_leg(102, 'OUT', 78000000, 'USD', 10, 15, 'STRESS-USD-OUT-1');
  add_leg(102, 'IN',  55000000, 'USD', 13, 30, 'STRESS-USD-IN-1');
  add_leg(105, 'OUT', 36000000, 'CHF', 11,  0, 'STRESS-CHF-OUT-1');
  add_leg(105, 'IN',  20000000, 'CHF', 15,  0, 'STRESS-CHF-IN-1');
END;
/

-- Format the UETR like a real one (8-4-4-4-12)
UPDATE payment_instructions
   SET uetr = SUBSTR(uetr,1,8)||'-'||SUBSTR(uetr,9,4)||'-'||SUBSTR(uetr,13,4)||'-'
              ||SUBSTR(uetr,17,4)||'-'||SUBSTR(uetr,21,12);

-- ---------------------------------------------------------------------
-- Intraday balance ladder, derived from the payment traffic so that the
-- time series and the payments always agree.
-- 30-minute grid, 08:00 -> 17:30.
-- ---------------------------------------------------------------------
INSERT INTO intraday_balances (
  snapshot_id, account_id, business_date, snapshot_ts, opening_bal, ledger_bal,
  pending_out, pending_in, projected_eod_bal, credit_used)
WITH slots AS (
  SELECT LEVEL AS slot_no,
         CAST(TRUNC(SYSDATE) + INTERVAL '8' HOUR AS TIMESTAMP)
           + NUMTODSINTERVAL((LEVEL - 1) * 30, 'MINUTE') AS snapshot_ts
    FROM dual CONNECT BY LEVEL <= 20
), grid AS (
  SELECT a.account_id, a.opening_ledger_bal, s.slot_no, s.snapshot_ts
    FROM accounts a CROSS JOIN slots s
), agg AS (
  SELECT g.account_id, g.slot_no, g.snapshot_ts, g.opening_ledger_bal,
         NVL(SUM(CASE WHEN p.status = 'SETTLED' AND p.settled_ts <= g.snapshot_ts
                      THEN CASE WHEN p.direction = 'IN' THEN p.amount ELSE -p.amount END END), 0) AS settled_net,
         NVL(SUM(CASE WHEN p.status IN ('QUEUED','PENDING','HELD')
                       AND p.direction = 'OUT' AND p.submitted_ts <= g.snapshot_ts
                      THEN p.amount END), 0) AS pending_out,
         NVL(SUM(CASE WHEN p.status IN ('QUEUED','PENDING')
                       AND p.direction = 'IN' AND p.submitted_ts <= g.snapshot_ts
                      THEN p.amount END), 0) AS pending_in
    FROM grid g
    LEFT JOIN payment_instructions p ON p.account_id = g.account_id
   GROUP BY g.account_id, g.slot_no, g.snapshot_ts, g.opening_ledger_bal
)
SELECT ROW_NUMBER() OVER (ORDER BY account_id, slot_no)     AS snapshot_id,
       account_id,
       TRUNC(SYSDATE)                                        AS business_date,
       snapshot_ts,
       opening_ledger_bal                                    AS opening_bal,
       ROUND(opening_ledger_bal + settled_net, 2)            AS ledger_bal,
       ROUND(pending_out, 2),
       ROUND(pending_in, 2),
       ROUND(opening_ledger_bal + settled_net + pending_in - pending_out, 2) AS projected_eod_bal,
       GREATEST(ROUND(-(opening_ledger_bal + settled_net), 2), 0)            AS credit_used
  FROM agg;

-- ---------------------------------------------------------------------
-- Hourly cash-flow forecast (08:00 -> 18:00) built from the day's traffic
-- with a confidence that decays for the later buckets.
-- ---------------------------------------------------------------------
INSERT INTO cashflow_forecast (forecast_id, account_id, bucket_start_ts, expected_in, expected_out, confidence_pct)
WITH buckets AS (
  SELECT LEVEL AS bucket_no,
         CAST(TRUNC(SYSDATE) + INTERVAL '8' HOUR AS TIMESTAMP)
           + NUMTODSINTERVAL((LEVEL - 1) * 60, 'MINUTE') AS bucket_start_ts
    FROM dual CONNECT BY LEVEL <= 10
)
SELECT ROW_NUMBER() OVER (ORDER BY a.account_id, b.bucket_no),
       a.account_id,
       b.bucket_start_ts,
       ROUND(a.opening_ledger_bal * 0.045 * (1 + MOD(b.bucket_no, 3) * 0.25), 2),
       ROUND(a.opening_ledger_bal * 0.048 * (1 + MOD(b.bucket_no + 1, 3) * 0.30), 2),
       GREATEST(95 - b.bucket_no * 4, 55)
  FROM accounts a CROSS JOIN buckets b;

-- ---------------------------------------------------------------------
-- Intraday funding transfers actually executed by the desk
-- ---------------------------------------------------------------------
INSERT INTO funding_transfers VALUES (1,101,102,35000000,'USD',
  CAST(TRUNC(SYSDATE)+INTERVAL '10' HOUR AS TIMESTAMP), CAST(TRUNC(SYSDATE)+INTERVAL '10' HOUR AS TIMESTAMP)+INTERVAL '12' MINUTE,
  'COMPLETED','Top-up ahead of Fedwire peak','desk.nyc');
INSERT INTO funding_transfers VALUES (2,103,110,12000000,'EUR',
  CAST(TRUNC(SYSDATE)+INTERVAL '11' HOUR AS TIMESTAMP), CAST(TRUNC(SYSDATE)+INTERVAL '11' HOUR AS TIMESTAMP)+INTERVAL '8' MINUTE,
  'COMPLETED','Rebalance EUR pool','desk.fra');
INSERT INTO funding_transfers VALUES (3,101,105, 9000000,'CHF',
  CAST(TRUNC(SYSDATE)+INTERVAL '13' HOUR AS TIMESTAMP), NULL,
  'IN_FLIGHT','FX-funded top-up USDCHF for CHF gap','desk.zrh');
INSERT INTO funding_transfers VALUES (4,102,101,18000000,'USD',
  CAST(TRUNC(SYSDATE)+INTERVAL '14' HOUR AS TIMESTAMP)+INTERVAL '30' MINUTE, NULL,
  'FAILED','Sweep excess to concentration account','auto.sweep');
INSERT INTO funding_transfers VALUES (5,104,103, 6500000,'GBP',
  CAST(TRUNC(SYSDATE)+INTERVAL '15' HOUR AS TIMESTAMP), CAST(TRUNC(SYSDATE)+INTERVAL '15' HOUR AS TIMESTAMP)+INTERVAL '5' MINUTE,
  'COMPLETED','FX-funded GBPEUR pre-cutoff move','desk.ldn');

-- ---------------------------------------------------------------------
-- Alerts: derived from the ladder, plus operational alerts
-- ---------------------------------------------------------------------
INSERT INTO liquidity_alerts (alert_id, account_id, raised_ts, alert_type, severity, message, status, cleared_ts)
WITH breaches AS (
  SELECT b.account_id, b.snapshot_ts, b.ledger_bal, b.credit_used, a.min_balance, a.intraday_credit_limit,
         ROW_NUMBER() OVER (PARTITION BY b.account_id,
                            CASE WHEN b.ledger_bal < a.min_balance THEN 1 ELSE 2 END
                            ORDER BY b.snapshot_ts) AS rn,
         CASE WHEN b.ledger_bal < a.min_balance THEN 'MIN_BALANCE_BREACH'
              WHEN a.intraday_credit_limit > 0 AND b.credit_used > 0.8 * a.intraday_credit_limit
                   THEN 'CREDIT_LIMIT_UTILISATION'
         END AS alert_type
    FROM intraday_balances b
    JOIN accounts a ON a.account_id = b.account_id
   WHERE b.ledger_bal < a.min_balance
      OR (a.intraday_credit_limit > 0 AND b.credit_used > 0.8 * a.intraday_credit_limit)
)
SELECT ROW_NUMBER() OVER (ORDER BY account_id, snapshot_ts) AS alert_id,
       account_id,
       snapshot_ts,
       alert_type,
       CASE WHEN alert_type = 'MIN_BALANCE_BREACH' THEN 'CRITICAL' ELSE 'HIGH' END,
       CASE WHEN alert_type = 'MIN_BALANCE_BREACH'
            THEN 'Ledger balance ' || TO_CHAR(ledger_bal, 'FM999,999,999,990.00')
                 || ' fell below the contractual floor of ' || TO_CHAR(min_balance, 'FM999,999,999,990.00')
            ELSE 'Daylight overdraft usage ' || TO_CHAR(credit_used, 'FM999,999,999,990.00')
                 || ' exceeds 80% of the ' || TO_CHAR(intraday_credit_limit, 'FM999,999,999,990.00') || ' intraday line'
       END,
       'OPEN', NULL
  FROM breaches
 WHERE rn = 1 AND alert_type IS NOT NULL;

DECLARE
  v_next NUMBER;
BEGIN
  SELECT NVL(MAX(alert_id), 0) INTO v_next FROM liquidity_alerts;

  INSERT INTO liquidity_alerts VALUES (v_next + 1, 102,
    CAST(TRUNC(SYSDATE) + INTERVAL '9' HOUR AS TIMESTAMP) + INTERVAL '45' MINUTE,
    'LARGE_OUTFLOW','HIGH',
    'Single RTGS outflow above 15% of the opening balance released without pre-funding','ACKNOWLEDGED',NULL);

  INSERT INTO liquidity_alerts VALUES (v_next + 2, 105,
    CAST(TRUNC(SYSDATE) + INTERVAL '13' HOUR AS TIMESTAMP) + INTERVAL '15' MINUTE,
    'PROJECTED_SHORTFALL','CRITICAL',
    'Projected end-of-day balance is below the target buffer; funding transfer 3 is still in flight','OPEN',NULL);

  INSERT INTO liquidity_alerts VALUES (v_next + 3, 104,
    CAST(TRUNC(SYSDATE) + INTERVAL '15' HOUR AS TIMESTAMP) + INTERVAL '50' MINUTE,
    'CUTOFF_RISK','MEDIUM',
    'Queued CHAPS payments remain unsettled 70 minutes before the 17:00 cut-off','OPEN',NULL);

  INSERT INTO liquidity_alerts VALUES (v_next + 4, 106,
    CAST(TRUNC(SYSDATE) + INTERVAL '11' HOUR AS TIMESTAMP),
    'QUEUE_BUILDUP','MEDIUM',
    'BOJNET queue depth above the intraday threshold for more than 30 minutes','CLOSED',
    CAST(TRUNC(SYSDATE) + INTERVAL '12' HOUR AS TIMESTAMP));

  INSERT INTO liquidity_alerts VALUES (v_next + 5, 103,
    CAST(TRUNC(SYSDATE) + INTERVAL '14' HOUR AS TIMESTAMP) + INTERVAL '20' MINUTE,
    'CREDIT_LIMIT_UTILISATION','MEDIUM',
    'TARGET2 intraday credit utilisation crossed 60% of the agreed line','ACKNOWLEDGED',NULL);
END;
/

COMMIT;

-- ---------------------------------------------------------------------
-- Optimiser statistics + a short load report
-- ---------------------------------------------------------------------
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS('BIR');
END;
/

SET SERVEROUTPUT ON
DECLARE
  v NUMBER;
  PROCEDURE p(p_label VARCHAR2, p_cnt NUMBER) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_label, 26) || TO_CHAR(p_cnt));
  END;
BEGIN
  SELECT COUNT(*) INTO v FROM currencies;           p('currencies', v);
  SELECT COUNT(*) INTO v FROM correspondents;       p('correspondents', v);
  SELECT COUNT(*) INTO v FROM accounts;             p('accounts', v);
  SELECT COUNT(*) INTO v FROM cutoff_times;         p('cutoff_times', v);
  SELECT COUNT(*) INTO v FROM payment_instructions; p('payment_instructions', v);
  SELECT COUNT(*) INTO v FROM intraday_balances;    p('intraday_balances', v);
  SELECT COUNT(*) INTO v FROM cashflow_forecast;    p('cashflow_forecast', v);
  SELECT COUNT(*) INTO v FROM funding_transfers;    p('funding_transfers', v);
  SELECT COUNT(*) INTO v FROM liquidity_alerts;     p('liquidity_alerts', v);
  SELECT COUNT(*) INTO v FROM fx_rates;             p('fx_rates', v);
END;
/
ALTER SESSION SET CURRENT_SCHEMA = bir;
COMMENT ON TABLE accounts IS 'Nostro and vostro accounts held with correspondent banks, with the intraday limits that apply to each';
COMMENT ON TABLE correspondents IS 'Correspondent banks: BIC, country, tier and credit rating';
COMMENT ON TABLE currencies IS 'Settlement currencies, their RTGS system and market time zone';
COMMENT ON TABLE cutoff_times IS 'Payment cut-off time per account and payment type, in the market time zone';
COMMENT ON TABLE intraday_balances IS 'Balance ladder on a 30-minute grid: settled position, pending flows and projected end-of-day balance per account';
COMMENT ON TABLE payment_instructions IS 'Payment traffic for the business day: settled, queued, pending, held and rejected instructions with their UETR';
COMMENT ON TABLE funding_transfers IS 'Intraday liquidity transfers executed between own accounts';
COMMENT ON TABLE cashflow_forecast IS 'Hourly expected inflow and outflow per account with a confidence percentage';
COMMENT ON TABLE liquidity_alerts IS 'Alerts raised by the intraday monitor: balance breaches, shortfalls, cut-off and queue risks';
COMMENT ON TABLE fx_rates IS 'Mid rates used to express positions in the USD reporting currency';

COMMENT ON COLUMN accounts.account_no IS 'External account identifier';
COMMENT ON COLUMN accounts.account_type IS 'NOSTRO (our account with them) or VOSTRO (their account with us)';
COMMENT ON COLUMN accounts.opening_ledger_bal IS 'Settled balance at the start of the business day';
COMMENT ON COLUMN accounts.min_balance IS 'Contractual or regulatory floor the balance must not fall below';
COMMENT ON COLUMN accounts.target_buffer IS 'Desired end-of-day cushion';
COMMENT ON COLUMN accounts.intraday_credit_limit IS 'Uncommitted daylight overdraft line granted by the correspondent';
COMMENT ON COLUMN intraday_balances.ledger_bal IS 'Settled position at the snapshot timestamp';
COMMENT ON COLUMN intraday_balances.pending_out IS 'Outgoing amount submitted but not yet settled at the snapshot';
COMMENT ON COLUMN intraday_balances.pending_in IS 'Incoming amount expected but not yet settled at the snapshot';
COMMENT ON COLUMN intraday_balances.projected_eod_bal IS 'Ledger balance plus pending inflows minus pending outflows';
COMMENT ON COLUMN intraday_balances.credit_used IS 'Daylight overdraft drawn at the snapshot, zero when the balance is positive';
COMMENT ON COLUMN payment_instructions.direction IS 'IN for incoming, OUT for outgoing';
COMMENT ON COLUMN payment_instructions.status IS 'SETTLED, QUEUED, PENDING, HELD or REJECTED';
COMMENT ON COLUMN payment_instructions.priority IS 'Settlement priority, 1 is most urgent, 9 least';
COMMENT ON COLUMN payment_instructions.uetr IS 'Unique end-to-end transaction reference (SWIFT gpi)';
COMMENT ON COLUMN payment_instructions.settled_ts IS 'Settlement timestamp, null while the payment is unsettled';
COMMENT ON COLUMN liquidity_alerts.alert_type IS 'MIN_BALANCE_BREACH, CREDIT_LIMIT_UTILISATION, PROJECTED_SHORTFALL, CUTOFF_RISK, LARGE_OUTFLOW or QUEUE_BUILDUP';
COMMENT ON COLUMN liquidity_alerts.severity IS 'LOW, MEDIUM, HIGH or CRITICAL';
COMMENT ON COLUMN funding_transfers.status IS 'COMPLETED, IN_FLIGHT or FAILED';
COMMENT ON COLUMN cashflow_forecast.confidence_pct IS 'Confidence in the forecast bucket, decaying for later hours';
COMMIT;
