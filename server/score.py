"""파트별 악보 올리기 / 목록.

EnsembleSync 의 score_upload.py + score_query.py 를 파트 단위로 넓힌
것이다. 그쪽은 방에 악보가 하나뿐이라 `/latest` 로 최신 한 장만 줬다.

    EnsembleSync   SELECT ... ORDER BY uploaded_at DESC LIMIT 1
    BarLink        파트마다 한 장씩

합칠 때 저 LIMIT 1 을 걷어내는 게 서버 쪽 작업의 대부분이다.
"""
import os
import uuid

import psycopg2.extras
import room_auth
import score_presets
from config import MAX_SCORE_BYTES, MAX_SCORE_MB, PARTS, SCORE_DIR, public_url, touch_room
from database import get_db
from fastapi import APIRouter, File, Form, Request, UploadFile

router = APIRouter()

ALLOWED = {".pdf": "pdf", ".png": "png", ".jpg": "jpg", ".jpeg": "jpeg"}


@router.post("/api/score/{room_id}/upload")
async def upload_score(
    http: Request,
    room_id: str,
    part: str = Form(...),
    file: UploadFile = File(...),
):
    if part not in PARTS:
        return {"status": 400, "message": "파트를 골라주세요."}

    suffix = os.path.splitext(file.filename or "")[1].lower()
    if suffix not in ALLOWED:
        return {"status": 400, "message": "PDF 나 이미지만 올릴 수 있습니다."}

    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        denied = room_auth.require(cur, room_id, http)
        if denied:
            return denied
        me = room_auth.member_of(cur, room_id, room_auth.token_from(http))

        data = await file.read()
        if len(data) > MAX_SCORE_BYTES:
            return {
                "status": 413,
                "message": f"악보는 {MAX_SCORE_MB}MB 까지만 올릴 수 있습니다.",
            }

        preset = score_presets.find(data)
        if preset is not None and preset["part"] != part:
            return {
                "status": 400,
                "message": "선택한 파트와 악보가 다릅니다. "
                f"이 파일은 {preset['part']} 악보입니다.",
            }

        os.makedirs(SCORE_DIR, exist_ok=True)
        name = f"{uuid.uuid4()}{suffix}"
        with open(os.path.join(SCORE_DIR, name), "wb") as out:
            out.write(data)
        rel = f"/uploads/scores/{name}"

        # 한 파트에 악보는 한 장이다. 다시 올리면 갈아끼운다.
        #
        # 남겨두면 앵커가 어느 쪽에 붙었는지 헷갈린다. 앵커는 악보에
        # 딸려 있으므로 예전 악보를 지우면 그 앵커도 함께 사라진다 —
        # 새 파일에는 줄 위치가 다를 테니 그게 맞다.
        cur.execute(
            "DELETE FROM score WHERE room_id = %s AND part = %s",
            (room_id, part),
        )
        cur.execute(
            """
            INSERT INTO score (room_id, uploaded_by, file_url, file_type, part)
            VALUES (%s, %s, %s, %s, %s) RETURNING id
            """,
            (room_id, me["member_id"], rel, ALLOWED[suffix], part),
        )
        score_id = cur.fetchone()["id"]
        if preset is not None:
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
                        anchor["page"],
                        anchor["y"],
                        anchor["measure"],
                        anchor["x_start"],
                        anchor["x_end"],
                        anchor["end_measure"],
                    )
                    for anchor in preset["anchors"]
                ],
            )
        touch_room(cur, room_id)
        conn.commit()

        return {
            "status": 200,
            "score_id": str(score_id),
            "part": part,
            "file_url": public_url(rel),
            "file_type": ALLOWED[suffix],
            "preset_linked": preset is not None,
        }
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"악보를 올리지 못했습니다: {e}"}
    finally:
        if conn:
            conn.close()


@router.get("/api/score/{room_id}/list")
async def list_scores(http: Request, room_id: str):
    """방 안의 악보를 파트별로 전부 준다.

    앵커 개수도 함께 센다. 화면에서 "아직 마디를 안 찍은 파트" 를
    바로 보여주려면 목록 한 번으로 알아야 한다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        denied = room_auth.require(cur, room_id, http)
        if denied:
            return denied

        cur.execute(
            """
            SELECT s.id, s.part, s.file_url, s.file_type, m.nickname,
                   (SELECT count(*) FROM score_anchor a WHERE a.score_id = s.id)
                       AS anchor_count
            FROM score s
            JOIN member m ON m.id = s.uploaded_by
            WHERE s.room_id = %s
            ORDER BY s.uploaded_at
            """,
            (room_id,),
        )
        scores = []
        for row in cur.fetchall():
            scores.append(
                {
                    "score_id": str(row["id"]),
                    "part": row["part"],
                    "file_url": public_url(row["file_url"]),
                    "file_type": row["file_type"],
                    "uploaded_by": row["nickname"],
                    "anchor_count": row["anchor_count"],
                }
            )
        return {"status": 200, "scores": scores}
    except Exception as e:
        return {"status": 500, "message": f"{e}"}
    finally:
        if conn:
            conn.close()
