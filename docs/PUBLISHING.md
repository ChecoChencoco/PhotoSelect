# 首次公开发布

本目录是整理后的独立源码仓库；旧项目、私人样张、数据库和历史日志不在其中。不要把旧工程整个目录再次复制进来。

## 所有者先完成

1. 已确认采用 MIT License，版权署名为陈可Checo（2026）；发布时保留根目录 LICENSE，并确认新增材料的发布权。
2. 在 GitHub 建立目标仓库；如果随后推送此本地仓库，创建时不要另行初始化 README、许可证或 .gitignore。
3. 配置自己用于公开提交的 Git 作者身份；如不希望公开私人邮箱，可使用 GitHub 提供的 noreply 地址。不要把令牌写进脚本或远程 URL。

## 本地复核与推送

```bash
python3 scripts/check_release.py
python3 scripts/build.py --checks

git status --short
git add .
git diff --cached --stat
git diff --cached
```

确认待提交内容后，再执行以下步骤；将示例仓库地址替换为自己的真实地址：

```bash
git commit -m "Initial source release"
git remote add origin https://github.com/ChecoChencoco/PhotoSelect.git
git push -u origin main
```

首次发布通过 GitHub 网页上传；本地后续开发应先获取远程 main，避免另建不关联的初始历史。新仓库没有旧 Git 历史；后续若导入旧历史，需要单独检查历史中的敏感数据，.gitignore 不会删除已提交内容。

`.app` 和安装压缩包不提交到源码仓库，可在确定版本、签名与发布说明后作为 GitHub Release 附件单独提供。本地构建仅 ad-hoc 签名，不宣称已通过 Apple 公证。
