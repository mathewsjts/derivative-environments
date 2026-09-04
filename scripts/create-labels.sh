#!/usr/bin/env bash
#
# create-labels.sh -- cria as 4 labels que o modelo usa. Idempotente (--force).
#
#   deploy:<env>   marca de intencao, aplicada por gente.
#                  "quero esta branch no conjunto de <env>".
#
#   blocked:<env>  marca de ESTADO, aplicada e removida so pelo job.
#                  E o unico "banco de dados" do modelo: e por causa dela que o
#                  job sabe se ja comentou, sem guardar estado em lugar nenhum.
#                  Nao aplique a mao.
set -euo pipefail

create() {
  gh label create "$1" --color "$2" --description "$3" --force
  printf '  %-16s %s\n' "$1" "$3"
}

echo "Criando labels em ${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}:"

create "deploy:dev"  "0E8A16" "Incluir esta branch na proxima reconstrucao de dev"
create "deploy:hom"  "1D76DB" "Incluir esta branch na proxima reconstrucao de hom"
create "blocked:dev" "D93F0B" "[automatico] Fora de dev por conflito - nao aplique a mao"
create "blocked:hom" "B60205" "[automatico] Fora de hom por conflito - nao aplique a mao"

echo
echo "Pronto. As labels blocked:* sao gerenciadas pelo job rebuild-env."
