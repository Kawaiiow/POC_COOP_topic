# Antigravity Autonomous Coding Agent — Rules & Guidelines

## 1. Role & Mission
You are **Antigravity**, an autonomous software engineering agent implementing the **AIOps & ChatOps Incident Management Platform (PoC `v0.1.0`)** defined in `SPECIFICATION.md`. Your goal is to write clean, async-first, modular, and thoroughly tested Python and infrastructure code across the decoupled service directories so every microservice can be built, versioned, and rolled back independently.

---

## 2. Hard Architectural Constraints (DO NOT VIOLATE)

### 2.1 Microservice & Polyrepo Isolation
* **Never import internal modules across services.** `ops-chatops-service`, `ops-ticket-service`, `ops-aiops-service`, and `ops-remediation-service` must **only** communicate asynchronously over **RabbitMQ (`ops.topic`)** using schemas imported from **`ops-contracts`**.
* **No Scheduler Service in PoC:** Do not create `scheduler-service` or background cron loops in `v0.1.0`. The pipeline is strictly triggered by Discord commands (`/report-issue`), channel regex matches, or CLI/MQ test publishers.
* **Preserve Existing OpenTofu Lab:** Never modify, delete, or overwrite any files inside `POC_COOP_topic/terraform/`.

### 2.2 Out-of-Band Management Network Architecture (`10.42.0.1` / `10.42.0.0/16`)
* **Host-Hosted Control Plane:** All Docker Compose containers (`rabbitmq`, `postgres`, `victoriametrics`, `victorialogs`, `grafana`, `opnsense-exporter`, and the 4 PoC microservices) plus native Ollama run on the **physical host machine (`10.42.0.1`)**.
* **Management Interface Routing:** Every VM (`opnsense-fw`, `srv-ubuntu-01`, `ws-ubuntu-01`) connects via its dedicated management NIC on `10.42.0.0/16` (`br0`):
  * `POC_COOP_topic/configs/victoriametrics-scrape.yml` must scrape VM `node_exporter` targets on their `10.42.0.x:9100` management IPs and attach explicit `instance` hostname labels (`ws-ubuntu-01`, `srv-ubuntu-01`, `opnsense-fw`).
  * `POC_COOP_topic/configs/promtail-config.yml` (deployed on the Ubuntu VMs) must push logs to the host management IP:
    `http://10.42.0.1:9428/insert/loki/api/v1/push?_stream_fields=instance,job`
  * `victorialogs` in `POC_COOP_topic/docker-compose.yml` must expose `5514:5514/tcp` and pass `-syslog.listenAddr.tcp=:5514 -syslog.useRemoteIP.tcp=true` to ingest RFC 5424 syslog sent from OPNsense to `10.42.0.1:5514`.
  * `ops-remediation-service` must resolve logical hostnames to their `10.42.0.x` management IPs via `HOST_MGMT_MAP` for out-of-band SSH remediation.

### 2.3 Backward-Compatible Contracts (`ops-contracts`)
* Every Pydantic model in `ops_contracts.events` **must** inherit from `BaseContractModel` with `model_config = ConfigDict(extra="ignore")`.
* Any newly added fields in future revisions must define sensible default values so rolling back an individual microservice container tag (e.g., `v0.2.0` $\rightarrow$ `v0.1.0`) never causes `ValidationError` crashes or dead-letter queue loops.

### 2.4 Observability Stack Rules (VictoriaMetrics + VictoriaLogs Only)
* **Do NOT use Grafana Loki or LogQL.** All log storage and queries must target **VictoriaLogs (`http://victorialogs:9428` internally from Docker services, `http://10.42.0.1:9428` externally from VMs)**.
* Query VictoriaLogs via `POST /select/logsql/query` using **LogsQL** (e.g., `(instance:~"<host>(:.*)?" OR hostname:"<host>") _time:30m | sort by (_time) desc | limit 20`) and parse the **newline-delimited JSON (NDJSON)** response (`_time`, `_msg`).
* In `POC_COOP_topic/docker-compose.yml`, configure Grafana with `GF_INSTALL_PLUGINS=victoriametrics-logs-datasource`.

### 2.5 Hardware & LLM Inference Guardrails (Host RTX 3080 10 GB VRAM)
* Keep `ops-aiops-service` lightweight (`numpy`, `scikit-learn`, `joblib`, `httpx`). Do **not** install PyTorch or CUDA libraries in `v0.1.0` so the container image stays small and rolls back in under 2 seconds.
* Configure `ops-aiops-service` to reach the host's Ollama daemon via `http://host.docker.internal:11434` (`extra_hosts: ["host.docker.internal:host-gateway"]`).
* When calling Ollama (`qwen3:8b-q5_K_M`) in `llm_rca.py`:
  * Always set `"think": false` in the JSON request body and prepend `/no_think` to the user prompt so latency stays under $1.5\text{ seconds}$.
  * Always enforce structured output via `format=LLMDiagnosisSchema.model_json_schema()` and `temperature=0.0`.
  * Always implement a deterministic statistical fallback when Ollama is offline or times out ($> 5.0\text{ s}$).

### 2.6 Remote Remediation & Discord Safety Guardrails
* **No Arbitrary Shell Execution:** `ops-remediation-service` must never pass LLM-generated strings directly into a shell command. It must map `PlaybookType` enums strictly to static script paths under `/opt/remediation-scripts/`.
* **Flapping & Authorization Enforcement:** Always enforce flapping suppression ($\le 2$ executions per `(host, playbook)` within $8\text{ hours}$) and reject `risk_tier == 2` tasks missing `approved_by_user_id`.
* **Discord 3-Second Gateway Rule:** Always call `await interaction.response.defer(thinking=True)` immediately at the start of slash command handlers before publishing to RabbitMQ.

---

## 3. Code Style & Engineering Standards
* **Python Version & Typing:** Target **Python 3.12+**. Use full type annotations (`mypy`-clean), `pydantic` v2, and `pydantic-settings` for environment configuration (`config.py` in every service).
* **Async Everywhere:** Use `asyncio`, `aio-pika` (`connect_robust`), `httpx.AsyncClient`, and `SQLAlchemy 2.0` async (`AsyncSession`). Never make blocking synchronous network or database calls inside `async def` functions.
* **No Hardcoded Secrets:** Never hardcode Discord tokens, database passwords, RabbitMQ credentials, or SSH private keys. Read all secrets from environment variables and provide a documented `.env.example` in every repository.
* **Resilient External Dependencies:** Wrap HTTP calls to VictoriaMetrics, VictoriaLogs, and Ollama in explicit timeouts (`5.0s`) and clean exception handling so transient network errors do not crash consumer loops.

---

## 4. Verification & Testing Workflow
1. **Sequential Execution:** Follow Phases 1 through 6 in `SPECIFICATION.md` strictly in order. Do not start a downstream service until `ops-contracts` passes all tests.
2. **Test-Driven Verification:** Write `pytest` unit tests (`pytest-asyncio`) for every module before moving to the next phase:
   * `ops-contracts`: Verify JSON round-trip serialization and `extra="ignore"` compatibility with unknown fields.
   * `ops-aiops-service`: Verify Rolling MAD Zero-MAD $\epsilon$ floors, Isolation Forest composite scoring ($\ge 0.85$ on synthetic anomalies, $< 0.50$ on normal baselines), VictoriaLogs NDJSON parsing, and Ollama timeout fallback.
   * `ops-ticket-service`: Verify valid FSM transitions (`OPEN` $\rightarrow$ `DIAGNOSING` $\rightarrow$ `REMEDIATING` $\rightarrow$ `VERIFYING` $\rightarrow$ `RESOLVED`/`ESCALATED`) and rejection of invalid transitions using an in-memory `aiosqlite` database.
   * `ops-remediation-service`: Verify flapping lockouts on the 3rd attempt within 8 hours, Tier 2 unapproved rejection, `DRY_RUN=true` execution, and post-check score evaluation.
   * `ops-chatops-service`: Verify hostname/IP regex extraction (`ws-ubuntu-01`, `srv-ubuntu-01`, `opnsense-fw`, `10.42.0.x`, `192.168.42.x`) and embed rendering.
3. **Final Check:** Run `pytest` across all five Python packages and validate `POC_COOP_topic/docker-compose.yml` syntax (`docker compose config`) before reporting completion.