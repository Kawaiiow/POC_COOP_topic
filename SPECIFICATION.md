# AIOps & ChatOps Incident Management Platform — PoC Specification & Implementation Guide

## 1. Document Purpose & Scope
This specification defines the Proof of Concept (PoC `v0.1.0`) implementation plan for the **AIOps-Driven Infrastructure Telemetry, Automated Remediation, and Discord ChatOps Incident Management System**. It is structured for **Antigravity** to implement a decoupled, event-driven microservice architecture over **RabbitMQ** with independent service versioning and single-service container rollback support.

### 1.1 PoC Scope Decisions
* **Purely Request-Driven Workflow (No Scheduler Service):** Background cron sweeps (`scheduler-service`) are excluded from `v0.1.0` to keep the PoC focused on proving the end-to-end event pipeline:
  $$\text{Discord Trigger} \longrightarrow \text{RabbitMQ} \longrightarrow \text{AIOps Diagnosis} \longrightarrow \text{Ticket FSM \& Approval} \longrightarrow \text{SSH Remediation \& 45s Post-Check}$$
* **Host-Hosted Control Plane via Out-of-Band Management (`10.42.0.1`):** All observability, messaging, LLM inference, and microservice containers run directly on the **physical host machine (`10.42.0.1` on `br0` / `10.42.0.0/16`)**. Every simulated VM connects a dedicated management NIC to `10.42.0.0/16` to send metrics and logs directly to `10.42.0.1` and receive out-of-band SSH remediation.
* **Unified VictoriaMetrics + VictoriaLogs Observability:** Uses **VictoriaMetrics** (`10.42.0.1:8428`) for time-series metrics and **VictoriaLogs** (`10.42.0.1:9428` HTTP / `10.42.0.1:5514` TCP syslog) for zero-config centralized log aggregation and **LogsQL** full-text search, visualized in **Grafana** (`10.42.0.1:3000`).
* **Baseline AIOps Stack:** Uses **Rolling Median Absolute Deviation (MAD) + Multivariate Isolation Forest** on CPU (`numpy`, `scikit-learn`) paired with **Qwen3-8B** (`qwen3:8b-q5_K_M` via Ollama on the host RTX 3080 10 GB VRAM) for Root-Cause Analysis (RCA) and VictoriaLogs syslog correlation.
* **Multi-Repository / Single-Service Rollback Ready:** Each microservice is isolated in its own directory (mapping $1\text{:}1$ to an independent Git repository) and shares message schemas exclusively through the versioned `ops-contracts` Python package.

---

## 2. System Architecture & Topology

### 2.1 Dual-Plane Lab & Host Topology (OpenTofu / KVM + Host Machine)
1. **Physical Hypervisor Host (`10.42.0.1` on `br0` / `10.42.0.0/16`):**
   * Runs the Docker Compose control plane (`rabbitmq`, `postgres`, `victoriametrics`, `victorialogs`, `grafana`, `opnsense-exporter`, and the 4 PoC microservices) plus native **Ollama** (`127.0.0.1:11434`, exposed to containers via `host.docker.internal:11434`).
   * Communicates with all VMs out-of-band over their dedicated `10.42.0.0/16` management interfaces so telemetry collection and SSH remediation remain reachable even during simulated `192.168.42.0/24` LAN or gateway failures.
2. **Simulated Infrastructure VMs (Provisioned via `POC_COOP_topic/terraform/`):**
   * **`sim-lab-opnsense-fw` (`opnsense-fw`):** Virtual firewall/gateway (`192.168.100.0/24` WAN NAT, `192.168.42.1/24` isolated internal LAN gateway, and dedicated `10.42.0.x` management interface on `br0`). Runs `os-node_exporter` (`:9100`), REST API (`:443`), and streams RFC 5424 TCP syslog to `10.42.0.1:5514`.
   * **`sim-lab-srv-01` (`srv-ubuntu-01`):** Ubuntu 24.04 Server (`192.168.42.0/24` data-plane LAN + `10.42.0.x` management interface on `br0`) running `node_exporter` (`:9100`), `promtail` pushing to `http://10.42.0.1:9428`, and SSH remediation user `svc-remediator`.
   * **`sim-lab-ws-01` (`ws-ubuntu-01`):** Ubuntu 24.04 Desktop (`192.168.42.0/24` data-plane LAN + `10.42.0.x` management interface on `br0`) representing the target user workstation running `node_exporter` (`:9100`), `promtail` pushing to `http://10.42.0.1:9428`, and SSH remediation user `svc-remediator`.

### 2.2 Event-Driven Microservice Topology
```text
                         [ Discord Support Channel ]
                              (/report-issue)
                                     |
                                     v
========================================================================================
PHYSICAL HOST MACHINE (10.42.0.1 on br0 / 10.42.0.0/16) — Docker Compose + Host Ollama
----------------------------------------------------------------------------------------
                       +---------------------------+
                       |    ops-chatops-service    |
                       |    (discord.py Gateway)   |
                       +-------------+-------------+
                                     | Publish / Consume
                                     v
+-------------------+    +---------------------------+    +-----------------------+
| ops-ticket-service+--->|      RabbitMQ Broker      |<---+ops-remediation-service|
| (PostgreSQL FSM)  |    |   Exchange: ops.topic     |    | (AsyncSSH / Paramiko) |
+-------------------+    +------+-------------+------+    +-----------+-----------+
                                |             |                       |
                  routing_key:  |             | routing_key:          |
                  task.diagnose |             | task.remediate.*      |
                                v             |                       |
                  +-------------------+       |                       |
                  | ops-aiops-service +-------+ (Auto Tier 1)         |
                  | (MAD+iForest+Qwen)|                               |
                  +---+-----------+---+                               |
                      |           |                                   |
                      |           +--> [ Ollama :11434 (RTX 3080) ]   |
                      v                                               |
       +--------------+--------------+                                |
       | VictoriaMetrics (:8428)     |                                |
       | VictoriaLogs (:9428 / :5514)|                                |
       | opnsense-exporter (:8080)   |                                |
       +--------------+--------------+                                |
======================|===============================================|=================
                      | Out-of-Band Management Network (10.42.0.0/16) |
                      | Metrics Scrape (:9100/:443) & Log Push        | SSH (:22)
                      v                                               v
       +-----------------------------------------------------------------------------+
       | Target VMs (Management NICs: 10.42.0.x | Data-Plane LAN: 192.168.42.0/24)   |
       |  • opnsense-fw   (192.168.42.1 GW  | Mgmt: 10.42.0.x)                       |
       |  • srv-ubuntu-01 (192.168.42.x LAN | Mgmt: 10.42.0.x)                       |
       |  • ws-ubuntu-01  (192.168.42.x LAN | Mgmt: 10.42.0.x)                       |
       +-----------------------------------------------------------------------------+
```

### 2.3 RabbitMQ Exchange & Queue Bindings
* **Primary Exchange:** `ops.topic` (`ExchangeType.TOPIC`, `durable=True`)
* **Dead-Letter Exchange:** `ops.dlx` (`ExchangeType.FANOUT`, `durable=True`) bound to queue `q.dead_letters`

| Routing Key | Target Queue(s) | Producer | Consumer(s) | Description |
| :--- | :--- | :--- | :--- | :--- |
| `task.diagnose` | `q.aiops.diagnose` | `ops-chatops-service` | `ops-aiops-service` | Requests 30m telemetry pull, MAD/iForest scoring, and Qwen3 RCA |
| `event.diagnosis.complete` | `q.ticket.events`, `q.chatops.notify` | `ops-aiops-service` | `ops-ticket-service`, `ops-chatops-service` | Fan-out event to create/update DB ticket and render Discord embed |
| `task.remediate.tier1` | `q.remediation.exec` | `ops-aiops-service` | `ops-remediation-service` | Triggers immediate autonomous execution of safe Tier 1 playbooks |
| `task.remediate.tier2` | `q.remediation.exec` | `ops-chatops-service` | `ops-remediation-service` | Triggers human-approved Tier 2 playbook after Discord button click |
| `event.remediation.result` | `q.ticket.events`, `q.chatops.notify` | `ops-remediation-service` | `ops-ticket-service`, `ops-chatops-service` | Reports SSH execution output and 45s post-check recovery status |

---

## 3. Workspace & Repository Layout
Scaffold the project using the following layout so each service can be built, tagged, and rolled back independently on the host machine:

```text
workspace-root/
├── AGENTS.md                              # Antigravity agent rules & constraints
├── SPECIFICATION.md                       # This technical specification
│
├── ops-contracts/                         # Repo 1: Shared AMQP & Pydantic Contract Package
│   ├── pyproject.toml
│   ├── src/
│   │   └── ops_contracts/
│   │       ├── __init__.py
│   │       ├── routing.py                 # Exchange names, queue names & routing keys
│   │       ├── events.py                  # Version-safe Pydantic v2 message payloads
│   │       └── broker.py                  # Reusable aio-pika connection, publisher & consumer
│   └── tests/
│       └── test_contracts.py
│
├── ops-chatops-service/                   # Repo 2: Discord Bot & Interactive UI
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── .env.example
│   ├── src/
│   │   └── chatops/
│   │       ├── __init__.py
│   │       ├── config.py
│   │       ├── main.py                    # Discord bot + RabbitMQ consumer loop
│   │       ├── parser.py                  # Regex hostname & symptom extractor
│   │       └── views.py                   # Discord Embed builder & Approve/Escalate buttons
│   └── tests/
│       └── test_parser.py
│
├── ops-ticket-service/                    # Repo 3: Incident State Machine & PostgreSQL
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── .env.example
│   ├── src/
│   │   └── ticket_service/
│   │       ├── __init__.py
│   │       ├── config.py
│   │       ├── models.py                  # SQLAlchemy 2.0 async models
│   │       ├── state_machine.py           # Strict FSM transition validator
│   │       └── main.py                    # Consumes q.ticket.events & persists state
│   └── tests/
│       └── test_state_machine.py
│
├── ops-aiops-service/                     # Repo 4: Rolling MAD + Isolation Forest + Qwen3-8B
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── .env.example
│   ├── models/
│   │   └── .gitkeep                       # Stores isolation_forest_ubuntu.pkl
│   ├── scripts/
│   │   └── train_baseline_iforest.py      # Fits & exports baseline .pkl model
│   ├── src/
│   │   └── aiops_service/
│   │       ├── __init__.py
│   │       ├── config.py
│   │       ├── telemetry.py               # Async VictoriaMetrics PromQL & VictoriaLogs LogsQL client
│   │       ├── detector.py                # Rolling MAD + Isolation Forest hybrid scorer
│   │       ├── llm_rca.py                 # Ollama Qwen3-8B structured JSON RCA client
│   │       └── main.py                    # Consumes q.aiops.diagnose & publishes diagnosis
│   └── tests/
│       └── test_detector.py
│
├── ops-remediation-service/               # Repo 5: Closed-Loop SSH Runner & Guardrails
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── .env.example
│   ├── playbooks/                         # Idempotent shell scripts deployed to targets
│   │   ├── tier1_clean_disk.sh
│   │   ├── tier1_flush_dns.sh
│   │   ├── tier2_kill_pid.sh
│   │   └── tier2_bounce_iface.sh
│   ├── src/
│   │   └── remediation_service/
│   │       ├── __init__.py
│   │       ├── config.py
│   │       ├── guardrails.py              # Flapping suppression (max 2/8h) & tier validator
│   │       ├── ssh_runner.py              # AsyncSSH / Paramiko command executor (10.42.0.x)
│   │       ├── verifier.py                # 45s sleep + post-check telemetry evaluator
│   │       └── main.py                    # Consumes q.remediation.exec
│   └── tests/
│       └── test_guardrails.py
│
└── POC_COOP_topic/                        # Repo 6: Umbrella Infrastructure & Deployment Repo
    ├── docker-compose.yml                 # Runs on host (10.42.0.1); pins semantic image tags
    ├── .env.example
    ├── Makefile
    ├── configs/
    │   ├── victoriametrics-scrape.yml     # Scrapes VM management IPs (10.42.0.x:9100)
    │   └── promtail-config.yml            # VM shipper config pushing to http://10.42.0.1:9428
    ├── scripts/
    │   └── fault_injection/               # Synthetic fault injectors for PoC evaluation
    │       ├── inject_memory_leak.py
    │       ├── inject_disk_fill.sh
    │       └── inject_dns_drop.sh
    └── terraform/                         # Existing OpenTofu KVM Lab (DO NOT MODIFY)
```

---

## 4. Detailed Component Specifications

### 4.1 Shared Contract Library (`ops-contracts`)

#### `routing.py`
Define immutable constants for exchanges, queues, and routing keys:
* `TOPIC_EXCHANGE = "ops.topic"`
* `DLX_EXCHANGE = "ops.dlx"`
* Routing keys:
  * `RK_TASK_DIAGNOSE = "task.diagnose"`
  * `RK_EVENT_DIAGNOSIS = "event.diagnosis.complete"`
  * `RK_TASK_REMEDIATE_T1 = "task.remediate.tier1"`
  * `RK_TASK_REMEDIATE_T2 = "task.remediate.tier2"`
  * `RK_EVENT_REMEDIATION = "event.remediation.result"`

#### `events.py`
All schemas must inherit from a base class configured with `model_config = ConfigDict(extra="ignore")` so that rolling back a consumer service to an older image tag never throws a `ValidationError` if a producer sends newer optional fields:

```python
from datetime import datetime, timezone
from typing import Dict, Literal, Optional
from pydantic import BaseModel, ConfigDict, Field
import uuid

PlaybookType = Literal[
    "TIER1_CLEAN_DISK",
    "TIER1_FLUSH_DNS",
    "TIER2_KILL_ROGUE_PID",
    "TIER2_BOUNCE_INTERFACE",
    "TIER3_ESCALATE_ADMIN",
]

TicketState = Literal[
    "OPEN",
    "DIAGNOSING",
    "PENDING_APPROVAL",
    "REMEDIATING",
    "VERIFYING",
    "RESOLVED",
    "ESCALATED",
]

class BaseContractModel(BaseModel):
    model_config = ConfigDict(extra="ignore")

class DiagnoseTask(BaseContractModel):
    correlation_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    host: str
    trigger_source: Literal["USER_DISCORD", "MANUAL_CLI"] = "USER_DISCORD"
    discord_thread_id: Optional[int] = None
    reporter_user_id: Optional[int] = None
    user_symptom: Optional[str] = None
    lookback_minutes: int = 30
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

class DiagnosisCompleteEvent(BaseContractModel):
    correlation_id: str
    host: str
    is_anomaly: bool
    composite_score: float = Field(ge=0.0, le=1.0)
    iforest_score: float = Field(ge=0.0, le=1.0)
    max_mad_score: float = Field(ge=0.0)
    primary_culprit: str
    root_cause_summary: str
    suspected_pid_or_service: Optional[str] = None
    recommended_playbook: PlaybookType
    risk_tier: Literal[1, 2, 3]
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    feature_values: Dict[str, float] = Field(default_factory=dict)
    feature_contributions: Dict[str, float] = Field(default_factory=dict)
    discord_thread_id: Optional[int] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

class RemediateTask(BaseContractModel):
    correlation_id: str
    host: str
    playbook: PlaybookType
    risk_tier: Literal[1, 2, 3]
    target_pid_or_service: Optional[str] = None
    approved_by_user_id: Optional[int] = None
    discord_thread_id: Optional[int] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

class RemediationResultEvent(BaseContractModel):
    correlation_id: str
    host: str
    playbook: PlaybookType
    executed: bool
    flapping_blocked: bool = False
    exit_code: int = -1
    stdout_excerpt: str = ""
    pre_check_score: float = 0.0
    post_check_score: float = 0.0
    final_ticket_state: Literal["RESOLVED", "ESCALATED"]
    reason: str
    discord_thread_id: Optional[int] = None
    completed_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
```

#### `broker.py`
Implement an `AsyncRabbitBroker` wrapper using `aio_pika.connect_robust`:
* Declares `ops.topic` (Topic) and `ops.dlx` (Fanout).
* Configures every consumer queue with `durable=True` and `arguments={"x-dead-letter-exchange": "ops.dlx"}`.
* Publishes messages with `delivery_mode=aio_pika.DeliveryMode.PERSISTENT`, `content_type="application/json"`, and `correlation_id`.

---

### 4.2 Service 1: `ops-aiops-service`

#### Step 1: 5D Metrics & VictoriaLogs Extraction (`telemetry.py`)
1. **VictoriaMetrics PromQL Extraction (`GET http://victoriametrics:8428/api/v1/query_range`):**
   Pull `step="15s"`, `lookback="30m"` for the 5 features (matching by `instance` label set in `victoriametrics-scrape.yml`) and align timestamps into a 2D NumPy matrix $X \in \mathbb{R}^{T \times 5}$:
   * `cpu_load_1m`: `node_load1{instance=~"<host>(:.*)?"}`
   * `memory_used_pct`: `(1 - (node_memory_MemAvailable_bytes{instance=~"<host>(:.*)?"} / node_memory_MemTotal_bytes{instance=~"<host>(:.*)?"})) * 100`
   * `disk_io_wait`: `rate(node_cpu_seconds_total{mode="iowait",instance=~"<host>(:.*)?"}[5m]) * 100`
   * `active_sockets`: `node_sockstat_TCP_inuse{instance=~"<host>(:.*)?"}`
   * `packet_discards`: `sum(rate(node_network_receive_drop_total{instance=~"<host>(:.*)?"}[5m]))`

2. **VictoriaLogs LogsQL Extraction (`POST http://victorialogs:9428/select/logsql/query`):**
   Query recent system, authentication, and OPNsense firewall logs for `<host>` using **LogsQL** (`form data`: `{"query": '(instance:~"<host>(:.*)?" OR hostname:"<host>") _time:30m | sort by (_time) desc | limit 20'}`).
   Parse the **newline-delimited JSON (NDJSON)** response line-by-line (`json.loads(line)`), extract `_time` and `_msg`, and reverse the list so logs appear in chronological order for the LLM prompt.

#### Step 2: Hybrid Anomaly Detection (`detector.py`)
1. **Univariate Rolling MAD (Modified Z-score):**
   For each feature $j \in \{1 \dots 5\}$, compute the historical median $\tilde{x}_w^{(j)}$ and Median Absolute Deviation $\text{MAD}_w^{(j)} = \text{median}(|x_i^{(j)} - \tilde{x}_w^{(j)}|)$ on $X[:-1, j]$.
   Compute the Modified Z-score for the latest observation $x_T^{(j)}$:
   $$M_T^{(j)} = \frac{|x_T^{(j)} - \tilde{x}_w^{(j)}|}{\max(1.4826 \cdot \text{MAD}_w^{(j)}, \epsilon^{(j)})}$$
   Use the following minimum dispersion floors $\epsilon^{(j)}$ to prevent division-by-zero false positives on flatline metrics:
   * `cpu_load_1m`: $0.25$
   * `memory_used_pct`: $1.0$
   * `disk_io_wait`: $1.0$
   * `active_sockets`: $2.0$
   * `packet_discards`: $0.5$
   Convert `max_mad = max(M_T.values())` into a bounded univariate score:
   $$S_{\text{mad}} = \text{clip}\left(\frac{\text{max\_mad}}{4.2}, 0.0, 1.0\right)$$

2. **Multivariate Isolation Forest:**
   Load `models/isolation_forest_ubuntu.pkl` (`n_estimators=100`, `contamination=0.05`, `random_state=42`). If the file does not exist on first boot, automatically fit a bootstrap model on a synthetic normal operating matrix ($N=500$) and save it to disk.
   Score the latest 5D vector $\mathbf{x}_T$:
   $$S_{\text{raw}} = -\text{model.score\_samples}(\mathbf{x}_T)[0]$$
   $$S_{\text{iforest}} = \text{clip}\left(\frac{S_{\text{raw}} - 0.42}{0.38}, 0.0, 1.0\right)$$

3. **Composite Anomaly Score & Attribution:**
   $$S_{\text{composite}} = \text{round}(0.7 \cdot S_{\text{iforest}} + 0.3 \cdot S_{\text{mad}}, 3)$$
   Flag `is_anomaly = (S_composite >= 0.85) or (max_mad >= 4.0)`.
   Calculate percentage feature contributions from $M_T^{(j)} / \sum_k M_T^{(k)}$.

#### Step 3: Qwen3-8B Root-Cause Analysis (`llm_rca.py`)
Call Ollama on the host machine (`POST http://host.docker.internal:11434/api/chat`) using `qwen3:8b-q5_K_M`, passing the 5D metric vector and VictoriaLogs entries:
* Pass `"think": false` (and prepend `/no_think` to the prompt) so inference finishes in $\le 1.5\text{ s}$ on the host RTX 3080.
* Pass `format=LLMDiagnosisSchema.model_json_schema()` and `options={"temperature": 0.0, "num_ctx": 4096}`.
* Provide a deterministic fallback: if Ollama is unreachable or times out ($> 5.0\text{ s}$), map the top-contributing feature from `detector.py` directly to its corresponding default playbook (`memory_used_pct` $\rightarrow$ `TIER2_KILL_ROGUE_PID`, `disk_io_wait` $\rightarrow$ `TIER1_CLEAN_DISK`, `packet_discards` $\rightarrow$ `TIER1_FLUSH_DNS`, etc.).

#### Step 4: Event Publishing (`main.py`)
* Publish `DiagnosisCompleteEvent` with routing key `event.diagnosis.complete`.
* If `is_anomaly` is `True` and `risk_tier == 1` (`TIER1_CLEAN_DISK` or `TIER1_FLUSH_DNS`), immediately publish a `RemediateTask` with routing key `task.remediate.tier1`.

---

### 4.3 Service 2: `ops-ticket-service`

#### Database Models (`models.py`)
Use `SQLAlchemy 2.0` async (`AsyncSession`, `asyncpg` for PostgreSQL, with `aiosqlite` support for unit testing):
1. `Workstation`: `id` (PK), `hostname` (unique), `mgmt_ip` (management IP in `10.42.0.0/16`), `lan_ip` (optional data-plane IP in `192.168.42.0/24`), `os_version`, `is_active`, `created_at`.
2. `Incident`: `ticket_id` (PK), `correlation_id` (unique index), `host_id` (FK), `discord_thread_id`, `state` (Enum), `trigger_source`, `anomaly_score`, `primary_culprit`, `recommended_playbook`, `created_at`, `resolved_at`.
3. `RemediationAction`: `action_id` (PK), `ticket_id` (FK), `playbook`, `risk_tier`, `approved_by_user_id`, `execution_stdout`, `exit_code`, `post_check_score`, `is_successful`, `executed_at`.

#### Finite State Machine (`state_machine.py`)
Enforce valid state transitions:
$$\text{OPEN} \longrightarrow \text{DIAGNOSING} \longrightarrow \left\{ \begin{matrix} \text{PENDING\_APPROVAL} \longrightarrow \text{REMEDIATING} \\ \text{REMEDIATING (Tier 1 Auto)} \end{matrix} \right\} \longrightarrow \text{VERIFYING} \longrightarrow \left\{ \begin{matrix} \text{RESOLVED} \\ \text{ESCALATED} \end{matrix} \right.$$

---

### 4.4 Service 3: `ops-remediation-service`

#### Guardrails (`guardrails.py`)
1. **Whitelist Mapping:** Map `PlaybookType` strictly to static script paths:
   * `TIER1_CLEAN_DISK` $\rightarrow$ `/opt/remediation-scripts/tier1_clean_disk.sh`
   * `TIER1_FLUSH_DNS` $\rightarrow$ `/opt/remediation-scripts/tier1_flush_dns.sh`
   * `TIER2_KILL_ROGUE_PID` $\rightarrow$ `/opt/remediation-scripts/tier2_kill_pid.sh`
   * `TIER2_BOUNCE_INTERFACE` $\rightarrow$ `/opt/remediation-scripts/tier2_bounce_iface.sh`
2. **Flapping Suppression:** Maintain a sliding window of execution timestamps per `(host, playbook)`. If a host has already executed $\ge 2$ remediations within the last $8\text{ hours}$ ($28,800\text{ seconds}$), block execution and emit `RemediationResultEvent(executed=False, flapping_blocked=True, final_ticket_state="ESCALATED")`.
3. **Tier 2 Authorization Check:** Reject any `risk_tier == 2` task that lacks a valid `approved_by_user_id`.

#### Out-of-Band SSH Execution & Closed-Loop Verification (`ssh_runner.py` & `verifier.py`)
1. Resolve target `host` to its **management IP (`10.42.0.x`)** via a configurable `HOST_MGMT_MAP` dictionary (e.g., `{"ws-ubuntu-01": "10.42.0.12", "srv-ubuntu-01": "10.42.0.11"}`) and connect from the host (`10.42.0.1`) via `asyncssh` (or `paramiko` inside `asyncio.to_thread`) as user `svc-remediator` using `SSH_KEY_PATH`. Include a `DRY_RUN=true` environment toggle for unit testing when target VMs are offline.
2. Execute `sudo -n /opt/remediation-scripts/<script>.sh` with a $15\text{-second}$ timeout.
3. Wait `VERIFICATION_DELAY_SECONDS` (default $45\text{ seconds}$; configurable down to $2\text{ seconds}$ in unit tests).
4. Query VictoriaMetrics to compute the post-remediation anomaly score.
5. Transition `final_ticket_state` to `"RESOLVED"` if `exit_code == 0` and `post_check_score < 0.50`; otherwise transition to `"ESCALATED"`.
6. Publish `RemediationResultEvent` to `event.remediation.result`.

---

### 4.5 Service 4: `ops-chatops-service`

#### Slash Command & Entity Parser (`main.py` & `parser.py`)
1. Register `/report-issue workstation:<str> symptom:<str>`.
2. **Immediate Deferral:** Call `await interaction.response.defer(thinking=True)` on the first line to satisfy Discord's $3\text{-second}$ gateway timeout.
3. Spawn a dedicated Discord Thread named `[Ticket] <host> - <short_symptom>`.
4. Publish `DiagnoseTask` to `task.diagnose` with `discord_thread_id=thread.id`.
5. Also support a regex listener on `#workstation-support` matching `(?:ws|srv)-ubuntu-\d{2}|sim-lab-(?:ws|srv|opnsense)(?:-\d{2}|-fw)|opnsense-fw|10\.42\.\d{1,3}\.\d{1,3}|192\.168\.42\.\d{1,3}` to suggest or auto-trigger diagnostics from freeform chat.

#### Diagnostic Card & Interactive Buttons (`views.py`)
When `q.chatops.notify` receives `DiagnosisCompleteEvent`:
* Render a rich `discord.Embed` showing:
  * **Status & Composite Score:** Color-coded Red ($S \ge 0.85$) or Green ($S < 0.85$)
  * **Primary Culprit & Root Cause Summary** (from Qwen3-8B)
  * **5D Telemetry Breakdown & Top Attribution %**
  * **Recommended Playbook & Risk Tier**
* If `risk_tier == 1` and `is_anomaly`: Display banner *"Tier 1 Auto-Remediation Triggered — Awaiting 45s Verification..."*
* If `risk_tier == 2` and `is_anomaly`: Attach a `discord.ui.View` with three buttons:
  * **[ Approve Remediation ]** (Green): Checks user role, disables buttons, updates message, and publishes `RemediateTask` to `task.remediate.tier2`.
  * **[ Escalate to IT ]** (Red): Marks ticket `ESCALATED` and pings `@IT-Admin`.
  * **[ Dismiss ]** (Grey): Closes thread as false alarm.
* When `q.chatops.notify` receives `RemediationResultEvent`: Post a verification summary embed showing pre-check vs. post-check scores, script exit code, and final state (`RESOLVED` or `ESCALATED`).

---

## 5. Host Observability & Single-Service Rollback (`POC_COOP_topic/docker-compose.yml`)

### 5.1 Host-Bound VictoriaMetrics, VictoriaLogs & Grafana (`10.42.0.1`)
All observability ports bind to the host machine (`10.42.0.1` / `0.0.0.0`) so VMs push logs and expose exporters over their `10.42.0.x` management interfaces:
* **`victoriametrics` (`10.42.0.1:8428`):** Scrapes `node_exporter` targets (`10.42.0.x:9100` for `ws-ubuntu-01`, `srv-ubuntu-01`, and `opnsense-fw`) plus `opnsense-exporter:8080` from `configs/victoriametrics-scrape.yml`, attaching explicit `instance` hostname labels (`ws-ubuntu-01`, `srv-ubuntu-01`, `opnsense-fw`).
* **`victorialogs` (`10.42.0.1:9428` HTTP & `10.42.0.1:5514/tcp` Syslog):** Runs with `-storageDataPath=/victoria-logs-data -retentionPeriod=30d -syslog.listenAddr.tcp=:5514 -syslog.useRemoteIP.tcp=true` to ingest both Promtail HTTP streams from Ubuntu VMs and RFC 5424 TCP syslog streams from OPNsense's management interface.
* **`configs/promtail-config.yml` (Deployed on `ws-ubuntu-01` & `srv-ubuntu-01`):** Pushes logs via the VM management interface to `http://10.42.0.1:9428/insert/loki/api/v1/push?_stream_fields=instance,job` (and drops any `_time` label to prevent field collision warnings).
* **`opnsense-exporter`:** Polls OPNsense's management IP (`10.42.0.x:443`) for PF state table, gateway RTT/loss, and Unbound DNS metrics.
* **`grafana` (`10.42.0.1:3000`):** Sets `GF_INSTALL_PLUGINS=victoriametrics-logs-datasource` so Grafana natively queries VictoriaLogs alongside VictoriaMetrics.

### 5.2 Pinned Microservice Image Tags for Rollbacks
Configure `POC_COOP_topic/docker-compose.yml` on the host machine so every custom microservice image uses an environment-variable tag defaulting to `v0.1.0` and includes `extra_hosts: ["host.docker.internal:host-gateway"]` for host Ollama access:

```yaml
  aiops-service:
    build:
      context: ../ops-aiops-service
    image: ghcr.io/kawaiiow/ops-aiops-service:${AIOPS_TAG:-v0.1.0}
    restart: unless-stopped
    env_file: .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      rabbitmq:
        condition: service_healthy
```

Provide a `Makefile` in `POC_COOP_topic/` with helper targets:
* `make up`: Starts infrastructure and all 4 PoC services on the host machine.
* `make test-all`: Runs `pytest` across `ops-contracts` and all 4 services.
* `make rollback SERVICE=<name> TAG=<version>`: Executes `<SERVICE>_TAG=<version> docker compose up -d --no-deps <service>` to roll back a single microservice without restarting RabbitMQ, PostgreSQL, or peer services.

---

## 6. Step-by-Step Implementation Order for Antigravity
Execute implementation in the following strict sequence, running `pytest` after completing each phase:
1. **Phase 1 — `ops-contracts`:** Implement `routing.py`, `events.py`, `broker.py`, and unit tests verifying `extra="ignore"` backward compatibility.
2. **Phase 2 — `ops-aiops-service`:** Implement `detector.py` (Rolling MAD + Isolation Forest), `scripts/train_baseline_iforest.py`, `telemetry.py` (VictoriaMetrics PromQL + VictoriaLogs LogsQL NDJSON client), `llm_rca.py` (`host.docker.internal:11434`), `main.py`, and unit tests verifying anomaly detection and NDJSON log parsing.
3. **Phase 3 — `ops-ticket-service`:** Implement `models.py`, `state_machine.py`, `main.py`, and unit tests verifying legal/illegal FSM transitions and idempotent event updates.
4. **Phase 4 — `ops-remediation-service`:** Implement the 4 shell scripts in `playbooks/`, `guardrails.py`, `ssh_runner.py` (targeting `10.42.0.x` management IPs), `verifier.py`, `main.py`, and unit tests verifying flapping suppression ($>2$ runs in $8\text{h}$) and closed-loop post-check transitions.
5. **Phase 5 — `ops-chatops-service`:** Implement `parser.py`, `views.py`, `main.py`, and unit tests for hostname/symptom regex extraction.
6. **Phase 6 — Host Umbrella Orchestration & Fault Injection:** Create `POC_COOP_topic/docker-compose.yml` (host-bound VictoriaMetrics + VictoriaLogs + `opnsense-exporter` + 4 PoC services), `Makefile`, `configs/` (targeting `10.42.0.1` and `10.42.0.x`), and synthetic fault injection scripts in `POC_COOP_topic/scripts/fault_injection/`.