# 多模态协议适配手册（给内置 Agent 读）

> 2026-10-14 首版。用途：以后 AIcove 内置的「协议适配 Agent」读这份文档，按用户给的「厂商网址＋Key」自己写出一份自定义协议模板，专供该渠道使用。
> 当前状态：**只有调研和模板草案**，适配 Agent 本体、通用模板执行器都还没做。现有已落地的格式见文末「与现有代码的关系」。

## 1. 为什么要这份文档

多模态（生图、语音合成、语音识别、识图）没有统一协议：同一件事，各家的路径、鉴权头、字段名、返回形态、同步还是异步全都不一样，而且更新很快（本次调研时 OpenAI 已到 `gpt-image-2.5-*`，Gemini 生图参数也换过一轮写法）。客户端为每家写死适配器追不上。

方向：保留少量内置格式（OpenAI 兼容、NovelAI、ComfyUI、MiniMax、阿里云、Fish），其余厂商由 Agent 读本文＋读厂商官方文档，产出一份**声明式模板**（只有 JSON，没有代码），存进该渠道的 `customConfig`，由同一个通用执行器跑。

## 2. 协议差异的六个维度

适配任何一家，都只需要回答这六个问题。模板就是这六个答案的结构化记录。

| 维度 | 常见取值 | 例子 |
|---|---|---|
| 鉴权 | `Authorization: Bearer {key}`／自定义头／查询参数 | OpenAI、阿里用 Bearer；ElevenLabs 用 `xi-api-key`；Gemini 用 `x-goog-api-key` |
| 地址 | 固定路径／路径里带模型或音色 | Gemini `/models/{model}:generateContent`；ElevenLabs `/text-to-speech/{voice}` |
| 请求体 | JSON／multipart 表单 | 识别类几乎都是 multipart 上传文件 |
| 参数写法 | 尺寸 `1024x1024`／`1024*1024`／`2K`／宽高比 `16:9` | OpenAI 用 `x`，阿里用 `*`，方舟用 `2K`，Gemini 用比例 |
| 返回形态 | 二进制直出／JSON 内 base64／hex／URL 再下载 | OpenAI 语音二进制；MiniMax 语音 hex；阿里生图 URL（24 小时有效） |
| 同步性 | 同步／异步任务（提交→轮询）／WebSocket | 阿里万相、ComfyUI 异步；阿里实时识别、Qwen 实时合成走 WebSocket |

WebSocket 流式协议（阿里 Paraformer realtime、Qwen-TTS realtime、ElevenLabs stream-input）**不在模板范围内**，继续用手写适配器。模板只覆盖「一次 HTTP 请求」和「提交＋轮询」两种。

## 3. 各家基础请求体（2026-10-14 官方文档）

下面的 `{key}` `{prompt}` 等是占位符，含义见第 4 节。标「未实测」的只读了文档，没发过真实请求。

### 3.1 生图

**OpenAI `/v1/images/generations`**（未实测，[参考](https://developers.openai.com/api/reference/resources/images/methods/generate/)）

```json
POST {base}/images/generations
Authorization: Bearer {key}

{ "model": "{model}", "prompt": "{prompt}", "n": 1, "size": "1024x1024",
  "quality": "auto", "output_format": "png" }
```

- 返回 `data[].b64_json`。GPT Image 系列**只返回 base64**，`response_format` 只对已退役的 dall-e 有效。
- `gpt-image-2*` 起 `size` 可任意 `宽x高`（16 的倍数，比例 1:3～3:1，最大 3840x2160）；旧模型只认三档。
- 改图走 `/v1/images/edits`（multipart，字段 `image[]`）。
- 很多中转站／国内厂商「OpenAI 兼容」只兼容这个最小集：`model/prompt/n/size`，返回可能是 `url` 也可能是 `b64_json`，两种都要能取。

**Gemini 原生生图 `generateContent`**（未实测，[参考](https://ai.google.dev/gemini-api/docs/generate-content/image-generation)）

```json
POST {base}/v1beta/models/{model}:generateContent
x-goog-api-key: {key}

{ "contents": [{ "parts": [{ "text": "{prompt}" }] }],
  "generationConfig": { "responseModalities": ["TEXT", "IMAGE"],
    "imageConfig": { "aspectRatio": "16:9" } } }
```

- 返回 `candidates[0].content.parts[]` 里带 `inlineData.data`（base64）和 `mimeType` 的那一段；同一回复里可能混着文字。
- 写法在变：Vertex 文档用 `imageConfig.aspectRatio`，AI Studio 新文档出现了 `generationConfig.responseFormat.image.{aspectRatio,imageSize}`，另有新的 `/v1beta/interactions` 接口。**Agent 适配时必须以用户当下给的文档为准**，两种写法都可能遇到。
- 参考图：在 `parts` 里加 `{"inline_data": {"mime_type": "image/png", "data": "<base64>"}}`。

**阿里云百炼 万相／Qwen-Image（异步）**（未实测，[参考](https://help.aliyun.com/zh/model-studio/first-call-to-image-and-video-api)）

```json
POST https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis
Authorization: Bearer {key}
X-DashScope-Async: enable

{ "model": "{model}", "input": { "prompt": "{prompt}", "negative_prompt": "{negative_prompt}" },
  "parameters": { "size": "1024*1024", "n": 1 } }
```

- 提交返回 `output.task_id`；轮询 `GET /api/v1/tasks/{task_id}`，`output.task_status` 为 `SUCCEEDED` 时取 `output.results[].url`（24 小时有效，需立刻下载）。失败值 `FAILED`／`CANCELED`／`UNKNOWN`。官方建议 3～10 秒轮询一次。
- 尺寸写 `宽*高`（星号）。不带 `X-DashScope-Async` 会报「does not support synchronous calls」。
- `qwen-image-2.0` 系列另有同步接口 `multimodal-generation/generation`，请求体是 `input.messages[].content[].text`，与上面不同。

**火山方舟 Seedream**（未实测，[参考](https://www.volcengine.com/docs/82379/1541523)，参数仅从转载示例确认）

```json
POST https://ark.cn-beijing.volces.com/api/v3/images/generations
Authorization: Bearer {key}

{ "model": "{model}", "prompt": "{prompt}", "size": "2K",
  "response_format": "url", "watermark": false }
```

- 外形是 OpenAI 兼容，但 `size` 接受 `2K` 这类档位，`watermark` 默认开。返回 `data[].url` 或 `data[].b64_json`。

**已内置，不再展开**：NovelAI（`/ai/generate-image`，返回 ZIP）、ComfyUI（`/prompt`→`/history`→`/view`），见 [图片渠道适配说明](../绘图功能/图片渠道适配说明_20260306.md)。

### 3.2 语音合成（TTS）

**OpenAI `/v1/audio/speech`**（已内置，[参考](https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create)）

```json
POST {base}/audio/speech
Authorization: Bearer {key}

{ "model": "{model}", "input": "{text}", "voice": "{voice}",
  "response_format": "mp3", "speed": 1.0, "instructions": "{instructions}" }
```

- 直接返回音频二进制。`instructions`（语气描述）只对 `gpt-4o-mini-tts` 有效。`voice` 也可以是 `{"id": "voice_xxx"}` 自定义音色对象。

**Gemini TTS**（未实测，按 Google 语音生成指南整理，**接入前需再核对**）

```json
POST {base}/v1beta/models/{model}:generateContent
x-goog-api-key: {key}

{ "contents": [{ "parts": [{ "text": "{text}" }] }],
  "generationConfig": { "responseModalities": ["AUDIO"],
    "speechConfig": { "voiceConfig": { "prebuiltVoiceConfig": { "voiceName": "{voice}" } } } } }
```

- 返回 `candidates[0].content.parts[0].inlineData.data`：base64 的**裸 PCM**（16 bit、24 kHz、单声道），没有文件头，播放前要包一层 WAV 头。

**ElevenLabs**（未实测，[参考](https://elevenlabs.io/docs/api-reference/text-to-speech/convert)）

```json
POST https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128
xi-api-key: {key}

{ "text": "{text}", "model_id": "{model}" }
```

- 音色在路径里，格式在查询参数里，鉴权是自定义头——三个维度都和 OpenAI 不同，是检验模板表达力的好例子。返回二进制。

**MiniMax `/v1/t2a_v2`**（已内置）

```json
{ "model": "{model}", "text": "{text}", "stream": false,
  "voice_setting": { "voice_id": "{voice}", "speed": 1, "vol": 1, "pitch": 0 },
  "audio_setting": { "sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1 },
  "output_format": "hex" }
```

- 返回 JSON，音频在 `data.audio`，是 **hex 字符串**（不是 base64）。

**阿里云 CosyVoice／Qwen-TTS**（已内置）：CosyVoice 体为 `{model, input:{text}, parameters:{voice}}`；Qwen-TTS 走 `multimodal-generation/generation`，体为 `{model, input:{text, voice, language_type}}`。

**Fish Audio**（已内置）：`POST /v1/tts`，头 `model: {model}`，体 `{text, reference_id: {voice}, format: "mp3"}`，返回二进制。

### 3.3 语音识别（STT）

**OpenAI `/v1/audio/transcriptions`**（未实测，[参考](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)）

```
POST {base}/audio/transcriptions
Authorization: Bearer {key}
Content-Type: multipart/form-data

file=@{audio_file}   model={model}   language=zh   response_format=json
```

- 返回 `{"text": "..."}`。模型有 `whisper-1`、`gpt-4o-transcribe`、`gpt-4o-mini-transcribe`、`gpt-transcribe` 等；大量国内厂商兼容此接口。

**ElevenLabs `/v1/speech-to-text`**（未实测）：multipart，`file` + `model_id`（如 `scribe_v2`），头 `xi-api-key`，返回 `text`。

**Gemini**：没有专门识别接口，把音频当 `inline_data`（`audio/wav` 等）放进 `generateContent`，再用文字提示「逐字转写」。属于「识图／识音」那一类，走聊天格式。

**阿里 Paraformer 实时识别**（已内置）：WebSocket，不进模板。

### 3.4 识图／多模态输入（聊天格式内）

这部分已由三种聊天适配器处理，Agent 一般不需要动，只列出差异备查：

| 格式 | 图片片段写法 |
|---|---|
| OpenAI Chat | `{"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}` |
| OpenAI Responses | `{"type":"input_image","image_url":"data:...","detail":"auto"}` |
| Anthropic | `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"..."}}` |
| Gemini | `{"inline_data":{"mime_type":"image/png","data":"..."}}`（REST 也接受驼峰 `inlineData`） |

Gemini 内联数据整个请求上限 20 MB，超过要先走 File API。

## 4. 自定义协议模板草案

在现有语音 `tts_template`（[configurable_tts_synthesis_adapter.dart](../../../lib/src/features/plugins/tts/synthesis/configurable_tts_synthesis_adapter.dart)）基础上扩展，生图／合成／识别共用一种结构。**仅为草案，字段名在实现时可调整**。

```json
{
  "kind": "image | tts | stt",
  "request": {
    "method": "POST",
    "path": "/v1/text-to-speech/{voice}",
    "query": { "output_format": "mp3_44100_128" },
    "headers": { "xi-api-key": "{apiKey}" },
    "auth": "none | bearer",
    "bodyType": "json | multipart",
    "body": { "text": "{text}", "model_id": "{model}" }
  },
  "async": {
    "taskIdPath": "output.task_id",
    "poll": { "method": "GET", "path": "/api/v1/tasks/{taskId}" },
    "statusPath": "output.task_status",
    "successValues": ["SUCCEEDED"],
    "failureValues": ["FAILED", "CANCELED", "UNKNOWN"],
    "intervalSeconds": 5
  },
  "response": {
    "type": "binary | json",
    "valuePath": "data[*].b64_json",
    "encoding": "raw | base64 | hex | url",
    "mimeType": "audio/mpeg",
    "pcm": { "sampleRate": 24000, "channels": 1, "bitsPerSample": 16 },
    "errorPath": "error.message"
  }
}
```

占位符（执行器统一替换，独占整个字符串的数值占位符替换为数字，沿用 ComfyUI 绑定的规则）：

| 占位符 | 用于 | 说明 |
|---|---|---|
| `{apiKey}` `{model}` | 全部 | 渠道 Key、当前模型 |
| `{prompt}` `{negative_prompt}` `{width}` `{height}` `{size}` `{n}` `{seed}` | 生图 | `{size}` 由执行器按 `sizeFormat` 拼：`x`／`*`／比例 |
| `{text}` `{voice}` `{speed}` `{format}` `{instructions}` | 合成 | 与现有 tts_template 一致 |
| `{audio_file}` `{language}` | 识别 | multipart 文件字段 |
| `{taskId}` | 轮询 | 来自 `async.taskIdPath` |

要点：

- `response.encoding = url` 时执行器负责下载；`pcm` 存在时执行器补 WAV 头。
- `async` 缺省即同步。轮询总时长复用现有绘图预设超时；超时不重提交、不换供应商（与 ComfyUI、NovelAI 的「不静默降级」一致）。
- 模板里不允许出现真实 Key，只能写 `{apiKey}`；Key 仍从渠道读，模板可安全导出分享。

## 5. 给适配 Agent 的工作流程（未来实现时用）

1. 用户给：厂商文档网址（或 API 根地址）＋ Key ＋要接的能力（生图／合成／识别）。
2. Agent 读厂商官方文档，逐条回答第 2 节六个维度，先判断是否命中内置格式（OpenAI 兼容、MiniMax、阿里、Fish、NovelAI、ComfyUI）。命中就直接选内置格式，不写模板。
3. 不命中则按第 4 节写模板，挑一个最小参数集（只填必填字段＋尺寸／音色），其余放进「额外请求参数」由用户改。
4. 测活：用渠道「测试模型」的现有路径发一次最小请求（生图 1 张、合成「你好」、识别一段内置短音频），**发之前提示可能计费**。
5. 失败时读 `response.errorPath` 或原始返回，改模板重试，最多 3 轮；仍失败就把原始错误和模板交给用户，不猜。
6. 成功后模板写入该渠道 `customConfig`，`requestFormat` 记为 `custom_template`，只对这个渠道生效。

## 6. 与现有代码的关系

| 能力 | 现有入口 | 现状 |
|---|---|---|
| 生图 | `core/api/image_providers/`（OpenAI 兼容、NovelAI、ComfyUI） | OpenAI 兼容支持 `imageEndpoint`／`image_parameters` 覆盖，但不能改字段名、鉴权头、异步 |
| 语音合成 | `TtsRequestFormat` 注册表（ADR0081）＋ `custom_rest` 模板 | 模板只支持「JSON 体＋二进制返回」，不支持 JSON 内取音频、路径外的查询参数、异步 |
| 语音识别 | `voice_call/data/`（阿里实时、sherpa 本地） | 没有 HTTP 识别通道，OpenAI 兼容 transcriptions 未接 |

通用模板执行器落地时，`custom_rest` 应并入它（旧 `tts_template` 是新结构的子集，可无损迁移），避免两套模板并存。

## 7. 待办（未排期）

- 通用模板执行器（JSON 取值路径、base64／hex／url／pcm 解码、提交＋轮询）。
- 渠道「自定义协议」选项与模板编辑页（复用现有通用 JSON 编辑弹窗）。
- 内置适配 Agent 与测活闭环。
- 本文标「未实测」的接口，在有对应 Key 时逐个补一次真实请求。
