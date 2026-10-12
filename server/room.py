"""방 만들기 / 들어가기.

EnsembleSync 의 room_create.py + room_enter.py 와 같은 모양이다. 다른
점은 파트를 함께 받는다는 것뿐이다.
"""
import random
import string

import psycopg2.extras
import room_auth
from config import PARTS
from database import get_db
from fastapi import APIRouter, Request
from pydantic import BaseModel

router = APIRouter()


class RoomCreateRequest(BaseModel):
    room_name: str
    nickname: str
    part: str


class RoomJoinRequest(BaseModel):
    room_code: str
    nickname: str
    part: str


def _generate_room_code() -> str:
    chars = string.ascii_uppercase + string.digits
    return "".join(random.choice(chars) for _ in range(6))


def _validate(nickname: str, part: str):
    if not nickname.strip():
        return {"status": 400, "message": "닉네임을 입력해주세요."}
    if part not in PARTS:
        return {"status": 400, "message": "파트를 골라주세요."}
    return None


@router.post("/api/room/create")
async def create_room(request: RoomCreateRequest):
    bad = _validate(request.nickname, request.part)
    if bad:
        return bad

    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.nickname.strip(),),
        )
        member_id = cur.fetchone()["id"]

        while True:
            room_code = _generate_room_code()
            cur.execute("SELECT 1 FROM room WHERE room_code = %s", (room_code,))
            if not cur.fetchone():
                break

        cur.execute(
            "INSERT INTO room (room_code, name, created_by) "
            "VALUES (%s, %s, %s) RETURNING id",
            (room_code, request.room_name.strip() or "이름 없는 방", member_id),
        )
        room_id = cur.fetchone()["id"]

        token = room_auth.issue(cur, room_id, member_id, request.part)
        conn.commit()

        return {
            "status": 200,
            "room_id": str(room_id),
            "room_code": room_code,
            "member_id": str(member_id),
            "part": request.part,
            "room_token": token,
        }
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방을 만들지 못했습니다: {e}"}
    finally:
        if conn:
            conn.close()


@router.post("/api/room/join")
async def join_room(request: RoomJoinRequest):
    bad = _validate(request.nickname, request.part)
    if bad:
        return bad

    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "SELECT id, name FROM room WHERE room_code = %s AND is_active",
            (request.room_code.strip().upper(),),
        )
        room = cur.fetchone()
        if not room:
            return {"status": 404, "message": "그런 방이 없습니다."}

        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.nickname.strip(),),
        )
        member_id = cur.fetchone()["id"]

        token = room_auth.issue(cur, room["id"], member_id, request.part)
        conn.commit()

        return {
            "status": 200,
            "room_id": str(room["id"]),
            "room_name": room["name"],
            "member_id": str(member_id),
            "part": request.part,
            "room_token": token,
        }
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방에 들어가지 못했습니다: {e}"}
    finally:
        if conn:
            conn.close()


@router.get("/api/room/{room_id}/members")
async def room_members(http: Request, room_id: str):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        denied = room_auth.require(cur, room_id, http)
        if denied:
            return denied

        cur.execute(
            """
            SELECT m.nickname, rp.part
            FROM room_participant rp
            JOIN member m ON m.id = rp.member_id
            WHERE rp.room_id = %s
            ORDER BY rp.joined_at
            """,
            (room_id,),
        )
        return {"status": 200, "members": [dict(r) for r in cur.fetchall()]}
    except Exception as e:
        return {"status": 500, "message": f"{e}"}
    finally:
        if conn:
            conn.close()
