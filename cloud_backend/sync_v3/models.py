"""Additive v3 tables. Legacy records remain untouched during rollout."""
from sqlalchemy import Column, Integer, BigInteger, String, Text, ForeignKey, Boolean, Index
from database import Base


class Installation(Base):
    __tablename__ = 'sync3_installation'
    id = Column(Integer, primary_key=True)
    schema_version = Column(Integer, nullable=False)
    key_check = Column(Text, nullable=False)


class Account(Base):
    __tablename__ = 'sync3_accounts'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    epoch = Column(String(36), nullable=False)
    cursor = Column(BigInteger, nullable=False, default=0)


class Entity(Base):
    __tablename__ = 'sync3_entities'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    kind = Column(String(50), primary_key=True)
    entity_id = Column(String(200), primary_key=True)
    version = Column(BigInteger, nullable=False)
    deleted = Column(Boolean, nullable=False, default=False)
    document = Column(Text, nullable=False)  # encrypted, including tombstones


class Change(Base):
    __tablename__ = 'sync3_changes'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    seq = Column(BigInteger, primary_key=True)
    kind = Column(String(50), nullable=False)
    entity_id = Column(String(200), nullable=False)
    document = Column(Text, nullable=False)


class Receipt(Base):
    __tablename__ = 'sync3_receipts'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    op_id = Column(String(100), primary_key=True)
    request_hash = Column(String(64), nullable=False)
    result = Column(Text, nullable=False)  # encrypted, no plaintext operation log


class ReadEntry(Base):
    """Small rebuildable index; original encrypted revisions stay in Change."""
    __tablename__ = 'sync3_read_index'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    seq = Column(BigInteger, primary_key=True)
    kind = Column(String(50), nullable=False)
    entity_id = Column(String(200), nullable=False)
    owner_id = Column(String(200))
    created_at = Column(BigInteger, nullable=False, default=0)
    hidden = Column(Boolean, nullable=False, default=False)
    message_snapshot = Column(Boolean, nullable=False, default=False)
    __table_args__ = (Index('sync3_read_entity_seq', 'user_id', 'kind', 'entity_id', 'seq'),)


class Blob(Base):
    __tablename__ = 'sync3_blobs'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    digest = Column(String(64), primary_key=True)
    size = Column(BigInteger, nullable=False)


class Snapshot(Base):
    __tablename__ = 'sync3_snapshots'
    user_id = Column(Integer, ForeignKey('users.id'), primary_key=True)
    snapshot_id = Column(String(36), primary_key=True)
    name = Column(String(100), nullable=False)
    cursor = Column(BigInteger, nullable=False)
    created_at = Column(BigInteger, nullable=False)
    manifest = Column(Text, nullable=False)
