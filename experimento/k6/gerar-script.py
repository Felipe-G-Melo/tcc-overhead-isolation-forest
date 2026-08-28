#!/usr/bin/env python3
"""
Deriva experimento/k6/script.js de src/load-generator/script.js.

Por que existir em vez de uma copia editada a mao: o arquivo gerado precisa ser
verificavelmente igual ao upstream a menos das duas alteracoes abaixo. Uma copia
manual de 11 KB nao sustenta essa afirmacao num TCC; este script sustenta, e
falha alto se o upstream mudar sob os pes.

Alteracoes:

1. executor `constant-vus` -> `constant-arrival-rate`.
   Com constant-vus a carga e FECHADA: se o Collector saturar no cenario de
   teste, a contrapressao chega aos exportadores dos SDKs, os servicos ficam
   mais lentos, cada VU itera menos e menos telemetria e gerada. O overhead se
   auto-atenua e aparece menor do que e. Carga aberta remove esse acoplamento:
   a taxa de chegada e imposta, nao negociada com o sistema sob medicao.

2. Remocao do `sleep(1..10)` ao fim de httpScenario.
   Com constant-arrival-rate o espacamento entre iteracoes e o proprio
   executor quem impoe; manter o sleep so consumiria VUs do pool sem
   alterar a taxa.

O cenario de browser nao e tocado: fica desligado por K6_BROWSER_ENABLED=false.
"""
import pathlib
import sys

RAIZ = pathlib.Path(__file__).resolve().parents[2]
ORIGEM = RAIZ / "src/load-generator/script.js"
DESTINO = RAIZ / "experimento/k6/script.js"

EXECUTOR_ORIGINAL = """        load: {
            executor: 'constant-vus',
            exec: 'httpScenario',
            vus: parseInt(__ENV.LOAD_GENERATOR_VUS || '10'),
            duration: __ENV.K6_DURATION || '9999h',
        },
"""

# LOAD_GENERATOR_RPS, e nao K6_RPS: k6 consome as variaveis com prefixo K6_
# como opcoes proprias -- K6_RPS existe e e um limitador global de taxa, que
# colidiria com o executor. O mesmo motivo pelo qual o upstream usa
# LOAD_GENERATOR_VUS em vez de K6_VUS.
#
# preAllocatedVUs == maxVUs de proposito: o pool de VUs fica sendo fator de
# controle (custo de CPU identico do gerador nos dois cenarios) e qualquer
# insuficiencia aparece como `dropped_iterations` no sumario do k6, em vez de
# ser absorvida silenciosamente por VUs extras.
EXECUTOR_NOVO = """        load: {
            executor: 'constant-arrival-rate',
            exec: 'httpScenario',
            rate: parseInt(__ENV.LOAD_GENERATOR_RPS || '50'),
            timeUnit: '1s',
            preAllocatedVUs: parseInt(__ENV.LOAD_GENERATOR_VUS || '50'),
            maxVUs: parseInt(__ENV.LOAD_GENERATOR_VUS || '50'),
            duration: __ENV.K6_DURATION || '9999h',
        },
"""

SLEEP_ORIGINAL = """
    sleep(cryptoRandom() * 9 + 1)  // mirrors Locust between(1, 10)
"""

def trocar(texto, antigo, novo, rotulo):
    n = texto.count(antigo)
    if n != 1:
        sys.exit(
            f"ERRO: o trecho '{rotulo}' aparece {n} vezes em {ORIGEM} "
            "(esperado: exatamente 1). O upstream mudou -- revise o patch "
            "antes de rodar o experimento."
        )
    return texto.replace(antigo, novo)


# Leitura e escrita com newline literal: sem isso o Python no Windows converteria
# LF para CRLF e o arquivo gerado divergiria do upstream em todas as linhas,
# tornando inutil o diff de auditoria.
# Path.read_text() so aceita `newline` no Python 3.13+; open() aceita em
# qualquer versao.
with ORIGEM.open("r", encoding="utf-8", newline="") as f:
    origem = f.read()
saida = trocar(origem, EXECUTOR_ORIGINAL, EXECUTOR_NOVO, "executor")
saida = trocar(saida, SLEEP_ORIGINAL, "\n", "sleep entre iteracoes")

cabecalho = (
    "// GERADO por experimento/k6/gerar-script.py -- NAO EDITAR A MAO.\n"
    "// Derivado de src/load-generator/script.js da release 3.0.0.\n"
    "// Delta: executor constant-vus -> constant-arrival-rate; sleep(1..10)\n"
    "// removido do fim de httpScenario. Ver o docstring do gerador.\n\n"
)
with DESTINO.open("w", encoding="utf-8", newline="") as f:
    f.write(cabecalho + saida)
print(f">> {DESTINO.relative_to(RAIZ)} gerado ({len(saida.splitlines())} linhas)")
