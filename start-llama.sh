#!/bin/bash
# ~/models/qwen3.6-35b-UNC/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
# ~/models/qwen3.6-35b-UNC/mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf
# 131072
#   --model ~/models/qwen3.6-35b-UNC/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf \
#   --mmproj ~/models/qwen3.6-35b-UNC/mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf \
#   --ctx-size 131072 \
#   --model ~/models/qwen3.6-27B-UNC/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q6_K.gguf \
#   --mmproj ~/models/qwen3.6-27B-UNC/mmproj-F16.gguf \
#   --ctx-size 32760 \
# Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q5_K_M.gguf
#   --model ~/models/qwen3.6-27B-UNC/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q5_K_M.gguf \
#   --mmproj ~/models/qwen3.6-27B-UNC/mmproj-F16.gguf \
#   --ctx-size 65536 \
#   --model ~/models/muse-glimmer-30B-heretic/Muse-Glimmer-30B-Heretic-Abliterated-BF16.Q6_K.gguf \

~/llama.cpp/build/bin/llama-server \
  --model /home/christian/models/Qwen3.8-27B-UNC/Qwen3.8-27B-Uncensored-Q5_K_M.gguf \
  --ctx-size 65536 \
  --n-gpu-layers 999 \
  --host 0.0.0.0 \
  --port 8080 \
  --parallel 1 \
  --temperature 1.0 \
  --top_p 0.95 \
  --top_k 20 \
  --min_p 0 \
  --presence_penalty 0
   --chat-template-kwargs "{\"reasoning_effort\":\"medium\"}"
# ~/models/muse-glimmer-30B-heretic/
