-- =====================================================================
-- BIR PoC : Correspondent-Account Liquidity Management (Intraday)
-- Schema owner : BIR
-- Target       : Oracle Database 23ai Free (PDB: FREEPDB1)
-- =====================================================================
SET ECHO ON
SET FEEDBACK ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

-- ---------------------------------------------------------------------
-- Application user
-- ---------------------------------------------------------------------
DECLARE
  v_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username = 'BIR';
  IF v_cnt = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER bir IDENTIFIED BY "&&bir_pwd." '
                   || 'DEFAULT TABLESPACE users QUOTA UNLIMITED ON users';
  END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE MATERIALIZED VIEW TO bir;

ALTER SESSION SET CURRENT_SCHEMA = bir;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE bir.currencies (
  ccy_code        VARCHAR2(3)   CONSTRAINT pk_currencies PRIMARY KEY,
  ccy_name        VARCHAR2(60)  NOT NULL,
  minor_units     NUMBER(1)     DEFAULT 2 NOT NULL,
  rtgs_system     VARCHAR2(20),
  tz_name         VARCHAR2(40)  NOT NULL
);

CREATE TABLE bir.correspondents (
  corr_id         NUMBER(6)     CONSTRAINT pk_correspondents PRIMARY KEY,
  bic             VARCHAR2(11)  NOT NULL CONSTRAINT uq_corr_bic UNIQUE,
  legal_name      VARCHAR2(120) NOT NULL,
  country_code    VARCHAR2(2)   NOT NULL,
  tier            VARCHAR2(10)  NOT NULL
     CONSTRAINT ck_corr_tier CHECK (tier IN ('TIER1','TIER2','TIER3')),
  credit_rating   VARCHAR2(5),
  relationship_since DATE,
  is_active       CHAR(1) DEFAULT 'Y' NOT NULL
     CONSTRAINT ck_corr_active CHECK (is_active IN ('Y','N'))
);

-- ---------------------------------------------------------------------
-- Accounts held with / for correspondents
-- ---------------------------------------------------------------------
CREATE TABLE bir.accounts (
  account_id      NUMBER(6)     CONSTRAINT pk_accounts PRIMARY KEY,
  account_no      VARCHAR2(34)  NOT NULL CONSTRAINT uq_acct_no UNIQUE,
  account_type    VARCHAR2(8)   NOT NULL
     CONSTRAINT ck_acct_type CHECK (account_type IN ('NOSTRO','VOSTRO')),
  corr_id         NUMBER(6)     NOT NULL
     CONSTRAINT fk_acct_corr REFERENCES bir.correspondents(corr_id),
  ccy_code        VARCHAR2(3)   NOT NULL
     CONSTRAINT fk_acct_ccy REFERENCES bir.currencies(ccy_code),
  opening_ledger_bal   NUMBER(18,2) DEFAULT 0 NOT NULL,
  min_balance          NUMBER(18,2) DEFAULT 0 NOT NULL,   -- regulatory / contractual floor
  target_buffer        NUMBER(18,2) DEFAULT 0 NOT NULL,   -- desired end-of-day cushion
  intraday_credit_limit NUMBER(18,2) DEFAULT 0 NOT NULL,  -- uncommitted daylight overdraft
  is_active       CHAR(1) DEFAULT 'Y' NOT NULL
     CONSTRAINT ck_acct_active CHECK (is_active IN ('Y','N'))
);
CREATE INDEX bir.ix_acct_corr ON bir.accounts(corr_id);
CREATE INDEX bir.ix_acct_ccy  ON bir.accounts(ccy_code);

-- ---------------------------------------------------------------------
-- Cut-off calendar (per account / payment type)
-- ---------------------------------------------------------------------
CREATE TABLE bir.cutoff_times (
  cutoff_id       NUMBER(6)     CONSTRAINT pk_cutoff PRIMARY KEY,
  account_id      NUMBER(6)     NOT NULL
     CONSTRAINT fk_cutoff_acct REFERENCES bir.accounts(account_id),
  payment_type    VARCHAR2(12)  NOT NULL
     CONSTRAINT ck_cutoff_ptype CHECK (payment_type IN ('RTGS','SWIFT','INTERNAL','SECURITIES','FX')),
  cutoff_local    VARCHAR2(5)   NOT NULL,   -- HH24:MI in the account's market time zone
  warning_lead_min NUMBER(4) DEFAULT 30 NOT NULL
);
CREATE INDEX bir.ix_cutoff_acct ON bir.cutoff_times(account_id);

-- ---------------------------------------------------------------------
-- Intraday balance time series (30-minute grid, per account)
-- ---------------------------------------------------------------------
CREATE TABLE bir.intraday_balances (
  snapshot_id     NUMBER(10)    CONSTRAINT pk_intraday_bal PRIMARY KEY,
  account_id      NUMBER(6)     NOT NULL
     CONSTRAINT fk_bal_acct REFERENCES bir.accounts(account_id),
  business_date   DATE          NOT NULL,
  snapshot_ts     TIMESTAMP     NOT NULL,
  opening_bal     NUMBER(18,2)  NOT NULL,
  ledger_bal      NUMBER(18,2)  NOT NULL,   -- settled position at snapshot_ts
  pending_out     NUMBER(18,2)  DEFAULT 0 NOT NULL,
  pending_in      NUMBER(18,2)  DEFAULT 0 NOT NULL,
  projected_eod_bal NUMBER(18,2) NOT NULL,
  credit_used     NUMBER(18,2)  DEFAULT 0 NOT NULL,
  CONSTRAINT uq_bal_acct_ts UNIQUE (account_id, snapshot_ts)
);
CREATE INDEX bir.ix_bal_ts ON bir.intraday_balances(snapshot_ts);

-- ---------------------------------------------------------------------
-- Payment instructions hitting the accounts
-- ---------------------------------------------------------------------
CREATE TABLE bir.payment_instructions (
  payment_id      NUMBER(10)    CONSTRAINT pk_payments PRIMARY KEY,
  uetr            VARCHAR2(36)  NOT NULL CONSTRAINT uq_pay_uetr UNIQUE,
  account_id      NUMBER(6)     NOT NULL
     CONSTRAINT fk_pay_acct REFERENCES bir.accounts(account_id),
  direction       VARCHAR2(3)   NOT NULL
     CONSTRAINT ck_pay_dir CHECK (direction IN ('IN','OUT')),
  payment_type    VARCHAR2(12)  NOT NULL
     CONSTRAINT ck_pay_ptype CHECK (payment_type IN ('RTGS','SWIFT','INTERNAL','SECURITIES','FX')),
  amount          NUMBER(18,2)  NOT NULL CONSTRAINT ck_pay_amt CHECK (amount > 0),
  ccy_code        VARCHAR2(3)   NOT NULL
     CONSTRAINT fk_pay_ccy REFERENCES bir.currencies(ccy_code),
  value_date      DATE          NOT NULL,
  submitted_ts    TIMESTAMP     NOT NULL,
  settled_ts      TIMESTAMP,
  status          VARCHAR2(10)  NOT NULL
     CONSTRAINT ck_pay_status CHECK (status IN ('SETTLED','QUEUED','PENDING','HELD','REJECTED')),
  priority        NUMBER(1)     DEFAULT 5 NOT NULL
     CONSTRAINT ck_pay_prio CHECK (priority BETWEEN 1 AND 9),   -- 1 = most urgent
  counterparty_bic VARCHAR2(11),
  client_ref      VARCHAR2(35)
);
CREATE INDEX bir.ix_pay_acct_status ON bir.payment_instructions(account_id, status);
CREATE INDEX bir.ix_pay_submitted   ON bir.payment_instructions(submitted_ts);
CREATE INDEX bir.ix_pay_valuedate   ON bir.payment_instructions(value_date);

-- ---------------------------------------------------------------------
-- Intraday funding moves between own accounts (liquidity transfers)
-- ---------------------------------------------------------------------
CREATE TABLE bir.funding_transfers (
  transfer_id     NUMBER(8)     CONSTRAINT pk_funding PRIMARY KEY,
  from_account_id NUMBER(6)     NOT NULL
     CONSTRAINT fk_fund_from REFERENCES bir.accounts(account_id),
  to_account_id   NUMBER(6)     NOT NULL
     CONSTRAINT fk_fund_to REFERENCES bir.accounts(account_id),
  amount          NUMBER(18,2)  NOT NULL,
  ccy_code        VARCHAR2(3)   NOT NULL
     CONSTRAINT fk_fund_ccy REFERENCES bir.currencies(ccy_code),
  initiated_ts    TIMESTAMP     NOT NULL,
  completed_ts    TIMESTAMP,
  status          VARCHAR2(10)  NOT NULL
     CONSTRAINT ck_fund_status CHECK (status IN ('COMPLETED','IN_FLIGHT','FAILED')),
  purpose         VARCHAR2(40)  NOT NULL,
  requested_by    VARCHAR2(40)
);

-- ---------------------------------------------------------------------
-- Forward-looking cash-flow buckets (hourly forecast per account)
-- ---------------------------------------------------------------------
CREATE TABLE bir.cashflow_forecast (
  forecast_id     NUMBER(10)    CONSTRAINT pk_forecast PRIMARY KEY,
  account_id      NUMBER(6)     NOT NULL
     CONSTRAINT fk_fc_acct REFERENCES bir.accounts(account_id),
  bucket_start_ts TIMESTAMP     NOT NULL,
  expected_in     NUMBER(18,2)  DEFAULT 0 NOT NULL,
  expected_out    NUMBER(18,2)  DEFAULT 0 NOT NULL,
  confidence_pct  NUMBER(3)     DEFAULT 80 NOT NULL,
  CONSTRAINT uq_fc_acct_bucket UNIQUE (account_id, bucket_start_ts)
);

-- ---------------------------------------------------------------------
-- Liquidity alerts raised by the intraday monitor
-- ---------------------------------------------------------------------
CREATE TABLE bir.liquidity_alerts (
  alert_id        NUMBER(8)     CONSTRAINT pk_alerts PRIMARY KEY,
  account_id      NUMBER(6)     NOT NULL
     CONSTRAINT fk_alert_acct REFERENCES bir.accounts(account_id),
  raised_ts       TIMESTAMP     NOT NULL,
  alert_type      VARCHAR2(24)  NOT NULL
     CONSTRAINT ck_alert_type CHECK (alert_type IN
       ('MIN_BALANCE_BREACH','CREDIT_LIMIT_UTILISATION','PROJECTED_SHORTFALL',
        'CUTOFF_RISK','LARGE_OUTFLOW','QUEUE_BUILDUP')),
  severity        VARCHAR2(8)   NOT NULL
     CONSTRAINT ck_alert_sev CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  message         VARCHAR2(400) NOT NULL,
  status          VARCHAR2(12)  DEFAULT 'OPEN' NOT NULL
     CONSTRAINT ck_alert_status CHECK (status IN ('OPEN','ACKNOWLEDGED','CLOSED')),
  cleared_ts      TIMESTAMP
);
CREATE INDEX bir.ix_alert_acct ON bir.liquidity_alerts(account_id, raised_ts);

-- ---------------------------------------------------------------------
-- FX rates used to express positions in the USD reporting currency
-- ---------------------------------------------------------------------
CREATE TABLE bir.fx_rates (
  base_ccy        VARCHAR2(3)   NOT NULL,
  quote_ccy       VARCHAR2(3)   NOT NULL,
  rate_date       DATE          NOT NULL,
  mid_rate        NUMBER(18,8)  NOT NULL,
  CONSTRAINT pk_fx PRIMARY KEY (base_ccy, quote_ccy, rate_date)
);

-- =====================================================================
-- Analytical views
-- =====================================================================

-- Latest snapshot per account, enriched with limits and USD equivalent.
CREATE OR REPLACE VIEW bir.v_account_position_now AS
SELECT a.account_id,
       a.account_no,
       a.account_type,
       c.bic                AS correspondent_bic,
       c.legal_name         AS correspondent_name,
       a.ccy_code,
       b.snapshot_ts,
       b.opening_bal,
       b.ledger_bal,
       b.pending_in,
       b.pending_out,
       b.projected_eod_bal,
       a.min_balance,
       a.target_buffer,
       a.intraday_credit_limit,
       b.credit_used,
       ROUND(CASE WHEN a.intraday_credit_limit > 0
                  THEN 100 * b.credit_used / a.intraday_credit_limit END, 1) AS credit_util_pct,
       b.ledger_bal - a.min_balance                       AS headroom_over_min,
       b.ledger_bal + a.intraday_credit_limit - b.credit_used AS available_liquidity,
       ROUND(b.ledger_bal * NVL(fx.mid_rate, 1), 2)       AS ledger_bal_usd
  FROM bir.accounts a
  JOIN bir.correspondents c ON c.corr_id = a.corr_id
  JOIN bir.intraday_balances b ON b.account_id = a.account_id
  LEFT JOIN bir.fx_rates fx
         ON fx.base_ccy = a.ccy_code
        AND fx.quote_ccy = 'USD'
        AND fx.rate_date = b.business_date
 WHERE b.snapshot_ts = (SELECT MAX(b2.snapshot_ts)
                          FROM bir.intraday_balances b2
                         WHERE b2.account_id = b.account_id);

-- Full intraday ladder: balance path plus limit breach flags.
CREATE OR REPLACE VIEW bir.v_intraday_ladder AS
SELECT b.account_id,
       a.account_no,
       a.ccy_code,
       b.business_date,
       b.snapshot_ts,
       b.ledger_bal,
       b.projected_eod_bal,
       b.credit_used,
       a.min_balance,
       a.intraday_credit_limit,
       CASE WHEN b.ledger_bal < a.min_balance THEN 'Y' ELSE 'N' END AS below_min_flag,
       CASE WHEN b.credit_used > 0.8 * NULLIF(a.intraday_credit_limit,0)
            THEN 'Y' ELSE 'N' END AS credit_stress_flag
  FROM bir.intraday_balances b
  JOIN bir.accounts a ON a.account_id = b.account_id;

-- Outgoing payments still waiting for liquidity, with queue ageing.
CREATE OR REPLACE VIEW bir.v_queued_payments AS
SELECT p.payment_id,
       p.uetr,
       p.account_id,
       a.account_no,
       a.ccy_code,
       p.payment_type,
       p.amount,
       p.priority,
       p.counterparty_bic,
       p.submitted_ts,
       ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(p.submitted_ts AS DATE)) * 1440) AS queued_minutes,
       p.status
  FROM bir.payment_instructions p
  JOIN bir.accounts a ON a.account_id = p.account_id
 WHERE p.direction = 'OUT'
   AND p.status IN ('QUEUED','HELD','PENDING');

-- Net intraday flow per account and per hour (settled traffic only).
CREATE OR REPLACE VIEW bir.v_hourly_flows AS
SELECT p.account_id,
       a.account_no,
       a.ccy_code,
       TRUNC(CAST(p.settled_ts AS DATE), 'HH24')                       AS flow_hour,
       SUM(CASE WHEN p.direction = 'IN'  THEN p.amount ELSE 0 END)     AS inflow,
       SUM(CASE WHEN p.direction = 'OUT' THEN p.amount ELSE 0 END)     AS outflow,
       SUM(CASE WHEN p.direction = 'IN'  THEN p.amount ELSE -p.amount END) AS net_flow,
       COUNT(*)                                                        AS payment_count
  FROM bir.payment_instructions p
  JOIN bir.accounts a ON a.account_id = p.account_id
 WHERE p.status = 'SETTLED'
 GROUP BY p.account_id, a.account_no, a.ccy_code, TRUNC(CAST(p.settled_ts AS DATE), 'HH24');

-- Open alerts joined to the account context.
CREATE OR REPLACE VIEW bir.v_open_alerts AS
SELECT al.alert_id,
       al.raised_ts,
       al.alert_type,
       al.severity,
       al.message,
       al.status,
       a.account_id,
       a.account_no,
       a.ccy_code,
       c.bic AS correspondent_bic,
       c.legal_name AS correspondent_name
  FROM bir.liquidity_alerts al
  JOIN bir.accounts a ON a.account_id = al.account_id
  JOIN bir.correspondents c ON c.corr_id = a.corr_id
 WHERE al.status <> 'CLOSED';

-- Funding gap: what each account still needs to reach its target buffer.
CREATE OR REPLACE VIEW bir.v_funding_requirements AS
SELECT pn.account_id,
       pn.account_no,
       pn.ccy_code,
       pn.correspondent_name,
       pn.ledger_bal,
       pn.projected_eod_bal,
       pn.min_balance,
       pn.target_buffer,
       GREATEST(pn.target_buffer - pn.projected_eod_bal, 0) AS funding_gap,
       CASE
         WHEN pn.projected_eod_bal < pn.min_balance                THEN 'CRITICAL'
         WHEN pn.projected_eod_bal < pn.target_buffer              THEN 'SHORT'
         WHEN pn.projected_eod_bal > 2 * pn.target_buffer          THEN 'EXCESS'
         ELSE 'BALANCED'
       END AS funding_status
  FROM bir.v_account_position_now pn;

COMMIT;

-- ---------------------------------------------------------------------
-- Read-only user used by the MCP server
-- ---------------------------------------------------------------------
DECLARE
  v_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username = 'BIR_RO';
  IF v_cnt = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER bir_ro IDENTIFIED BY "&&bir_ro_pwd."';
  END IF;
END;
/

GRANT CREATE SESSION TO bir_ro;
ALTER USER bir_ro DEFAULT TABLESPACE users;

BEGIN
  FOR o IN (SELECT object_name, object_type
              FROM dba_objects
             WHERE owner = 'BIR'
               AND object_type IN ('TABLE','VIEW')) LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT ON bir.' || o.object_name || ' TO bir_ro';
  END LOOP;
END;
/

-- Unqualified names in a BIR_RO session resolve against the BIR schema, so
-- ad-hoc SQL from an MCP client does not need to prefix every table.
CREATE OR REPLACE TRIGGER bir_ro_default_schema
  AFTER LOGON ON bir_ro.SCHEMA
BEGIN
  EXECUTE IMMEDIATE 'ALTER SESSION SET CURRENT_SCHEMA = BIR';
END;
/
