"""Persistent server-side encryption. This is not end-to-end encryption."""
import json
import os
from cryptography.fernet import Fernet
from .contracts import canonical


class Vault:
    def __init__(self, key=None):
        key = key or os.getenv('SYNC_V3_ENCRYPTION_KEY')
        if not key:
            raise RuntimeError('SYNC_V3_ENCRYPTION_KEY must be configured and backed up')
        self.cipher = Fernet(key.encode() if isinstance(key, str) else key)

    def seal(self, value):
        return self.cipher.encrypt(canonical(value).encode()).decode()

    def open(self, value):
        return json.loads(self.cipher.decrypt(value.encode()))
