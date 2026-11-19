# App Store 上架清单

_核对日期:2026-11-18。凡是写"已就绪"的,都注明了我当时看的是哪个文件、怎么看的;没能亲自核对的,一律放进"还没做 / 待验证"。例外是第一部分第 14–17 条:它们依据的是当天跑真机自测的会话汇总的结果,不是我逐个重读原始文件得来的。另一个会话还在改界面代码(`App/**`),所以第二部分末尾列了界面改完后需要复查的项。_

## 先说结论

1. **已经在一台真机上跑通,但还有不少情况没测。**
   - **编译与测试。** 模拟器 Debug 包和真机 Release 包都编过,真机包用免费账号签名,已包含隐私清单、图标和致谢;核心逻辑有单元测试,界面有 UI 测试。
   - **真机自测。** 2026-11-18 在一台 iPhone 18 Pro Max(12 GB 内存,iOS 27.2.1)上跑了真机自测。五个模型都从 Hugging Face 下载成功、加载成功,并完成了三轮对话(不开思考)。详情见第一部分第 14–17 条。
   - **还没测的。** 离线、发热、切后台、停止按钮、无障碍、空间或内存不足这些情况还没在手机上试过,见第二部分第 1 条。
   - **两个模型的毛病。** 真机上发现两个模型自身的问题,见第二部分第 16、17 条。
2. **上架前还差这些:**
   - 把第二部分第 1 条里还没在真机上验证的情况测一遍,截真机截图;
   - 定下最终名字;
   - 把隐私政策和支持页面挂到公开网址;
   - 修掉几个小问题(清单见第二部分)。
3. **有几件事只能你本人做:** 花 99 美元/年加入 Apple Developer Program,在 App Store Connect 建 app,填年龄分级和"App 隐私"问卷,选开源许可证,最后提交审核。

## 名词速查

| 名词 | 白话解释 |
|---|---|
| App Store Connect(下称 ASC) | 苹果的上架后台网站:建 app、填资料、传截图、提交审核都在这里。需要付费账号。 |
| Bundle ID | app 的内部唯一标识,形如 `com.xxx.llmoniphone`。用户看不到,但传过构建之后基本就改不了。 |
| Team / Personal Team | 签名用的开发者身份。免费 Apple 账号对应 "Personal Team",付费会员有正式 team。 |
| 描述文件(provisioning profile) | 苹果签发的"安装许可"。免费账号的 7 天就过期。 |
| entitlement(权限) | 写进签名里的特殊能力,比如"提高内存上限"。 |
| 隐私清单(`PrivacyInfo.xcprivacy`) | 打包进 app 的一个文件,声明 app 是否追踪、用了哪些"需要说明理由的系统接口"。 |
| App 隐私问卷 / 隐私标签 | 在 ASC 里回答的问卷,决定商店页面显示"未收集数据"还是列出收集项。 |
| TestFlight | 苹果的测试分发渠道,需要付费账号。 |
| jetsam | iOS 内存不够时直接杀掉 app 的机制。审核时被杀,等同于崩溃。 |
| KV cache | 模型对话时的"工作记忆",对话越长占内存越多。 |
| 自测(SELFTEST) | 本项目自带的真机自动测试:下载 → 加载 → 三轮对话 → 记录数据,详见 README。 |
| token、tok/s | token 是模型处理文字的最小单位,一个英文单词通常是一到两个 token。tok/s 是每秒生成多少个 token,也就是生成速度。 |
| 思考块 | 支持"思考模式"的模型会先把推理过程写在 `<think>` 和 `</think>` 之间,再写回答。app 把这一段折叠成"思考了 N 秒"。 |
| EOS | 模型输出的"说完了"标记。回复正常结束,就是模型自己输出了 EOS。 |
| 贪心解码 | 温度设为 0,每一步都取概率最高的 token,同样的输入每次得到同样的输出。 |

## 一、已就绪(附核对方法)

| # | 项目 | 现状 | 我怎么核对的 |
|---|---|---|---|
| 1 | 设备、方向和系统版本 | 只支持 iPhone、只支持竖屏、最低 iOS 26。 | `project.yml`:`TARGETED_DEVICE_FAMILY: "1"`、`deploymentTarget iOS: "26.0"`、方向只开 Portrait。 |
| 2 | 下载前说明大小并先询问(审核条款 4.2.3) | 弹窗写明"从 huggingface.co 下载 X MB,请保持 app 打开,下载在后台会暂停,建议用 Wi-Fi";空间不够时另有提示。首次启动的推荐卡片上直接写着大小。不会自动下载。 | 读了 `App/Sources/UI/Components.swift` 的 `DownloadConfirmation`。读了 `App/Sources/AppEnvironment.swift`:`download` 只由界面在确认后调用,自测构建除外。 |
| 3 | 隐私清单 | 不追踪,没有追踪域名,不申报收集数据。只声明了"磁盘空间"一类接口,理由代码是 `E174.1` 和 `85F4.1`(含义见下文 B 节)。 | 读了 `App/Resources/PrivacyInfo.xcprivacy`。对两个构建(真机 Release 13:37,模拟器 Debug 14:39)的二进制跑了 `nm -u`,15:49 的新真机 Release 包又跑了一次:需要理由的符号里只出现两个"卷可用容量"键,和清单一致。`C617.1` 是否需要见第二部分。 |
| 4 | 出口合规(加密)的 Info.plist 键 | `ITSAppUsesNonExemptEncryption = NO` 已经写好。依据有两条:联网只用系统 `URLSession` 的 HTTPS(苹果文档说系统自带的加密一般属于豁免);链接进来的 swift-crypto 只在 Hugging Face 客户端里算 SHA-256 校验值。 | 读了 `App/Info.plist`;在依赖源码里 grep 了 `import Crypto` 的用途。最终答案仍需你确认(第三部分第 9 条)。 |
| 5 | "提高内存上限"权限 | 已申请 `com.apple.developer.kernel.increased-memory-limit`。真机 Release 包的签名和包内描述文件都带这个键。描述文件有效期 7 天,也就是免费 team。 | 读了 `App/LLMOnIPhone.entitlements`。对 `.build/products/Release-iphoneos/LLMOnIPhone.app` 用 `codesign -d` 和 `security cms -D` 查看,只 grep 键名,没有输出任何 ID。 |
| 6 | App 图标 | 1024×1024,没有透明通道。画面是三行文字加一个橙色光标,没有画 iPhone 外形;苹果的设计规范不允许在图标里复制苹果硬件。 | `App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`:用 `sips` 查了尺寸和 alpha,并打开看了图。 |
| 7 | 许可证与致谢 | 有三处:设置 › 关于 › 致谢(17 个开源包及许可证原文)、设置 › 关于 › 模型许可证,以及每张模型卡片上的许可证标签。 | 读了 `App/Sources/UI/Settings/AcknowledgementsView.swift`、`App/Resources/Acknowledgements.json`(由 `scripts/gen-acknowledgements.py` 生成)、`ModelsScreen.swift`。 |
| 8 | app 内的模型"目录"(审核 4.7.4 要求列出 app 里能用的软件) | 模型页列出全部 5 个预设,带大小、许可证和内存判断。 | 读了 `App/Sources/UI/Models/ModelsScreen.swift`。 |
| 9 | 没有统计、广告、账号 | 唯一的联网代码在 `HubModelDownloader.swift`(`bearerToken: nil`,不带令牌)。研究笔记确认依赖库里没有遥测代码。 | grep 了 `App/Sources` 和 `Packages/LLMCore/Sources`。 |
| 10 | 加载模型不联网 | `OfflineOnlyDownloader` 一旦被调用就报错;分词器只从本地文件夹读取。 | 读了 `App/Sources/MLX/MLXEngine.swift`,以及 swift-transformers 1.3.0 的 `Hub.loadConfig(modelFolder:)` 源码。 |
| 11 | AI 内容提示 | 设置 › 隐私 里写明"回复由小型语言模型生成,可能不准确或不恰当"。 | 读了 `App/Sources/UI/Settings/SettingsScreen.swift`,15:02 又看了一次,还在。 |
| 12 | 模型版本固定 | 每个预设都钉在完整的 commit 哈希上;下载大小按该版本实际要下载的文件计算。 | 读了 `Packages/LLMCore/Sources/LLMCore/Catalog/ModelCatalog.swift`。 |
| 13 | v1 只用 Apache-2.0 / MIT 模型 | 5 个预设里 4 个是 Apache-2.0,1 个是 MIT。 | 读了 `ModelCatalog.swift` 的 `license` 字段;详情见 `docs/MODEL_LICENSES.md`。 |
| 14 | 真机跑通:五个模型的下载、加载和三轮对话 | 2026-11-18,iPhone 18 Pro Max(12 GB,iOS 27.2.1),免费 team 签名的 Release 自测包,不开思考。五个模型都从 Hugging Face 下载、加载,并完成了"选一个数 → 乘二 → 200 字左右的讲解"三轮。全程温度状态是 nominal(正常)。生成速度:Qwen3 0.6B 180–186 tok/s,Qwen3 1.7B 89 tok/s(贪心 95.5),SmolLM3 3B 53.5,Phi-4-mini 45.2,Qwen3 4B 41.2。加载 0.3–0.7 秒,首 token 延迟 0.04–0.18 秒。 | 依据是当天真机自测的结果:`scripts/selftest-device.sh` 的摘要和拷回的 `selftest-result.json`,由跑测试的会话汇总。这次更新文档时没有逐个重读原始文件。完整表格见 README 的"性能"一节。 |
| 15 | "提高内存上限"在真机上生效 | 带这个权限时,iOS 给本 app 的内存上限是 6.44 GB(手机是 12 GB)。内存占用最高的 Qwen3 4B 也只到 2.59 GB,五个模型都低于 app 的估算值。但测的都是短对话。 | 同第 14 条。内存上限按 `availableBytes + footprintBytes` 算。设置 › 设备 页面本身没在手机上看过,见第二部分第 1 条。 |
| 16 | 真实下载、删除、重新下载 | Wi-Fi 下 982 MB(Qwen3 1.7B)用了 11.3 秒,350 MB(Qwen3 0.6B)用了 4.3 秒。自测的 `--delete-after` 删除模型后释放了 0.35 GB,之后重新下载也正常。加上自动重试和快照完整性检查之后,又从零下载了一次,成功,没有用到重试。 | 同第 14 条。 |
| 17 | 真机上的显示 | Markdown 加粗显示正常。自测每轮截的对话界面截图看起来正常。Qwen3 1.7B 开思考时三轮全对(25 → 50 → 通顺的短文),87–88 tok/s,思考块都正常结束。 | 同第 14 条。 |

## 二、还没做 / 待验证

1. **真机上还没验证的情况(最重要)。**
   - **已经做完的。** 五个模型的真机自测都跑通了,见第一部分第 14–17 条;README 里的 `TODO(device-selftest)` 已经换成实测数字。
   - **还没在手机上试过的:**
     - 开飞行模式离线使用;
     - 回复达到长度上限(当天所有回复都是模型自己结束的);
     - 发热提示和过热停止(当天温度一直是 nominal,没触发过);
     - app 切到后台时停止生成;
     - 点"停止"按钮;
     - VoiceOver(旁白)和动态字体(系统里调大字号);
     - 存储空间不足、内存不够时的提示;
     - 真实网络出错后的自动重试;
     - 用中文和 SmolLM3 3B、Phi-4-mini 对话。
   - **也还没做的:**
     - Qwen3 0.6B 和 Qwen3 4B 开思考跑一次;
     - 设置 › 设备 里"提高内存上限"是否显示"使用中"(权限本身生效了,见第一部分第 15 条,但这个页面没在手机上看过);
     - 下载到一半切到后台会怎样;
     - 取消后重新下载,已经下完的文件会不会跳过;
     - 长对话下内存估算是否合理。当天都是短对话,实测占用都低于估算。
   - **怎么跑。** `scripts/selftest-device.sh --model <id> [--thinking] [--greedy] [--delete-after]`:它会编译 `--selftest` 包、安装、启动、拷回结果并打印摘要。上面列的多数情况自测覆盖不到,要在普通 Release 包上手动试。
   - **为什么必须做。** 审核条款 2.1(a) 要求 app 在真机上测过;审核时被 iOS 因内存不足杀掉,算作崩溃。
   - **提醒。** 达到回复上限的一轮现在算正常结束(`truncated: true`,见第 5 条);如果某一轮报 "Reply was stopped early",那才是切后台或过热。

2. **用最新代码重打真机 Release 包(已完成)。** 15:49 先打了 `--selftest` 包,再打了普通 Release 包。普通包里:有 `PrivacyInfo.xcprivacy` 和图标,有提高内存上限的权限,二进制里没有 `LLM_SELFTEST` / `LLM_UI_DEMO` 字样,`codesign --verify --strict` 通过。真机自测之后,手机上现在装的是普通 Release 包(不含自测代码),五个模型都留着,一共约 7.5 GB。

3. **重跑单元测试。**
   - **已跑过。** 最后一次跑:`scripts/test-core.sh` 的 115 个测试全部通过;`scripts/test-ui.sh` 的 3 个界面流程全部通过。
   - **还没跑。** 为"思考块没关"(第 16 条)新加的测试在 `Packages/LLMCore/Tests/LLMCoreTests/UnterminatedThinkingTests.swift`。这些测试,连同改过的 `ChatTypes.swift`、`ChatViewModel.swift`、`MessageRow.swift`、`SelfTestRunner.swift`,都还没编译、没跑过。

4. **真机截图。** 规格见下文 A 节。现有的演示截图(`scripts/screenshots.sh` 生成,在 `.build/screenshots/`)有三个问题:
   - **透明通道(已解决)。** 尺寸 1206×2622,正好是必交的"灵动岛(中)"档。`scripts/screenshots.sh` 现在会把截图重新编码成不带透明通道的 RGB PNG(`sips` 显示 `hasAlpha: no`)。
   - **数据是假的。** 演示场景用的是模拟引擎,回复内容和 tok/s 都是假的,不能当商店截图,要在真机上截。
   - **内容要适合 4+。** 截图里的对话内容必须适合 4+(条款 2.3.8),哪怕 app 分级是 18+。

5. **截断的回复显示成"已停止"(已在 app 里绕过)。**
   - **原因。** mlx-swift-lm 3.31.3 在回复达到 token 上限时,把结束原因报成"取消"。读源码确认过:生成循环遍历的是迭代器的拷贝,计数器一直是 0。
   - **现在的处理。** `MLXEngine` 自己判断:没人要求停止、且 `generatedTokens >= maxTokens` 时,按"长度上限"上报。app 显示"已达长度上限",自测也不再把它算作失败。这个判断有单元测试。2026-11-18 的真机自测里,每条回复都是模型自己结束的(EOS),没有一条碰到上限,所以它在真机上还没被触发过。

6. **把隐私政策和支持页挂到公开网址。**
   - **草稿。** `docs/PRIVACY.md` 和 `docs/PRIVACY.zh-CN.md` 是草稿,联系方式、生效日期、最终名字都还是 TODO。仓库公开后可以直接用 GitHub 上的文件链接,或者用 GitHub Pages。
   - **填网址。** 在 `Config/Base.xcconfig` 填 `PRIVACY_POLICY_URL` 和 `SUPPORT_URL`。xcconfig 里 `//` 表示注释,所以要写成 `https:/$()/example.com/privacy`。
   - **为什么必须做。** 现在两个都是空的,所以设置里的"隐私政策""支持""报告有问题的回复"三行都不显示。条款 5.1.1(i) 要求 app 里也能找到隐私政策链接,所以这是必做项。

7. **隐私清单要不要加 `C617.1`(文件时间戳类)。**
   - **疑点。** swift-huggingface 下载时会用 `FileManager.attributesOfItem` 读文件大小。这种 Objective-C 方法调用,`nm` 看不出来。
   - **怎么处理。** 如果上传后收到苹果"缺少 API 声明"一类的邮件(例如 ITMS-91053),就在清单里加 `NSPrivacyAccessedAPICategoryFileTimestamp` + `C617.1`(读取 app 容器内文件的元数据)。app 不向用户显示文件时间,所以不需要 `DDA9.1`。

8. **复查本地化是否完整。**
   - **现状。** 两个字符串目录里已有的每个 key 都有简体中文:app 148 个(含新加的两个页脚标注,见第 16 条),核心 26 个。这是 2026-11-18 用 python 数的。
   - **原来的缺口已补上。** 设置页新的隐私文案已经进了目录,见第 10 条。
   - **还要查的。** 代码里新加的字符串有没有进目录,要先跑 `scripts/build-sim.sh`、再跑 `scripts/check-strings.py` 才知道。界面还在改,等改完再查。

9. **改名时要动的地方**(名字本身由你定,见第三部分):
   - `Config/Base.xcconfig` 的 `APP_DISPLAY_NAME`;
   - User-Agent 不用改:它在运行时由显示名和版本号拼出来(`UserAgent.current`);
   - 致谢页脚注里的 "Pocket LLM"(`AcknowledgementsView.swift`,以及 `App/Resources/Localizable.xcstrings` 里的译文);
   - README 和隐私政策;
   - `project.yml` 里 bundle ID 的后缀 `.llmoniphone`。用户看不到它,但传过构建就改不了,要在 ASC 建记录之前定。

10. **设置页的隐私文案(代码已改,翻译已补)。**
    - **原来的问题。** 原文写着对话 "never leave the iPhone",可对话文件会进 iCloud 或电脑备份:`Packages/LLMCore/Sources/LLMCore/Support/AppDirectories.swift` 的注释写明 "backed up normally",只有模型被排除在备份之外。
    - **现在的状态。** 15:01 界面会话已经把 `SettingsScreen.swift` 改成 "Runs on this iPhone" 加一段提到 iCloud 或电脑备份的说明,和隐私政策草稿一致了。
    - **翻译(已补)。** 15:02 查的时候,目录里还没有这两条新文案。2026-11-18 晚些时候再查,"Runs on this iPhone"和那段隐私说明都已经在 `App/Resources/Localizable.xcstrings` 里,都有中文;"never leave the iPhone"那条旧文案已经不在目录里了。代码里实际用到的字符串和目录是否一一对应,仍要等编译后跑 `scripts/check-strings.py` 才能确认(第 8 条)。

11. **Qwen3 4B 的英文简介(已改)。** 原来的 "Best answers of the three" 已改掉;中英文现在都加了一句:长回复会随手机发热变慢。

12. **默认系统提示词。** 现在是空的。只有选 13+ 分级时才需要加(见 D 节)。

13. **开源前的小清理。**
    - **脚本(已改)。** 防护改成了可选的环境变量 `LLM_BUILD_GUARD='<正则>'`,不设就不检查;脚本里已经没有具体的本地进程名。
    - **许可证。** 已选 MIT(2026-11-19),仓库根目录有 LICENSE 文件。

14. **库升级(v1 之后)。**
    - **现状。** mlx-swift-lm 3.33.0 和 mlx-swift 0.33.0 已经发布,但有破坏性改动。研究笔记建议提交前升级,理由是能用上更新的模型、修掉内存泄漏和取消相关的问题;不过已经决定 v1 先不升。
    - **注意。** 如果要升,得在支持的最低 iOS 版本上做真机冒烟测试:0.32.2 和 0.33.0 都修过"启动即崩溃"一类的问题。

15. **审核备注**,写法见第三部分第 10 条。

16. **SmolLM3 3B 开思考时不关思考块(代码已改,还没编译、没测)。**
    - **真机上看到的。** 2026-11-18 只跑过一次。第 1 轮正常:思考 830 个字符,回答"30"。第 2 轮正常:没有思考,回答"60"。第 3 轮它先写推理,接着把整篇短文也写进思考块,然后直接输出 EOS 结束,始终没写 `</think>`。结果 app 里是 1,943 个字符的"思考过程"加一个空回答,自测以 `emptyAnswer` 判这一轮失败。
    - **原因。** SmolLM3 的 `<think>` / `</think>` 只是普通文字,不是特殊标记,模板也不强制它关上。
    - **代码里的修复。** 回复结束时,`ChatMessage.promoteUnterminatedThinkingIfNeeded()` 检查五个条件:正常结束、结束原因是 EOS、思考块没关、回答为空、思考内容不为空。都满足时,把思考内容挪成回答,页脚标注"思考内容作为回答显示",自测记 `thinkingPromoted: true`,并把这一轮算作有回答。
    - **不挪的情况。** 碰到长度上限、被停止或者出错的回复,仍保留为思考过程。已经结束却没有回答的回复,思考过程会自动展开;长度上限那种情况,页脚写"思考时已达长度上限"。
    - **还要做。** 编译、跑 `scripts/test-core.sh`(新测试在 `UnterminatedThinkingTests.swift`)、跑 `scripts/check-strings.py`,再用 `scripts/selftest-device.sh --model smollm3-3b-4bit --thinking` 在真机上复测。

17. **Qwen3 1.7B 不开思考时不守数字范围(像是模型局限,没对照过)。**
    - **看到的。** 自测第 1 轮要它"在 11 到 49 之间选一个整数",大约一半的运行给出范围外的数,比如 57、67。贪心解码(温度 0)也一样:它答 67,下一轮再正确地乘二得到 134。
    - **为什么像是模型本身。** 另外四个模型走完全相同的代码都答对了;复查采样部分的源码,也没发现问题。所以看起来是这个 4-bit 小模型不开思考时的能力局限。
    - **还没确认。** **没有**在 Mac 上和参考实现对照过,所以不能完全排除 app 这边的问题。
    - **开思考时。** Qwen3 1.7B 三轮全对。
    - **对上架的影响。** 不影响上架。但审核备注里推荐审核员先试的模型(第三部分第 10 条)要考虑这一点。

**界面改完后需要复查的(当时文件还在变):**

- 第 2 条:重打真机包(已完成);
- 第 8 条:本地化完整性;
- 第 10 条:设置页文案;
- 已就绪第 2、7、11 条:下载确认弹窗、致谢 / 模型许可证页、AI 内容提示是否还在原处、措辞是否变了;
- 隐私清单是否仍然只需要磁盘空间类,也就是界面有没有新用到 `UserDefaults` / `@AppStorage`。

## 三、必须你本人操作

1. **加入 Apple Developer Program。**
   - **费用与资格。** 99 美元/年,有当地货币价格时按当地货币收(<https://developer.apple.com/support/enrollment/>)。只有你本人能注册和付款。
   - **注意。** 以个人身份注册时,商店上显示的开发者名字一般是你的法定姓名;不想公开的话,要用组织身份注册(需要法人实体)。这一点没在研究笔记里核对过,以苹果注册页面为准。
2. **付费 App 协议、银行、税务。** 只有 app 收费时才需要,包括付费下载和内购。免费 app 不用填。
3. **在 ASC 建 app 记录。** 要填名字(不超过 30 个字符,不能和已有 app 重名)、主要语言、Bundle ID、SKU(自己起的内部编号)。
4. **年龄分级问卷。** 推荐 18+,理由和备选方案见 D 节。
5. **App 隐私问卷。** 推荐答"未收集数据",理由见 C 节。
6. **隐私政策网址、支持网址。** 在 ASC 里都是必填,也都可以按语言分别填;"版权"字段同样必填(<https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties>)。网址本身见第二部分第 6 条。
7. **定名字。** 见 F 节。定了之后按第二部分第 9 条改代码。
8. ~~选开源许可证。~~ 已定 MIT(2026-11-19),LICENSE 文件和 README 的 License 一节都已补上。
9. **出口合规。** Info.plist 已经声明"不使用非豁免加密",你要确认这个说法成立:app 只用系统 HTTPS 和 SHA-256 校验,没有自己写的加密。有了这个键,每次上传就不会再弹出口合规问卷(<https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption>、<https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>)。
10. **提交审核。** 写给审核员的备注建议包括:
    - 模型在本机运行,首次要下载;建议先下 Qwen3 0.6B(约 350 MB,用 Wi-Fi);
    - 没有账号,内容不经过任何服务器;
    - "报告有问题的回复"和联系方式在哪里。

---

## A. 截图规格

来源:<https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications>

- **格式与数量。** 支持 .jpeg、.jpg、.png;每个尺寸至少 1 张、最多 10 张;**不能带透明通道**。
- **必交档位。** iPhone "灵动岛(中)"档至少 1 张。本 app 只支持 iPhone,不用交 iPad 截图。
- **自动缩放。** 如果界面在各种尺寸上一致,只交最高的必需分辨率就行,ASC 会自动缩小。
- **苹果页面自身的不一致。** "Face ID(大)"那一行还写着"没交灵动岛(大)截图时必需"。

| 档位 | 例子 | 竖屏像素 |
|---|---|---|
| 灵动岛(大) | iPhone Air、14 Pro Max – 18 Pro Max、15/16 Plus | 1260×2736、1290×2796、1320×2868 |
| **灵动岛(中),必交** | 14 Pro – 18 Pro、15、16、17 | **1179×2556、1206×2622** |
| Face ID(大) | — | 1284×2778、1242×2688 |
| Face ID(中) | — | 1170×2532、1125×2436、1080×2340 |

- **iPhone Duo。** 外屏 1398×2034,内屏 2007×2853。苹果写明,从 2027 年 4 月起,用 iOS 27.1 或更高版本 SDK 构建的 app 必须交 Duo 截图。本机 Xcode 27.2 用的是 iOS 27.2 SDK,所以到时会适用。本 app 只支持竖屏,在 Duo 上的表现也还没测过。
- **内容要求。** 截图属于元数据,必须适合 4+(条款 2.3.8)。

## B. 隐私清单内容与理由代码

来源:<https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype>

**当前 `App/Resources/PrivacyInfo.xcprivacy` 的内容:**

| 键 | 值 |
|---|---|
| `NSPrivacyTracking` | false |
| `NSPrivacyTrackingDomains` | 空 |
| `NSPrivacyCollectedDataTypes` | 空 |
| `NSPrivacyAccessedAPITypes` | `NSPrivacyAccessedAPICategoryDiskSpace`:`E174.1`、`85F4.1` |

**两个理由代码的含义,以及 app 实际怎么用:**

- **`E174.1`:为了判断空间够不够写文件而查剩余空间。** 苹果要求 app 根据空间大小做出用户看得到的不同行为,并允许"空间不足就不下载"这种用法。本 app 就是这么做的:空间不足时拒绝下载并提示(`LiveModelStore.swift`、`Components.swift`)。
- **`85F4.1`:把磁盘空间信息显示给用户。** 本 app 在模型页底部显示"模型占用 X · 本机剩余 Y"(`ModelsScreen.swift`)。

**没有声明的几类,以及原因:**

- **`UserDefaults`(`CA92.1`)。** 代码里没有用,`nm` 也没找到。
- **文件时间戳(`C617.1` / `DDA9.1`)。** 见第二部分第 7 条。
- **系统开机时间(`35F9.1`)。** 计时用的是 `Date` 和 `ContinuousClock`,不在苹果的名单上。

**依赖库**(来自研究笔记,外加我查的链接清单):

- **不带清单的库。** mlx-swift、mlx-swift-lm、swift-transformers、swift-huggingface、swift-jinja、yyjson 都不带隐私清单。研究笔记 grep 过,除 swift-huggingface 读文件大小那一处外,没有需要理由的接口。
- **swift-crypto。** 自带空清单。
- **swift-nio。** 只有 NIOPosix、NIOFS 这几个模块带清单,而模拟器包的链接清单(`LLMOnIPhone.LinkFileList`)里只有 NIOCore 一类模块,没有 NIOPosix。
- **BoringSSL。** 它在苹果"需要隐私清单和签名的 SDK"名单上(<https://developer.apple.com/support/third-party-SDK-requirements/>)。但模拟器 Debug 包的链接清单里没有它;真机包没查。签名要求只针对以二进制形式引入的依赖,SPM 源码包不适用。

## C. App 隐私问卷:为什么可以答"未收集数据"

来源:<https://developer.apple.com/app-store/app-privacy-details/>

**苹果的定义(意译):**

- **什么算"收集"。** "收集"指把数据从设备传出去,并且你或你的第三方合作方能在超过"实时处理这次请求所需"的时间之后访问它。
- **不算收集的情况。**
  - 只在设备上处理的数据,不算收集。
  - 服务器请求里带了 IP 地址或令牌,但不保留,不用申报。
  - 发到服务器、处理完立即丢弃的数据,也不用申报。
- **谁是"第三方合作方"。** 指你加进 app 的分析工具、广告网络、第三方 SDK 或其他外部供应商。

**对照本 app:**

- 没有自己的服务器;
- 唯一的外发请求是去 Hugging Face 下载模型文件,不带令牌,也不带自定义标识(User-Agent 只有 app 名和版本),也不保存、不回传 Cookie;
- 对话只在本机;
- 没有分析或崩溃上报 SDK。

**结论(这是解读,不是苹果的裁定):** 回答"否,我们不从此 app 收集数据",商店页面就会显示"未收集数据"。

**注意:**

- **对方能看到什么。** Hugging Face(不是你)能看到用户的 IP 和请求了哪些文件。
- **什么时候要改答案。** 以后如果加了崩溃上报、统计、Hugging Face 登录令牌,或者自建服务器,答案就要改。
- **隐私政策照样要有。** 条款 5.1.1(i) 要求必须提供隐私政策。

## D. 年龄分级

来源:<https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions>、<https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating>、<https://developer.apple.com/news/upcoming-requirements/>

**分级体系与问卷:**

- **现在的档位。** 4+、9+、13+、16+、18+,另有"未分级",未分级不能上架。旧 app 的新版问卷截止日是 2026-01-31。
- **各档大致门槛。**
  - **13+:** 例如频繁的粗口和低俗幽默,或者偶尔出现的性内容、写实暴力、酒精 / 药物、医疗信息;
  - **16+:** 不受限制的网页访问、频繁的医疗信息、频繁的成人或暗示性主题;
  - **18+:** 频繁的酒精 / 药物、性内容、写实暴力,以及赌博。
- **问卷结构。** 依次是:app 内管控(家长控制、年龄确认)、功能(不受限网页访问、用户生成内容、社交、聊天、广告),然后是按出现频率勾选的内容描述。研究时两个帮助页都搜过,**没有专门针对 AI / 聊天机器人的问题**。
- **可以手动调高。** 可以手动"覆盖为更高分级";如果 EULA 规定的最低年龄高于苹果算出的分级,就必须覆盖。

**推荐:18+,用"覆盖为更高分级"来设。**

- **理由一。** app 不带内容过滤,小模型被要求时什么都可能写,问卷各项都答"无"站不住。
- **理由二。** 下载量不是目标。
- **理由三。** 定在 18+ 后,条款 4.7.5 的风险最小。4.7.5 要求能识别"超出 app 分级的软件"并做年龄限制;定在 18+,任何模型都不会"超出"。这一点是我的解读。
- **代价。** 商店显示 18+,未成年人用不了。

**备选:13+。需要做到:**

- 如实勾选"偶尔 / 轻度"的内容描述,例如成人或暗示性主题、医疗信息、粗口、恐怖、酒精 / 药物提及;
- 加一个默认系统提示词,现在是空的;
- 保留 AI 内容提示(已经有了);
- 让"报告有问题的回复"真正能用,也就是填上 `SUPPORT_URL`;
- 并且接受审核员可能按 1.2 / 4.7 要求更多过滤措施。

**同类 app 的分级(2026-11-18 查):**

- **"API"列** 是 iTunes Search API 返回的旧标签(12+/17+);**"商店页"列** 是 apps.apple.com 当前显示的分级。
- **规律。** 同类 app 基本分成两堆:13+(勾了"偶尔 / 轻度"描述),或 18+。

| App | API | 商店页 | API 列出的内容描述 |
|---|---|---|---|
| [PocketPal AI](https://apps.apple.com/us/app/pocketpal-ai/id6502579498) | 17+ | **18+** | 无 |
| [Locally AI by LM Studio](https://apps.apple.com/us/app/locally-ai-by-lm-studio/id6741426692) | 12+ | **13+** | 偶尔/轻度:医疗、酒精/药物、恐怖、成人/暗示 |
| [Private LLM - Local AI Chat](https://apps.apple.com/us/app/private-llm-local-ai-chat/id6448106860) | 12+ | **13+** | 偶尔/轻度:恐怖、医疗、成人/暗示 |
| [Enclave - Local AI Assistant](https://apps.apple.com/us/app/enclave-local-ai-assistant/id6476614556) | 17+ | **18+** | 偶尔/轻度:粗口、卡通暴力、恐怖、酒精/药物、写实暴力 |
| [Liquid Apollo](https://apps.apple.com/us/app/liquid-apollo/id6448019325) | 12+ | **13+** | 偶尔/轻度:医疗 |
| [Noema: Local AI & Offline LLM](https://apps.apple.com/us/app/noema-local-ai-offline-llm/id6751169935) | 12+ | **13+** | 偶尔/轻度:医疗 |
| [fullmoon: local intelligence](https://apps.apple.com/us/app/fullmoon-local-intelligence/id6727014156) | 17+ | **18+** | 无 |
| [MLC Chat](https://apps.apple.com/us/app/mlc-chat/id6448482937) | 17+ | 未查 | 偶尔/轻度:卡通暴力、写实暴力 |

LLM Farm 在美区 iTunes 搜索里没找到,可能不在美区商店上架(未核实)。

## E. 审核条款风险

来源:<https://developer.apple.com/app-store/review/guidelines/>(页面标注最后更新于 2026 年 10 月 16 日)。条款大意是我意译的,原文请看链接。

| 条款 | 大意 | app 现在怎么做 | 仍不确定的地方 |
|---|---|---|---|
| **1.2** 用户生成内容 | 现在明确包括"AI 内容生成"类 app。要求:过滤不当内容、提供举报机制并及时处理、能屏蔽滥用用户、公开联系方式。 | 单人离线使用,没有"发布 / 分享到平台"的环节。设置里有 AI 内容提示。"报告有问题的回复"链接要填了 `SUPPORT_URL` 才显示。没有过滤;也没有别的用户可屏蔽。 | 审核会不会把单人离线聊天按 1.2 处理,**未知**。 |
| **4.7** 不在二进制里的软件(含 chatbots) | 开发者要为这些软件负责。4.7.1:要有过滤、举报、屏蔽。4.7.4:要提供 app 内可用软件的索引。4.7.5:要能识别超出 app 分级的软件,并按年龄做限制。 | 模型页就是索引(5 个预设 + 许可证)。选 18+ 可以避开 4.7.5 的分级落差。 | 下载的模型权重算不算这里说的 "chatbots",是解读,**未确认**。 |
| **2.5.2** 自包含 | 不能下载或执行会新增、改变功能的代码。 | 下载的是权重(数据)和 json / jinja 配置。同类 app 都是装好后再下载模型并且已经上架,说明这种做法通常被接受(推断)。 | `chat_template.jinja` 是从模型仓库下载、由 swift-jinja 解释执行的模板。目前没见到被点名,但**未确认**。 |
| **4.2.3(ii)** 首次使用需要下载 | 要说明下载大小,并先征得同意。 | 已做,见已就绪第 2 条。 | — |
| **2.3.7 / 2.3.8** 名字与元数据 | 2.3.7:名字要唯一,不能堆商标词,不超过 30 字符。2.3.8:元数据(含截图)要适合 4+。 | 名字未定(见 F 节);截图未做。 | — |
| **5.1.1** 隐私 | (i):ASC 和 app 内都要有隐私政策链接。(ii):收集数据要征得同意。 | 隐私政策草稿已写;app 内链接要等填网址。不收集数据,所以 (ii) 不涉及。 | — |
| 5.1.2(i) 与第三方 AI 共享数据 | 要明示并取得许可。 | 推理全在本机,不适用。 | — |
| 2.1(a) 完整性 | 要在真机上测过;会崩溃的二进制会被拒。 | 2026-11-18 五个模型在一台 iPhone 18 Pro Max 上跑通了自测(第一部分第 14–17 条)。还有不少情况没测(第二部分第 1 条)。内存估算会拒绝装不下的模型;实测占用都低于估算,但只测了短对话。 | 长对话下估算准不准,还要在真机上验证。 |

## F. 命名

来源:<https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html>、<https://developer.apple.com/app-store/marketing/guidelines/>、<https://developer.apple.com/design/human-interface-guidelines/app-icons>

**苹果的规则(意译):**

- **商标规则。** 不能把 iPhone 等苹果商标用作产品名或其中一部分。
- **唯一例外:说明兼容性,而且三条都要满足:**
  - 商标不在产品名里;
  - 用 "for / runs on / compatible with" 这类指代短语;
  - 商标没有产品名显眼。
- **营销指南的说法。** 可以说 "<app 名> for iPhone",不要说 "iPhone <app 名>"。

**判断:"LLM on iPhone" 不能用。**

- **为什么。** 除了 iPhone,名字里只剩一个通用词 "LLM",于是 iPhone 实际成了名字的主体,也谈不上"没有产品名显眼"。这和 2.3.7、5.2.1 也冲突。
- **可行的写法。** 起一个独立的名字,需要时加后缀,例如 "<名字> – Local AI for iPhone";或者名字里干脆不出现 iPhone。
- **图标。** 不要画 iPhone,现在的图标也没有画。
- **模型品牌。** 名字和图标里也别用 Qwen、Llama、Gemma 这些模型品牌(条款 4.1(c)、5.2.1)。

**撞名检查**(iTunes Search API,美区,2026-11-18。只看了前面若干条结果,不是穷举):

| 候选 | 结果 |
|---|---|
| Pocket LLM(现在的暂定名) | **已被占用**,作为名字的一部分:"Private AI Chat: Pocket LLM"(id6752952699)、"Pocket LLM Chat"(id6805865627) |
| Offline LLM | 多个,如 "Offline LLM - Locally AI Chat"、"Offline LLM: Private AI Chat"、"Ciel - Offline LLM" |
| Local LLM | 非常多,如 "Local LLM: On-Device"、"Local LLM: MITHRIL"、"Local LLM - Offline AI" |
| Tiny LLM | 前排结果里没有 |
| LLM on iPhone | 没有匹配,但有上面的商标问题 |

ASC 会不会拦"只是包含相同词"的名字,没测过;只确定完全重名会被拦。

## G. 模型许可证

完整版(含固定版本号和许可证要求解读)见 [`docs/MODEL_LICENSES.md`](MODEL_LICENSES.md)。

| 预设 | 上游模型 | 许可证 |
|---|---|---|
| Qwen3 0.6B / 1.7B / 4B | [Qwen/Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B)、[Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B)、[Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) | Apache-2.0([LICENSE](https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/LICENSE)) |
| SmolLM3 3B | [HuggingFaceTB/SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) | Apache-2.0(model card) |
| Phi-4-mini | [microsoft/Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct) | MIT([LICENSE](https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/LICENSE),另有 NOTICE.md) |

**被排除的模型**(条款为意译,带章节号;原文见链接):

- **Llama 3.2 1B/3B**,[Llama 3.2 Community License](https://raw.githubusercontent.com/meta-llama/llama-models/main/models/llama3_2/LICENSE):
  - §1.b.i:分发或提供包含 Llama 的产品,要附上协议,并醒目显示 "Built with Llama";
  - §1.b.iii:要附指定的版权声明;
  - §1.b.iv:使用必须遵守 Meta 的可接受使用政策;
  - §2:月活超过 7 亿另有条款。
- **Gemma 3(1B)、Gemma 3n**,[Gemma Terms of Use](https://ai.google.dev/gemma/terms)(2026-04-01 修订):
  - §1.1(b):通过远程方式提供 Gemma 的功能,也算"分发";
  - §3.1:分发者要把使用限制写进自己的条款,并附 Notice 文件;
  - §3.2:必须遵守禁止用途政策;
  - Google 还保留远程限制使用的权利。
- **LFM2 / LFM2.5 / LFM3**,[LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE):§5(a)(b),年收入达到 1,000 万美元以上的主体,商业使用不在授权范围内。
- **EXAONE 4.0 1.2B**,[EXAONE AI Model License](https://huggingface.co/LGAI-EXAONE/EXAONE-4.0-1.2B/blob/main/LICENSE):§3.1 禁止任何商业用途。

**不是因为许可证、而是暂缓的:**

- **Gemma 4 E2B。** 许可证其实是 Apache-2.0,但当前版本在 3.31.3 上加载不了。
- **Qwen 3.5。** 也是 Apache-2.0,但 3.31.3 缺数值修复。

两者都等库升级之后再考虑。"只是让用户自己下载"算不算分发,是解读,不是法律意见。

## H. 免费账号(Personal Team)的限制

来源:<https://developer.apple.com/support/compare-memberships/>、<https://developer.apple.com/help/account/reference/supported-capabilities-ios>

**数量和有效期(苹果原意):**

- **App ID。** 最多注册 10 个,7 天后过期。
- **设备。** 最多 3 台,7 天后过期。
- **app。** 每台设备最多装 3 个。
- **描述文件。** 7 天过期,过期后要重新编译、重新安装。

网上常说"每 7 天最多 10 个 App ID(滚动计算)",苹果原文里没有这个说法。

**免费账号用不了的:** 证书 / 标识符 / 描述文件后台、TestFlight、App Store Connect、Xcode Cloud。

**能力表:**

- **免费可用:** App Groups、后台模式等。
- **不可用:** Extended Virtual Addressing(扩展虚拟寻址)、Increased Debugging Memory Limit、推送、iCloud 等。
- **Increased Memory Limit(提高内存上限)不在表里。** 但本项目真机包里那份 7 天有效期的描述文件确实带着它(已核对,见已就绪第 5 条)。研究笔记里的两条社区报告也这么说。

## I. 拿到付费账号之后

1. **改 `Config/Local.xcconfig`。**
   - **`DEVELOPMENT_TEAM`:** 换成付费 team 的 ID,在 developer.apple.com 的 Membership 页面能看到。
   - **`BUNDLE_ID_PREFIX`:** 换成正式前缀,例如你的反向域名。
   - **最终的 Bundle ID** 是"前缀 + `.llmoniphone`"。想改后缀,就改 `project.yml` 再跑 `xcodegen generate`,一定要在第一次上传前定好。
2. **签名。** 仍然用自动签名(`Config/Base.xcconfig` 里 `CODE_SIGN_STYLE = Automatic`)。Xcode 会为付费 team 注册 App ID,并按 `App/LLMOnIPhone.entitlements` 打开"提高内存上限";描述文件也不再是 7 天就过期。
3. **打包上传。**
   - **步骤。** Xcode › Product › Archive(scheme 的 archive 用 Release,见 `project.yml`)→ Distribute App → App Store Connect。仓库里目前没有命令行打包 / 上传脚本。
   - **别传错包。** 不要上传 `--selftest` 构建:自测代码只在显式传参时才编进去,演示场景只在 DEBUG 里有,正常的 Release archive 两者都不含。
4. **TestFlight。** 上传后可以先发给内部测试员;外部测试员需要先过 Beta 审核。细节以苹果当前说明为准。
5. **工具链要求。** 2026-04-28 起,上传的 app 必须用 Xcode 26 或更高版本、iOS 26 SDK 构建(<https://developer.apple.com/news/upcoming-requirements/>),本机的 Xcode 27.2 满足。
6. **上传后留意苹果的邮件。** 比如缺少 API 声明这类自动检查结果(见第二部分第 7 条)。
