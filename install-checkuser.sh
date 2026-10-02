#!/usr/bin/env bash
set -Eeuo pipefail

# CheckUser DTunnel + Void Pro+ (binário estático; não instala Go)
# Serviço isolado para não conflitar com instalações antigas do CheckUser-Go.

REPO="Willapela/check-dt-voidpro"
RELEASE_TAG="${RELEASE_TAG:-v1.0.0}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ASSET="checkuser-min-linux-amd64" ;;
  aarch64|arm64) ASSET="checkuser-min-linux-arm64" ;;
  *) echo "Arquitetura não suportada: $ARCH" >&2; exit 1 ;;
esac

APP_NAME="check-dt-voidpro"
SERVICE="${APP_NAME}.service"
TUNNEL_SERVICE="${APP_NAME}-tunnel.service"
INSTALL_DIR="/usr/local/lib/${APP_NAME}"
BIN="${INSTALL_DIR}/checkuser"
LIMITS_DB="${LIMITS_DB:-/root/usuarios.db}"
PORT="${PORT:-2052}"
LOG="/var/log/${APP_NAME}-tunnel.log"
MENU="/usr/local/bin/check"

GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✔${NC} $*"; }
warn(){ echo -e "${YELLOW}➜${NC} $*"; }
die(){ echo -e "${RED}✘${NC} $*" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || die "Execute como root."
[[ "$LIMITS_DB" != *[[:space:]]* ]] || die "LIMITS_DB não pode conter espaços."

# Evita alterar locks do apt: aguarda e falha claramente se outro apt estiver ativo.
wait_dpkg(){
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    n=$((n + 1))
    (( n <= 30 )) || die "apt/dpkg ocupado há muito tempo; tente novamente após o update terminar."
    sleep 2
  done
}

stop_old_services(){
  # Apenas unidades conhecidas do CheckUser-Go/versões anteriores; não mata serviços arbitrários.
  for unit in checkuser.service checkuser-go.service checkuser-min.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      warn "Serviço antigo parado: $unit"
    fi
  done
  systemctl daemon-reload
}

install_binary(){
  mkdir -p "$INSTALL_DIR"
  local release_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET}"
  local raw_url="https://raw.githubusercontent.com/${REPO}/main/${ASSET}"
  local tmp="${INSTALL_DIR}/checkuser.new"
  warn "Baixando ${ASSET}..."
  if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$raw_url"; then
    warn "Binário não encontrado na branch main; tentando Release ${RELEASE_TAG}..."
    curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$release_url" || die "Binário não encontrado. Envie ${ASSET} para a raiz do repositório ou publique o Release ${RELEASE_TAG}."
  fi
  chmod 0755 "$tmp"
  "$tmp" -version >/tmp/check-dt-voidpro-version 2>&1 || die "O arquivo baixado não é um CheckUser executável."
  grep -q 'checkuser-min' /tmp/check-dt-voidpro-version || die "Versão do binário inesperada: $(cat /tmp/check-dt-voidpro-version)"
  mv -f "$tmp" "$BIN"
  ok "Binário instalado: $BIN ($(cat /tmp/check-dt-voidpro-version))"
}

configure_service(){
  [[ -r "$LIMITS_DB" ]] || die "Arquivo de limites não encontrado: $LIMITS_DB"
  # O binário espera uma linha 'usuario limite'. Não alteramos o banco do SSHPlus.
  local count
  count=$(awk 'NF >= 2 && $1 !~ /^#/ && $2 ~ /^[0-9]+$/ {n++} END {print n+0}' "$LIMITS_DB")
  (( count > 0 )) || warn "Nenhuma linha 'usuario limite' foi detectada em $LIMITS_DB; verifique o formato."

  stop_old_services
  systemctl stop "$TUNNEL_SERVICE" 2>/dev/null || true
  systemctl disable "$TUNNEL_SERVICE" 2>/dev/null || true
  systemctl stop "$SERVICE" 2>/dev/null || true

  # Libera somente a porta configurada; o usuário deve conferir se outro serviço a usa.
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  cat > "/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=CheckUser DTunnel + Void Pro+ (isolated)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} --start --host 0.0.0.0 --port ${PORT} --limits-db ${LIMITS_DB}
Restart=always
RestartSec=3
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" || { systemctl status "$SERVICE" --no-pager; die "CheckUser não iniciou."; }
  curl -fsS "http://127.0.0.1:${PORT}/check?user=__healthcheck__&uuid=&hwid=" >/tmp/check-dt-voidpro-health 2>/dev/null || true
  ok "CheckUser ativo em ${PORT}; limites: ${LIMITS_DB}"
}

install_tunnel(){
  local cf=""
  if command -v cloudflared >/dev/null 2>&1; then cf=$(command -v cloudflared)
  else
    wait_dpkg
    local cf_arch='amd64'; [[ "$ARCH" == aarch64 || "$ARCH" == arm64 ]] && cf_arch='arm64'
    local deb="/tmp/cloudflared-${cf_arch}.deb"
    if curl -fL --retry 3 -o "$deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}.deb" && dpkg -i "$deb" >/dev/null 2>&1; then
      rm -f "$deb"; cf=$(command -v cloudflared || true)
    fi
    rm -f "$deb"
  fi
  if [[ -z "$cf" ]]; then
    warn "cloudflared não foi instalado; o CheckUser continua funcionando por IP:porta."
    return 0
  fi
  cat > "/etc/systemd/system/${TUNNEL_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for ${APP_NAME}
After=network-online.target ${SERVICE}
Requires=${SERVICE}

[Service]
Type=simple
ExecStart=${cf} tunnel --url http://127.0.0.1:${PORT}
Restart=always
RestartSec=5
StandardOutput=append:${LOG}
StandardError=append:${LOG}

[Install]
WantedBy=multi-user.target
EOF
  : > "$LOG"
  systemctl daemon-reload
  systemctl enable "$TUNNEL_SERVICE" >/dev/null
  systemctl restart "$TUNNEL_SERVICE"
  ok "Cloudflare Tunnel configurado (opcional)."
}

install_menu(){
  cat > "$MENU" <<'MENU_EOF'
#!/usr/bin/env bash
APP_NAME="check-dt-voidpro"
SERVICE="${APP_NAME}.service"
TUNNEL_SERVICE="${APP_NAME}-tunnel.service"
PORT="2052"
LOG="/var/log/${APP_NAME}-tunnel.log"
GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
link(){ grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -1; }
show(){ local l; l=$(link); echo; echo "CheckUser: $(systemctl is-active "$SERVICE" 2>/dev/null || true)"; echo "Porta: $PORT"; echo "Limites: $(systemctl cat "$SERVICE" 2>/dev/null | sed -n 's/.*--limits-db \([^ ]*\).*/\1/p' | tail -1)"; echo "DTunnel: ${l:-não disponível}"; echo "Void Pro+: ${l:-http://IP_DA_VPS:$PORT}/check?user={username}&uuid={uuid}&hwid={hwid}"; echo; }
while true; do clear; echo "CHECKUSER DT + VOID PRO+"; echo "========================"; show; echo "[1] Iniciar"; echo "[2] Parar"; echo "[3] Reiniciar"; echo "[4] Status"; echo "[5] Logs"; echo "[6] Sair"; read -r -p 'Opção: ' op; case "$op" in 1) systemctl start "$SERVICE" "$TUNNEL_SERVICE" 2>/dev/null;; 2) systemctl stop "$TUNNEL_SERVICE" "$SERVICE" 2>/dev/null;; 3) systemctl restart "$SERVICE"; systemctl restart "$TUNNEL_SERVICE" 2>/dev/null || true;; 4) systemctl status "$SERVICE" "$TUNNEL_SERVICE" --no-pager;; 5) tail -n 80 "$LOG" 2>/dev/null;; 6) exit 0;; esac; read -r -p 'ENTER para continuar' _; done
MENU_EOF
  chmod 0755 "$MENU"
}

install_binary
configure_service
install_tunnel
install_menu

printf '\n%sCheckUser instalado com sucesso.%s\n' "$GREEN" "$NC"
echo "Serviço: $SERVICE"
echo "Porta: ${PORT}"
echo "Arquivo de limites: ${LIMITS_DB}"
echo "DTunnel/Void: digite check para ver os links"
