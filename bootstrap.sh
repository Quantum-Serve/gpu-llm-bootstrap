#!/usr/bin/env bash
#####################################################################################################################################################
# RunPod GPU box bootstrap (no-custom-image path). Run on a stock ubuntu:24.04 Pod via the Pod's start command. Installs Ollama (persisted on the
# volume), nginx token gate, and Tailscale at boot, writes the gate config inline, joins the tailnet (tagged), exposes the gate over Tailscale, and
# serves gemma4:31b. Avoids pushing an 8GB custom image — RunPod pulls only the tiny ubuntu base on its own fast pipe.
#
# Required env (set in the RunPod Pod config):
#   TS_AUTHKEY     - Tailscale reusable auth key (tag:gpu)
# Optional env:
#   MODEL (default gemma4:31b), TS_HOSTNAME (default gpu-llm)
#
# The model + the Ollama binary both persist on /workspace, so only the first boot downloads them.
#####################################################################################################################################################
set -x
export HOME=/root
export DEBIAN_FRONTEND=noninteractive
MODEL="${MODEL:-gemma4:31b}"
TS_HOSTNAME="${TS_HOSTNAME:-gpu-llm}"
export OLLAMA_MODELS=/workspace/ollama/models
export OLLAMA_KEEP_ALIVE=-1
export OLLAMA_CONTEXT_LENGTH=131072
mkdir -p "$OLLAMA_MODELS" /workspace/ollama-dist /var/run/tailscale /workspace/tailscale

# --- deps: nginx + curl + tailscale (small; installed each boot) ---
apt-get update -qq
apt-get install -y -qq --no-install-recommends nginx curl ca-certificates zstd tar >/dev/null 2>&1
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh

# --- Ollama: install via the official script (lands in /usr/local/bin, on PATH). Reinstalls each boot (~1 min on RunPod's
# pipe); the model itself persists on the volume so it never re-downloads. (The .tgz direct-download path 404s.) ---
command -v ollama >/dev/null 2>&1 || curl -fsSL https://ollama.com/install.sh | sh

# --- nginx token gate (Host rewritten to localhost so Ollama's anti-DNS-rebinding check doesn't 403 proxied requests) ---
cat > /etc/nginx/conf.d/llm.conf <<'NGINX'
map_hash_bucket_size 256;
map "$http_x_quantum_instance:$http_authorization" $client_ok {
    default 0;
    include /etc/nginx/llm-keys.map;
}
server {
    listen 80 default_server;
    location = /healthz { return 200 "ok"; access_log off; }
    location / {
        if ($client_ok = 0) { return 401; }
        proxy_pass http://127.0.0.1:11434;
        proxy_set_header Host localhost;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 300s;
        proxy_buffering off;
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
sed -i 's/ default_server//g' /etc/nginx/nginx.conf 2>/dev/null || true
touch /workspace/llm-keys.map
ln -sf /workspace/llm-keys.map /etc/nginx/llm-keys.map

# --- Tailscale (userspace networking; tagged so it never expires; HTTP-mode serve exposes the gate over the tailnet auto-cert) ---
tailscaled --tun=userspace-networking --state=/workspace/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/workspace/tailscaled.log 2>&1 &
sleep 3
tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="${TS_AUTHKEY}" --hostname="$TS_HOSTNAME" --advertise-tags=tag:gpu --accept-dns=false
tailscale --socket=/var/run/tailscale/tailscaled.sock serve --bg 80

# --- Ollama serve + ensure model present (already on the volume after first boot) ---
ollama serve >/workspace/ollama.log 2>&1 &
for i in $(seq 1 60); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break || sleep 5; done
ollama list | grep -qF "$MODEL" || for i in $(seq 1 20); do ollama pull "$MODEL" && ollama list | grep -qF "$MODEL" && break; sleep 15; done

# --- warm the model into VRAM in the background ---
(
	for i in $(seq 1 60); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break || sleep 5; done
	curl -sf -m 300 http://127.0.0.1:11434/api/chat -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false,\"keep_alive\":-1}" >/dev/null 2>&1 || true
) &

# --- nginx in foreground keeps the container alive ---
nginx -t && exec nginx -g 'daemon off;'
