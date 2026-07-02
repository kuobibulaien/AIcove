"""提示词默认值源码管理面板 API。

仅负责 prompts + variables 的读写与 Dart 常量再生。Agent 与节点图的管理已统一收敛到
`agent_context_admin_api`。
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from prompt_defaults_codegen import (
    DART_PATH,
    JSON_PATH,
    PromptCodegenError,
    generate,
    generate_from_document,
    load_document,
)

router = APIRouter()

PANEL_PATH = Path(__file__).resolve().parent / 'prompt_defaults_admin_panel.html'


def _build_payload(document: dict[str, Any], *, message: str | None = None) -> dict[str, Any]:
    json_stat = JSON_PATH.stat()
    dart_stat = DART_PATH.stat() if DART_PATH.exists() else None
    return {
        'message': message,
        'document': document,
        'jsonPath': str(JSON_PATH),
        'dartPath': str(DART_PATH),
        'promptCount': len(document.get('prompts', [])),
        'variableCount': len(document.get('variables', [])),
        'jsonUpdatedAt': json_stat.st_mtime,
        'dartUpdatedAt': dart_stat.st_mtime if dart_stat else None,
    }


def _load_or_500() -> dict[str, Any]:
    try:
        return load_document()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f'读取提示词文档失败：{exc}') from exc


def _save_or_400(document: dict[str, Any], *, message: str) -> dict[str, Any]:
    try:
        generate_from_document(document)
    except PromptCodegenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f'保存提示词文档失败：{exc}') from exc
    return _build_payload(document, message=message)


@router.get('/document')
async def get_document():
    """读取源码里的默认提示词文档。"""
    return _build_payload(_load_or_500())


@router.put('/document')
async def save_document(payload: dict[str, Any]):
    """保存源码里的默认提示词文档并重新生成 Dart 常量。"""
    document = payload.get('document')
    if not isinstance(document, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含 document 对象')
    document.pop('agents', None)
    return _save_or_400(document, message='保存成功，已同步更新 Dart 内置默认值。')


@router.post('/regenerate')
async def regenerate_document():
    """根据现有 JSON 重新生成 Dart 常量文件。"""
    try:
        generate()
        document = load_document()
    except PromptCodegenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f'重新生成失败：{exc}') from exc
    return _build_payload(document, message='重新生成完成。')


@router.get('/panel', include_in_schema=False)
async def get_panel():
    """返回管理面板。"""
    if not PANEL_PATH.exists():
        raise HTTPException(status_code=404, detail=f'面板文件不存在：{PANEL_PATH}')
    return FileResponse(
        PANEL_PATH,
        media_type='text/html; charset=utf-8',
        headers={'Cache-Control': 'no-store'},
    )
