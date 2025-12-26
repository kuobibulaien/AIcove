"""信封加密模块（施工手册 7.1）

用于 providers.api_keys 的加密存储：
- KEK (Key Encryption Key): 服务端长期主密钥，来自环境变量
- DEK (Data Encryption Key): 每次写入生成的一次性数据密钥
- 加密算法: AES-256-GCM
"""
import os
import json
import base64
import secrets
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from typing import Optional


def get_kek() -> bytes:
    """获取主密钥 KEK（32 字节 = 256 位）"""
    kek_b64 = os.getenv("ENCRYPTION_KEK")
    if not kek_b64:
        # 开发环境使用默认值（生产环境必须配置）
        kek_b64 = "ZGV2ZWxvcG1lbnRfa2V5XzMyX2J5dGVzXw=="  # 32 bytes
    kek = base64.b64decode(kek_b64)
    if len(kek) != 32:
        raise ValueError("KEK 必须是 32 字节")
    return kek


def encrypt_envelope(plaintext: str) -> dict:
    """信封加密

    Args:
        plaintext: 要加密的明文（如 JSON 字符串）

    Returns:
        信封格式的加密数据：
        {
            "v": 1,
            "cipher": "AES-256-GCM",
            "dek_wrap": "KEK-AES-GCM",
            "nonce": "base64...",
            "ciphertext": "base64...",
            "tag": "base64...",  # GCM 模式下 tag 包含在 ciphertext 中
            "wrapped_dek": "base64..."
        }
    """
    kek = get_kek()

    # 1. 生成一次性 DEK
    dek = secrets.token_bytes(32)  # 256 位

    # 2. 用 DEK 加密数据
    data_nonce = secrets.token_bytes(12)  # GCM 推荐 96 位 nonce
    data_aesgcm = AESGCM(dek)
    ciphertext = data_aesgcm.encrypt(data_nonce, plaintext.encode('utf-8'), None)

    # 3. 用 KEK 包装 DEK
    wrap_nonce = secrets.token_bytes(12)
    kek_aesgcm = AESGCM(kek)
    wrapped_dek = kek_aesgcm.encrypt(wrap_nonce, dek, None)

    return {
        "v": 1,
        "cipher": "AES-256-GCM",
        "dek_wrap": "KEK-AES-GCM",
        "nonce": base64.b64encode(data_nonce).decode('ascii'),
        "ciphertext": base64.b64encode(ciphertext).decode('ascii'),
        "wrap_nonce": base64.b64encode(wrap_nonce).decode('ascii'),
        "wrapped_dek": base64.b64encode(wrapped_dek).decode('ascii')
    }


def decrypt_envelope(envelope: dict) -> str:
    """信封解密

    Args:
        envelope: encrypt_envelope 返回的信封数据

    Returns:
        解密后的明文
    """
    if envelope.get("v") != 1:
        raise ValueError(f"不支持的信封版本: {envelope.get('v')}")

    kek = get_kek()

    # 1. 解包 DEK
    wrap_nonce = base64.b64decode(envelope["wrap_nonce"])
    wrapped_dek = base64.b64decode(envelope["wrapped_dek"])
    kek_aesgcm = AESGCM(kek)
    dek = kek_aesgcm.decrypt(wrap_nonce, wrapped_dek, None)

    # 2. 用 DEK 解密数据
    data_nonce = base64.b64decode(envelope["nonce"])
    ciphertext = base64.b64decode(envelope["ciphertext"])
    data_aesgcm = AESGCM(dek)
    plaintext = data_aesgcm.decrypt(data_nonce, ciphertext, None)

    return plaintext.decode('utf-8')


def encrypt_api_keys(api_keys: list) -> str:
    """加密 API keys 列表

    Args:
        api_keys: API key 字符串列表

    Returns:
        加密后的 JSON 字符串（信封格式）
    """
    plaintext = json.dumps(api_keys)
    envelope = encrypt_envelope(plaintext)
    return json.dumps(envelope)


def decrypt_api_keys(encrypted: str) -> list:
    """解密 API keys

    Args:
        encrypted: encrypt_api_keys 返回的加密字符串

    Returns:
        API key 字符串列表
    """
    if not encrypted or encrypted == '[]':
        return []

    try:
        envelope = json.loads(encrypted)
        # 检查是否是信封格式
        if isinstance(envelope, dict) and envelope.get("v") == 1:
            plaintext = decrypt_envelope(envelope)
            return json.loads(plaintext)
        else:
            # 兼容旧格式（未加密的 JSON 数组）
            return envelope if isinstance(envelope, list) else []
    except Exception:
        return []


# 便捷函数：生成新的 KEK（用于初始化）
def generate_kek() -> str:
    """生成新的 KEK（base64 编码）

    用于初始化环境变量 ENCRYPTION_KEK
    """
    kek = secrets.token_bytes(32)
    return base64.b64encode(kek).decode('ascii')


if __name__ == "__main__":
    # 测试
    print("生成新的 KEK:")
    print(generate_kek())

    print("\n测试加密解密:")
    keys = ["sk-test-key-1", "sk-test-key-2"]
    encrypted = encrypt_api_keys(keys)
    print(f"加密后: {encrypted[:100]}...")
    decrypted = decrypt_api_keys(encrypted)
    print(f"解密后: {decrypted}")
    assert keys == decrypted, "加密解密测试失败"
    print("✅ 测试通过")
