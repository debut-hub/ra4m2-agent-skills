# RA4M2 Agent Skills

[English](README.md) | 中文

让 AI 助手帮你开发瑞萨 RA 系列单片机（e² studio + FSP）的技能包，包括命令行编译、通过 SCI 引导模式烧录，以及排查常见故障。

以下内容来自真实开发板的调试记录，文档里提到的问题都在开发板上实际出现过。

---

## 这个技能包能帮你做什么

安装后，AI 助手能读取这块板子的引脚、时钟、烧录时序和已知问题：

| 你可以这样说 | 助手会做 |
|---|---|
| 「帮我把这个工程编译一下」 | 自动找到你机器上的工具链，修掉生成 makefile 里的机器相关路径，产出 `.srec` |
| 「把这个固件烧进板子」 | 告诉你怎么拨 BOOT 拨码，然后发出烧录命令 |
| 「为什么烧不进去，报 E3000105」 | 按引导窗口时序排查 —— 大概率是你先做了探测动作 |
| 「串口全是乱码」 | 直接指出 XTAL 没设成 12M |
| 「烧录成功但板子没反应」 | 指出 BOOT 拨码没拨回单片模式 |
| 「帮我写个呼吸灯」 | 用 GPT + 正确时钟算出 period 和占空比，给可套用的代码 |

没有技能包时，AI 只能给通用的 STM32 式建议，甚至可能给出错误的引脚号。装了这个技能包，它回答的是你这块板子的情况。

---

## 里面有什么

### 三个技能

| 技能 | 什么时候用 |
|---|---|
| [`ra4m2-build-flash`](skills/ra4m2-build-flash/) | 编译 e² studio 工程，或用 Renesas Flash Programmer 烧录 |
| [`ra4m2-troubleshoot`](skills/ra4m2-troubleshoot/) | 编译失败、烧录失败、板子没反应、串口没输出或乱码 |
| [`ra4m2-fsp-api`](skills/ra4m2-fsp-api/) | 写/改固件：GPIO、外部中断、GPT/AGT 的 PWM、串口+printf 重定向、I²C、RTC、ADC、看门狗 |

### 四个命令行工具（不装技能也能直接用）

| 工具 | 作用 |
|---|---|
| [`tools/resolve-env.ps1`](tools/resolve-env.ps1) | 找到你这台机器上的 e² studio、ARM GCC、make、RFP 和串口，输出 JSON |
| [`tools/build-project.ps1`](tools/build-project.ps1) | 命令行编译工程，自动修复生成 makefile 里的机器相关缺陷 |
| [`tools/flash.ps1`](tools/flash.ps1) | 烧录（会处理复位时序，每个固件前都会提醒你按复位） |
| [`tools/capture-serial.ps1`](tools/capture-serial.ps1) | 抓串口输出，包括只在开机打印一次的那行横幅 |

---

## 安装

技能包就是几个 markdown 文件，不装任何软件。复制到助手读取的技能目录即可。

注意不能多套一层目录，加载器不会递归查找：

```
<技能根目录>/
├── ra4m2-build-flash/
│   ├── SKILL.md
│   └── scripts/resolve-env.ps1
├── ra4m2-troubleshoot/
│   └── SKILL.md
└── ra4m2-fsp-api/
    └── SKILL.md
```

常见位置：

| 助手 | 用户级技能目录 |
|---|---|
| DeepSeek Harness | `~/.dsh/skills/` |
| 项目级（通用） | `<你的工作目录>/.dsh/skills/` |

```powershell
# 例：DeepSeek Harness，用户级
$dst = "$env:USERPROFILE\.dsh\skills"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\skills\* $dst -Recurse -Force
```

### 怎么确认装对了

装好后不用重启（会自动热加载）。问助手一个只有这些技能才知道的问题：

> 这块板子的 LED 和按键分别接在哪个引脚？

如果它答 P111（高电平点亮）和 P000（有上拉，按下为低），说明技能生效了。

再问一个验证故障排查技能：

> 我烧录成功但板子没反应，串口也没输出，最可能是什么原因？

答 BOOT 拨码还在引导模式就对了。

---

## 关于"我这块板子不一样"

引脚号是板级信息，不是芯片信息。

这个技能包里的引脚表（LED=P111、按键=P000、I²C 的 P301/P302 等）来自一块特定的 RA4M2 教学板。如果你用的是别的板子，这些引脚大概率不同。

技能本身已经处理了这个问题 —— `ra4m2-fsp-api` 里明确要求 AI：

1. 区分芯片级事实（RA4M2 的定时器时钟频率、API 用法）和板级事实（LED 接哪个脚）
2. 不许猜板级信息，必须从这些地方查：板子原理图 → `ra_gen/pin_data.c` → `configuration.xml` → 问你本人
3. 查不到就明说查不到，而不是编一个引脚号

所以即使板子不同，技能依然有用 —— 它会向你要正确的信息，而不是给你错的。

如果你要适配自己的板子：直接编辑 `skills/ra4m2-fsp-api/SKILL.md`，把里面那张引脚表换成你自己板子的。那是个普通的 markdown 文件，改完立即生效。

---

## 可迁移性（为什么换台电脑也能用）

技能包里没有任何绝对路径。所有跟机器相关的东西都由 `resolve-env.ps1` 在运行时探测，按四层顺序，先命中先用：

| 层次 | 方式 | 为什么需要 |
|---|---|---|
| 1 | `-E2Studio` / `-Rfp` 参数 | 脚本化 / CI，以及最后的兜底 |
| 2 | `RA4M2_E2STUDIO` / `RA4M2_RFP` 环境变量 | 装在非常规位置时的显式覆盖 |
| 3 | **Windows 注册表卸载项** | 默认安装零配置就能找到，且能跨版本 |
| 4 | 候选目录 + 版本通配 | 自定义安装位置 |

两个实际使用中会遇到的细节：

- 通配找 `.exe`，不拼目录名 —— 工具链目录名在不同安装间不一致（`arm-gnu-toolchain-13.2.Rel1-mingw-w64-i686-arm-none-eabi` vs 简单的 `13.2.rel1`），只有 `arm-none-eabi-gcc.exe` 这个文件名是可靠的。
- 串口靠枚举，不用 COM3 —— 并且会识别 CH340 类的 USB 转串口。多个候选时工具不猜测，列出候选并报错退出。

万一探测失败，设环境变量再跑一次：

```powershell
$env:RA4M2_E2STUDIO = 'E:\Tools\Renesas\RA\e2studio_vXXXX'   # 含 \eclipse 的那一层
$env:RA4M2_RFP      = 'D:\Tools\RFP\rfp-cli.exe'
```

设计细节见 [`docs/portability.md`](docs/portability.md)（英文）。

---

## 直接用工具

```powershell
# 这台机器上有什么？
pwsh -File tools/resolve-env.ps1

# 编译（会在副本里编译，不改动你的源码树）
pwsh -File tools/build-project.ps1 -ProjectDir C:\work\MyProject

# 烧录（每个固件前都会提示你按复位 —— 引导窗口是一次性的）
pwsh -File tools/flash.ps1 -Image C:\work\_build\MyProject\Debug\MyProject.srec

# 看板子打印什么（运行时按复位键）
pwsh -File tools/capture-serial.ps1 -Seconds 20
```

`resolve-env.ps1` 把诊断信息写 stderr、JSON 写 stdout，所以可以这样组合：

```powershell
$env = & .\tools\resolve-env.ps1 2>$null | ConvertFrom-Json
& $env.rfp.exe -d RA -t COM -if uart -port $env.serial.ports[0].Port -s 115200 -sig
```

---

## 验证它真的能用

```powershell
pwsh -File tests/run-tests.ps1
```

测试套件只需要 PowerShell 和文件系统 —— 不需要 e² studio、不需要板子、不需要联网，所以能在 CI 里跑。

CI 会在一个什么都没装的干净机器上跑这套测试。我们的 GitHub Actions 就是这么做的，而且通过了，可以验证"别人拿到就能用"。

---

## 环境要求

- Windows
- PowerShell 5.1（Windows 自带）或 PowerShell 7+
- 编译需要：装了 ARM GCC 工具链的 e² studio
- 烧录需要：Renesas Flash Programmer（用的是它的 `rfp-cli.exe`）
- 一块接在串口上的瑞萨 RA 开发板（能识别 CH340 类转串口芯片）

---

## 常见问题

以下是调试过程中遇到的问题，按优先级排列：前两个是最常见的失败原因，建议优先排查；后面的属于特定场景才会遇到的坑。

### 优先排查

#### 1. 串口引导窗口是一次性的

RA 的引导加载程序只接受一次连接，工具一断开，芯片就退出引导模式。

所以"先连上确认一下，再烧录"会失败，报 E3000105。正确做法：按复位 → 立刻发一条完整的烧录命令，中间不要做其他操作。

#### 2. 烧录成功 ≠ 程序在跑

如果 BOOT/MD 拨码还在引导模式，芯片复位后会再次进入引导加载程序，不会启动你的代码。表现是串口没有输出，容易误判为程序写错。

### 其他问题

#### 3. `makefile.init` 会替换 PATH

有些工程里有一行 `export PATH=<另一台机器的 e²studio>\...`，它会整体替换 PATH，导致工具链不可用。症状是：

```
'arm-none-eabi-gcc' is not recognized as an internal or external command
```

这里容易误判：你手动敲 `arm-none-eabi-gcc --version` 完全正常，单独写个小 makefile 也正常，只有真实工程失败，容易误判成工具链没装。

#### 4. 生成的 makefile 里嵌着生成机器的绝对路径

同一个仓库里不同工程可能来自不同机器，路径前缀不一致 —— 实际见过两个不同开发者留下的、用户名各不相同的路径前缀。

#### 5. 非 ASCII 路径会在链接期报错，而不是编译期

GNU Make 用 ANSI 代码页写它的 `$(file > ...)` 响应文件。所以路径里有中文时，编译能过，但链接器随后报：

```
cannot open linker script file
```

看起来像链接器脚本丢了，其实是路径编码被破坏了。工程路径请保持纯 ASCII。

#### 6. 打开串口不会复位 RA 板子

`DtrEnable` / `RtsEnable` 翻转实测无效。所以只在开机打印一次的横幅，只能靠让人在你读取的时候按复位键才能抓到。

顺带一个实用推论：判断程序是否在运行，看有没有周期性输出比抓启动横幅靠谱得多。

---

## 许可

MIT —— 见 [LICENSE](LICENSE)。
