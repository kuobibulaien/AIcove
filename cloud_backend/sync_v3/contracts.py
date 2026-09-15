"""Wire contract v3. Revisions order changes; timestamps describe user history."""
import json
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

KINDS = {
    'conversations', 'messages', 'message_blocks', 'message_projection_mappings',
    'providers', 'memories', 'summarization_records', 'memory_tombstones',
    'diaries', 'topic_handoffs', 'settings', 'plugin_presets', 'contact_memory',
    'media_assets',
}
PROTOCOL_VERSION = 3
PAYLOAD_VERSION = 1
MAX_DOCUMENT_BYTES = 4 * 1024 * 1024


class Contract(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class MediaLocation(Contract):
    device_id: str = Field(min_length=1, max_length=100)
    path: str = Field(min_length=1, max_length=4096)


class MediaAsset(Contract):
    media_version: Literal[1] = 1
    media_id: str = Field(pattern=r'^[0-9a-f]{64}$')
    mime_type: str = Field(min_length=1, max_length=100)
    byte_length: int = Field(ge=0)
    created_at_ms: int = Field(ge=0)
    original_required: bool = False
    last_chat_at_ms: int = Field(default=0, ge=0)
    width: int | None = Field(default=None, gt=0)
    height: int | None = Field(default=None, gt=0)
    thumbnail_blob: str | None = Field(default=None, pattern=r'^[0-9a-f]{64}$')
    original_blob: str | None = Field(default=None, pattern=r'^[0-9a-f]{64}$')
    original_sha256: str | None = Field(default=None, pattern=r'^[0-9a-f]{64}$')
    locations: list[MediaLocation] = Field(default_factory=list, max_length=100)


class Mutation(Contract):
    op_id: str = Field(min_length=1, max_length=100)
    kind: str
    entity_id: str = Field(min_length=1, max_length=200)
    base_version: int = Field(ge=0)
    action: Literal['put', 'delete'] = 'put'
    payload_version: Literal[1] = 1
    payload: dict[str, Any] = Field(default_factory=dict)
    blob_ids: list[str] = Field(default_factory=list, max_length=500)
    media_ids: list[str] = Field(default_factory=list, max_length=500)

    @field_validator('kind')
    @classmethod
    def known_kind(cls, value):
        if value not in KINDS:
            raise ValueError('unsupported entity kind')
        return value

    @field_validator('payload')
    @classmethod
    def bounded_payload(cls, value):
        if len(canonical(value).encode()) > MAX_DOCUMENT_BYTES:
            raise ValueError('document too large')
        return value

    @field_validator('blob_ids', 'media_ids')
    @classmethod
    def valid_blobs(cls, value):
        if len(set(value)) != len(value):
            raise ValueError('duplicate blob reference')
        for item in value:
            if len(item) != 64 or any(c not in '0123456789abcdef' for c in item):
                raise ValueError('invalid blob digest')
        return value

    @model_validator(mode='after')
    def media_contract(self):
        if self.kind == 'media_assets' and self.action == 'put':
            media = MediaAsset(**self.payload)
            if media.media_id != self.entity_id:
                raise ValueError('media identity differs from entity ID')
            if media.original_sha256 and media.original_blob and media.original_blob != media.original_sha256:
                raise ValueError('original blob does not match its content digest')
            expected = {b for b in (media.original_blob, media.thumbnail_blob) if b}
            if set(self.blob_ids) != expected or self.media_ids:
                raise ValueError('media blob references do not match metadata')
        return self


class BlobInventory(Contract):
    digests: list[str] = Field(max_length=512)

    @field_validator('digests')
    @classmethod
    def valid_digests(cls, value):
        return Mutation.valid_blobs(value)


class Push(Contract):
    protocol_version: Literal[3] = 3
    epoch: str
    device_id: str = Field(min_length=1, max_length=100)
    mutations: list[Mutation] = Field(min_length=1, max_length=100)


class SnapshotCreate(Contract):
    name: str = Field(min_length=1, max_length=100)


class Restore(Contract):
    op_id: str = Field(min_length=1, max_length=100)
    device_id: str = Field(min_length=1, max_length=100)
    epoch: str
    expected_cursor: int = Field(ge=0)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)
