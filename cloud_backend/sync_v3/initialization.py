"""Schema and persistent-key validation for the public sync process."""
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .models import Installation, Entity, Snapshot, Receipt
from .reads import backfill_read_index


def validate_installation(db, vault):
    installation = db.get(Installation, 1)
    if installation is None:
        # Also validate stores created before the installation marker existed.
        for model, field in ((Entity, 'document'), (Snapshot, 'manifest'), (Receipt, 'result')):
            row = db.scalar(select(model).limit(1))
            if row:
                vault.open(getattr(row, field))
        try:
            with db.begin_nested():
                db.add(Installation(id=1, schema_version=1,
                                     key_check=vault.seal({'service': 'aicove-sync-v3'})))
                db.flush()
        except IntegrityError:
            pass
        installation = db.get(Installation, 1, populate_existing=True)
    if installation.schema_version != 1:
        raise RuntimeError('Unsupported cloud schema version; use the matching server release')
    if vault.open(installation.key_check) != {'service': 'aicove-sync-v3'}:
        raise RuntimeError('Invalid cloud encryption key')
    db.commit()
    backfill_read_index(db, vault)
