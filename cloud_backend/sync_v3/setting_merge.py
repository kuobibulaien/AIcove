"""Field edit clocks for settings; message history remains version protected."""
import json
import re

from .contracts import canonical

SETTING_KINDS = {'conversations', 'providers', 'settings'}
META = {'setting_times_version', 'setting_times'}
ABSENT = object()


def content(payload):
    return {k: v for k, v in payload.items() if k not in META}


def media_references(payload):
    referenced = set()
    def visit(value):
        if isinstance(value, dict):
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
        elif isinstance(value, str):
            if re.fullmatch(r'aicove-media://[0-9a-f]{64}', value):
                referenced.add(value.removeprefix('aicove-media://'))
            elif value.startswith(('{', '[')):
                try:
                    visit(json.loads(value))
                except ValueError:
                    pass
    visit(content(payload))
    return referenced


def _fields(kind, payload):
    if kind in {'conversations', 'providers'}:
        row = payload.get('row')
        if not isinstance(row, dict):
            return None
        identity = {k: v for k, v in content(payload).items() if k != 'row'}
        identity['identity'] = {k: row[k] for k in ('id', 'created_at') if k in row}
        fields = {k: v for k, v in row.items() if k not in {'id', 'created_at', 'updated_at'}}
        return identity, fields, False
    if payload.get('storage') != 'preference':
        return None
    value = payload.get('json_value')
    encoded = False
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
            if isinstance(decoded, dict):
                value, encoded = decoded, True
        except ValueError:
            pass
    fields = value if isinstance(value, dict) else {'value': value}
    identity = {k: v for k, v in content(payload).items() if k != 'json_value'}
    identity['object_value'] = isinstance(value, dict)
    return identity, fields, encoded


def _clock(times, field):
    value = times.get(field, {})
    return value.get('at_ms', 0), value.get('device_id', '')


def explicit_setting_edit(kind, payload, current_payload, device, at_ms):
    """An explicit restore/choice edits now, including removed preference keys."""
    if kind not in SETTING_KINDS or (chosen := _fields(kind, payload)) is None:
        return payload
    current = _fields(kind, current_payload or {})
    old_times = (current_payload or {}).get('setting_times', {})
    chosen_times = payload.get('setting_times', {})
    at_ms = max(at_ms, max((stamp['at_ms'] + 1 for stamp in
                            [*old_times.values(), *chosen_times.values()]), default=0))
    fields = set(chosen[1]) | set(chosen_times) | set(old_times)
    if current is not None:
        fields.update(current[1])
    return {**payload, 'setting_times_version': 1,
            'setting_times': {field: {'at_ms': at_ms, 'device_id': device} for field in fields}}


def merge_settings(kind, current, incoming, blob_ids, media_ids):
    if (kind not in SETTING_KINDS or current['deleted']
            or incoming.get('setting_times_version') != 1
            or current['payload'].get('setting_times_version') != 1
            or set(blob_ids) != set(current['blob_ids'])):
        return None
    old = current['payload']
    a, b = _fields(kind, old), _fields(kind, incoming)
    if a is None or b is None or a[0] != b[0]:
        return None
    old_times, new_times = old['setting_times'], incoming['setting_times']
    fields, times = {}, {}
    for field in sorted(set(a[1]) | set(b[1]) | set(old_times) | set(new_times)):
        left, right = a[1].get(field, ABSENT), b[1].get(field, ABSENT)
        lc, rc = _clock(old_times, field), _clock(new_times, field)
        same = (left is ABSENT and right is ABSENT) or (
            left is not ABSENT and right is not ABSENT and canonical(left) == canonical(right))
        if not same and (lc[0] == rc[0] == 0 or lc == rc):
            # Unknown legacy edit times and inconsistent equal stamps do not
            # authorize overwriting either value.
            return None
        use_right = rc > lc
        value = right if use_right else left
        stamp = new_times.get(field) if use_right else old_times.get(field)
        if value is not ABSENT:
            fields[field] = value
        if stamp is not None:
            times[field] = stamp
    payload = dict(old)
    if kind in {'conversations', 'providers'}:
        row = {**a[0]['identity'], **fields}
        dates = [p['row'].get('updated_at') for p in (old, incoming)]
        if any(date is not None for date in dates):
            row['updated_at'] = max(date for date in dates if date is not None)
        payload['row'] = row
    else:
        value = fields if a[0]['object_value'] else fields.get('value')
        payload['json_value'] = canonical(value) if a[2] else value
    payload['setting_times'] = times
    # Only surviving references belong to the merged document. In particular,
    # a newer clear must not keep the previous wallpaper as a dependency.
    allowed = set(media_ids) | set(current.get('media_ids', []))
    return payload, sorted(media_references(payload) & allowed)
