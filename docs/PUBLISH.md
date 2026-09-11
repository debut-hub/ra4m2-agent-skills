# 发布到 GitHub

本地仓库已就绪：**3 个提交，工作区干净，27/27 测试通过。**
你只需要在 GitHub 上建一个空仓库，然后把地址给我，剩下的我做。

---

## 第 1 步（你做）：在 GitHub 建空仓库

1. 打开 https://github.com/new
2. 填 **Repository name**，建议 `ra4m2-agent-skills`
3. 选 **Public**（要分享给同学的话）
4. **不要**勾选 "Add a README file"、".gitignore"、"license"
   —— **必须保持空仓库**，否则推送会冲突
5. 点 **Create repository**

建完 GitHub 会显示一个页面，里面有仓库地址，形如：

```
https://github.com/<你的用户名>/ra4m2-agent-skills.git
```

**把这个地址发给我。**

---

## 第 2 步（我做）：配远程并验证

你给我地址后，我会执行：

```powershell
git -C "C:\Users\Lenovo\Desktop\ai\助教资料\ra4m2-agent-skills" `
    remote add origin <你给的地址>

# 只读验证：确认远程可达、地址正确、凭据可用（不推送）
git -C "...\ra4m2-agent-skills" ls-remote origin
```

`ls-remote` 是**只读**的 —— 它验证连通性和认证，不改变任何东西。
如果它失败，说明凭据或地址有问题，我会先修好再推。

**注意**：`ls-remote` 可能弹出凭据窗口（Git Credential Manager）。
如果弹了，正常登录即可 —— 这是在配置你这台机器对 GitHub 的认证，凭据由 Windows
凭据管理器保存，**不会经过我**。

---

## 第 3 步（我做）：推送并验证

```powershell
git -C "...\ra4m2-agent-skills" push -u origin main
```

推送后我会验证：

1. `git ls-remote origin` 能看到 `refs/heads/main`，且 commit hash 与本地一致
2. 本地 `git status` 干净、无未推送提交
3. 检查仓库里**没有**误提交敏感或本地化内容

---

## 第 4 步：确认 CI 通过

仓库带了一个 GitHub Actions 工作流（`.github/workflows/tests.yml`），
推送后会自动跑测试：

- 在 `windows-latest` 上跑
- 分别用 **pwsh** 和 **Windows PowerShell 5.1** 各跑一遍

**为什么值得看**：这会验证我的"可迁移性"主张 —— 在一台**没有装 e²studio、没有插板子**
的干净机器上，测试套件依然要全绿。这正是"别人拿到就能用"的证明。

到 https://github.com/<你>/ra4m2-agent-skills/actions 看结果。
**第一次跑需要你点一下启用 workflow**（GitHub 对 fork/新建仓库的默认行为）。

---

## 发布后：把技能分发给同学

同学拿到仓库后，两条命令即可：

```powershell
git clone https://github.com/<你>/ra4m2-agent-skills.git
Copy-Item .\ra4m2-agent-skills\skills\* "$env:USERPROFILE\.dsh\skills\" -Recurse -Force
```

或者只想装一个技能（每个技能目录都是自包含的）：

```powershell
Copy-Item .\skills\ra4m2-build-flash "$env:USERPROFILE\.dsh\skills\" -Recurse -Force
```

> `ra4m2-build-flash` 里**自带了一份 `resolve-env.ps1`**，所以单独拷这一个目录也能用。
> `ra4m2-troubleshoot` 会引用它 —— 那条路径写的是**相对位置**，不是绝对路径。

---

## 仓库里有什么

```
ra4m2-agent-skills/
├── README.md                          项目说明、硬核经验总结
├── LICENSE                            MIT
├── CHANGELOG.md
├── .gitattributes                     行尾锁定（保证 shebang 在 Unix CI 上可用）
├── .github/workflows/tests.yml        CI：双 shell 跑测试
├── docs/portability.md                可迁移性设计说明
├── skills/
│   ├── ra4m2-build-flash/
│   │   ├── SKILL.md
│   │   └── scripts/resolve-env.ps1    ← 自包含副本
│   ├── ra4m2-troubleshoot/SKILL.md
│   └── ra4m2-fsp-api/SKILL.md
├── tools/                             可独立使用的命令行工具
│   ├── resolve-env.ps1
│   ├── build-project.ps1
│   ├── flash.ps1
│   └── capture-serial.ps1
└── tests/run-tests.ps1                27 项断言的测试套件
```

---

## 推送前你可以自己先看一眼

```powershell
cd C:\Users\Lenovo\Desktop\ai\助教资料\ra4m2-agent-skills

git --no-pager log --oneline      # 看提交历史
git ls-files                      # 看会推上去的文件（共 15 个）
.\tests\run-tests.ps1             # 再跑一遍测试
```

---

## 如果 `ls-remote` 失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `Repository not found` | 地址错了，或仓库没建 | 核对地址拼写 |
| `Authentication failed` | 凭据没配或被拒 | 会弹登录窗口；或改用 SSH 地址 |
| `could not read Username` | 没有凭据助手 | 用 GitHub Desktop 登录一次，或配 PAT |
| 推送被拒 `non-fast-forward` | 你建仓时勾了 README | 我改成 `git pull --rebase` 后再推 |

---

## 一个提醒

推送需要**你的账号凭据**。我这边只做 `git` 命令的编排，
凭据由 Windows 凭据管理器保管、由 GitHub 校验，**我看不到也不经手**。
如果你更希望完全自己掌控，随时可以自己执行第 2、3 步的命令 —— 它们都写在上面了。
