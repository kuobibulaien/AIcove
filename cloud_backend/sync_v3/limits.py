"""Bound request bytes and expanded JSON before parsing nested documents."""
import zlib
from starlette.responses import JSONResponse
from starlette.middleware.gzip import GZipMiddleware


class RequestLimits:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http' or scope['method'] not in ('POST', 'PUT', 'PATCH'):
            return await self.app(scope, receive, send)
        if '/sync/v3/blobs/' in scope['path']:
            return await self.app(scope, receive, send)
        limit = 16 * 1024 * 1024 if '/sync/v3/' in scope['path'] else 64 * 1024

        async def reject(status, code, message):
            response = JSONResponse(status_code=status, content={'detail': {'code': code, 'message': message}})
            return await response(scope, receive, send)

        encoding = dict(scope['headers']).get(b'content-encoding', b'identity').lower()
        if encoding not in (b'identity', b'gzip'):
            return await reject(415, 'unsupported_encoding', '不支持的请求压缩格式')
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS) if encoding == b'gzip' else None
        chunks, size, wire_size = [], 0, 0
        try:
            while True:
                message = await receive()
                if message['type'] == 'http.disconnect':
                    return
                chunk = message.get('body', b'')
                wire_size += len(chunk)
                if wire_size > limit:
                    return await reject(413, 'request_too_large', '请求过大，请减小同步批次')
                if decoder:
                    chunk = decoder.decompress(chunk, limit - size + 1)
                size += len(chunk)
                if size > limit or (decoder and decoder.unconsumed_tail):
                    return await reject(413, 'request_too_large', '请求过大，请减小同步批次')
                chunks.append(chunk)
                if not message.get('more_body', False):
                    break
            if decoder and (not decoder.eof or decoder.unused_data):
                return await reject(400, 'invalid_gzip', '压缩请求不完整或格式无效')
        except zlib.error:
            return await reject(400, 'invalid_gzip', '压缩请求不完整或格式无效')
        body = b''.join(chunks)
        if decoder:
            scope = {**scope, 'headers': [(k, v) for k, v in scope['headers']
                if k not in (b'content-encoding', b'content-length')] + [(b'content-length', str(len(body)).encode())]}
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {'type': 'http.request', 'body': body, 'more_body': False}
            return await receive()

        await self.app(scope, replay, send)


class JsonResponseCompression:
    def __init__(self, app):
        self.app = app
        self.compressed = GZipMiddleware(app, minimum_size=1024, compresslevel=3)

    async def __call__(self, scope, receive, send):
        target = self.app if '/sync/v3/blobs/' in scope.get('path', '') else self.compressed
        return await target(scope, receive, send)
