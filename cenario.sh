#!/usr/bin/env bash
# =============================================================================
# cenario.sh — sobe o demo em um dos dois cenarios do experimento
#
#   ./cenario.sh baseline        Isolation Forest desativado
#   ./cenario.sh teste           Isolation Forest ativado (traces+metrics+logs)
#   ./cenario.sh validar teste   so valida a config, nao sobe nada
#   ./cenario.sh parar           derruba tudo
#
# Variaveis:
#   RPS=<n>   taxa de chegada imposta ao k6, em iteracoes/s
#   VUS=<n>   tamanho do pool de VUs do k6
#             (ver secao "VUs" abaixo — nao basta mexer no .env)
# =============================================================================
set -euo pipefail

# No Git Bash / MSYS, argumentos que parecem caminhos POSIX absolutos sao
# reescritos para o equivalente Windows antes de chegar ao processo. Os
# `--config=/etc/otelcol-config.yml` da validacao virariam
# `C:/Program Files/Git/etc/...` e o Collector nao acharia os arquivos.
# Inofensivo no Linux, onde as duas variaveis simplesmente nao sao lidas.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

cd "$(dirname "$0")"

CENARIO="${1:-}"
SOMENTE_VALIDAR=0

if [[ "$CENARIO" == "parar" ]]; then
  echo ">> derrubando o ambiente (make stop apaga os volumes, inclusive o TSDB"
  echo "   do Prometheus — exporte os dados ANTES com ./experimento/coletar.sh)"
  make stop
  exit 0
fi

if [[ "$CENARIO" == "validar" ]]; then
  SOMENTE_VALIDAR=1
  CENARIO="${2:-}"
fi

case "$CENARIO" in
  baseline) EXTRAS="./experimento/configs/otelcol-config-extras.BASELINE.yml" ;;
  teste)    EXTRAS="./experimento/configs/otelcol-config-extras.TESTE.yml" ;;
  *)
    echo "uso: $0 {baseline|teste|parar}  |  $0 validar {baseline|teste}" >&2
    exit 2
    ;;
esac

COMPOSE_FILES=(-f compose.yaml -f compose.full.yaml -f compose.observability.yaml -f compose.extras.yaml)
COMPOSE_ENV=(--env-file .env --env-file .env.override)

# -----------------------------------------------------------------------------
# 1. Seleciona o arquivo de extras do Collector.
#
# A troca e feita em .env.override e nao em .env: .env.override e carregado
# depois e nao faz parte da release, entao o .env da 3.0.0 permanece auditavel.
# -----------------------------------------------------------------------------
touch .env.override
sed -i '/^OTEL_COLLECTOR_CONFIG_EXTRAS=/d;/^# --- experimento:/d' .env.override
{
  echo "# --- experimento: cenario ativo (reescrito por cenario.sh) ---"
  echo "OTEL_COLLECTOR_CONFIG_EXTRAS=${EXTRAS}"
} >> .env.override
echo ">> cenario: ${CENARIO}"
echo ">> OTEL_COLLECTOR_CONFIG_EXTRAS=${EXTRAS}"

# -----------------------------------------------------------------------------
# 2. Gera a config do Prometheus com o rotulo do cenario.
#
# O Prometheus nao expande variaveis de ambiente em static_configs, entao o
# rotulo tem de ser gravado no arquivo antes da subida.
# -----------------------------------------------------------------------------
sed "s/__CENARIO__/${CENARIO}/" \
  experimento/configs/prometheus-config.template.yaml \
  > experimento/configs/prometheus-config.generated.yaml
echo ">> prometheus-config.generated.yaml gerado com cenario='${CENARIO}'"

# -----------------------------------------------------------------------------
# 3. Script do k6.
#
# Regerado a cada subida a partir de src/load-generator/script.js. O gerador
# aborta se o trecho que ele substitui nao aparecer exatamente uma vez, de modo
# que uma divergencia com o upstream falha aqui e nao no meio de uma execucao.
# -----------------------------------------------------------------------------
python3 experimento/k6/gerar-script.py

if [[ -n "${RPS:-}" ]]; then
  sed -i '/^LOAD_GENERATOR_RPS=/d' .env.override
  echo "LOAD_GENERATOR_RPS=${RPS}" >> .env.override
  echo ">> LOAD_GENERATOR_RPS=${RPS}"
fi

# -----------------------------------------------------------------------------
# 4. VUs do k6.
#
# ARMADILHA DA 3.0.0: LOAD_GENERATOR_VUS no .env NAO controla a carga.
# O entrypoint.sh do load-generator consulta o flag `loadGeneratorVUs` no flagd
# a cada 10s e so cai no valor do .env se o flag retornar 0 ou falhar. O flag
# vem habilitado com defaultVariant "5", entao o .env e sempre ignorado.
# A fonte de verdade e src/flagd/demo.flagd.json.
# -----------------------------------------------------------------------------
if [[ -n "${VUS:-}" ]]; then
  python3 - "$VUS" <<'PY'
import json, sys
vus = str(int(sys.argv[1]))
p = "src/flagd/demo.flagd.json"
with open(p) as f:
    cfg = json.load(f)
flag = cfg["flags"]["loadGeneratorVUs"]
flag["variants"][vus] = int(vus)
flag["defaultVariant"] = vus
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f">> flagd loadGeneratorVUs fixado em {vus}")
PY
else
  python3 -c "import json;c=json.load(open('src/flagd/demo.flagd.json'))['flags']['loadGeneratorVUs'];print('>> flagd loadGeneratorVUs (inalterado):',c['variants'][c['defaultVariant']])"
fi

# -----------------------------------------------------------------------------
# 5. Valida a configuracao ANTES de subir.
#
# O Collector rejeita chaves desconhecidas e aborta na subida. Como o README
# upstream do isolationforest documenta campos que nao existem no codigo da
# v0.157.0, um erro de schema aqui e o modo de falha mais provavel — e sem esta
# etapa ele so apareceria depois de 20 minutos de `docker compose up`.
#
# A validacao usa a MESMA cadeia de --config da subida real. Validar apenas o
# arquivo de extras falharia: sozinho ele e um fragmento.
# -----------------------------------------------------------------------------
echo ">> validando a cadeia de configuracao do Collector..."
docker compose "${COMPOSE_ENV[@]}" "${COMPOSE_FILES[@]}" \
  run --rm --no-deps --quiet-pull otel-collector \
    validate \
      --config=/etc/otelcol-config.yml \
      --config=/etc/otelcol-config-full.yml \
      --config=/etc/otelcol-config-observability.yml \
      --config=/etc/otelcol-config-extras.yml \
      --feature-gates=service.profilesSupport
echo ">> configuracao valida."

if [[ "$SOMENTE_VALIDAR" -eq 1 ]]; then
  exit 0
fi

# -----------------------------------------------------------------------------
# 6. Sobe o ambiente e registra a marca de tempo.
#
# make start usa --force-recreate: nenhum container sobrevive do cenario
# anterior. make stop (em ./cenario.sh parar) apaga os volumes, entao cada
# execucao comeca com o TSDB do Prometheus vazio.
# -----------------------------------------------------------------------------
make start

INICIO_EPOCH=$(date +%s)
mkdir -p experimento/execucoes
REGISTRO="experimento/execucoes/${CENARIO}-$(date -u -d "@${INICIO_EPOCH}" +%Y%m%dT%H%M%SZ).env"
{
  echo "CENARIO=${CENARIO}"
  echo "INICIO_EPOCH=${INICIO_EPOCH}"
  echo "AQUECIMENTO_FIM_EPOCH=$((INICIO_EPOCH + 600))"
  echo "MEDICAO_FIM_EPOCH=$((INICIO_EPOCH + 600 + 1800))"
  echo "EXTRAS=${EXTRAS}"
  echo "VUS=$(python3 -c "import json;c=json.load(open('src/flagd/demo.flagd.json'))['flags']['loadGeneratorVUs'];print(c['variants'][c['defaultVariant']])")"
  echo "RPS=$(grep -h '^LOAD_GENERATOR_RPS=' .env.override .env | head -1 | cut -d= -f2)"
  # Steal time acumulado do host no inicio da execucao. A diferenca contra a
  # leitura final e a evidencia de que a VM compartilhada nao contaminou a
  # medicao (secao "Limitacoes" do TCC).
  echo "STEAL_INICIO=$(awk '/^cpu /{print $9}' /proc/stat)"
} > "$REGISTRO"

echo
echo "=============================================================="
echo " cenario ....... ${CENARIO}"
echo " registro ...... ${REGISTRO}"
echo " descarte ...... ate $(date -d "@$((INICIO_EPOCH + 600))" '+%H:%M:%S')  (10 min de aquecimento)"
echo " medir de ...... $(date -d "@$((INICIO_EPOCH + 600))" '+%H:%M:%S')"
echo "        ate .... $(date -d "@$((INICIO_EPOCH + 2400))" '+%H:%M:%S')  (30 min)"
echo "=============================================================="
echo
echo "Conferir se o processador subiu (esperado apenas no cenario 'teste'):"
echo "  docker logs otel-collector 2>&1 | grep -i isolationforest"
echo
echo "Conferir se o cAdvisor esta sendo raspado:"
echo "  curl -s localhost:9090/api/v1/targets | grep -o '\"health\":\"[a-z]*\"'"
