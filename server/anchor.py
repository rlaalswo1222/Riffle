"""마디 앵커 읽기 / 쓰기.

앵커는 한 악보의 "몇 페이지 몇 번째 줄이 몇 마디" 목록이다. 이 서비스가
서로 다른 PDF 를 잇는 유일한 정보다.

통째로 갈아끼우는 방식이다. 한 줄만 고치는 API 를 따로 두지 않는다.
앵커는 많아야 한 악보에 수십 개고, 편집 화면에서 여러 개를 한꺼번에
옮기고 지운다. 그때마다 어느 것이 새 것이고 어느 것이 지워진 것인지
가려내는 것보다, 지금 화면에 있는 목록을 그대로 보내는 편이 훨씬 덜
틀린다.
"""
import psycopg2.extras
import room_auth
from config import touch_room
from database import get_db
from fastapi import APIRouter, Request
from pydantic import BaseModel

router = APIRouter()

# 한 악보에 둘 수 있는 앵커의 최대 개수.
#
# 한 줄에 하나씩 찍는다. 100페이지짜리 악보라도 1000줄을 넘지 않는다.
MAX_ANCHORS = 1000


class Anchor(BaseModel):
    page: int
    y: float
    measure: float
    x_start: float = 0.0
    x_end: float = 1.0
    end_measure: float | None = None


class AnchorsRequest(BaseModel):
    anchors: list[Anchor]


@router.get("/api/score/{score_id}/anchors")
async def get_anchors(http: Request, score_id: str):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        room_id = room_auth.room_of_score(cur, score_id)
        denied = room_auth.require(cur, room_id, http)
        if denied:
            return denied

        cur.execute(
            "SELECT page, y, measure, x_start, x_end, end_measure "
            "FROM score_anchor "
            "WHERE score_id = %s ORDER BY page, y",
            (score_id,),
        )
        return {"status": 200, "anchors": [dict(r) for r in cur.fetchall()]}
    except Exception as e:
        return {"status": 500, "message": f"{e}"}
    finally:
        if conn:
            conn.close()


@router.put("/api/score/{score_id}/anchors")
async def put_anchors(http: Request, score_id: str, request: AnchorsRequest):
    if len(request.anchors) > MAX_ANCHORS:
        return {"status": 400, "message": "앵커가 너무 많습니다."}
    for a in request.anchors:
        if (
            a.page < 0
            or not (0.0 <= a.y <= 1.0)
            or not (0.0 <= a.x_start < a.x_end <= 1.0)
            or (a.end_measure is not None and a.end_measure <= a.measure)
        ):
            return {"status": 400, "message": "앵커 위치가 올바르지 않습니다."}

    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        room_id = room_auth.room_of_score(cur, score_id)
        denied = room_auth.require(cur, room_id, http)
        if denied:
            return denied

        cur.execute("DELETE FROM score_anchor WHERE score_id = %s", (score_id,))
        if request.anchors:
            psycopg2.extras.execute_values(
                cur,
                """
                INSERT INTO score_anchor
                    (score_id, page, y, measure, x_start, x_end, end_measure)
                VALUES %s
                """,
                [
                    (
                        score_id,
                        a.page,
                        a.y,
                        a.measure,
                        a.x_start,
                        a.x_end,
                        a.end_measure,
                    )
                    for a in request.anchors
                ],
            )
        touch_room(cur, room_id)
        conn.commit()

        return {"status": 200, "count": len(request.anchors)}
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"앵커를 저장하지 못했습니다: {e}"}
    finally:
        if conn:
            conn.close()
