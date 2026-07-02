# Backend Directory Structure

## 主目录

```text
cloud_backend/
  main.py                         # 主入口，挂载路由和静态站点
  database.py                     # 数据库连接
  models.py                       # SQLAlchemy 模型
  *_api.py                        # API 路由模块
  prompt_defaults_admin_panel.html
  data/                           # 运行期数据
```

## 模块规则

- 新 API 优先拆到独立 `*_api.py`，再在 `main.py` 挂载。
- 数据模型集中在 `models.py`，除非模块已明确独立。
- 管理面板当前是零依赖单文件 HTML，改动时避免引入前端构建链。
- Agent Context Studio Phase 1 使用 JSON 文档存储，不入 DB、不生成 Dart。

