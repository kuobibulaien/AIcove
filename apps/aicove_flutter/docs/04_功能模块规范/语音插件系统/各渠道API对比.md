# 各渠道 API 对比

> 2026-01-31 整理
> 方便后续接入新渠道时快速对比差异

---

## 一、音色管理 API 对比

### 1.1 获取音色列表

| 渠道 | 接口 | 请求方式 | 返回内容 |
|------|------|---------|---------|
| 硅基流动 | `/v1/audio/voice/list` | GET | 用户上传的音色列表 |
| 阿里云 Qwen-TTS | `/api/v1/services/audio/tts/customization` | POST `action=list` | 已创建的音色列表 |
| 阿里云 CosyVoice | 同上 | POST `action=list_voice` | 已创建的音色列表（含状态） |
| MiniMax | `/v1/get_voice` | POST `voice_type=all` | system_voice + voice_cloning 两个列表 |

### 1.2 创建/上传音色

| 渠道 | 接口 | 请求方式 | 步骤数 | 关键参数 |
|------|------|---------|--------|---------|
| 硅基流动 | `/v1/uploads/audio/voice` | POST multipart | 1步 | file, model, customName, text |
| 阿里云 Qwen-TTS | 同上 customization 端点 | POST JSON | 1步 | action=create, audio.data (Base64/URL), preferred_name, target_model |
| 阿里云 CosyVoice | 同上 | POST JSON | 1步+轮询 | action=create_voice, url, prefix, target_model |
| MiniMax | `/v1/files/upload` → `/v1/voice_clone` | POST multipart → POST JSON | **2步** | step1: file+purpose; step2: file_id+voice_id |

### 1.3 删除音色

| 渠道 | 接口 | 请求方式 | 参数 |
|------|------|---------|------|
| 硅基流动 | `/v1/audio/voice/deletions` | POST | uri (音色URI) |
| 阿里云 Qwen-TTS | 同 customization 端点 | POST | action=delete, voice |
| 阿里云 CosyVoice | 同上 | POST | action=delete_voice, voice_id |
| MiniMax | `/v1/voice/delete` | POST | voice_id |

---

## 二、语音合成 API 对比

| 渠道 | 接口 | 请求方式 | 音色参数 | 输出格式 |
|------|------|---------|---------|---------|
| 硅基流动 | `/v1/audio/speech` | POST JSON | voice (URI 或 model:id) | mp3 二进制 |
| 阿里云 Qwen-TTS | dashscope HTTP 端点 | POST JSON | parameters.voice | mp3/wav 二进制 |
| 阿里云 Qwen-TTS (realtime) | WebSocket | WS | voice | PCM 流 → 转 WAV |
| 阿里云 CosyVoice | 同 Qwen-TTS HTTP | POST JSON | parameters.voice | mp3/wav 二进制 |
| MiniMax | `/v1/t2a_v2` | POST JSON | voice_setting.voice_id | hex 编码音频 |

---

## 三、认证方式对比

| 渠道 | 认证方式 | Header |
|------|---------|--------|
| 硅基流动 | Bearer Token | `Authorization: Bearer {api_key}` |
| 阿里云 | Bearer Token | `Authorization: Bearer {api_key}` |
| MiniMax | Bearer Token | `Authorization: Bearer {api_key}` |

所有渠道认证方式一致，统一用 Bearer Token。

---

## 四、音色 ID 格式对比

| 渠道 | ID 格式 | 示例 | 是否可自定义 |
|------|---------|------|------------|
| 硅基流动（预置） | `model:voiceId` | `FunAudioLLM/CosyVoice2-0.5B:alex` | 否 |
| 硅基流动（用户） | `speech:xxx:xxx` | `speech:my-voice:abc123` | 否（系统生成） |
| 阿里云 Qwen-TTS | 自定义名称 | `myvoice_20260131` | 是（preferred_name） |
| 阿里云 CosyVoice | 系统生成 | `cosyvoice-clone-v1-xxx` | 否 |
| MiniMax | 自定义字符串 | `MyCharacterVoice001` | 是（8-256字符） |

---

## 五、限制条件对比

| 渠道 | 文件大小限制 | 时长限制 | 格式要求 | 其他限制 |
|------|------------|---------|---------|---------|
| 硅基流动 | 无明确限制 | 无明确限制 | mp3/wav/ogg/opus | 需要参考文本 |
| 阿里云 Qwen-TTS | 10MB | 无明确限制 | mp3/wav/m4a/ogg | 名称仅字母数字下划线 |
| 阿里云 CosyVoice | 10MB | 无明确限制 | mp3/wav/m4a/ogg | 只支持公网URL；名称仅小写字母数字 |
| MiniMax | 20MB | 10秒-5分钟 | mp3/m4a/wav | 需实名认证；7天临时音色策略 |
