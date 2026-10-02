"""The General page is device-local, including historical sync documents."""
import json
from .contracts import canonical
from .setting_merge import media_references

LOCAL_GENERAL_SETTINGS = {
    'message_chunking_enabled', 'message_format_config',
    'stream_segment_delay_seconds', 'chat_display_style',
    'text_scale_factor', 'ui_scale_factor', 'image_preview_scale',
    'windows_window_controls_side', 'chat_background_color',
    'global_background_color', 'is_dark_mode', 'use_system_theme',
    'hide_user_avatar', 'expand_audio_text', 'skip_vision_compat_dialog',
    'interface_skin', 'accent_color', 'glass_effect_enabled',
    'glass_blur_sigma', 'use_liquid_glass',
    'user_name', 'user_avatar',
}


def project_payload(kind, payload):
    if (kind != 'settings' or payload.get('storage') != 'preference'
            or payload.get('key') != 'aicove.ui_models.v1'):
        return payload
    value = payload.get('json_value')
    encoded = isinstance(value, str)
    if encoded:
        try:
            value = json.loads(value)
        except ValueError:
            return payload
    if not isinstance(value, dict):
        return payload
    result = dict(payload)
    value = {k: v for k, v in value.items() if k not in LOCAL_GENERAL_SETTINGS}
    result['json_value'] = canonical(value) if encoded else value
    if 'setting_times' in result:
        result['setting_times'] = {k: v for k, v in result['setting_times'].items()
                                   if k not in LOCAL_GENERAL_SETTINGS}
    return result


def public_document(document):
    if document is None:
        return None
    result = dict(document)
    result['payload'] = project_payload(result['kind'], result['payload'])
    if (result['kind'] == 'settings' and result['payload'].get('key') == 'aicove.ui_models.v1'):
        result['media_ids'] = sorted(set(result.get('media_ids', [])) & media_references(result['payload']))
    if result['kind'] == '_conflicts':
        payload = dict(result['payload'])
        payload['incoming'] = public_document(payload['incoming'])
        payload['current'] = public_document(payload['current'])
        result['payload'] = payload
    return result
