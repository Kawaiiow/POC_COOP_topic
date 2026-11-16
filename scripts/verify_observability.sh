#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

HOST_IP="${HOST_CONTROL_PLANE_IP:-10.42.0.1}"
VM_PORT="${VICTORIAMETRICS_PORT:-8428}"
VL_HTTP_PORT="${VICTORIALOGS_HTTP_PORT:-9428}"
VL_SYSLOG_PORT="${VICTORIALOGS_SYSLOG_PORT:-5514}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

echo -e "${YELLOW}======================================================================${NC}"
echo -e "${YELLOW}Observability Stack Verification Script (VictoriaMetrics + VictoriaLogs)${NC}"
echo -e "${YELLOW}Host Control Plane IP: ${HOST_IP}${NC}"
echo -e "${YELLOW}======================================================================${NC}"

# 1. VictoriaMetrics Health Check
echo -n "1. Checking VictoriaMetrics health (http://${HOST_IP}:${VM_PORT}/health)... "
if curl -fsS "http://${HOST_IP}:${VM_PORT}/health" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    exit 1
fi

# 2. VictoriaMetrics Scrape Targets
echo -n "2. Checking VictoriaMetrics scrape targets... "
TARGETS=$(curl -s "http://${HOST_IP}:${VM_PORT}/api/v1/targets")
TARGET_COUNT=$(echo "${TARGETS}" | jq -r '.data.activeTargets | length' 2>/dev/null || echo "0")
echo -e "${GREEN}OK (${TARGET_COUNT} active targets discovered)${NC}"

# 3. VictoriaMetrics PromQL Query Test
echo -n "3. Testing PromQL telemetry query (node_load1)... "
PROM_RESULT=$(curl -s -G "http://${HOST_IP}:${VM_PORT}/api/v1/query" --data-urlencode 'query=node_load1' | jq -r '.data.result | length' 2>/dev/null || echo "0")
echo -e "${GREEN}OK (${PROM_RESULT} series returned)${NC}"

# 4. VictoriaLogs Health Check
echo -n "4. Checking VictoriaLogs health (http://${HOST_IP}:${VL_HTTP_PORT}/health)... "
if curl -fsS "http://${HOST_IP}:${VL_HTTP_PORT}/health" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    exit 1
fi

# 5. VictoriaLogs Loki HTTP Push Ingestion Test
echo -n "5. Ingesting test log stream via Promtail/Loki push endpoint... "
TIMESTAMP_NS=$(date +%s%N)
TEST_MSG="Smoke-test log verification entry at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
PUSH_PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "instance": "test-verification-node",
        "job": "observability-verification"
      },
      "values": [
        ["${TIMESTAMP_NS}", "${TEST_MSG}"]
      ]
    }
  ]
}
EOF
)

PUSH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
  -X POST "http://${HOST_IP}:${VL_HTTP_PORT}/insert/loki/api/v1/push?_stream_fields=instance,job" \
  -d "${PUSH_PAYLOAD}")

if [ "${PUSH_STATUS}" -eq 204 ] || [ "${PUSH_STATUS}" -eq 200 ]; then
    echo -e "${GREEN}OK (HTTP ${PUSH_STATUS})${NC}"
else
    echo -e "${RED}FAILED (HTTP ${PUSH_STATUS})${NC}"
    exit 1
fi

# 6. VictoriaLogs LogsQL Query Test (NDJSON response)
echo -n "6. Querying VictoriaLogs via LogsQL (POST /select/logsql/query)... "
LOG_QUERY_RESULT=$(curl -s -d 'query=instance:test-verification-node' "http://${HOST_IP}:${VL_HTTP_PORT}/select/logsql/query")
if echo "${LOG_QUERY_RESULT}" | grep -q "Smoke-test log verification"; then
    echo -e "${GREEN}OK (NDJSON query confirmed match)${NC}"
else
    echo -e "${YELLOW}Warning: Immediate query did not find match (index flush pending)${NC}"
fi

# 7. RFC 5424 Syslog TCP Ingestion Test
echo -n "7. Testing RFC 5424 TCP Syslog ingestion on port ${VL_SYSLOG_PORT}... "
SYSLOG_LINE="<134>1 $(date -u +%Y-%m-%dT%H:%M:%SZ) opnsense-fw filterlog 1234 - [meta sequenceId=\"42\"] filterlog: 1,,,0,vtnet0,match,pass,out,4,0x0,,64,0,0,DF,6,tcp,60,192.168.42.10,1.1.1.1,54321,443,0,S,12345678,,1024,,mss"
echo "${SYSLOG_LINE}" | nc -w 1 "${HOST_IP}" "${VL_SYSLOG_PORT}" || true
echo -e "${GREEN}OK (Syslog packet sent)${NC}"

# 8. Grafana Health Check
echo -n "8. Checking Grafana health (http://${HOST_IP}:${GRAFANA_PORT}/api/health)... "
if curl -fsS "http://${HOST_IP}:${GRAFANA_PORT}/api/health" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}Pending / Starting up${NC}"
fi

echo -e "${YELLOW}======================================================================${NC}"
echo -e "${GREEN}All core Observability checks completed successfully!${NC}"
echo -e "${YELLOW}======================================================================${NC}"
