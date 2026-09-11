#!/usr/bin/env bash
# =============================================================================
# restart_raylight_cluster.sh — 乾淨重啟 raylight 跨機 Ray cluster（head + peer）
#
# 用途：雙 GX10（head=192.168.100.1 本機, peer=192.168.100.2）上重啟 H3 REF2VA
#       （Minimax_H3_REF2VA_Raylight_2xGX10）所需的 raylight Ray cluster。
#       整套流程已於 2026-09-12 實證跑通 H3 REF2VA 2xGX10 成功。
#
# 安全紅線（務必遵守）：
#   * 只動「TCP/命令列含 6380」的 raylight 進程；絕不碰 vLLM deepseek cluster（6379）。
#   * 只 kill 本機使用者（shang）的進程；vLLM raylets 屬 root → kill 會被系統拒絕、自動無傷。
#   * 不跑 `ray stop`（會誤傷同機其他 Ray cluster 例如 vLLM）；全程精準 PID kill。
#
# 用法：
#   ./restart_raylight_cluster.sh            # 完整重啟（清 6380 進程 → 起 head → 起 peer → 驗證）
#   ./restart_raylight_cluster.sh --start-only  # 只啟動，若 cluster 已在跑則直接驗證/離開
#   ./restart_raylight_cluster.sh --help
#
# 之後：重啟 cluster 後需重啟 ComfyUI 才能接上新的 cluster：
#   sudo systemctl restart comfyui.service   （head 那台，sudo 需手動）
# =============================================================================
set -euo pipefail

# ---- 常數（對應實證成功的設定，勿亂改）----------------------------------------
RAYLIGHT_PORT=6380
THRESHOLD=0.995
HEAD_IP=192.168.100.1
PEER_IP=192.168.100.2
PEER_USER=shang
RAY_BIN=/home/shang/projects/ComfyUI/venv/bin/ray
COMFYUI_DIR=/home/shang/projects/ComfyUI
LOGDIR=/home/shang/raylight-logs
MY_USER=$(id -un)

MODE=full
case "${1:-}" in
  --start-only) MODE=start-only ;;
  --help|-h)    sed -n '1,30p' "$0"; exit 0 ;;
  --)           :
esac

# ---- 1) 清理 raylight（6380）進程；絕不碰 vLLM（6379）--------------------------
kill_raylight() {
  local host="$1" peer="$2"

  if [[ "$peer" -eq 0 ]]; then
    # 本機 head
    echo "== 清理本機 ${HEAD_IP} 的 raylight(6380) 進程 =="
    local pids
    pids=$(pgrep -u "$MY_USER" -af \
           | grep '6380' \
           | grep -E 'raylet|gcs_server|log_monitor|dashboard' \
           | cut -d' ' -f1 \
           | grep -vw "$$" || true)
    if [[ -n "$pids" ]]; then
      for p in $pids; do kill "$p" 2>/dev/null || true; done
      sleep 3
      for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
      echo "  killed: $pids"
    else
      echo "  (本機無 raylight 進程)"
    fi
  else
    # 對端 peer —— 對端 shell 是 zsh：避免 $ / [t] / 巢狀引號；用 cut 而非 awk；無 $ 相依
    echo "== 清理對端 ${PEER_IP} 的 raylight(6380) 進程 =="
    ssh -o BatchMode=yes "$PEER_USER@$PEER_IP" \
      'pgrep -u shang -af | grep 6380 | grep -E "raylet|gcs_server|log_monitor|dashboard" | cut -d" " -f1 | while read p; do kill -9 "$p" 2>/dev/null; done; true'
    echo "  對端清理完成"
  fi
}

# ---- 2) 起 head ---------------------------------------------------------------
start_head() {
  echo "== 啟動 head ${HEAD_IP}:${RAYLIGHT_PORT} (threshold=${THRESHOLD}) =="
  mkdir -p "$LOGDIR"
  local log="$LOGDIR/head_last.log"
  cd "$COMFYUI_DIR"
  RAY_memory_usage_threshold="$THRESHOLD" nohup "$RAY_BIN" start --head \
    --node-ip-address="$HEAD_IP" \
    --port="$RAYLIGHT_PORT" \
    --dashboard-host=0.0.0.0 --dashboard-port=8266 \
    --num-cpus=20 --num-gpus=1 \
    > "$log" 2>&1 &
  sleep 14
  echo "  head log: $log"
  if ! pgrep -u "$MY_USER" -af | grep -q "$RAYLIGHT_PORT.*raylet" \
     && ! pgrep -u "$MY_USER" -af | grep -q "raylet.*$RAYLIGHT_PORT"; then
    echo "  !!! 警告：未見 head raylet 產生，請看 $log"
  fi
}

# ---- 3) 起 peer worker -----------------------------------------------------------
start_peer() {
  echo "== 啟動對端 worker ${PEER_IP}（連 ${HEAD_IP}:${RAYLIGHT_PORT}） =="
  # 對端寫 log 到 /tmp，map 到本機 LOGDIR 即可；雙引號讓本端 bash 展開變數，無 $ 殘留給 zsh
  ssh -o BatchMode=yes "$PEER_USER@$PEER_IP" \
    "cd $COMFYUI_DIR && RAY_memory_usage_threshold=$THRESHOLD nohup $RAY_BIN start --address=${HEAD_IP}:${RAYLIGHT_PORT} --node-ip-address=$PEER_IP --num-cpus=20 --num-gpus=1 > /tmp/rayworker_last.log 2>&1 &"
  sleep 14
  echo "  對端啟動完成（log: /tmp/rayworker_last.log）"
}

# ---- 4) 驗證 -----------------------------------------------------------------------
verify() {
  echo "== 驗證 cluster (ray status) =="
  sleep 5
  local out
  out=$("$RAY_BIN" status --address="$HEAD_IP:$RAYLIGHT_PORT" 2>&1 || true)
  echo "$out" | grep -E 'node_|GPU|Active|Total' | head -20
  echo "--"
  local gpu_active
  gpu_active=$(echo "$out" | grep -cE 'GPU' || true)
  echo "預期：2 nodes / 2 GPU 且 vLLM(6379) 未動。若有 3 nodes / 3 GPU → 對端仍有 stale raylet，請重跑一次清理，或手動 kill 多出來那顆。"
}

# ---- main ---------------------------------------------------------------------------
if [[ "$MODE" == "full" ]]; then
  kill_raylight head  0
  kill_raylight peer  1
fi

start_head
start_peer
verify

echo ""
echo "✅ 完成。下一步：在 head 重啟 ComfyUI 後即可重跑 workflow："
echo "   sudo systemctl restart comfyui.service"
echo "   再於 ComfyUI 重新 queue：Minimax_H3_REF2VA_Raylight_2xGX10"
