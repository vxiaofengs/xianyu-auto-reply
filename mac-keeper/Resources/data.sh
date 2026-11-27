#!/bin/bash
# 作者：huangxiaofeng
# 创建日期：2026-11-25
# 闲鱼助手 · 数据导出 / 导入（数据库 + 上传文件）
#
# 用法：
#   data.sh export <输出文件.tar.gz>
#   data.sh import <备份文件.tar.gz>    导入前须先停止服务（闲鱼助手会自动处理）

set -euo pipefail

CONFIG="$HOME/Library/Application Support/XianyuKeeper/config.env"
[ -f "$CONFIG" ] || { echo "未找到配置，请先完成环境安装" >&2; exit 1; }
source "$CONFIG"
MYSQL_BIN="${MYSQL_BIN:-$BREW_PREFIX/opt/mysql@8.4/bin}"
DB=xianyu_auto_reply

static_dir() {
  local d
  d="$(grep -E '^STATIC_DIR=' "$REPO_DIR/backend-web/.env" | head -1 | cut -d= -f2- || true)"
  case "$d" in /*) echo "$d" ;; "") echo "$REPO_DIR/data/static" ;; *) echo "$REPO_DIR/backend-web/$d" ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "${1:-}" in
  export)
    out="${2:?缺少输出文件路径}"
    "$MYSQL_BIN/mysqldump" -uroot --single-transaction --routines --triggers \
      --default-character-set=utf8mb4 --set-gtid-purged=OFF "$DB" > "$TMP/db.sql"
    mkdir -p "$TMP/static"
    sd="$(static_dir)"
    [ -d "$sd" ] && rsync -a "$sd/" "$TMP/static/"
    {
      echo "format=1"
      echo "exported_at=$(date '+%Y-%m-%d %H:%M:%S')"
      echo "host=$(scutil --get ComputerName 2>/dev/null || hostname)"
      echo "code_version=$(git -C "$REPO_DIR" log --oneline -1 2>/dev/null || echo unknown)"
    } > "$TMP/meta.txt"
    tar -czf "$out" -C "$TMP" meta.txt db.sql static
    echo "导出完成：${out}（$(du -h "$out" | cut -f1)）"
    ;;
  import)
    in="${2:?缺少备份文件路径}"
    tar -xzf "$in" -C "$TMP"
    [ -f "$TMP/db.sql" ] && [ -f "$TMP/meta.txt" ] || { echo "不是闲鱼助手导出的备份文件" >&2; exit 1; }
    "$MYSQL_BIN/mysql" -uroot -e "CREATE DATABASE IF NOT EXISTS $DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    "$MYSQL_BIN/mysql" -uroot --default-character-set=utf8mb4 "$DB" < "$TMP/db.sql"
    sd="$(static_dir)"
    mkdir -p "$sd"
    [ -d "$TMP/static" ] && rsync -a "$TMP/static/" "$sd/"
    echo "导入完成（来源：$(grep -E '^(host|exported_at)=' "$TMP/meta.txt" | cut -d= -f2 | paste -sd ' ' -)）"
    ;;
  *)
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
