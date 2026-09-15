"""Bound login work for the single-process private cloud service."""
from collections import deque
import math
import time

from starlette.responses import JSONResponse


class LoginLimits:
    def __init__(self, app, attempts=10, window=60, clock=time.monotonic):
        self.app, self.attempts, self.window, self.clock = app, attempts, window, clock
        self.clients = {}

    async def __call__(self, scope, receive, send):
        if (scope['type'] != 'http' or scope['method'] != 'POST'
                or scope['path'].rstrip('/') != '/api/v1/auth/login'):
            return await self.app(scope, receive, send)
        now = self.clock()
        for address in list(self.clients):
            times = self.clients[address]
            while times and times[0] <= now - self.window:
                times.popleft()
            if not times:
                del self.clients[address]
        # Only the ASGI peer is trusted. Uvicorn may replace it using a
        # deployment-specific allowlist of trusted reverse-proxy addresses.
        address = (scope.get('client') or ('unknown', 0))[0]
        times = self.clients.get(address)
        full = times is None and len(self.clients) >= 2048
        if full or (times is not None and len(times) >= self.attempts):
            retry = max(1, math.ceil(self.window - (now - times[0]))) if times else self.window
            response = JSONResponse(status_code=429,
                content={'detail': '登录尝试过于频繁，请稍后重试'},
                headers={'Retry-After': str(retry)})
            return await response(scope, receive, send)
        if times is None:
            times = self.clients[address] = deque()
        times.append(now)
        await self.app(scope, receive, send)
