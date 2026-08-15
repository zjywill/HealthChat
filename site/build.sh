#!/bin/bash
# 组装 vana.pinapia.com 要发布的那个目录。
#
# **隐私说明不在这个目录里,它在 `Vana/Legal/PrivacyPolicy.html`**——那一份同时打进 app 包
# (设置 › 关于 › 隐私说明)。网上和 app 里必须逐字相同,审核核对的正是这个,所以这里不留
# 副本、由这个脚本在发布时复制一次。留两份的话,改一处忘一处是迟早的事。
set -euo pipefail

cd "$(dirname "$0")/.."
out="build/site"

rm -rf "$out"
mkdir -p "$out/support" "$out/privacy"

cp site/index.html          "$out/index.html"
cp site/support/index.html  "$out/support/index.html"
cp Vana/Legal/PrivacyPolicy.html "$out/privacy/index.html"

echo "组装好了：$out"
find "$out" -type f | sort | sed 's/^/  /'
cat <<'EOF'

发布（第一次会开浏览器让你登录 Cloudflare）：

  npx wrangler@latest pages deploy build/site --project-name=vana-bqs

项目名是 vana-bqs 不是 vana——vana.pages.dev 被别人占了,Cloudflare 自动加的后缀。

自定义域只在第一次绑一次：Workers & Pages > vana-bqs > Custom domains > 填
vana.pinapia.com。**别在 DNS 页手工加记录**:那条路要选 CNAME(不是 A)、指向
vana-bqs.pages.dev(不带 https://、不带某次部署的哈希前缀,否则域名会钉死在那一版),
而且加完还得回 Pages 项目里把域名登记一遍,否则 Pages 认不出这个 Host,返回 404。

三个 URL 填进 App Store Connect：

  Marketing URL     https://vana.pinapia.com/
  Support URL       https://vana.pinapia.com/support/
  隐私政策 URL       https://vana.pinapia.com/privacy/
EOF
