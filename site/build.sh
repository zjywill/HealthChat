#!/bin/bash
# 组装 vana.pinapia.com 要发布的那个目录。
#
# **隐私说明不在这个目录里,它在 `Vana/Legal/<语言>.lproj/PrivacyPolicy.html`**——那两份
# 同时打进 app 包(设置 › 关于 › 隐私说明,跟着界面语言走)。网上和 app 里必须逐字相同,
# 审核核对的正是这个,所以这里不留副本、由这个脚本在发布时复制一次。留两份的话,改一处
# 忘一处是迟早的事。
#
# 英文那份发在 `/privacy/en/`:ASC 的隐私政策 URL 是按语言各填一个的,而英文用户点开一份
# 中文说明,和没有说明差不多。
set -euo pipefail

cd "$(dirname "$0")/.."
out="build/site"

rm -rf "$out"
mkdir -p "$out/support" "$out/privacy" "$out/privacy/en"

cp site/index.html          "$out/index.html"
cp site/support/index.html  "$out/support/index.html"
cp Vana/Legal/zh-Hans.lproj/PrivacyPolicy.html "$out/privacy/index.html"
cp Vana/Legal/en.lproj/PrivacyPolicy.html      "$out/privacy/en/index.html"

echo "组装好了：$out"
find "$out" -type f | sort | sed 's/^/  /'
cat <<'EOF'

发布（第一次会开浏览器让你登录 Cloudflare）：

  npx wrangler@latest pages deploy build/site --project-name=vana-bqs --branch=master

项目名是 vana-bqs 不是 vana——vana.pages.dev 被别人占了,Cloudflare 自动加的后缀。

**`--branch=master` 不能省。** Pages 只把生产分支(这个项目设的是 master,和仓库的默认
分支一致)的部署当生产,别的分支一律建成预览——预览有自己的 URL,`vana.pinapia.com`
一个字都不会变。而命令行照样打印 "Deployment complete!",**它不报错**:2026-08-16
在 `fix/app-review-2026-08-16` 分支上发过两次才发现,一次贴的标签是分支名、一次是
`--branch=main`(这仓库压根没有 main 分支,那个值只是个标签)。

所以发布前先确认自己在 master 上,而且要发的东西已经合进来了——从别的分支带着
`--branch=master` 发,内容是上得去,但 Cloudflare 上会显示成"master 部署了 master
里没有的东西",下次排查对不上。

发完验一句,别只看命令行:

  curl -sS https://vana.pinapia.com/support/ | grep -c "Vana 是免费的"

自定义域只在第一次绑一次：Workers & Pages > vana-bqs > Custom domains > 填
vana.pinapia.com。**别在 DNS 页手工加记录**:那条路要选 CNAME(不是 A)、指向
vana-bqs.pages.dev(不带 https://、不带某次部署的哈希前缀,否则域名会钉死在那一版),
而且加完还得回 Pages 项目里把域名登记一遍,否则 Pages 认不出这个 Host,返回 404。

三个 URL 填进 App Store Connect：

  Marketing URL     https://vana.pinapia.com/
  Support URL       https://vana.pinapia.com/support/
  隐私政策 URL       https://vana.pinapia.com/privacy/      （简体中文）
                    https://vana.pinapia.com/privacy/en/   （English，填在 ASC 的英文本地化里）
EOF
