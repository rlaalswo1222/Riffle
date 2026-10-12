import os
from contextlib import asynccontextmanager

import anchor
import room
import score
import websocket
from config import UPLOAD_ROOT
from database import ensure_score_anchor_geometry
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

@asynccontextmanager
async def lifespan(_: FastAPI):
    ensure_score_anchor_geometry()
    yield


app = FastAPI(title="BarLink", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(UPLOAD_ROOT, exist_ok=True)
# 서명 없이 그대로 내준다. EnsembleSync 와 합칠 때 그쪽의 서명 라우트로
# 바뀐다 — 그때 이 한 줄을 지우면 된다.
app.mount("/uploads", StaticFiles(directory=UPLOAD_ROOT), name="uploads")

app.include_router(room.router)
app.include_router(score.router)
app.include_router(anchor.router)
app.include_router(websocket.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
