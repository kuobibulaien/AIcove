# 云同步服务（测试中）

AIcove 唯一的云端功能是云同步。此目录仅保留 `sync_v3/`、同步账号认证、数据库连接、测试与运行配置。API Key 由客户端自行配置，不再提供中心化 Key 配发、会员/额度、云触发器、云记忆执行或 Web 管理面板。

Flutter 已接入 v3；完整多端数据对齐与实机速度仍在测试，不以本地测试通过宣称验收完成。协议、账号维护、备份和附件规则见 [云同步 v3](sync_v3/README.md)。

## 本地运行

在 `cloud_backend/` 中执行，使用独立 Python 环境：

```bash
python -m pip install -r requirements-dev.txt
python -m sync_v3 init-config
python -m sync_v3 create-user --username tester
python -m uvicorn sync_v3.app:app --env-file .env --host 127.0.0.1 --port 8000
```

`init-config` 不覆盖既有 `.env`；账号命令交互读取密码。默认不开公开注册。保留登录、当前账号查询及同步账号停用/恢复能力，用于同步数据归属与访问隔离，不提供会员等级。

`main:app` 与 `python main.py` 兼容入口均使用同一套同步服务。`start.sh` / `start.ps1` 和 Docker 也只启动 v3；容器配置见 `docker-compose.yml`，配置字段见 `sync-v3.env.example`。

## 本地验证

在 `cloud_backend/` 执行：

```bash
PYTHONPATH="$PWD" python -m unittest discover -s tests -p 'test_*.py'
```

测试使用临时数据库、附件和虚构账号，不需要生产凭证。

## 清理边界与回滚

2026-09-13 按用户要求删除旧 v1/v2 同步及其他云端服务代码，数据库只注册同步账号和 v3 模型。已有数据库、旧表、附件、密钥、客户端队列未清理或迁移；旧会员列不再映射或参与业务。未部署线上服务。

本地改动前源码副本与清单保存在 `.codex-temp/cloud-retirement-20260913-172143/`（仓库根目录），可按清单逐文件恢复，避免覆盖并行改动。不要通过删除同步数据回滚代码。

默认提示词生成器已移到客户端 [tool/prompt_defaults_codegen.py](../apps/aicove_flutter/tool/prompt_defaults_codegen.py)，见 [提示词默认值系统](../apps/aicove_flutter/docs/提示词默认值系统.md)。
