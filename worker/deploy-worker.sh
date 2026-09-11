#!/bin/bash
# 一键部署 Cloudflare Worker。
# 依赖：wrangler CLI（npm install -g wrangler）+ 已登录 Cloudflare 账号。
# 用法：
#   ./deploy-worker.sh                  # 部署，不设鉴权
#   TOKEN=你的密钥 ./deploy-worker.sh   # 部署并设置 TOKEN 鉴权
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if ! command -v wrangler >/dev/null 2>&1; then
  echo "未找到 wrangler，先安装：npm install -g wrangler"
  exit 1
fi

if ! wrangler whoami >/dev/null 2>&1; then
  echo "==> 尚未登录，即将打开浏览器完成 Cloudflare 登录"
  wrangler login
fi

echo "==> 部署 Worker（名称见 wrangler.toml，想改名称先改好再跑）"
wrangler deploy

if [ -n "$TOKEN" ]; then
  echo "==> 设置 TOKEN 密钥（来自环境变量 TOKEN）"
  printf '%s' "$TOKEN" | wrangler secret put TOKEN
else
  echo "==> 未检测到 TOKEN，跳过鉴权设置。"
  echo "    需要鉴权时执行：echo '你的TOKEN' | wrangler secret put TOKEN"
fi

echo ""
echo "部署完成。地址：https://<worker名>.<你的CF子域>.workers.dev"
echo "把这个地址填进 EchOS 的「服务地址」，端口 443。"
