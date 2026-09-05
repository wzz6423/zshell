# Zshell 验证与清理参考

## 依赖安装

```sh
(cd mac && bun install --frozen-lockfile)
(cd web && bun install --frozen-lockfile)
```

两个包各有锁文件，不要在仓库根装依赖，也不要把它们合成一个 workspace。

## 检查矩阵

| 改动范围 | 命令 | 期望 |
| --- | --- | --- |
| 任何 app 代码 | `make run` 后实际操作改动路径 | 构建通过，行为符合预期；UI 改动留截图或录屏 |
| 终端 surface / 面板 | 同上，并在 Settings 切换 Backend 后新开终端复测 | Ghostty 与 Alacritty 都成立 |
| `mac/Vendor/alacritty-bridge` | `cd mac/Vendor/alacritty-bridge && cargo test --locked` | 测试通过；`--locked` 与构建阶段一致，能提前暴露过期的 `Cargo.lock` |
| 桥的发布构型 | `(cd mac/Vendor/alacritty-bridge && cargo build --locked --release)` | 与 app 实际链接的 profile 一致（`panic = "abort"` 只在 release 生效） |
| `mac/scripts/**` | `cd mac && bunx tsc --noEmit` | 无类型错误（`mac/tsconfig.json` 的 `include` 就是 `scripts`） |
| `mac/scripts/make-dev-icon.py` | `python3 -m py_compile mac/scripts/make-dev-icon.py` 后删掉 `__pycache__` | 可编译 |
| `web/**` | `cd web && bun run typecheck && bun run build` | 类型与静态构建都通过 |
| `skills/**`、`mac/zshell/Skills/**` | `ruby .github/scripts/validate-skills.rb` | 每个 `SKILL.md` 都通过；名字必须与目录同名，本地引用不能越出 skill 目录 |
| 签名 / entitlements / bundle id | `codesign --verify --deep --strict --verbose=2 'mac/build/debug/Build/Products/Debug/zshell Debug.app'` | 校验通过，且 Debug 与已安装正式版仍能并存 |
| 自动化 CLI | 在 Zshell 面板内跑 `zshell +pane list`、`zshell +agent list` | 命令返回 JSON，跨项目目标仍被拒绝 |

app 没有单元测试目标，不要为了"有测试"给 Xcode 工程新增 test target；也不要把
`cargo test` 当成 app 行为的证明。

## 本地一次性纯构建

```sh
(
  zshell_derived="$(mktemp -d "${TMPDIR:-/tmp}/zshell-verify.XXXXXX")"
  trap 'rm -rf "$zshell_derived"' EXIT
  xcodebuild -project mac/zshell.xcodeproj -scheme zshell -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$zshell_derived" build
)
```

构建前核对工程当前使用本地还是远端包；有远端锁文件时可加
`-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile` 固定版本。

CI 另外加 `-skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，
本地想跳过签名时可以照抄，但那样得到的 bundle 不能用来验证签名相关改动。

## CI 与路径作用域

| 工作流 | 触发路径 | 主要内容 |
| --- | --- | --- |
| `macOS App` | `mac/zshell/**`、`mac/zshell.xcodeproj/**`、`mac/Vendor/**`、`mac/Config/**`、`mac/Makefile`、`Makefile`、`mac/scripts/build-alacritty-bridge.sh`、`.github/**` | 桥的 `cargo test`/release 构建、Debug app 冒烟构建与 bundle 结构检查、Swift CodeQL |
| `Release Scripts` | `mac/scripts/**`、`mac/package.json`、`mac/bun.lock`、`mac/tsconfig.json`、`.github/**` | `bunx tsc --noEmit`、Python 脚本可编译 |
| `Web CI` | `web/**`、`.github/**` | `bun run typecheck`、`bun run build` |
| `Skill CI` | `skills/**`、`mac/zshell/Skills/**`、`.github/**` | 每个 `SKILL.md` 的 frontmatter、本地引用与 release URL |
| `CI Lint`、`Repository Hygiene`、`PR Quality Gates`、`CodeQL`、`Dependency Review` | 无作用域 | 每个 PR 都跑 |

作用域由 `.github/ci-skip.json` 的 `paths` 拥有；改工作流文件必须同步这个清单，
否则 `Test CI Scripts` 会因清单漂移失败。`.github/**` 下任何改动都会跑全部工作流。
跳过检查的 `skip-*` / `unskip-*` 评论指令规则见 `CONTRIBUTING.md`，只有仓库 owner、
组织成员、协作者或被请求的 reviewer 能用，且新 commit 一推就失效。

## 常见构建失败

| 现象 | 原因与处理 |
| --- | --- |
| `error: cargo not found` / `rustc not found` | 没装 Rust 工具链；Xcode 的 PATH 被裁剪，脚本只回退 `~/.cargo/bin`、`/opt/homebrew/bin`、`/usr/local/bin` |
| `error: Rust target … is not installed` | `rustup target add aarch64-apple-darwin` 或 `x86_64-apple-darwin`；不要试图在构建阶段里装，沙箱禁止写 `~/.rustup` |
| Ghostty 相关符号找不到 | 检查 vendored 源码、SwiftPM 下载的 XCFramework 和实际链接错误；当前目录不是 submodule |
| 迁移目录后找不到旧路径的 XCFramework | SwiftPM 缓存保存了绝对路径；使用新的 DerivedData/SourcePackages，或只清理已确认失效的缓存，保留用户源码与锁文件 |
| `Conflicting identity for sttextview` | fork 被登记成 local package，必须改回 root package（把文件夹拖进工程） |
| 构建阶段报写入被拒 | `ENABLE_USER_SCRIPT_SANDBOXING` 生效，脚本只能写声明的输出和 `TARGET_TEMP_DIR` |
| `No signing certificate "Apple Development"` | 没建 `mac/Config/Local.xcconfig` 或 `DEVELOPMENT_TEAM` 不对；用 `security find-identity -v -p codesigning` 核对 |
| Debug app 退不掉 | `make stop` 先 `terminate` 再 `forceTerminate`；直接 `kill -9` 会跳过终端会话的正常关闭路径 |
| 启动后立刻退出、像执行了一条命令 | 在 Zshell 面板里手动 `open` 了 bundle，继承了 `ZSHELL_CLI_STATE` / `ZSHELL_CLI_TOKEN`；用 `make run` |
| 新字符串在字符串目录里看不到 | 先构建一次让字符串提取跑过，再编辑 `Localizable.xcstrings` |

## 清理清单

仅清理本次创建的 DerivedData、Rust target、网站输出、Python `__pycache__` 和临时日志。
若使用了共享目录，先确认没有其他任务正在使用；不得默认删除已有依赖或停止用户的应用。
用户要求整体清理时，可在仓库根运行 `make clean`。

提交前检查 `git status --short` 与 `git diff --cached --name-only`；`mac/build/`、Rust target、
`node_modules/`、`web/dist`、`web/.source`、DMG、ZIP、日志、凭据和 `mac/Config/Local.xcconfig`
都不应纳入 Git。
