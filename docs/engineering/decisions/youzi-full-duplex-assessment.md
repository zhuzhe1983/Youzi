# Youzi 本地全双工语音：可行性与验收边界

日期：2026-09-07。负责人：Atlas（本地 Mac）。状态：**方案评估，不是全双工已通过验收**。
本次交付只修复 AVFAudio 回调崩溃；以下声学/插话增强尚未实现。

## 结论

采用 **macOS 原生 Voice Processing + 近端语音判定 + 可取消的对话状态机**
作为首选路线。先做好内建扬声器/麦克风，按具体设备开放资格；半双工作为显式备用。
不为此切换到云端 Realtime API，不把关闭麦克风称作全双工，不先引入第二套 AEC。

用户提供的另一项目截图使用 ALSA/aplay，其“PCM 时长 + 播放尾音保护后再恢复采集”
是半双工防回灌思路。不能据此推断 Youzi 使用 aplay 或存在完全相同的队列错误。

## 代码核查（来自当前交付分支，不是网络推测）

- `YouziLiveAudioEngine`：同一 `AVAudioEngine` 连接输入和 TTS player，启动前启用
  `setVoiceProcessingEnabled(true)`，检查输入/输出均启用；失败需显式选择半双工。
- 播放使用 `.dataPlayedBack`，不是“HTTP 返回完成/发送队列空”。`LiveVoicePlaybackPacing`
  仅估算排队量，不能证明扬声器播完，也不能估计房间混响何时消失。
- `LiveVoiceUtteranceDetector` 目前只是 RMS >= 0.018 连续 10 个 20ms 窗口；
  360ms pre-roll、660ms 静音结束、15s 上限。没有近端语音/残余远端回声判别。
  持续的残余回声或噪声同样可能触发 `speechStarted`，并打断自己的回复。
- `YouziLiveVoiceController.receive` 在非半双工时持续处理输入，检测到语音即取消旧轮。
  已有 turn/epoch 归属、TTS 取消、player stop、迟到 PCM 丢弃和工具审批交接。
- 半双工在非 listening 状态忽略输入，但自然播放完成和手动 interrupt 后都没有独立的
  声学尾音保护状态。此缺口与真正全双工的近端插话判定必须分开处理。
- ASR 仍是语句窗口 HTTP 调用，不是原生增量 ASR；LLM 和 TTS 的响应是流式。
  全双工指同时收听/播放与插话能力，不会自动消除语句结束/ASR/LLM 延迟。

## 原生能力核实与容易用错的 API

主依据为 Apple WWDC2019 Session 510、WWDC2023 Session 10235 与本机 SDK
`AVAudioIONode.h` / `AVAudioPlayerNode.h`。

1. Voice Processing 包含回声消除、噪声抑制、自动增益；只处理一条流不够，正确的
   输入/输出参考路径不可缺少。Apple 要求在停止引擎时切换此模式。
2. 双讲（double-talk）即双方同时发声，是回声消除必须验证的场景；不能用“已启用”
   标志替代高音量/混响/设备组合下的实测。核查 enabled、bypassed、AGC、设备和采样率
   可用于初始化诊断，但不能从这些标志计算回声抑制效果。
3. `setMutedSpeechActivityEventListener` 是**输入静音时**的说话提醒，不是全双工常开 VAD。
   不能为了接收该回调把麦克风静音，再宣称同时听说。
4. Apple 另有 HAL VAD，系统处理麦克风输入并提供语音检测事件。应先查询设备属性支持、
   作用范围与恢复要求；不能直接把一个设备的布尔事件视为所有路由均有的回声置信度。
   若不适用，再评估 AEC 后 PCM 上的语音 VAD。神经 VAD 本身也不是 AEC：AI 的回声
   同样是人声，仍需远端播放/残余回声信息与双讲策略。
5. `voiceProcessingOtherAudioDuckingConfiguration` 主要调低**其他非语音音频**。
   它不是 TTS 插话仲裁器。若需要“疑似插话时暂降 AI 音量”，应单独控制应用自己的
   player 增益，确认/排除后停止或恢复，不能误改系统全局音量。
6. 系统 Voice Processing 不支持 manual/offline rendering。离线真实 AVFAudio 回调测试
   可以验证线程/生命周期，**无法验证系统 AEC 或实际扬声器尾音**。

## 建议的产品状态机（待实现）

```text
收听 ──语句结束──> 识别/生成 ──PCM──> 播放（仍持续接收 AEC 后输入）
                                         │
                                 疑似近端语音
                                         ↓
                              保留 pre-roll / 确认插话
                                │              │
                           判定为回声       确认用户插话
                                │              ↓
                           继续原回复    停播放器 + 取消旧 TTS/自有 LLM 轮
                                               ↓
                                       新语句识别与后续任务
```

- 维护远端实际播放状态、输出设备/采样率/延迟、近端语音证据；不要只提高 RMS 阈值。
- 用短时、可取消的插话确认保留开头音节；只有确认后才永久取消旧回复。
  时长应通过测量确定，不能把某个毫秒数当作所有房间的固定正确值。
- 不用“识别文本与 AI 回复相同就丢弃”作唯一保护：用户可能复述、引用、纠正 AI。
- 打断后立即停止已排队音频，作废旧 epoch、取消仍在生成的请求；记录实际已播段落，
  避免下一轮假设用户听到了未播放的整段答案。已执行工具的副作用不能假装回滚，
  原有高风险操作的人工审批必须保留。
- 回声持续可疑、设备不支持或路由改变时给出明确状态：停止/重新初始化，提示切换
  半双工或耳机；不悄悄变成无 AEC 全双工。
- 单独完善半双工：自然播放完成以及手动打断后都要考虑输出/房间尾音，期间不提交
  录音，清空 VAD pre-roll 后恢复。该保护不是全双工实现，也不能用队列为空判断。

## 为什么暂不直接换 WebRTC AEC3

WebRTC 的 AudioProcessing 接口要求应用提供按时序对应的 render/reverse stream 与
capture stream，并正确处理帧长度、采样率、音量/延迟变化。Youzi 只做 Apple Silicon
macOS，原生链路已经存在，优先补足判定与真机验收的集成风险更小。

只有原生路线在目标设备上的双讲/残余回声实测不达标，才独立验证 AEC3。
那时应明确接管 render reference、重采样、延迟估计和设备变更，不默认串联两套 AEC。
这是一项工程取舍，**不是 AEC3 不支持 macOS，也不是已测得原生一定更好**。

## 上线前的可复现验收（以下是建议门槛，尚无通过数据）

1. 用户明确同意后启动；先内建扬声器/麦克风，再 USB/蓝牙组合。记录设备、系统版本、
   音量、房间/距离、voice-processing 状态、已加载模型和其他负载；默认不持久化音频。
2. 仅 AI 播放：普通与较高音量分别连续 10 分钟，**0 次自发提交/错误插话**。
3. 近端单讲与双讲：各至少 20 次，包括“停一下/换成英文/先别执行”、复述 AI 原句、
   轻声、键盘噪声；目标至少 19/20 正确响应，确认后旧 PCM 不得继续/恢复播放。
4. 测量真实用户起声→扬声器停止的 p50/p95，首轮目标 p95 <= 500ms（不是已达指标）；
   同时记录误打断率、漏检率和开头音节是否保留，不能只追求更低延迟。
5. 分别测量语句结束、ASR 完成、LLM 首字、TTS 首 PCM、设备首个可闻输出。
   当前既有 6.564s“最后输入帧→首 PCM”的软件链路结果不符合即时对白体验；
   不能拿独立 TTS 首包或全双工开关替代整链路响应时间。
6. 自然播完、手动停止、取消后迟到包、切换设备、睡眠/恢复、关闭窗口、权限拒绝、
   服务失联与工具审批均不得崩溃或继续偷偷录音。只有通过的具体路由才能标注可用。

## 官方资料

- Apple, WWDC2019, *What's New in AVAudioEngine*：
  https://developer.apple.com/videos/play/wwdc2019/510/
- Apple, WWDC2023, *What's new in voice processing*（含 HAL VAD、muted speech 与 ducking）：
  https://developer.apple.com/videos/play/wwdc2023/10235/
- Apple API, `setVoiceProcessingEnabled(_:)`：
  https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
- WebRTC 官方 AudioProcessing API（核查时 main，使用时应锁定 commit）：
  https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h

后续实施需新建独立分支；不要把尚未测量的 AEC/VAD 更换混入崩溃热修复。
