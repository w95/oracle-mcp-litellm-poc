# BIR PoC — Oracle + MCP + LiteLLM

Proof of concept for **Correspondent-Account Liquidity Management (intraday)**:
an Oracle database carrying a realistic intraday-liquidity data set, reached by
off-the-shelf **Oracle MCP servers** through a **LiteLLM** gateway.

Three wirings of the same idea run side by side, so they can be compared:

```
                    ┌────────────────────────────────────────────────┐
  MCP client / LLM ▶│ LiteLLM proxy                 :4000  /mcp      │
                    │  config-only: no database                      │
                    │                                                │
                    │  path2: oracledb-mcp-server, spawned here      │
                    │         per call with uvx                      │
                    └───┬──────────┬───────────────────────┬─────────┘
                        │ HTTP     │ HTTP                  │
        ┌───────────────▼──┐  ┌────▼─────────────────┐     │
        │ mcp-path1  :9011 │  │ mcp-path3     :9012  │     │
        │ dmeppiel image   │  │ python:3.12-slim     │     │
        │ + mcp-proxy      │  │ + mcp-proxy          │     │
        │ 15 tools         │  │ 5 tools              │     │
        └───────────────┬──┘  └────┬─────────────────┘     │
                        │          │                       │
                    ┌───▼──────────▼───────────────────────▼─────────┐
                    │ Oracle DB Free (26ai)            :1522         │
                    │  PDB FREEPDB1, schema BIR                      │
                    └────────────────────────────────────────────────┘
```

Four containers: the database, one per HTTP-served path, and the proxy (which
hosts path2 itself). Every path queries as `BIR_RO`, so none of them can write.

> **Note on the database version.** The request was Oracle 19c. There is no
> ARM64 Oracle 19c container image, and this host is Apple Silicon — 19c would
> have to run under x86 emulation (~10 GB image, very slow start, frequently
> unstable). This PoC therefore runs the `database/free` image, currently
> **Oracle AI Database 26ai Free (23.26.3.0.0)**, which is natively ARM64.
> Nothing in the schema, the SQL or the MCP server is version-specific;
> pointing `docker-compose.yml` at a 19c image and switching the service name
> from `FREEPDB1` to `ORCLPDB1` is the porting delta.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Services: `oracle`, `oracle-init`, `mcp-path1`, `mcp-path3`, `litellm` |
| `.env` | Ports, passwords, optional provider keys |
| `oracle/sql/01_schema.sql` | Tables, indexes, views, `BIR` + `BIR_RO` users |
| `oracle/sql/02_seed.sql` | One business day of deterministic seed data |
| `oracle/setup/init.sh` | Idempotent loader run by the `oracle-init` service |
| `litellm/config.yaml` | LiteLLM proxy config: the three MCP servers |

## Run it

```bash
docker compose up -d
```

First start takes a few minutes: the Oracle container creates the database,
`oracle-init` then loads the schema and the seed data, and only afterwards does
`litellm` start (compose dependency conditions handle the ordering). Watch
progress with:

```bash
docker compose logs -f oracle-init
```

Ports (all configurable in `.env`):

| Service | Host port | Endpoint |
| --- | --- | --- |
| Oracle | 1522 | `localhost:1522/FREEPDB1` |
| LiteLLM | 4000 | `http://localhost:4000` (UI at `/ui`, MCP at `/mcp`) |
| path1 | 9011 | `http://localhost:9011/mcp` (dmeppiel image, bridged) |
| path3 | 9012 | `http://localhost:9012/mcp` (oracledb-mcp-server, bridged) |

## Data model

One business day (`TRUNC(SYSDATE)`), 8 correspondent banks, 10 nostro/vostro
accounts in 6 currencies.

| Table | Rows | Content |
| --- | --- | --- |
| `CURRENCIES` | 6 | Currency, RTGS system, market time zone |
| `CORRESPONDENTS` | 8 | Correspondent banks, BIC, tier, rating |
| `ACCOUNTS` | 10 | Nostro/vostro accounts, floor, target buffer, intraday credit line |
| `CUTOFF_TIMES` | 50 | Cut-off per account and payment type |
| `PAYMENT_INSTRUCTIONS` | 436 | Settled / queued / pending / held / rejected traffic with UETR |
| `INTRADAY_BALANCES` | 200 | 30-minute balance ladder, 08:00–17:30 |
| `CASHFLOW_FORECAST` | 100 | Hourly expected in/out with confidence |
| `FUNDING_TRANSFERS` | 5 | Intraday funding moves between own accounts |
| `LIQUIDITY_ALERTS` | 6 | Breaches, shortfalls, cut-off and queue alerts |
| `FX_RATES` | 6 | Rates to the USD reporting currency |

The balance ladder is **derived from the payment traffic**: each snapshot is
the opening balance plus the settled flows up to that timestamp, so the time
series and the payments always reconcile.

Views: `V_ACCOUNT_POSITION_NOW`, `V_INTRADAY_LADDER`, `V_QUEUED_PAYMENTS`,
`V_HOURLY_FLOWS`, `V_OPEN_ALERTS`, `V_FUNDING_REQUIREMENTS`.

Accounts 102 (USD/Citi) and 105 (CHF/UBS) are deliberately stressed: a heavy
outflow bias plus two large scripted RTGS outflows (10:15 and 11:00) with
partial recovery inflows later in the day. The result of the current seed is
account 105 `CRITICAL` (13 snapshots in daylight overdraft, peak credit usage
7.9m CHF), account 102 `SHORT`, the remaining eight `EXCESS` — so questions
about breaches, funding gaps and queued payments have real answers.

## MCP tools

The two off-the-shelf servers bring their own tool sets, all read-only:

| Server | Tools |
| --- | --- |
| `dmeppiel/oracle-mcp-server` (path1) | 15: `get_table_schema`, `get_tables_schema`, `search_tables_schema`, `search_columns`, `get_table_constraints`, `get_table_indexes`, `get_pl_sql_objects`, `get_object_source`, `get_dependent_objects`, `get_related_tables`, `get_user_defined_types`, `get_database_vendor_info`, `rebuild_schema_cache`, `run_sql_query`, `explain_query_plan` |
| `oracledb-mcp-server` (path2 and path3) | 5: `get_table_details`, `get_column_details`, `execute_sql`, `create_comment_db_connection`, `connect_to_database` |

Table and column comments were added to the schema (10 tables, 20 columns), so
both servers hand the model descriptions rather than bare names.

## Using it through LiteLLM

The MCP gateway is authenticated with the LiteLLM key. Any MCP client that can
send headers works:

```
URL:     http://localhost:4000/mcp
Headers: x-litellm-api-key: $LITELLM_MASTER_KEY
         x-mcp-servers: path1,path2,path3
```

Tools are namespaced with the server alias: `path1-run_sql_query`,
`path2-execute_sql`, `path3-execute_sql`. Drop names from `x-mcp-servers` to
expose only one path; omit the header for all three.

List the registered MCP servers over REST:

```bash
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://localhost:4000/v1/mcp/server | jq
```

To also route **LLM** traffic (so a model can call these tools itself), put a
provider key in `.env` (`ANTHROPIC_API_KEY=...`) and restart LiteLLM; the
`claude-sonnet-5` entry in `litellm/config.yaml` then becomes usable at
`/v1/chat/completions` with `"mcp_servers": ["path1"]`.

## Checking it works

```bash
curl -s -X POST http://localhost:4000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'x-litellm-api-key: $LITELLM_MASTER_KEY' \
  -H 'x-mcp-servers: path1' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

The reply carries a `litellm.ai/server_outcomes` block per server; `status: ok`
with a `tool_count` means the path is wired correctly. Current state:
`{'path1': 15, 'path2': 5, 'path3': 5}` - 25 tools in total.

## Database logins

Set in `.env`, created by `oracle/sql/01_schema.sql`:

| User | `.env` variable | Rights | Used for |
| --- | --- | --- | --- |
| `sys` | `ORACLE_PWD` | sysdba, service `FREE` | schema load, admin |
| `bir` | `BIR_PWD` | owns the schema | seed data; the metadata connection of `oracledb-mcp-server`, which reads `USER_TAB_COMMENTS` |
| `bir_ro` | `BIR_RO_PWD` | `CREATE SESSION` + `SELECT` on the BIR objects | every query from every path |

A logon trigger sets `CURRENT_SCHEMA = BIR` for `bir_ro`, so unqualified names
in ad-hoc SQL resolve without a `BIR.` prefix. LiteLLM's own credential is
`LITELLM_MASTER_KEY`; the UI at `/ui` takes `admin` plus that key as the
password.

There is no `.env` in the repository. Copy `.env.example`, set your own values,
and keep it out of version control:

```bash
cp .env.example .env
# then edit the passwords and the master key
```

These accounts only ever exist inside your own containers, but treat them like
any other credential: pick fresh values and never expose the ports beyond
localhost without changing them.

## Questions the data can answer

Useful as smoke tests for whichever path you are exercising:

```sql
-- which accounts will end the day short of their target buffer
SELECT account_no, ccy_code, projected_eod_bal, target_buffer, funding_gap, funding_status
  FROM v_funding_requirements ORDER BY funding_gap DESC;

-- the intraday dip on the stressed CHF account
SELECT snapshot_ts, ledger_bal, credit_used, below_min_flag
  FROM v_intraday_ladder WHERE account_id = 105 ORDER BY snapshot_ts;

-- outgoing payments still waiting for liquidity, worst first
SELECT account_no, ccy_code, amount, priority, queued_minutes, status
  FROM v_queued_payments ORDER BY priority, amount DESC;

-- open alerts by severity
SELECT severity, alert_type, account_no, message FROM v_open_alerts;
```

## No database behind the proxy

LiteLLM runs from `config.yaml` alone - there is no Postgres in this stack.
`general_settings` carries only the master key, and the MCP servers and models
come from the file:

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

Verified with the database removed: `/health/liveliness` 200, `/ui/` 200,
`/v1/mcp/server` 200 and all three paths return their tools.

What a database would add, and what is therefore unavailable here:

| Needs a DB | Works without one |
| --- | --- |
| Virtual keys, teams, budgets (`/key/generate` returns *"DB not connected"*) | The master key as the single credential |
| Spend and request logs | Health endpoints, the MCP gateway, model routing |
| Adding models or MCP servers through the UI | Everything declared in `config.yaml` |

To put it back: run a Postgres service, set `DATABASE_URL` and
`STORE_MODEL_IN_DB=True` on the proxy, and add `database_url` /
`store_model_in_db` to `general_settings`.

## Three ways to wire an MCP server

All three are live in `litellm/config.yaml`. Same database, same read-only
login; what differs is where the MCP process runs and how it is reached.

| Alias | What runs | Where | Tools |
| --- | --- | --- | --- |
| `path1` | `dmeppiel/oracle-mcp-server` | own container (`mcp-path1`), bridged to HTTP | 15 |
| `path2` | `oracledb-mcp-server` | inside the proxy, spawned per call with `uvx` | 5 |
| `path3` | `oracledb-mcp-server` | own container (`mcp-path3`), bridged to HTTP | 5 |

### path1 - a published image as its own container

Every off-the-shelf Oracle MCP server speaks **stdio only**: it reads the pipes
of whatever process started it. A compose service like

```yaml
  oracle-mcp-server:
    image: dmeppiel/oracle-mcp-server
    stdin_open: true
    tty: true
```

therefore starts a server that waits forever on a stdin nobody writes to. No
port is opened, and LiteLLM has nothing to connect to.

`mcp-proxy` closes that gap - it runs the stdio server as a child and exposes
it over streamable HTTP. The image already carries `uv`, so no image build is
needed:

```yaml
  mcp-path1:
    image: dmeppiel/oracle-mcp-server
    command:
      - sh
      - -c
      - |
        exec uvx --with "mcp<2" mcp-proxy --pass-environment \
          --host 0.0.0.0 --port 8000 --stateless -- uv run main.py
    environment:
      ORACLE_CONNECTION_STRING: "bir_ro/${BIR_RO_PWD}@oracle:1521/FREEPDB1"
      TARGET_SCHEMA: BIR
      READ_ONLY_MODE: "1"
```

```yaml
  path1:
    url: http://mcp-path1:8000/mcp
    transport: http
```

Two flags matter: `--pass-environment`, or mcp-proxy starts the child with a
clean environment and the server exits with *"ORACLE_CONNECTION_STRING
environment variable is required"*; and `--with "mcp<2"`, because mcp-proxy
0.12 imports `request_ctx`, which mcp 2.x moved.

### path2 - the proxy spawns the server through uv

The stock LiteLLM image ships neither `uv` nor `uvx` (nor `npx`, `npm` or
`pip`) - only `python` and `node`. LiteLLM's stdio allow-list *permits* `uvx`,
but the binary still has to exist. The image is Wolfi-based and has `apk`, so
both are installed at container start, with no custom image:

```yaml
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        apk add --no-cache uv
        uv tool install --python 3.12 --with "mcp<2" oracledb-mcp-server==0.1.1
        exec docker/prod_entrypoint.sh --config /app/config.yaml --port 4000
```

```yaml
  path2:
    transport: stdio
    command: uvx
    args: ["--offline", "--from", "oracledb-mcp-server", "oracledb_mcp_server"]
```

Installing up front is what lets each per-call spawn run `uvx --offline`, so no
tool call waits on PyPI. Cost: about 20 seconds of startup, and the container
must reach the Wolfi apk repo and PyPI on **every** start, so `start_period` is
120s and an offline start fails.

Also note that LiteLLM hands the subprocess the `env` map as its *entire*
environment - `PATH`, `HOME` and the `UV_*` directories have to be repeated
there, or the spawn dies with `Connection closed`.

### path3 - the same package, bridged in its own container

Path 2's server, moved out of the proxy. A stock `python:3.12-slim` installs
`uv` at start and `mcp-proxy` fronts the stdio server:

```yaml
  mcp-path3:
    image: python:3.12-slim
    command:
      - sh
      - -c
      - |
        pip install --no-cache-dir --quiet uv
        exec uvx --with "mcp<2" mcp-proxy --pass-environment --host 0.0.0.0 \
          --port 8000 --stateless \
          -- uvx --with "mcp<2" --from oracledb-mcp-server oracledb_mcp_server
```

Same five tools as path 2, but with its own health check, logs and scaling, and
the proxy holds only a URL.

### Two database logins, in every path

`oracledb-mcp-server` reads table comments from `USER_TAB_COMMENTS`, which only
shows objects the login *owns*, so `COMMENT_DB_CONNECTION_STRING` is the schema
owner `BIR`. Its `execute_sql` has no read-only guard of its own, so
`DB_CONNECTION_STRING` is the SELECT-only `BIR_RO`, and writes come back as
`ORA-41900` / `ORA-01031`. dmeppiel's server has its own `READ_ONLY_MODE=1` and
also connects as `BIR_RO`, so it refuses writes twice over.

Scope comes from `TARGET_SCHEMA` (dmeppiel) or `TABLE_WHITE_LIST` /
`COLUMN_WHITE_LIST` (oracledb-mcp-server). Neither constrains raw SQL; `BIR_RO`
privileges are what keep other application data out of reach.

Known limitation of `oracledb-mcp-server`: `get_column_details` needs
module-level state that `get_table_details` sets in the same process. Under a
per-call spawn (path2) it always logs *"Error loading table details"* and times
out; behind the bridge (path3) the process is long-lived, so calling
`get_table_details` first makes it work.

### Comparison

| | path1 / path3 (own container) | path2 (inside the proxy) |
| --- | --- | --- |
| Proxy image | stock, untouched | stock + ~20s install at every start |
| Probes, logs, scaling | per component | none of its own |
| Process lifetime | long-lived, state survives calls | forked per call |
| DB connections | `replicas x pool` | one per call |
| Kubernetes | Deployment + Service, no chart patches | wants your own image - the chart has no init hook |
| Offline start | needs the registry only at image pull | needs apk + PyPI on every start |

## Reloading the data

`oracle-init` is idempotent and skips a schema that is already loaded. To
regenerate the data set after editing `oracle/sql/02_seed.sql`:

```bash
docker exec -i bir-oracle sqlplus -s -L "sys/$(grep '^ORACLE_PWD=' .env | cut -d= -f2-)@//localhost:1521/FREEPDB1 as sysdba" <<'SQL'
DROP USER bir CASCADE;
DROP USER bir_ro CASCADE;
EXIT
SQL
docker compose run --rm oracle-init
```

## Teardown

```bash
docker compose down          # keep the data
docker compose down -v       # drop the Oracle and LiteLLM volumes
```
