#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/prompt_seguridad.md"
OUT_DIR="$SCRIPT_DIR/informes"

# Muestra un menú numerado y devuelve la elección en ELEGIDO
elegir() {
  local titulo="$1"; shift
  local opts=("$@")
  echo "" >&2
  echo "$titulo" >&2
  local i
  for i in "${!opts[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${opts[$i]}" >&2
  done
  local n
  while true; do
    read -r -p "Elegí una opción [1-${#opts[@]}]: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#opts[@]} )); then
      ELEGIDO="${opts[$((n-1))]}"
      return 0
    fi
    echo "Opción inválida." >&2
  done
}

# ---------- 1. Repositorio ----------
if [[ $# -ge 1 ]]; then
  REPO="$1"
else
  read -r -p "Ruta del repo a auditar [$PWD]: " REPO_IN
  REPO="${REPO_IN:-$PWD}"
fi
[[ -d "$REPO" ]] || { echo "No existe el directorio: $REPO" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"
REPO_BRANCH="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
REPO_COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"
if [[ -z "$REPO_BRANCH" ]]; then REPO_BRANCH="HEAD separado o no es un repo Git"; fi
if [[ -z "$REPO_COMMIT" ]]; then REPO_COMMIT="desconocido"; fi
if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
  REPO_DIRTY="si"
else
  REPO_DIRTY="no"
fi

# ---------- 2. CLI ----------
elegir "¿Qué CLI querés usar?" "Claude Code" "GitHub Copilot CLI"
case "$ELEGIDO" in
  "Claude Code")        ENGINE="claude" ;;
  "GitHub Copilot CLI") ENGINE="copilot" ;;
esac

command -v "$ENGINE" >/dev/null || { echo "No encuentro '$ENGINE' en el PATH." >&2; exit 1; }

# ---------- 3. Modelo (texto libre) ----------
echo ""
echo "Modelo: escribí el nombre y presioná Enter."
if [[ "$ENGINE" == "claude" ]]; then
  echo "  Claude Code acepta alias (sonnet, opus, haiku, fable, best) o un nombre completo."
else
  echo "  Copilot CLI: usá el nombre exacto que muestra /model dentro de una sesión."
fi
echo "  Dejalo vacío para usar el modelo predeterminado de la CLI."
read -r -p "Modelo: " MODEL

MODEL_ARGS=()
MODEL_LABEL="predeterminado"
if [[ -n "$MODEL" ]]; then
  MODEL_ARGS=(--model "$MODEL")
  MODEL_LABEL="$MODEL"
fi

# ---------- 4. Confirmación ----------
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d_%H%M)"
RUN_DIR="$OUT_DIR/${REPO_NAME}_${STAMP}"
REPORT="$RUN_DIR/informe.md"
OSV_JSON="$RUN_DIR/osv.json"
SEMGREP_JSON="$RUN_DIR/semgrep.json"
GITLEAKS_JSON="$RUN_DIR/gitleaks.json"

echo ""
echo "Resumen:"
echo "  Repositorio : $REPO"
echo "  Branch      : $REPO_BRANCH"
echo "  Commit      : $REPO_COMMIT"
echo "  Cambios     : $REPO_DIRTY"
echo "  CLI         : $ENGINE"
echo "  Modelo      : $MODEL_LABEL"
  echo "  Carpeta     : $RUN_DIR"
echo "  Informe     : $REPORT"
echo "  JSON Gitleaks: $GITLEAKS_JSON"
read -r -p "¿Ejecutar la auditoría? [s/N]: " OK
if [[ ! "$OK" =~ ^[sSyY]$ ]]; then
  echo "Cancelado."
  exit 0
fi

# ---------- 5. Ejecución ----------
mkdir -p "$RUN_DIR"
PROMPT="$(cat "$PROMPT_FILE")

Rutas de salida:
- Informe: $REPORT
- JSON de OSV: $OSV_JSON
- JSON de Semgrep: $SEMGREP_JSON
- JSON de Gitleaks: $GITLEAKS_JSON

Contexto del checkout auditado:
- Branch: $REPO_BRANCH
- Commit: $REPO_COMMIT
- Cambios locales sin commit: $REPO_DIRTY"

cd "$REPO"

# ${arr[@]+"${arr[@]}"} evita error con arrays vacíos en bash antiguo (macOS)
if [[ "$ENGINE" == "claude" ]]; then
  claude -p "$PROMPT" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    --add-dir "$RUN_DIR" \
    --allowedTools "Bash(osv-scanner:*) Bash(semgrep:*) Bash(gitleaks:*) Bash(npm:*) Bash(pip-audit:*) Bash(grep:*) Bash(curl:*) Read Grep Glob Write"
else
  copilot -p "$PROMPT" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    -s \
    --no-ask-user \
    --add-dir "$RUN_DIR" \
    --allow-tool='read' \
    --allow-tool='write' \
    --allow-tool='shell(osv-scanner)' \
    --allow-tool='shell(semgrep)' \
    --allow-tool='shell(gitleaks)' \
    --allow-tool='shell(npm)' \
    --allow-tool='shell(pip-audit)' \
    --allow-tool='shell(grep)' \
    --allow-tool='shell(curl)'
fi

echo ""
echo "Resultados generados en: $RUN_DIR"