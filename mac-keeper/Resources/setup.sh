#!/bin/bash
# 作者：huangxiaofeng
# 创建日期：2026-11-25
# 闲鱼助手 · 运行环境安装 / 更新脚本（可重复执行）
#
# 用法：setup.sh [install|update]
#   install  首次安装或修复环境（默认）
#   update   拉取最新代码并更新依赖
#
# 状态写入 ~/Library/Application Support/XianyuKeeper/setup-status（running / done / failed），
# 闲鱼助手据此判断何时启动服务。

set -euo pipefail

MODE="${1:-install}"
SUPPORT="$HOME/Library/Application Support/XianyuKeeper"
CONFIG="$SUPPORT/config.env"
STATUS="$SUPPORT/setup-status"
# 自己的 fork（含本地定制）；原作者仓库作为 upstream，仅用于手动合并上游更新
REPO_URL="https://github.com/vxiaofengs/xianyu-auto-reply.git"
UPSTREAM_URL="https://github.com/zhinianboke/xianyu-auto-reply.git"
SERVICES=(backend-web websocket scheduler)

PYPI_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
NPM_REGISTRY="https://registry.npmmirror.com"
export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

mkdir -p "$SUPPORT"
echo running > "$STATUS"

STEP=0
step() { STEP=$((STEP + 1)); printf '\n\033[1;36m[%d] %s\033[0m\n' "$STEP" "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }

on_error() {
  echo failed > "$STATUS"
  printf '\n\033[1;31m✗ 第 %d 步失败（上面是错误信息）。\033[0m\n' "$STEP"
  echo "  多数是网络问题，可以在闲鱼助手菜单里选「重新运行环境安装」重试，已完成的步骤会自动跳过。"
}
trap on_error ERR

retry() {  # retry <次数> <命令...>
  local n="$1" i; shift
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    [ "$i" -lt "$n" ] && { warn "失败，5 秒后重试（${i}/${n}）"; sleep 5; }
  done
  return 1
}

set_kv() {  # set_kv <文件> <键> <值>：有则替换整行，无则追加
  local f="$1" k="$2" v="$3"
  if grep -qE "^$k=" "$f"; then
    sed -i '' -E "s|^$k=.*|$k=$v|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# 读取已有配置（更新 / 修复时沿用原目录）
REPO_DIR=""
[ -f "$CONFIG" ] && source "$CONFIG"
REPO_DIR="${REPO_DIR:-$HOME/XianyuAutoReply}"

printf '\033[1m闲鱼助手 · %s\033[0m\n' "$([ "$MODE" = update ] && echo 更新程序 || echo 安装运行环境)"
echo "程序目录：$REPO_DIR"

# ---------------------------------------------------------------------------
step "检查 Homebrew"
BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { BREW="$b"; break; }; done
if [ -z "$BREW" ]; then
  echo failed > "$STATUS"
  trap - ERR
  cat <<'EOF'

  这台电脑还没有安装 Homebrew（Mac 上的软件包管理器），请先安装：

  1. 打开「终端」，粘贴下面这行并回车（国内镜像，按提示输入开机密码）：

     /bin/bash -c "$(curl -fsSL https://gitee.com/ineo6/homebrew-install/raw/master/install.sh)"

  2. 安装完成后，重新打开闲鱼助手即可继续。
EOF
  exit 1
fi
BREW_PREFIX="$("$BREW" --prefix)"
export PATH="$BREW_PREFIX/bin:$PATH"
ok "Homebrew：$BREW_PREFIX"

# ---------------------------------------------------------------------------
step "安装 MySQL / Redis / Python / Node"
for f in mysql@8.4 redis python@3.11 node; do
  if "$BREW" list --versions "$f" >/dev/null 2>&1; then
    ok "$f 已安装"
  else
    retry 3 "$BREW" install "$f"
    ok "$f 安装完成"
  fi
done
MYSQL_BIN="$BREW_PREFIX/opt/mysql@8.4/bin"
PYTHON="$BREW_PREFIX/opt/python@3.11/bin/python3.11"

# ---------------------------------------------------------------------------
step "启动 MySQL / Redis（开机自动运行）"
"$BREW" services start mysql@8.4 >/dev/null 2>&1 || true
"$BREW" services start redis >/dev/null 2>&1 || true
for i in $(seq 1 60); do "$MYSQL_BIN/mysqladmin" -uroot ping >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL_BIN/mysqladmin" -uroot ping >/dev/null
ok "MySQL 运行中"
for i in $(seq 1 30); do "$BREW_PREFIX/bin/redis-cli" ping >/dev/null 2>&1 && break; sleep 1; done
"$BREW_PREFIX/bin/redis-cli" ping >/dev/null
ok "Redis 运行中"

# ---------------------------------------------------------------------------
step "获取程序代码"
if [ -d "$REPO_DIR/.git" ]; then
  # 早期安装直接 clone 的原作者仓库：把 origin 切到自己的 fork，原仓库改名 upstream
  if [ "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" = "$UPSTREAM_URL" ]; then
    git -C "$REPO_DIR" remote rename origin upstream
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
    ok "代码来源已切换到 $REPO_URL"
  fi
  if [ "$MODE" = update ]; then
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
    retry 3 git -C "$REPO_DIR" fetch origin
    git -C "$REPO_DIR" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null
    if ! git -C "$REPO_DIR" merge --ff-only "origin/$branch"; then
      warn "本地有未提交或冲突的改动，无法自动更新。请先把本地改动提交并推送到 fork，或手动处理后再更新。"
      false
    fi
    ok "已更新到 $(git -C "$REPO_DIR" log --oneline -1)"
  else
    ok "已存在：$(git -C "$REPO_DIR" log --oneline -1)"
  fi
else
  mkdir -p "$(dirname "$REPO_DIR")"
  rm -rf "$REPO_DIR.partial"
  retry 3 git clone --depth 1 "$REPO_URL" "$REPO_DIR.partial"
  mv "$REPO_DIR.partial" "$REPO_DIR"
  git -C "$REPO_DIR" remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
  ok "下载完成：$(git -C "$REPO_DIR" log --oneline -1)"
fi
mkdir -p "$REPO_DIR/data/static" "$REPO_DIR/data/backups" "$REPO_DIR/logs"

# ---------------------------------------------------------------------------
step "配置数据库"
PW=""
[ -f "$REPO_DIR/backend-web/.env" ] && PW="$(grep -E '^MYSQL_PASSWORD=' "$REPO_DIR/backend-web/.env" | head -1 | cut -d= -f2- || true)"
[ -z "$PW" ] && PW="$(openssl rand -hex 12)"
"$MYSQL_BIN/mysql" -uroot <<SQL
SET PERSIST max_connections = GREATEST(@@max_connections, 2000);
CREATE DATABASE IF NOT EXISTS xianyu_auto_reply CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'xianyu'@'localhost' IDENTIFIED BY '$PW';
CREATE USER IF NOT EXISTS 'xianyu'@'127.0.0.1' IDENTIFIED BY '$PW';
ALTER USER 'xianyu'@'localhost' IDENTIFIED BY '$PW';
ALTER USER 'xianyu'@'127.0.0.1' IDENTIFIED BY '$PW';
GRANT ALL PRIVILEGES ON xianyu_auto_reply.* TO 'xianyu'@'localhost';
GRANT ALL PRIVILEGES ON xianyu_auto_reply.* TO 'xianyu'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "数据库 xianyu_auto_reply、用户 xianyu 就绪"

# ---------------------------------------------------------------------------
step "生成服务配置（.env）"
for d in "${SERVICES[@]}"; do
  env_file="$REPO_DIR/$d/.env"
  if [ ! -f "$env_file" ]; then
    cp "$REPO_DIR/$d/.env.example" "$env_file"
    set_kv "$env_file" MYSQL_USER xianyu
    set_kv "$env_file" MYSQL_PASSWORD "$PW"
    set_kv "$env_file" REDIS_PASSWORD ""
    set_kv "$env_file" SQL_ECHO false
    set_kv "$env_file" STATIC_DIR "$REPO_DIR/data/static"
    grep -qE '^BACKUP_DIR=' "$env_file" && set_kv "$env_file" BACKUP_DIR "$REPO_DIR/data/backups"
    # 项目要求连接池 ≥ 600（按需建连，不会真的占满）
    set_kv "$env_file" DB_POOL_SIZE 600
    set_kv "$env_file" DB_MAX_OVERFLOW 20
    set_kv "$env_file" REDIS_POOL_SIZE 600
    # 不展示作者服务器下发的广告 / 公告 / 弹窗公告
    for k in ENABLE_REMOTE_ADS ENABLE_REMOTE_ANNOUNCEMENTS ENABLE_REMOTE_POPUP_ANNOUNCEMENTS; do
      grep -qE "^$k=" "$env_file" && set_kv "$env_file" "$k" false
    done
    ok "$d/.env 已生成"
  else
    ok "$d/.env 已存在，保留原配置"
  fi
  # macOS 上 HOST=:: 只监听 IPv6，服务间用 127.0.0.1 互访会连不上
  set_kv "$env_file" HOST 127.0.0.1
done

# ---------------------------------------------------------------------------
step "安装 Python 依赖（三个后端）"
for d in "${SERVICES[@]}"; do
  (
    cd "$REPO_DIR/$d"
    [ -x .venv/bin/python ] || "$PYTHON" -m venv .venv
    retry 3 .venv/bin/python -m pip install -q -U pip -i "$PYPI_MIRROR"
    retry 3 .venv/bin/python -m pip install -q -e . -i "$PYPI_MIRROR"
    # 上游 websocket / scheduler 漏声明了公共代码用到的 email-validator
    retry 3 .venv/bin/python -m pip install -q 'email-validator>=2' -i "$PYPI_MIRROR"
  )
  ok "$d 依赖就绪"
done

# ---------------------------------------------------------------------------
step "安装浏览器（Chromium，首次约 200MB）"
for d in "${SERVICES[@]}"; do
  retry 3 "$REPO_DIR/$d/.venv/bin/python" -m playwright install chromium
done
for d in backend-web websocket; do
  if "$REPO_DIR/$d/.venv/bin/python" -c 'import patchright' 2>/dev/null; then
    retry 3 "$REPO_DIR/$d/.venv/bin/python" -m patchright install chromium
  fi
done
ok "浏览器就绪"

# ---------------------------------------------------------------------------
step "安装网页前端依赖"
(
  cd "$REPO_DIR/frontend"
  retry 3 npm ci --no-audit --no-fund --registry="$NPM_REGISTRY"
)
ok "前端依赖就绪"

# ---------------------------------------------------------------------------
cat > "$CONFIG" <<EOF
REPO_DIR="$REPO_DIR"
BREW_PREFIX="$BREW_PREFIX"
EOF
echo done > "$STATUS"
trap - ERR

printf '\n\033[1;32m✓ 全部完成！\033[0m闲鱼助手会自动启动服务，这个窗口可以关闭了。\n'
if [ "$MODE" != update ]; then
  echo "  管理后台：http://127.0.0.1:9000   默认账号 admin / admin123（登录后请修改密码）"
fi
