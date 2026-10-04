"""Cloud synchronization composition root."""
from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text

from auth import router as auth_router
from .admin import router as admin_router
from database import init_db, SessionLocal
from .api import router
from .crypto import Vault
from .limits import RequestLimits, JsonResponseCompression
from .account_limits import LoginLimits
from .initialization import validate_installation


@asynccontextmanager
async def lifespan(app):
    secret = os.getenv('SECRET_KEY', '')
    if len(secret) < 32 or secret == 'change-this-secret-key':
        raise RuntimeError('Configure a persistent SECRET_KEY of at least 32 characters')
    vault = Vault()
    init_db()
    with SessionLocal() as db:
        validate_installation(db, vault)
    yield


app = FastAPI(title='AIcove Cloud', version='3.0.0', lifespan=lifespan)
app.add_middleware(RequestLimits)
app.add_middleware(JsonResponseCompression)
app.add_middleware(LoginLimits)
origins = [s.strip() for s in os.getenv('ALLOWED_ORIGINS', '').split(',') if s.strip()]
if origins:
    app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=False,
                       allow_methods=['GET', 'POST', 'PUT'], allow_headers=['Authorization', 'Content-Type'])
app.include_router(auth_router)
app.include_router(admin_router)
app.include_router(router)


@app.get('/health')
def health():
    with SessionLocal() as db:
        db.execute(text('SELECT 1'))
    return {'status': 'ok', 'protocol_version': 3}


@app.exception_handler(Exception)
async def internal_error(request, error):
    # Never serialize exception details containing request content or keys.
    return JSONResponse(status_code=500, content={'detail': {
        'code': 'internal_error', 'message': '服务器内部错误，请稍后重试'}})
