# Overhead do Isolation Forest no OpenTelemetry Collector

Experimento do TCC: **quanto custa em CPU e memória** manter o processador
`isolationforest` rodando na pipeline do OpenTelemetry Collector, sob carga
realista, no OpenTelemetry Demo 3.0.0.

Compara dois cenários com todos os outros fatores constantes:

| Cenário | Collector |
|---|---|
| `baseline` | demo 3.0.0 intocado |
| `teste` | `isolationforest` acrescentado aos 3 pipelines (traces, metrics, logs) |

Saída: CSV de CPU e memória do container `otel-collector`, exportados do
Prometheus, 3 execuções por cenário.

Este README é o passo a passo operacional completo — do zero até os dados na
sua máquina. Cada escolha não-óbvia está justificada no ponto em que aparece.

---

## Índice

- [Parte 0 — Pré-requisitos e custo](#parte-0--pré-requisitos-e-custo)
- [Parte 1 — Montar a árvore do experimento](#parte-1--montar-a-árvore-do-experimento)
- [Parte 2 — Provisionar a instância na AWS](#parte-2--provisionar-a-instância-na-aws)
- [Parte 3 — Preparar o sistema operacional](#parte-3--preparar-o-sistema-operacional)
- [Parte 4 — Enviar o experimento para a VM](#parte-4--enviar-o-experimento-para-a-vm)
- [Parte 5 — Validar e smoke test](#parte-5--validar-e-smoke-test)
- [Parte 6 — Piloto de calibração](#parte-6--piloto-de-calibração)
- [Parte 7 — As seis execuções medidas](#parte-7--as-seis-execuções-medidas)
- [Parte 8 — Trazer os dados e desligar](#parte-8--trazer-os-dados-e-desligar)
- [Referência rápida](#referência-rápida)
- [Armadilhas conhecidas](#armadilhas-conhecidas)
- [Estrutura do repositório](#estrutura-do-repositório)

---

## Parte 0 — Pré-requisitos e custo

### Na sua máquina

- AWS CLI v2 configurada (`aws configure`) com uma conta que tenha crédito
- Cliente SSH e `scp` (no Windows: **Git Bash**)
- `unzip`, `python3`

### Na VM (instalado na Parte 3)

- Ubuntu Server 24.04 LTS, Docker Engine + Compose plugin, `make`, `python3`

### Custo

`c6i.2xlarge` on-demand: **US$ 0,34/h**.

| Etapa | Tempo |
|---|---|
| Provisionar + preparar SO + Docker | ~40 min |
| Validação + smoke test | ~40 min |
| Piloto de calibração | ~1 h 30 |
| 6 execuções (3 por cenário × ~50 min) | ~5 h |
| Folga para re-execuções | ~2 h |
| **Total** | **~10 h ≈ US$ 3,40** |

> **Pare a instância entre as sessões.** O EBS continua cobrando ~US$ 8/mês
> pelos 100 GB (irrelevante); a instância ligada, não.

---

## Parte 1 — Montar a árvore do experimento

Este repositório **não** contém o OpenTelemetry Demo. Ele carrega só a camada
do experimento: os arquivos que você aplica sobre a release 3.0.0 oficial,
baixada do upstream no passo 1.1.

É de propósito. O experimento inteiro se apoia em comparar um Collector
**intocado** contra o mesmo Collector com um processador a mais. Se o
repositório trouxesse uma cópia já modificada do demo, ninguém teria como
verificar o que foi mexido — e "baseline" viraria uma alegação, não um fato
conferível.

### O princípio: quase nada da release é editado

Só **dois** arquivos da 3.0.0 são alterados à mão:

| Arquivo | O que muda |
|---|---|
| `.env` | 3 linhas |
| `compose.extras.yaml` | substituído (era um stub só de comentários) |

Mais dois são reescritos **em tempo de execução** pelo `cenario.sh`:

| Arquivo | Quando |
|---|---|
| `.env.override` | a cada subida (seleciona o cenário) |
| `src/flagd/demo.flagd.json` | quando se passa `VUS=` |

Todo o resto é **aditivo**: mora em `experimento/`. Permanecem **intocados**
`src/otel-collector/otelcol-config-extras.yml`,
`src/prometheus/prometheus-config.yaml`, `src/load-generator/script.js`,
`compose.yaml`, `compose.full.yaml` e `compose.observability.yaml`.

Isso é deliberado: o baseline precisa ser o demo intocado. Se a montagem
editasse arquivos da release, "baseline" deixaria de significar isso.

### 1.1 Baixar este repositório e a release do demo

Os dois ficam **lado a lado**, na mesma pasta de trabalho:

```bash
mkdir -p ~/tcc && cd ~/tcc

# 1. este repositório
git clone https://github.com/Felipe-G-Melo/tcc-overhead-isolation-forest.git

# 2. a release 3.0.0 oficial do OpenTelemetry Demo
curl -L -o opentelemetry-demo-3.0.0.zip \
  https://github.com/open-telemetry/opentelemetry-demo/archive/refs/tags/v3.0.0.zip
unzip opentelemetry-demo-3.0.0.zip
```

Resultado:

```
~/tcc/
├── tcc-overhead-isolation-forest/    este repositório
└── opentelemetry-demo-3.0.0/         a release limpa
```

Os passos 1.2 a 1.5 rodam **de dentro da release**:

```bash
cd ~/tcc/opentelemetry-demo-3.0.0
```

### 1.2 Preservar os originais

```bash
mkdir -p experimento/configs experimento/k6
cp .env .env.ORIGINAL-3.0.0
cp compose.extras.yaml experimento/compose.extras.yaml.ORIGINAL-3.0.0
```

Não é zelo excessivo: é o que permite provar depois que as alterações foram
exatamente as descritas — `diff .env.ORIGINAL-3.0.0 .env`.

### 1.3 Editar o `.env` (3 mudanças)

**1.** Linha 4 — fixar a versão do demo:

```diff
-DEMO_VERSION=latest
+DEMO_VERSION=3.0.0
```

**2.** No bloco `# Dependent images`, logo antes de `FIREPIT_IMAGE` — pinar o cAdvisor:

```diff
+CADVISOR_IMAGE=gcr.io/cadvisor/cadvisor:v0.53.0
 FIREPIT_IMAGE=ghcr.io/florianl/firepit:v0.1.0
```

**3.** Na linha de `LOAD_GENERATOR_VUS` — documentar a armadilha e acrescentar
a taxa de chegada:

```diff
+# Pool de VUs do k6 (preAllocatedVUs == maxVUs no script do experimento).
+# ATENCAO: com o entrypoint.sh da 3.0.0 este valor so vale se o flag
+# loadGeneratorVUs do flagd retornar 0. Use VUS= no cenario.sh.
 LOAD_GENERATOR_VUS=5
+
+# Taxa de chegada imposta ao k6, em iteracoes/s (executor constant-arrival-rate).
+# Definir no piloto de calibracao.
+LOAD_GENERATOR_RPS=50
 K6_TARGET_URL=http://${FRONTEND_PROXY_ADDR}
```

**Por quê:**

- **(1)** `latest` são tags mutáveis. Baseline e teste poderiam rodar binários
  diferentes, silenciosamente, e o experimento perderia o sentido sem dar sinal.
- **(2)** O cAdvisor é o instrumento de medição. Tag móvel no instrumento é o
  mesmo problema, um nível acima.
- **(3)** O executor `constant-arrival-rate` lê `LOAD_GENERATOR_RPS`. O nome
  não pode começar com `K6_` — o k6 consome essas variáveis como opções
  próprias, e `K6_RPS` é um limitador global de taxa que colidiria com o executor.

Conferir: `diff .env.ORIGINAL-3.0.0 .env`

### 1.4 Copiar os arquivos do experimento

Ainda de dentro de `opentelemetry-demo-3.0.0/`, com o repositório ao lado:

```bash
REPO=../tcc-overhead-isolation-forest

cp "$REPO/cenario.sh" "$REPO/compose.extras.yaml" .
cp -r "$REPO/experimento/." experimento/
```

Os caminhos do repositório espelham exatamente onde cada arquivo entra na
release:

```
cenario.sh                                        (raiz)
compose.extras.yaml                               (raiz, substitui o stub)
experimento/coletar.sh
experimento/k6/gerar-script.py
experimento/configs/otelcol-config-extras.BASELINE.yml
experimento/configs/otelcol-config-extras.TESTE.yml
experimento/configs/prometheus-config.template.yaml
```

Integridade dos arquivos **operativos** — os que afetam o resultado da medição
(primeiros 16 caracteres do SHA-256, estado de 22/08/2026):

```
93d4bd0b599d4fd3  cenario.sh
09d7ca4b354b525e  compose.extras.yaml
605bf3ef1cd6d4a4  experimento/coletar.sh
39a324ce40c707d8  experimento/k6/gerar-script.py
7179da677d4e32c0  experimento/configs/otelcol-config-extras.BASELINE.yml
5c52916d8a123c20  experimento/configs/otelcol-config-extras.TESTE.yml
3a931bc7d587822b  experimento/configs/prometheus-config.template.yaml
```

Verificar os sete de uma vez:

```bash
for f in cenario.sh compose.extras.yaml experimento/coletar.sh \
         experimento/k6/gerar-script.py \
         experimento/configs/otelcol-config-extras.BASELINE.yml \
         experimento/configs/otelcol-config-extras.TESTE.yml \
         experimento/configs/prometheus-config.template.yaml; do
  printf '%s  %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"
done
```

A documentação fica de fora de propósito: muda a cada revisão de texto e um
checksum ali só produziria alarme falso.

<details>
<summary>Como dois desses arquivos derivam da release (auditável)</summary>

**`otelcol-config-extras.BASELINE.yml`** — cópia verbatim de
`src/otel-collector/otelcol-config-extras.yml` (que só tem comentários), mais
um cabeçalho explicativo:

```bash
diff src/otel-collector/otelcol-config-extras.yml \
     experimento/configs/otelcol-config-extras.BASELINE.yml
```

Só devem aparecer as 12 linhas de cabeçalho. Ele existe como arquivo separado,
em vez de apontar para o stub, para que os dois cenários sejam montados pelo
mesmo caminho — o único delta entre eles é o conteúdo do arquivo.

**`prometheus-config.template.yaml`** — cópia de
`src/prometheus/prometheus-config.yaml` mais um bloco `scrape_configs` no fim:

```bash
diff src/prometheus/prometheus-config.yaml \
     experimento/configs/prometheus-config.template.yaml
```

Só deve aparecer o bloco acrescentado. Os demais arquivos são originais deste
trabalho.

</details>

### 1.5 Gerar os derivados e verificar

```bash
chmod +x cenario.sh experimento/coletar.sh
sed -i 's/\r$//' cenario.sh experimento/coletar.sh   # se veio do Windows
```

**Script do k6:**

```bash
python3 experimento/k6/gerar-script.py
diff <(tail -n +6 experimento/k6/script.js) src/load-generator/script.js
```

Deve mostrar **exatamente** duas alterações: `constant-vus` virando
`constant-arrival-rate`, e a remoção do `sleep(1..10)` no fim de
`httpScenario`. Qualquer outra coisa significa que a release não é a 3.0.0.

**Compose:**

```bash
docker compose --env-file .env --env-file .env.override \
  -f compose.yaml -f compose.full.yaml -f compose.observability.yaml \
  -f compose.extras.yaml config --quiet
```

Silêncio é sucesso.

**Configuração do Collector** — a verificação mais importante da montagem.
Confirma que o `isolationforest` existe na imagem contrib 0.157.0 e que o
schema escrito é o que o binário aceita:

```bash
./cenario.sh validar baseline
./cenario.sh validar teste
```

Esperado: `>> configuracao valida.` nos dois.

**Listas de processors:**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('experimento/configs/otelcol-config-extras.TESTE.yml'))
for p, v in d['service']['pipelines'].items():
    print(p, v['processors'])
"
```

Devem sair as listas da 3.0.0 com `isolationforest` **acrescentado ao final**:

```
traces  ['resourcedetection', 'memory_limiter', 'transform/sanitize_spans', 'gen_ai_normalizer', 'isolationforest']
metrics ['resourcedetection', 'memory_limiter', 'isolationforest']
logs    ['resourcedetection', 'memory_limiter', 'transform/sanitize_logs', 'isolationforest']
```

O Collector **substitui** arrays em vez de concatenar: um nome esquecido faria
o cenário de teste rodar sem `memory_limiter` ou sem as transformações, e a
comparação seria inválida **sem dar erro**.

### 1.6 Estado esperado ao fim da Parte 1

```
opentelemetry-demo-3.0.0/
├── .env                         editado (3 linhas)
├── .env.ORIGINAL-3.0.0          cópia de segurança
├── .env.override                reescrito pelo cenario.sh
├── cenario.sh                   novo
├── compose.extras.yaml          substituído
└── experimento/
    ├── coletar.sh
    ├── compose.extras.yaml.ORIGINAL-3.0.0
    ├── configs/
    │   ├── otelcol-config-extras.BASELINE.yml
    │   ├── otelcol-config-extras.TESTE.yml
    │   ├── prometheus-config.generated.yaml     gerado
    │   └── prometheus-config.template.yaml
    ├── execucoes/                               criado na 1ª execução
    └── k6/
        ├── gerar-script.py
        └── script.js                            gerado
```

---

## Parte 2 — Provisionar a instância na AWS

Tudo em `us-east-1`. O tráfego é 100% interno à VM, então a região só afeta custo.

Pelo AWS CLI, e não pelo console: os parâmetros abaixo são citáveis no texto e
reproduzíveis por quem ler o trabalho.

```bash
export AWS_REGION=us-east-1

# SSH restrito ao seu IP atual. Se sua conexão trocar de IP, refaça esta regra.
MEU_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 create-key-pair --key-name tcc-overhead \
  --query 'KeyMaterial' --output text > ~/.ssh/tcc-overhead.pem
chmod 400 ~/.ssh/tcc-overhead.pem

SG_ID=$(aws ec2 create-security-group \
  --group-name tcc-overhead \
  --description "TCC overhead Isolation Forest - somente SSH" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MEU_IP}/32"

# AMI oficial da Canonical, resolvida por SSM em vez de ID fixo: IDs de AMI
# variam por região e são substituídos a cada republicação.
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameters[0].Value' --output text)

ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type c6i.2xlarge \
  --cpu-options CoreCount=4,ThreadsPerCore=1 \
  --key-name tcc-overhead \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=tcc-overhead-if}]' \
  --query 'Instances[0].InstanceId' --output text)

echo "$ID" > ~/.ssh/tcc-instance-id

IP=$(aws ec2 describe-instances --instance-ids "$ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "IP: $IP"
```

> **`--cpu-options` só vale no lançamento.** Não há como desligar o SMT depois.
> Se errar, é preciso terminar a instância e lançar outra.

**Conferir que o SMT está mesmo desligado:**

```bash
ssh -i ~/.ssh/tcc-overhead.pem ubuntu@"$IP"
lscpu | grep -E 'CPU\(s\)|Thread|Core|Model name'
```

Esperado: `CPU(s): 4`, `Thread(s) per core: 1`, `Core(s) per socket: 4`.
Se aparecerem 8 vCPUs, o `--cpu-options` não pegou — relance a instância.

---

## Parte 3 — Preparar o sistema operacional

> **Não é burocracia.** O Ubuntu vem com atualização automática ligada. Um
> `apt` disparando no meio de uma janela de 30 min queima CPU e contamina
> *uma* das seis execuções, de forma invisível, criando um outlier que você
> não saberia explicar.

```bash
sudo systemctl disable --now \
  unattended-upgrades \
  apt-daily.timer apt-daily-upgrade.timer \
  apt-daily.service apt-daily-upgrade.service

sudo snap refresh --hold

# Atualiza uma vez, agora, e não mais durante o experimento.
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y make python3 ca-certificates curl gnupg
```

### Docker pelo repositório oficial

O `docker.io` do Ubuntu vem atrasado. O repositório oficial dá uma versão
pinável e citável.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker ubuntu
```

**Saia e entre de novo no SSH** para o grupo `docker` valer.

### Registrar o ambiente

Fonte da caracterização do ambiente no texto — traga este arquivo junto com os CSV.

```bash
{
  echo "=== data ==="; date -u
  echo "=== instancia ==="
  TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-type; echo
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/availability-zone; echo
  echo "=== cpu ==="; lscpu
  echo "=== memoria ==="; free -h
  echo "=== kernel ==="; uname -a
  echo "=== so ==="; cat /etc/os-release
  echo "=== docker ==="; docker --version; docker compose version
} > ~/ambiente.txt
```

---

## Parte 4 — Enviar o experimento para a VM

Da sua máquina (Git Bash), em `~/tcc` — a pasta que contém a árvore montada na
Parte 1. Vai a **release já com o experimento aplicado**, não este repositório:

```bash
cd ~/tcc
scp -i ~/.ssh/tcc-overhead.pem -r opentelemetry-demo-3.0.0 ubuntu@"$IP":~/
```

São ~10 MB. Já na VM:

```bash
cd ~/opentelemetry-demo-3.0.0
sed -i 's/\r$//' cenario.sh experimento/coletar.sh
chmod +x cenario.sh experimento/coletar.sh
```

O `sed` remove CRLF que o Windows possa ter introduzido: um `\r` no shebang
produz `bad interpreter` — erro que não parece o que é.

---

## Parte 5 — Validar e smoke test

```bash
./cenario.sh validar baseline
./cenario.sh validar teste
```

Depois, carga baixa. O objetivo aqui é provar que a máquina funciona, **não** medir:

```bash
RPS=20 VUS=30 ./cenario.sh teste
```

O primeiro `up` puxa ~20 imagens. Enquanto baixa, abra um segundo terminal com
o túnel SSH para as interfaces — as portas **não** estão abertas na internet, e
não devem estar:

```bash
ssh -i ~/.ssh/tcc-overhead.pem \
  -L 8080:localhost:8080 -L 9090:localhost:9090 ubuntu@"$IP"
```

### As cinco verificações

```bash
# a) o processador carregou (só deve sair no cenário 'teste')
docker logs otel-collector 2>&1 | grep -i isolationforest

# b) o cAdvisor está sendo raspado
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'

# c) a consulta de CPU do Collector retorna dado (esperar ~3 min)
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=rate(container_cpu_usage_seconds_total{name="otel-collector"}[1m])*100'

# d) a carga está sendo entregue — deve ficar em zero
docker logs load-generator 2>&1 | grep -i dropped_iterations

# e) quais métricas internas o Collector expõe
curl -s localhost:9090/api/v1/label/__name__/values | tr ',' '\n' | grep otelcol_
```

> A verificação (e) resolve uma pendência aberta: CPU e memória vêm do
> cAdvisor, mas o Collector **não** expõe um "tempo dentro do processador".
> Use esta listagem para escolher a definição operacional de latência antes da
> primeira execução medida.

### A verificação que decide tudo

Depois de ~15 min de carga, abra `http://localhost:8080/jaeger/ui` pelo túnel,
escolha um serviço e procure `anomaly.isolation_score` nos atributos de um span.
Em `mode: enrich` é assim que o processador se manifesta.

Se o atributo não aparecer, o processador subiu mas está **inerte** — e o
experimento estaria medindo a diferença entre "desligado" e "ligado sem fazer
nada". Suspeito nº 1: `min_samples: 1000` não foi atingido. Suba o RPS ou
espere mais.

```bash
./cenario.sh parar
```

---

## Parte 6 — Piloto de calibração

Objetivo: achar o `RPS` que deixa o **host** em 50–60% de CPU no cenário baseline.

> **O alvo é o host, não o Collector.** A razão é deixar folga para o Isolation
> Forest consumir CPU: se a máquina já estiver saturada, o custo do processador
> não aparece como delta de CPU — vira enfileiramento e latência, e a atribuição
> causal se perde. Um Collector a 55% de *um* núcleo, numa máquina de 4, não
> diria nada sobre saturação.

```bash
RPS=40 VUS=60 ./cenario.sh baseline
```

Espere ~12 min e observe as duas séries. O host primeiro:

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=sum(rate(container_cpu_usage_seconds_total{id="/"}[1m])) / machine_cpu_cores'
```

E o Collector:

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=rate(container_cpu_usage_seconds_total{name="otel-collector"}[1m])*100'
```

Ajuste o `RPS` e repita até o host estabilizar entre **0,50 e 0,60**. Registre
os dois números — o do host justifica o critério, o do Collector é a linha de
base da variável dependente.

Confira também que `dropped_iterations` continua em zero: se o k6 não estiver
entregando a taxa pedida, o RPS calibrado é fictício. Se cair, aumente `VUS`.

Fixado o valor, **ele vira fator de controle**: não muda mais entre execuções.

---

## Parte 7 — As seis execuções medidas

Alternando os cenários, para diluir deriva térmica ou de vizinhança:

```
baseline → teste → baseline → teste → baseline → teste
```

Para cada uma, com o `RPS` e o `VUS` do piloto:

```bash
RPS=<piloto> VUS=<piloto> ./cenario.sh baseline   # ou teste

# O script imprime a janela. São 40 min: 10 de aquecimento (descartados)
# + 30 de medição. Espere.

./experimento/coletar.sh experimento/execucoes/<arquivo>.env
./cenario.sh parar
```

> **`coletar.sh` ANTES de `parar`.** O `make stop` remove os volumes, e o TSDB
> do Prometheus vai junto. Coletar depois é perder a execução.

O `coletar.sh` grava os CSV (`.cpu.csv` e `.memoria.csv`), imprime
média/mediana/P99 e anexa o delta de `steal time` ao arquivo da execução.

**Confira o steal a cada rodada**: se subir de forma perceptível, a VM teve
contenção de vizinhança e aquela execução precisa ser refeita.

---

## Parte 8 — Trazer os dados e desligar

```bash
# da sua máquina
scp -i ~/.ssh/tcc-overhead.pem -r \
  ubuntu@"$IP":~/opentelemetry-demo-3.0.0/experimento/execucoes ./resultados
scp -i ~/.ssh/tcc-overhead.pem ubuntu@"$IP":~/ambiente.txt ./resultados/
```

Entre sessões — para de cobrar a instância, mantém o disco:

```bash
aws ec2 stop-instances  --instance-ids "$(cat ~/.ssh/tcc-instance-id)"
aws ec2 start-instances --instance-ids "$(cat ~/.ssh/tcc-instance-id)"
```

> O IP **público** muda a cada start. Pegue o novo com `describe-instances`. E
> lembre que a regra do security group aponta para o *seu* IP, não o dela — se
> sua conexão trocar de IP, refaça a regra da Parte 2.

No fim de tudo, **só depois de conferir que os CSV chegaram**:

```bash
aws ec2 terminate-instances --instance-ids "$(cat ~/.ssh/tcc-instance-id)"
```

Isso apaga o disco de 100 GB junto (`DeleteOnTermination: true`).

---

## Referência rápida

```bash
./cenario.sh validar baseline|teste      # valida a config, não sobe nada
RPS=<n> VUS=<n> ./cenario.sh baseline    # sobe o cenário baseline
RPS=<n> VUS=<n> ./cenario.sh teste       # sobe o cenário teste
./experimento/coletar.sh <registro>.env  # exporta a janela (ANTES de parar)
./cenario.sh parar                       # derruba tudo (apaga volumes)
```

| Variável | Papel |
|---|---|
| `RPS` | taxa de chegada imposta ao k6, em iterações/s |
| `VUS` | tamanho do pool de VUs (escrito no flagd, não no `.env`) |

| Endereço (pelo túnel SSH) | O quê |
|---|---|
| `localhost:8080` | frontend proxy do demo |
| `localhost:8080/jaeger/ui` | Jaeger — conferir `anomaly.isolation_score` |
| `localhost:9090` | Prometheus |

---

## Armadilhas conhecidas

As cinco primeiras são do próprio demo; as três últimas são de ambiente.

| # | Armadilha | Como se manifesta |
|---|---|---|
| 1 | k6 com carga fechada (`constant-vus` + `sleep`) | **Nenhuma.** O overhead se auto-atenua silenciosamente |
| 2 | `LOAD_GENERATOR_VUS` do `.env` é ignorado | A carga não muda por mais que você edite o `.env` |
| 3 | `scrape_interval` global de 60 s | `rate(...[1m])` volta vazio ou serrilhado |
| 4 | Collector limitado a 400 MB, contra `max_memory_mb: 512` | Delta de memória achatado, lido como "sem overhead" |
| 5 | Chromium headless ligado por padrão | Ruído de dezenas de pontos percentuais na CPU |
| 6 | `Path.read_text(newline=)` só existe no Python 3.13+ | `TypeError` no gerador do k6. Ubuntu 24.04 traz 3.12 |
| 7 | Git Bash reescreve `/etc/...` para `C:/Program Files/Git/etc/...` | `unable to read the file` na validação. Só no Windows |
| 8 | CRLF no shebang de scripts vindos do Windows | `bad interpreter` — erro que não parece o que é |

A de nº 1 é a mais perigosa das oito, porque é a única que **não produz
sintoma**: o experimento roda até o fim, gera números, e os números estão
errados na direção de subestimar o efeito medido.

---

## Estrutura do repositório

Este repositório carrega **só a camada do experimento** — o OpenTelemetry Demo
3.0.0 é baixado do upstream no
[passo 1.1](#11-baixar-este-repositório-e-a-release-do-demo). Os caminhos aqui
espelham exatamente onde cada arquivo entra na release.

```
.
├── README.md                    este guia
├── .gitignore                   ignora os derivados e a release baixada
├── cenario.sh                   sobe um cenário          → raiz da release
├── compose.extras.yaml          cAdvisor, limites de     → raiz da release
│                                memória, k6 sem browser
└── experimento/                                          → experimento/
    ├── coletar.sh               exporta a janela medida do Prometheus
    ├── configs/
    │   ├── otelcol-config-extras.BASELINE.yml    cenário baseline
    │   ├── otelcol-config-extras.TESTE.yml       cenário teste
    │   └── prometheus-config.template.yaml       + job do cAdvisor
    └── k6/
        └── gerar-script.py      deriva o script de carga do upstream
```

| Arquivo | Papel |
|---|---|
| `cenario.sh` | Sobe, valida ou derruba um cenário. Gera os arquivos derivados |
| `compose.extras.yaml` | Overlay idêntico nos dois cenários: cAdvisor, limites de memória do Collector (1 GB) e do Prometheus (1 GB), `K6_BROWSER_ENABLED=false` |
| `configs/otelcol-config-extras.BASELINE.yml` | Só comentários — Collector upstream intocado |
| `configs/otelcol-config-extras.TESTE.yml` | `isolationforest` nos 3 pipelines. **Único delta entre os cenários** |
| `configs/prometheus-config.template.yaml` | Config do Prometheus + job do cAdvisor, com `__CENARIO__` |
| `k6/gerar-script.py` | Troca o executor do script upstream e remove o `sleep`. Aborta se o trecho não bater |
| `coletar.sh` | Exporta a janela medida para CSV e imprime média/mediana/P99 |

**Gerados em tempo de execução** (não versionados, não editar):
`.env.override`, `experimento/configs/prometheus-config.generated.yaml`,
`experimento/k6/script.js`, `experimento/execucoes/`.
