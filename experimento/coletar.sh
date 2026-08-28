#!/usr/bin/env bash
# =============================================================================
# coletar.sh — exporta do Prometheus a janela medida de uma execucao
#
#   ./experimento/coletar.sh experimento/execucoes/teste-2026....env
#
# Gera, ao lado do registro da execucao, um .csv por variavel dependente.
# RODE ANTES de `./cenario.sh parar`: make stop apaga o volume do Prometheus.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRO="${1:-}"
[[ -f "$REGISTRO" ]] || { echo "uso: $0 <experimento/execucoes/*.env>" >&2; exit 2; }
# shellcheck disable=SC1090
source "$REGISTRO"

AGORA=$(date +%s)
if (( AGORA < MEDICAO_FIM_EPOCH )); then
  echo "AVISO: a janela de medicao termina em $(( (MEDICAO_FIM_EPOCH - AGORA) / 60 )) min." >&2
  echo "       Exportando o que existe ate agora." >&2
  MEDICAO_FIM_EPOCH=$AGORA
fi

PROM="http://localhost:9090"
BASE="${REGISTRO%.env}"
# `step` casado com o scrape_interval de 5s do job cadvisor: nao inventa
# resolucao que o dado nao tem, nem descarta amostras coletadas.
STEP=5s

consultar() {
  local nome="$1" query="$2"
  local saida="${BASE}.${nome}.csv"
  curl -sG "${PROM}/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${AQUECIMENTO_FIM_EPOCH}" \
    --data-urlencode "end=${MEDICAO_FIM_EPOCH}" \
    --data-urlencode "step=${STEP}" \
  | python3 -c '
import json,sys,csv
d=json.load(sys.stdin)
if d.get("status")!="success":
    sys.exit("Prometheus: "+json.dumps(d))
r=d["data"]["result"]
w=csv.writer(sys.stdout); w.writerow(["timestamp","valor"])
if not r:
    sys.exit("consulta sem series — o alvo cadvisor esta up?")
for ts,v in r[0]["values"]:
    w.writerow([ts,v])
' > "$saida"
  echo ">> ${saida}  ($(( $(wc -l < "$saida") - 1 )) amostras)"
}

# CPU do Collector, em nucleos. Multiplicar por 100 da % de um nucleo.
consultar cpu    'rate(container_cpu_usage_seconds_total{name="otel-collector"}[1m])'
# Memoria residente do Collector, em bytes.
consultar memoria 'container_memory_working_set_bytes{name="otel-collector"}'

# Steal time: evidencia de que a VM compartilhada nao contaminou a medicao.
STEAL_FIM=$(awk '/^cpu /{print $9}' /proc/stat)
echo "STEAL_FIM=${STEAL_FIM}" >> "$REGISTRO"
echo "STEAL_DELTA_TICKS=$(( STEAL_FIM - STEAL_INICIO ))" >> "$REGISTRO"

# Estatisticas descritivas da janela.
python3 - "$BASE" "$CENARIO" <<'PY'
import csv, statistics, sys
base, cenario = sys.argv[1], sys.argv[2]
print(f"\n=== {cenario} ===")
for nome, fator, unidade in (("cpu", 100.0, "% de 1 nucleo"), ("memoria", 1/1048576, "MB")):
    try:
        with open(f"{base}.{nome}.csv") as f:
            vals = sorted(float(r["valor"]) * fator for r in csv.DictReader(f))
    except FileNotFoundError:
        continue
    if not vals:
        continue
    n = len(vals)
    # P99 por indice em amostra ordenada; com ~360 pontos e resolucao suficiente.
    p99 = vals[min(n - 1, int(round(0.99 * (n - 1))))]
    print(f"{nome:8} n={n:4}  media={statistics.fmean(vals):9.2f}  "
          f"mediana={statistics.median(vals):9.2f}  p99={p99:9.2f}  ({unidade})")
PY
