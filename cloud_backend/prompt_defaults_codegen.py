#!/usr/bin/env python3
"""Prompt defaults code generator.

Source of truth: apps/aicove_flutter/assets/prompt_defaults.json
Generated file: apps/aicove_flutter/lib/src/core/prompts/prompt_builtin_defaults.g.dart
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = REPO_ROOT / 'apps' / 'aicove_flutter' / 'assets' / 'prompt_defaults.json'
DART_PATH = REPO_ROOT / 'apps' / 'aicove_flutter' / 'lib' / 'src' / 'core' / 'prompts' / 'prompt_builtin_defaults.g.dart'
JSON_INDENT = 2


class PromptCodegenError(RuntimeError):
    pass


def _dart_string_literal(text: str) -> str:
    if "'''" not in text:
        return "r'''" + text + "'''"
    if '"""' not in text:
        return 'r"""' + text + '"""'
    return json.dumps(text, ensure_ascii=False)


def _load_document() -> dict[str, Any]:
    if not JSON_PATH.exists():
        raise PromptCodegenError(f'Prompt defaults JSON not found: {JSON_PATH}')
    with JSON_PATH.open('r', encoding='utf-8') as fp:
        doc = json.load(fp)
    if not isinstance(doc, dict):
        raise PromptCodegenError('Prompt defaults JSON root must be an object')
    return doc


def _validate_prompt(prompt: dict[str, Any], seen_ids: set[str], seen_names: set[str]) -> None:
    prompt_id = prompt.get('id')
    dart_name = prompt.get('dartName')
    template = prompt.get('template')
    if not isinstance(prompt_id, str) or not prompt_id.strip():
        raise PromptCodegenError(f'Invalid prompt id: {prompt!r}')
    if not isinstance(dart_name, str) or not dart_name.strip():
        raise PromptCodegenError(f'Prompt {prompt_id!r} missing dartName')
    if not isinstance(template, str):
        raise PromptCodegenError(f'Prompt {prompt_id!r} missing template string')
    if prompt_id in seen_ids:
        raise PromptCodegenError(f'Duplicate prompt id: {prompt_id}')
    if dart_name in seen_names:
        raise PromptCodegenError(f'Duplicate prompt dartName: {dart_name}')
    seen_ids.add(prompt_id)
    seen_names.add(dart_name)


def _build_dart(doc: dict[str, Any]) -> str:
    prompts = doc.get('prompts')
    if not isinstance(prompts, list) or not prompts:
        raise PromptCodegenError('prompts must be a non-empty list')

    seen_ids: set[str] = set()
    seen_names: set[str] = set()
    normalized_prompts: list[dict[str, Any]] = []
    for raw in prompts:
        if not isinstance(raw, dict):
            raise PromptCodegenError('Each prompt entry must be an object')
        _validate_prompt(raw, seen_ids, seen_names)
        normalized_prompts.append(raw)

    lines: list[str] = [
        '// GENERATED CODE - DO NOT EDIT BY HAND.',
        '// Source: apps/aicove_flutter/assets/prompt_defaults.json',
        '',
        'library;',
        '',
        'class PromptBuiltinDefaults {',
        '  const PromptBuiltinDefaults._();',
        '',
    ]

    for prompt in normalized_prompts:
        description = (prompt.get('description') or '').strip()
        if description:
            lines.append(f"  /// {description}")
        lines.append(
            f"  static const String {prompt['dartName']} = {_dart_string_literal(prompt['template'])};"
        )
        lines.append('')

    lines.append('  static const List<String> ids = <String>[')
    for prompt in normalized_prompts:
        lines.append(f"    '{prompt['id']}',")
    lines.append('  ];')
    lines.append('')
    lines.append('  static String? templateById(String id) {')
    lines.append('    switch (id) {')
    for prompt in normalized_prompts:
        lines.append(f"      case '{prompt['id']}':")
        lines.append(f"        return {prompt['dartName']};")
    lines.append('      default:')
    lines.append('        return null;')
    lines.append('    }')
    lines.append('  }')
    lines.append('')
    lines.append('  static String requireTemplate(String id) {')
    lines.append('    final template = templateById(id);')
    lines.append("    if (template == null) {")
    lines.append("      throw ArgumentError('Unknown prompt id: $id');")
    lines.append('    }')
    lines.append('    return template;')
    lines.append('  }')
    lines.append('}')
    lines.append('')
    return '\n'.join(lines)


def load_document() -> dict[str, Any]:
    return _load_document()


def build_dart_for_document(doc: dict[str, Any]) -> str:
    return _build_dart(doc)


def write_document(doc: dict[str, Any]) -> Path:
    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    JSON_PATH.write_text(
        json.dumps(doc, ensure_ascii=False, indent=JSON_INDENT) + '\n',
        encoding='utf-8',
    )
    return JSON_PATH


def generate_from_document(doc: dict[str, Any]) -> Path:
    dart = _build_dart(doc)
    write_document(doc)
    DART_PATH.parent.mkdir(parents=True, exist_ok=True)
    DART_PATH.write_text(dart, encoding='utf-8')
    return DART_PATH


def generate() -> Path:
    doc = load_document()
    return generate_from_document(doc)


if __name__ == '__main__':
    output = generate()
    print(output)
