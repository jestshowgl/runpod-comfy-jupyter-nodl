#!/usr/bin/env bash
set -euo pipefail

# --- Порты ---
COMFY_PORT="${COMFY_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

# --- Volume ---
VOL="/workspace"
COMFY_DIR="${COMFY_DIR:-$VOL/ComfyUI}"
VENV_DIR="${VENV_DIR:-$VOL/venv}"

# --- Jupyter token (ОБЯЗАТЕЛЬНО) ---
# если не задашь env JUPYTER_TOKEN, сгенерим случайный и покажем в логах
if [[ -z "${JUPYTER_TOKEN:-}" ]]; then
  JUPYTER_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
  export JUPYTER_TOKEN
fi

echo "[INFO] Volume: $VOL"
echo "[INFO] ComfyUI dir: $COMFY_DIR"
echo "[INFO] Jupyter token: $JUPYTER_TOKEN"

# --- Проверка ComfyUI на диске ---
if [[ ! -d "$COMFY_DIR" ]]; then
  echo "[FATAL] Не найден ComfyUI в $COMFY_DIR"
  echo "Положи ComfyUI в /workspace/ComfyUI (или задай COMFY_DIR) и перезапусти Pod."
  exit 1
fi

# --- Виртуальное окружение на volume (чтобы зависимости нод не слетали) ---
if [[ ! -d "$VENV_DIR" ]]; then
  echo "[INFO] Создаю venv в $VENV_DIR (один раз, потом сохраняется на диске)"
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
python -m pip install -U pip wheel setuptools >/dev/null

# --- Ставим requirements ComfyUI (без автопуллов/докачек моделей) ---
if [[ -f "$COMFY_DIR/requirements.txt" ]]; then
  echo "[INFO] Installing ComfyUI requirements (если уже стоят — быстро пройдет)"
  python -m pip install -r "$COMFY_DIR/requirements.txt"
fi

# --- Опционально: общий файл зависимостей для нод ---
# Если хочешь стабильно фиксировать зависимости — создай /workspace/requirements_nodes.txt
if [[ -f "$VOL/requirements_nodes.txt" ]]; then
  echo "[INFO] Installing node requirements from /workspace/requirements_nodes.txt"
  python -m pip install -r "$VOL/requirements_nodes.txt"
fi

# --- Запуск JupyterLab ---
# ВАЖНО: запускаем как root, иначе часто нет прав на volume -> нельзя удалять/терминал
# Root в контейнере = нормально для RunPod, но НЕ выключай токен.
#
# FIX для RunPod proxy / xterm.js:
# - отключаем websocket compression (часто ломает ввод в терминале через proxy)
# - включаем websocket ping, чтобы соединение не "замирало"
# - trust_xheaders + allow_remote_access для нормальной работы за reverse proxy
TORNADO_SETTINGS="{'websocket_compression_options': None, 'websocket_ping_interval': 25, 'websocket_ping_timeout': 120}"

echo "[INFO] Starting JupyterLab on port $JUPYTER_PORT"
jupyter lab \
  --ip=0.0.0.0 \
  --port="$JUPYTER_PORT" \
  --no-browser \
  --ServerApp.token="$JUPYTER_TOKEN" \
  --ServerApp.password="" \
  --ServerApp.allow_root=True \
  --ServerApp.root_dir="$VOL" \
  --ServerApp.allow_remote_access=True \
  --ServerApp.trust_xheaders=True \
  --ServerApp.terminals_enabled=True \
  --ServerApp.tornado_settings="$TORNADO_SETTINGS" \
  >/tmp/jupyter.log 2>&1 &

JUP_PID=$!

# --- Запуск ComfyUI ---
cd "$COMFY_DIR"
COMFY_ARGS="${COMFYUI_ARGS:---listen 0.0.0.0 --port $COMFY_PORT}"
echo "[INFO] Starting ComfyUI: python main.py $COMFY_ARGS"
python main.py $COMFY_ARGS >/tmp/comfy.log 2>&1 &
COMFY_PID=$!

# --- Ждём любой процесс; если один умер — гасим второй и падаем (чтобы было видно проблему) ---
set +e
wait -n "$JUP_PID" "$COMFY_PID"
CODE=$?
echo "[ERROR] One of services stopped (exit=$CODE). Printing last logs:"

echo "----- JUPYTER (tail) -----"
tail -n 200 /tmp/jupyter.log || true
echo "----- COMFY (tail) -----"
tail -n 200 /tmp/comfy.log || true

kill "$JUP_PID" "$COMFY_PID" 2>/dev/null || true
exit $CODE
