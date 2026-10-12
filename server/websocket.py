"""합주 중 위치 공유.

서버는 마디 번호만 나른다. 좌표는 나르지 않는다.

    보내는 쪽   내 악보의 이 점  →  37.4마디  →  서버
    서버        37.4마디  →  방 안 모두에게
    받는 쪽     37.4마디  →  내 악보의 이 줄

좌표를 그대로 보내면 각자 악보가 다르므로 아무 뜻이 없다. 마디 번호로
한 번 바꿔서 보내는 것이 이 서비스의 전부다.

EnsembleSync 의 websocket.py 와 같은 구조다(방별 연결 목록 + Redis
pub/sub). 메시지 종류만 다르다. 합칠 때는 `point` 처리 한 덩어리를
그쪽 msg_type 분기에 더하면 된다.
"""
import asyncio
import json

import redis.asyncio as aioredis
import room_auth
from config import REDIS_HOST, REDIS_PORT
from database import get_db
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

router = APIRouter()

_redis = aioredis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

# 방별 참여자 { room_id: { user_name: WebSocket } }
_rooms: dict = {}
_redis_tasks: dict = {}

# 마지막으로 가리킨 위치를 방마다 기억해 둔다.
#
# 늦게 들어온 사람이 "지금 어디 보는 중인지" 를 바로 알 수 있어야 한다.
# 연습 중에 끊겼다 다시 붙는 일이 흔한데, 그때마다 누가 다시 짚어주기를
# 기다리게 두면 이 기능이 있으나 마나다.
_LAST_KEY = "barlink:last_point:{}"

# 그 기억을 얼마나 들고 있을지.
_LAST_TTL = 60 * 60 * 6


async def _broadcast(room_id: str, message: dict, exclude: str | None = None):
    for name, ws in list(_rooms.get(room_id, {}).items()):
        if name == exclude:
            continue
        try:
            await ws.send_json(message)
        except Exception:
            _rooms.get(room_id, {}).pop(name, None)


async def _redis_listener(room_id: str):
    """다른 서버 프로세스가 받은 메시지도 이 방에 전한다."""
    pubsub = _redis.pubsub()
    await pubsub.subscribe(f"room_{room_id}")
    try:
        async for message in pubsub.listen():
            if not _rooms.get(room_id):
                break
            if message["type"] == "message":
                try:
                    await _broadcast(room_id, json.loads(message["data"]))
                except Exception:
                    pass
    finally:
        await pubsub.unsubscribe(f"room_{room_id}")
        _redis_tasks.pop(room_id, None)


def _is_member(room_id: str, token: str | None) -> bool:
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor()
        return room_auth.member_of(cur, room_id, token) is not None
    except Exception:
        return False
    finally:
        if conn:
            conn.close()


@router.websocket("/api/ws/room/{room_id}")
async def room_socket(
    websocket: WebSocket,
    room_id: str,
    user_name: str = "익명",
    room_token: str | None = None,
):
    # 받아주기 전에 확인한다. 받고 나서 끊으면 그 사이에 보낸 것이
    # 이미 방 안에 퍼진 뒤다.
    if not _is_member(room_id, room_token):
        await websocket.close(code=4401)
        return

    await websocket.accept()
    _rooms.setdefault(room_id, {})[user_name] = websocket

    if room_id not in _redis_tasks:
        _redis_tasks[room_id] = asyncio.create_task(_redis_listener(room_id))

    # 들어오자마자 마지막으로 가리킨 곳을 알려준다.
    last = await _redis.get(_LAST_KEY.format(room_id))
    if last:
        try:
            await websocket.send_json({"type": "point", **json.loads(last)})
        except Exception:
            pass

    await _broadcast(
        room_id, {"type": "user_joined", "user_name": user_name}, exclude=user_name
    )

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = data.get("type")

            if msg_type == "point":
                measure = data.get("measure")
                if not isinstance(measure, (int, float)):
                    continue
                payload = {
                    "measure": float(measure),
                    "from": user_name,
                    "part": data.get("part"),
                }
                await _redis.setex(
                    _LAST_KEY.format(room_id), _LAST_TTL, json.dumps(payload)
                )
                out = {"type": "point", **payload}
                await _broadcast(room_id, out, exclude=user_name)
                await _redis.publish(f"room_{room_id}", json.dumps(out))

            elif msg_type == "score_uploaded":
                out = {"type": "score_uploaded", "part": data.get("part")}
                await _broadcast(room_id, out, exclude=user_name)
                await _redis.publish(f"room_{room_id}", json.dumps(out))

            elif msg_type == "ping":
                await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        pass
    finally:
        _rooms.get(room_id, {}).pop(user_name, None)
        if not _rooms.get(room_id):
            _rooms.pop(room_id, None)
        await _broadcast(room_id, {"type": "user_left", "user_name": user_name})
