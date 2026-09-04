# Shared settings. Windows env.ps1 reads these literal assignments; no shell is needed.
LOOP_MODEL='gpt-5.6-sol'
# A fresh codex exec submits one user turn (tool calls within it are not turns).
LOOP_MAX_TURNS=1
LOOP_WAIT_SECONDS=30
# 0 = unlimited rounds.
LOOP_MAX_ROUNDS=0
# Hard per-round wall-clock limit; timeout exits with failure for scheduler retry.
LOOP_ROUND_TIMEOUT_SECONDS=3600
