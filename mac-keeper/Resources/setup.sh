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

set -Eeuo pipefail  # -E：函数内出错也触发 ERR trap，状态才会写成 failed

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

# macOS 12 及以下：Homebrew 已不提供预编译包，改用官方二进制 / 源码编译的独立运行环境
LEGACY=0
[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ] && LEGACY=1

if [ "$LEGACY" = 1 ]; then
# ---------------------------------------------------------------------------
step "安装运行环境（macOS 12 独立版：Python / Node / MySQL / Redis）"
RUNTIME="$SUPPORT/runtime"
mkdir -p "$RUNTIME/bin" "$RUNTIME/logs"
export UV_INSTALL_DIR="$RUNTIME/bin" UV_PYTHON_INSTALL_DIR="$RUNTIME/python" INSTALLER_NO_MODIFY_PATH=1
[ -x "$RUNTIME/bin/uv" ] || retry 3 sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
retry 3 "$RUNTIME/bin/uv" python install 3.11
PYTHON="$("$RUNTIME/bin/uv" python find 3.11)"
ok "Python：$("$PYTHON" -V)"

# Node 24 起要求 macOS 13.5，固定 22 LTS
NODE_VER=v22.23.5
if [ ! -x "$RUNTIME/node/bin/node" ]; then
  retry 3 curl -fsSL -o "$RUNTIME/node.tgz" "https://registry.npmmirror.com/-/binary/node/$NODE_VER/node-$NODE_VER-darwin-x64.tar.gz"
  rm -rf "$RUNTIME/node" && mkdir -p "$RUNTIME/node"
  tar -xzf "$RUNTIME/node.tgz" -C "$RUNTIME/node" --strip-components 1 && rm -f "$RUNTIME/node.tgz"
fi
ok "Node：$("$RUNTIME/node/bin/node" -v)"

# MySQL 8.0.31 是最后一个提供 macOS 12 构建的官方版本
MYSQL_PKG=mysql-8.0.31-macos12-x86_64
if [ ! -x "$RUNTIME/mysql/bin/mysqld" ]; then
  retry 3 curl -fsSL -o "$RUNTIME/mysql.tgz" "https://cdn.mysql.com/archives/mysql-8.0/$MYSQL_PKG.tar.gz"
  rm -rf "$RUNTIME/mysql" && mkdir -p "$RUNTIME/mysql"
  tar -xzf "$RUNTIME/mysql.tgz" -C "$RUNTIME/mysql" --strip-components 1 && rm -f "$RUNTIME/mysql.tgz"
fi
if [ ! -d "$RUNTIME/mysql-data/mysql" ]; then
  rm -rf "$RUNTIME/mysql-data"
  "$RUNTIME/mysql/bin/mysqld" --initialize-insecure --basedir="$RUNTIME/mysql" --datadir="$RUNTIME/mysql-data" >/dev/null 2>&1
fi
ok "MySQL：$("$RUNTIME/mysql/bin/mysqld" --version | grep -oE 'Ver [0-9.]+' | cut -d' ' -f2)"

REDIS_VER=7.4.2
if [ ! -x "$RUNTIME/redis/bin/redis-server" ]; then
  retry 3 curl -fsSL -o "$RUNTIME/redis.tgz" "https://download.redis.io/releases/redis-$REDIS_VER.tar.gz"
  rm -rf "$RUNTIME/redis-src" && mkdir -p "$RUNTIME/redis-src"
  tar -xzf "$RUNTIME/redis.tgz" -C "$RUNTIME/redis-src" --strip-components 1
  make -C "$RUNTIME/redis-src" -j2 >"$RUNTIME/logs/redis-build.log" 2>&1
  # make install 不支持带空格的路径（Application Support），直接复制产物
  mkdir -p "$RUNTIME/redis/bin"
  cp "$RUNTIME/redis-src/src/redis-server" "$RUNTIME/redis-src/src/redis-cli" "$RUNTIME/redis/bin/"
  rm -rf "$RUNTIME/redis-src" "$RUNTIME/redis.tgz"
fi
mkdir -p "$RUNTIME/redis-data"
ok "Redis：$("$RUNTIME/redis/bin/redis-server" --version | grep -oE 'v=[0-9.]+' | cut -d= -f2)"

MYSQL_BIN="$RUNTIME/mysql/bin"
REDIS_CLI="$RUNTIME/redis/bin/redis-cli"
BIN_PATH="$RUNTIME/node/bin:$RUNTIME/mysql/bin:$RUNTIME/redis/bin:$RUNTIME/bin"
export PATH="$BIN_PATH:$PATH"
# 新版 Playwright / patchright 自带的 Node 驱动和 Chromium 需要 macOS 13
# （不用 PIP_CONSTRAINT 环境变量：pip 会按空格拆分，路径里有 Application Support）
printf 'playwright==1.61.0\npatchright==1.61.2\n' > "$RUNTIME/pip-constraints.txt"
# 很多库的新版只发 macOS 13+ 的 wheel，不加 --prefer-binary 会在这台机器上现场编译（cryptography / opencv 等，数小时且易失败）
PIP_C=(-c "$RUNTIME/pip-constraints.txt" --prefer-binary)

# ---------------------------------------------------------------------------
step "启动 MySQL / Redis（开机自动运行）"
agent_plist() {  # agent_plist <label> <参数...>：生成常驻 LaunchAgent 并加载
  local label="$1"; shift
  local plist="$HOME/Library/LaunchAgents/$label.plist" args="" a
  for a in "$@"; do args="$args<string>$a</string>"; done
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$args</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>$RUNTIME/logs/$label.log</string>
</dict></plist>
PLIST
  # bootout 是异步的，没卸载完就 bootstrap 会报 5: Input/output error
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 0.5; done
  retry 3 launchctl bootstrap "gui/$(id -u)" "$plist"
}
agent_plist local.xianyu.dep.mysql "$RUNTIME/mysql/bin/mysqld" --basedir="$RUNTIME/mysql" --datadir="$RUNTIME/mysql-data" \
  --port=3306 --bind-address=127.0.0.1 --socket=/tmp/mysql.sock --mysqlx=OFF --log-error="$RUNTIME/logs/mysqld.err"
agent_plist local.xianyu.dep.redis "$RUNTIME/redis/bin/redis-server" --bind 127.0.0.1 --port 6379 --dir "$RUNTIME/redis-data"
for i in $(seq 1 60); do "$MYSQL_BIN/mysqladmin" -uroot ping >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL_BIN/mysqladmin" -uroot ping >/dev/null
ok "MySQL 运行中"
for i in $(seq 1 30); do "$REDIS_CLI" ping >/dev/null 2>&1 && break; sleep 1; done
"$REDIS_CLI" ping >/dev/null
ok "Redis 运行中"

else
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
BIN_PATH="$BREW_PREFIX/bin"
fi

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
# MySQL 8.0 的 SET PERSIST 不接受表达式，先查当前值再设
[ "$("$MYSQL_BIN/mysql" -uroot -N -e 'SELECT @@max_connections')" -lt 2000 ] && \
  "$MYSQL_BIN/mysql" -uroot -e 'SET PERSIST max_connections = 2000'
"$MYSQL_BIN/mysql" -uroot <<SQL
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
    retry 3 .venv/bin/python -m pip install -q -e . -i "$PYPI_MIRROR" ${PIP_C[@]+"${PIP_C[@]}"}
    # 上游 websocket / scheduler 漏声明了公共代码用到的 email-validator
    retry 3 .venv/bin/python -m pip install -q 'email-validator>=2' -i "$PYPI_MIRROR" ${PIP_C[@]+"${PIP_C[@]}"}
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
if [ "$LEGACY" = 1 ]; then
  cat > "$CONFIG" <<EOF
REPO_DIR="$REPO_DIR"
BIN_PATH="$BIN_PATH"
MYSQL_BIN="$MYSQL_BIN"
DEPS_MODE="launchd"
EOF
else
  cat > "$CONFIG" <<EOF
REPO_DIR="$REPO_DIR"
BREW_PREFIX="$BREW_PREFIX"
EOF
fi
# 手动设置过的管理网页监听地址（如 0.0.0.0 供远程访问）在更新时保留
[ -n "${FRONTEND_HOST:-}" ] && echo "FRONTEND_HOST=\"$FRONTEND_HOST\"" >> "$CONFIG"
echo done > "$STATUS"
trap - ERR

printf '\n\033[1;32m✓ 全部完成！\033[0m闲鱼助手会自动启动服务，这个窗口可以关闭了。\n'
if [ "$MODE" != update ]; then
  echo "  管理后台：http://127.0.0.1:9000   默认账号 admin / admin123（登录后请修改密码）"
fi
