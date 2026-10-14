# 语音通话（方案与实测）

> 状态（2026-10-12）：路线已定（ADR0074）。已实现：引擎、Fish 流式合成、回复生成、麦克风／播放、通话页与聊天页入口、通话记录（v22）、气泡与记录页、上下文快照与通话摘要、识别来源设置。Mac 应用内已打通电话。模型下载还没做。数据都是在 Mac 上测的，连接的是开发者本机网络，真机和移动网络还没测。

## 流水线

```text
麦克风 → 流式 ASR（服务端判断说完）→ 聊天模型流式输出 → 切句 → 流式 TTS（角色音色预设）→ 边收边播
```

- 切句比文字聊天更激进：句号、问号、感叹号直接切；逗号等弱标点在攒够 6 个字后才切。每段发 `text` 再发 `flush`。
- 通话提示词要求先给一两个字的即时反应（“诶？”“嗯……”），让首段尽量短。
- 开场白（2026-10-12）：接通后角色先开口（`VoiceCallSession.greetOnConnect` 默认开），此时通话轮次为空，提醒里追加 `kVoiceCallOpening`，要求一两句简单的招呼。开场白期间话筒照旧不送识别。
- 通话模式关闭模型思考。
- 语气标签（2026-10-12）：合成是 Fish Audio 时，通话提醒里附上方括号语气说明（`kFishAudioCallSpeechGuide`），模型在台词里写 `[笑着说]`、`[轻笑]` 等；切句不在方括号内切。逐句记录 `text` 保留标签供下一轮模型照着说，字幕、通话记录页和摘要用 `CallTurn.spokenText` 去掉标签；估算朗读时长也不算标签。非 Fish 合成时提醒改为禁止方括号。

## 代码结构（第一批＋通话记录，2026-10-12）

| 层 | 文件（`lib/src/features/voice_call/`） | 职责 |
|---|---|---|
| 端口 | `domain/speech_recognizer_port.dart`、`domain/voice_call_ports.dart` | 识别、流式合成、麦克风、播放、回复生成五个端口，以及 `CallTurn` |
| 引擎 | `application/voice_call_session.dart`、`application/call_reply_segmenter.dart` | 在听／在想／在说状态机、用户分段拼句、切句、轮次结束判定、打断与“只记已播出部分”、静音。轮次结束要求收到的音频不短于按字数估算的下限，8 秒无进展则打断合成；挂断先停播放 |
| 存档 | `application/voice_call_archiver.dart`、`domain/call_record_port.dart`、`data/sqlite_call_record_store.dart` | 挂断后聊天里追加一条通话气泡，逐句记录存在气泡里；没接通不留记录。`call_sessions`／`call_turns` 只读，给 10-12 之前的旧气泡兜底 |
| 适配器 | `data/fish_audio_streaming_tts.dart` | Fish 主连接＋备用连接、20 秒 ping、打断换连接、丢弃旧连接音频 |
| | `data/api_runner_call_reply_generator.dart`、`data/voice_call_context_brief.dart` | 接通时走主聊天唯一装配入口 `prepareApiConfig` 拿上下文快照：只带最近 8 条原文，更早的由后台自动压缩 Agent 压成接通前摘要（只存内存）；只留记忆、时间感知插件，去掉工具；插件提醒不留在快照里（`deferReminders`），每轮按发送时刻现算当前时间，和通话约束合成一条贴在用户最新一句前（2026-10-14 修：之前接通时算一次，还插在文字聊天最后一条用户消息前，角色感知不到通话中的时间），请求关闭思考（Kimi K3 不理这个参数，仍会短暂思考，2026-10-12 实测）。快照不写预设变量和 `context_summaries`；模型取默认聊天模型。每轮把两条 assistant 占位换成摘要和通话轮次（保留被合并进来的前后文字），并插入通话约束提醒，经 `ApiRunner` 一律流式调用，没流出的部分用最终回复补齐 |
| | `data/voice_call_summarizer.dart` | 通话摘要 Agent `local.voice_call_summary`：复用后台运行壳和压缩模型，输入只有本次逐句转写 |
| | `data/device_call_audio.dart` | `record` 采集 16 kHz PCM（系统回声消除只在手机上开）；`mp_audio_stream` 播放，进度按墙钟估算，清空靠重建播放流 |
| 通话生命周期 | `application/active_voice_call.dart`、`activeVoiceCallProvider` | 一通电话的全局控制器（同一时间一通）：接通、挂断存档、话筒／扬声器、收起成悬浮窗（`minimize`，输入换成打字、话筒暂停）与恢复（`restore`）、打字输入（`sendText`）。通话页和聊天页悬浮窗都只是它的视图 |
| 装配 | `providers/voice_call_providers.dart`、`providers/voice_call_settings.dart` | 按角色音色预设取 Fish 音色；按设置的识别来源（自动／本地／阿里云，只存本机）选识别器 |
| 界面 | `lib/src/ui/features/voice_call/pages/voice_call_page.dart` | 参照 Telegram：全屏渐变（接通前蓝紫、接通后蓝绿、结束灰），大头像在角色说话时有波纹，名字与计时白字，背景用角色的聊天背景（没有则用全局壁纸）加深色遮罩；底部扬声器／挂断／话筒三个毛玻璃圆按钮，字幕开关和「打字」是「在听」下面的小胶囊，关掉扬声器或话筒时按钮上方出现提示胶囊。关扬声器是让角色立刻无声、通话和字幕照常（播放插件没有音量接口，靠重建播放流、把没播的部分按静音重推实现，计时不变）；手机上的听筒／外放切换还没做。聊天页顶栏电话按钮进入（`MoeWorkspace.open`），离开即挂断并存档（点「打字」收成悬浮窗除外）；全局或角色关掉语音插件时不显示按钮 |
| | `lib/src/ui/features/voice_call/widgets/voice_call_floating_window.dart`、`widgets/voice_call_live_messages.dart` | 打字模式：通话页字幕旁的「打字」胶囊把通话收成聊天页右上角的可拖动小窗（正中是禁用的话筒，下面是时长，点一下回到通话、话筒恢复）。聊天输入框提示「通话中，打字给对方」，发出的字经 `sendText` 进通话，和识别结果走同一条回复链路并写进同一份逐句记录，不写 messages 表、不进主对话上下文；图片和文件不收。通话进行中聊天列表把逐句记录投影成普通样子的临时气泡，长按只有复制和删除（没有编辑、重新生成、引用、多选）；删除只是不再显示，通话记录和摘要不变。挂断存档后换成通话气泡。收起后关掉聊天页或切到别的角色即挂断 |
| | `lib/src/ui/features/voice_call/pages/voice_call_settings_page.dart` | 语音插件页里的「语音通话」子页面：识别来源三选一，并显示每个来源当前能不能用。通话属于语音插件，不单独做插件 |
| | `lib/src/ui/features/voice_call/widgets/call_record_bubble.dart`、`pages/call_transcript_page.dart` | 聊天里的通话气泡（电话图标＋时长），点开是只读逐句记录 |

### 通话记录存储

- 聊天里的气泡是一条 `role = user` 的普通消息，块为 `CallRecordBlock`（`TextBlock` 子类，JSON 里带 `callRecord: {callId, durationMs, summary?, turns?}`）。逐句记录 `turns`（`role`、`text`、`interrupted`）是气泡的附属数据，随聊天走云同步和局域网同步；块的文字内容只有标签和摘要，模型看不到逐句原话（2026-10-12 用户修订，之前只存本机）。
- 角色主动来电没接（2026-10-14，主动关怀方案 12 §13）：以角色名义写一条 `role = assistant` 的气泡，块为 `CallRecordBlock.missed`（`callRecord.missed = true`，时长 0，无逐句记录），显示「未接来电」、不可点，模型看到 `[未接的语音通话]`。接听时 `ScriptedOpeningReplyGenerator` 让角色第一句直接说预生成的开场白，之后照常由模型生成。
- 2026-10-12 之前的通话：记录在本机 `call_sessions`／`call_turns`（数据库 v22，随角色删除级联删除），记录页回退只读这两张表；新通话不再写入。别的设备点开这类旧气泡会提示记录只在通话那台设备上。
- 挂断后，后台会整理通话摘要并更新气泡（`attachCallSummary`：气泡仍有效且仍是这通电话才写，不改会话预览和时间）。之后模型看到的文字内容是 `[语音通话 03:21]` 加一行「通话摘要：……」；摘要写好之前只有标签。摘要失败只记日志，不影响气泡。

第一批的限制：

- 默认半双工：角色在想或在说的时候，麦克风不送去识别，避免外放时角色自己打断自己。能打断的全双工要等回声消除在真机上验证后再打开（`allowBargeIn`）。桌面端目前没有可用的回声消除，做全双工前先看下面「全双工前置条件」。
- 流式合成只接了 Fish Audio；角色的音色预设如果是其它供应商，会提示暂不支持。
- 模型请求不能中途取消，打断后只是不再转发后续文字。
- 诊断日志（`VoiceCall` 来源）只记阶段、字数、耗时和麦克风电平，不记用户说的内容。
- 每轮通话会在对话轨迹里开一轮（会话标识 `voice_call_<会话 id>`，来源 `VoiceCall`），调试中心「对话日志」能看到每轮请求和回复，与打字聊天一样；之前只写原始请求日志，对话日志里看不到（2026-10-12 补）。

## 实测数据

探针：[`tool/voice_call_latency_probe.dart`](../../../tool/voice_call_latency_probe.dart)。默认读取 Mac 版 AIcove 已配置的密钥，不会打印密钥。模型用 DeepSeek `deepseek-flash`，TTS 用 Fish Audio `s2.1-pro-free` 的 PCM 24 kHz 输出，ASR 用阿里云 `paraformer-realtime-v2`。

| 指标 | 结果 |
|---|---|
| 从模型收到文字到听见首块音频（Fish `balanced`，4 轮） | 平均 1.21 秒（0.97～1.48） |
| 同上，Fish `normal` | 平均 1.57 秒，出现过 0.34 秒卡顿 |
| 对照：等整段文字生成完再一次性合成 | 6.6～8.3 秒 |
| ASR 判断说完（`max_sentence_silence=500`） | 说完后约 0.66 秒出最终结果，转写全对 |
| ASR，阈值 300 ms | 在句中逗号停顿处就截断了（只识别出“我今天下午去面试了。”），不可用 |
| 端到端：说完话 → 听见首块音频 | 平均 2.74 秒（2.49～3.13） |
| Fish WebSocket 建连并发送 start | 约 0.9 秒，需在通话接通时预先完成 |

复现命令（在 `apps/aicove_flutter/` 下运行）：

```bash
tool/flutterw --dart run tool/voice_call_latency_probe.dart --runs 3 --baseline
tool/flutterw --dart run tool/voice_call_latency_probe.dart --runs 3 --asr <16k单声道.wav>
tool/flutterw --dart run tool/voice_call_latency_probe.dart --keepalive 0,15,45,90,180,300 --ping 20
```

## 连接保活与打断（Fish Audio）

| 场景 | 结果 |
|---|---|
| 一条连接跑多轮（每轮 `text`＋`flush`，不发 `stop`） | 可行，每轮首块音频 1.1～1.9 秒 |
| 不发心跳 | 空闲约 30 秒后被服务器断开（close code 1002） |
| 每 20 秒发一次 WebSocket ping | 空闲 45、90、180、300 秒后仍可用，延迟不变 |
| 打断：已 flush 的文字 | 即使不再发新文字，已排队的音频仍会继续推送（实测打断后 6 秒内又推来约 12 秒长的音频）；协议没有取消事件 |

由此得出的约束：

1. 通话期间保持一条 Fish 连接，每 20 秒发一次 ping。
2. 打断时直接关掉当前连接、清空播放队列，换到提前建好的备用连接，避免约 0.9 秒的重新握手。已排队但没播出的音频是否计费还没核实。
3. 阿里云 ASR 的静音阈值不能低于 500 ms。想要更快接话，应改用语义判断（见下文的开源参考），不能靠继续压低静音阈值。

## 语音识别：三种来源

用户在「语音 · 语音通话」里选择识别来源（自动／本地／阿里云，只存本机），通话逻辑只依赖 `SpeechRecognizerPort`（`lib/src/features/voice_call/domain/speech_recognizer_port.dart`）。

| 来源 | 适配器 | 现状 |
|---|---|---|
| 本地离线（应用内下载模型） | `SherpaLocalSpeechRecognizer`：Silero VAD 判断说完，SenseVoice 识别整句，跑在后台 isolate | 已实现，在 Mac 的 `flutter test` 中用真实模型测试通过；Mac、Android 能构建，但应用内还没实际运行过；模型下载和管理还没做 |
| 云端（用户自填密钥） | `AliyunRealtimeSpeechRecognizer`：百炼 Paraformer 实时识别 | 已实现，有协议测试；其它云端厂商以后按同一端口接入 |
| 系统语音识别 | 未实现（候选：`speech_to_text` 包，调用 Android SpeechRecognizer 和 Apple Speech 框架） | 只做了调研，见下文 |

### 本地模型选型（2026-10-12）

基准脚本：[`tool/local_asr_benchmark.dart`](../../../tool/local_asr_benchmark.dart)。测试集共 8 段：4 段 macOS 系统中文语音，4 段 Fish 合成的多句回复，都有参考文本。指标按“去掉标点后的字错误率”计算。“说完→出结果”在音频时间线上测量，并计入解码耗时。

| 方案 | 下载体积 | 字错误率 | 说完→出结果（静音 0.5／0.3 秒） | 单句误切（0.3 秒，4 段系统语音） | 计算量（实时率） |
|---|---|---|---|---|---|
| 流式 zipformer small ctc | 20 MB | 21.2% | 0.62／0.54 秒 | 11 次 | 0.018 |
| 流式 X-ASR 160ms 带标点 | 127 MB | 6.2% | 1.16／0.82 秒 | 4 次 | 0.083 |
| **Silero VAD＋SenseVoice（采用）** | 158 MB＋2 MB | 7.1%～7.4% | 1.14／0.92 秒 | **0 次** | 0.055 |

结论：

- 默认采用 VAD＋SenseVoice，静音阈值 0.3 秒。它几乎不误切，准确率接近阿里云。缺点是没有中间结果，通话界面不能实时显示用户正在说的字。
- 小模型准确率太差，不予考虑。X-ASR 准确率最好，还带标点和中间结果，但遇到句中停顿容易误切；以后如果做语义轮次判断，可以重新评估。
- 实时率 0.055 表示 6 秒的话约需 0.3 秒解码，所以必须放在后台 isolate 里跑。
- VAD 判定开口时会吃掉第一个字的起音，适配器会从缓存里往前补 0.25 秒（pre-roll）。
- 0.3 秒只是“切段”阈值，不是“说完”阈值。真人句中停顿经常超过 0.3 秒（系统合成语音几乎没有停顿，所以基准没暴露）。第一次真机测试（10-12）就是句子被切开：前半句被当成整轮送去回复，后半句在半双工下被丢掉，用户感知为“识别不准”。现在引擎把最后一段之后再静默 0.6 秒（`userTurnGap`）才算这一轮说完，期间的段拼成一句，代价是每轮回复晚约 0.6 秒。
- 纯数字音量不影响 SenseVoice：把基准音频压到 3% 音量，字错率 6.2%，原音量 6.8%（`--gain 0.03`），所以不做音量归一化。

### 应用内实测（Mac 调试版，2026-10-12）

- 本地识别 + DeepSeek + Fish：两轮完整跑通。从用户说完到出第一个字约 2.4～3.3 秒，到听见第一块音频约 3.0～3.9 秒；合成连接 0.8～0.9 秒、识别器 1.6～1.8 秒在接通阶段完成。
- macOS 上 `record` 开启系统语音处理（回声消除）后，输入收到的全是零，真人说话也一样（2026-10-12 用户实测纠正；之前以为是外放的 `say` 被当回声消掉）。所以系统语音处理只在 Android／iOS 开，桌面端一律关闭（`callVoiceProcessingSupported`），桌面通话保持半双工。
- 调试版每次重新构建签名都会变，macOS 会再弹一次麦克风权限框。

### 依赖与平台注意

- `sherpa_onnx` 锁定在 1.13.8，各平台原生包通过 `dependency_overrides` 锁到同一版本，避免 Dart FFI 结构和原生库对不上。
- 不用 1.13.4：它自带的 macOS／iOS 原生库签名损坏，构建时被系统杀掉（见经验教训）。1.13.8 的 Web 插件要求 `web ^1.1`，和 `share_plus 9` 冲突；因为 Web 不是目标平台，所以通过 override 放开 `web` 的版本。
- 原生库体积（推理引擎，与是否下载模型无关）：Android arm64 约 27 MB（onnxruntime 22 MB＋sherpa 5 MB）；macOS 构建后约 27 MB（pub 包里的 58 MB 是 Intel＋Apple 芯片的 universal 原件，Xcode 构建时只保留 arm64）。
- 加载方式：应用内调用 `initBindings()`，macOS／iOS 从进程符号加载，Android 按库名加载。Dart 命令行会自动定位 pub 缓存里的库。`flutter test` 里无法自动定位，要传 `sherpa_onnx_<平台>-1.13.8/<平台>` 目录。

本地识别测试默认跳过，按下面的方式运行（Mac）：

```bash
AICOVE_SHERPA_MODELS=<模型目录> AICOVE_SHERPA_NATIVE=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.8/macos AICOVE_SHERPA_CLIP=<16k单声道.wav> tool/flutterw test test/features/voice_call
```

### 系统语音识别（第三条路）

拿不到第三方输入法的识别能力：Android 和 iOS 都没有开放“调用某个输入法的语音识别”的接口，hook 输入法也违反平台规则。能正规调用的是系统识别服务：

- Android `SpeechRecognizer`：调用系统设置里的默认识别服务。国行手机常常没有 Google 服务，有没有可用实现、能不能离线都取决于厂商；连续识别会在停顿后自动结束，还可能有提示音，不适合长时间通话。
- iOS／macOS `SFSpeechRecognizer`：中文可以离线识别；联网模式下单次识别有时长限制。
- 定位：零配置的兜底选项。它的隐私去向由系统或厂商决定，需要在界面上提示用户。

## 开源参考

| 项目 | 可借鉴 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（[Flutter 包](https://pub.dev/packages/sherpa_onnx)） | 本地离线 ASR＋Silero VAD，支持 Android、iOS、macOS、Windows；有流式中英 Zipformer／Paraformer 模型，官方 Flutter 示例用 `record` 采集 16 kHz PCM。可作为不上云的 ASR 选项 |
| [Pipecat](https://docs.pipecat.ai/learn/speech-input) | VAD 只判断有没有人声，Smart Turn 模型结合语调和语义判断说没说完；打断时向下游广播 flush，同时停 TTS、取消模型生成 |
| [LiveKit Agents](https://docs.livekit.io/agents/logic/turns/tuning/) | 打断最短时长默认 0.5 秒，过滤咳嗽等噪声；假打断超时 2 秒，期间没有转写就恢复播放；端点延迟可按会话自适应 |
| [TEN VAD／TEN Turn Detection](https://github.com/TEN-framework/ten-turn-detection) | 面向全双工对话的轻量 VAD 和语义轮次判断，有中文社区；许可证是 Apache 2.0 加额外限制，商用前要先核对 |

## 全双工前置条件（2026-10-12 记录）

全双工（角色说话时用户也能插话打断）必须先有可用的回声消除，否则麦克风会录进角色自己的声音，角色会自己打断自己。目前的状况：

- **macOS 不能用 `record` 自带的系统回声消除。** 打开 `echoCancel` 后，`record` 会对 AVAudioEngine 的输入节点调用 `setVoiceProcessingEnabled(true)`，之后输入回调全是零，真人说话也一样。所以桌面端现在一律关闭系统语音处理（`callVoiceProcessingSupported`），通话只能半双工。
- 原因还没有查实。推测是 Apple 的语音处理单元（VPIO）是输入输出一体的：它需要知道正在播什么才能消回声，而我们的播放走的是另一个音频设备（`mp_audio_stream`／miniaudio），没有经过同一个 AVAudioEngine。这只是推测，未验证。
- 桌面端要做全双工，可以试的方向（都未验证）：
  1. 写一个原生插件，让录音和播放走同一个 AVAudioEngine 并开启语音处理，播放就成了回声消除的参考信号。
  2. 用软件回声消除（例如 WebRTC 的音频处理模块），把播放的音频当参考信号，自己从麦克风里减掉。
  3. 只在插着耳机时允许打断，外放时仍半双工。
- 手机端（Android／iOS）仍开着系统回声消除，但外放时效果还没有在真机上验证；打开 `allowBargeIn` 前要先在一加 13T 上测。
- 排查“没声音”时先看日志里的「系统语音处理：开/关」和麦克风峰值：峰值一直是 0 时，先怀疑语音处理，再怀疑权限。

## 待办

- 真机测试：在一加 13T 上用 4G／Wi-Fi 重测端到端延迟。
- 手机听筒／外放切换（`audio_session` 有接口，但 `mp_audio_stream` 的播放用途可能不跟随通话路由，要真机验证）。
- 回声消除：手机外放时防止麦克风录进角色的声音，可以试 `record` 的系统回声消除，或先用耳机模式规避；桌面端见「全双工前置条件」。
- 应用内模型下载与管理（约 160 MB），放在「语音 · 语音通话」页；系统识别作为第四个识别来源。
- 逐句原文交给记忆 Agent 整理（ADR0074 决定 4 的后半）。
- 识别准确率对比：同一段真人录音分别走本地 SenseVoice、阿里云 Paraformer、本地 Paraformer-large，按字错率选默认来源。
- 一加 13T 上查看系统识别服务：ADB 未授权，暂时没查。
- 预测式生成：ASR 中间结果稳定时就先启动模型生成，用户继续说话再取消（LiveKit 有同类做法）。
