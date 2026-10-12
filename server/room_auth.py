"""방 참가자 확인.

EnsembleSync 의 room_auth.py 와 같은 모양이다. 합칠 때 그쪽 것을 쓰면
되므로 이 파일은 버려진다. 다만 `part` 를 함께 돌려주는 부분만 그쪽에
옮겨 주면 된다.

방 코드는 한 번 쓰는 초대장이다. 사진 한 장으로 새어 나가면 회수할
방법이 없어서, 그것만으로 방 안의 악보에 닿게 두지 않는다. 들어올 때
기기마다 따로 열쇠를 발급한다.
"""
import secrets

# 끌 수 있는 스위치. 무언가 잘못됐을 때 서비스를 세우지 않고 검사만
# 내릴 수 있게 둔다.
ENFORCE = True

DENIED = {"status": 401, "message": "이 방에 들어와 있지 않습니다."}


def new_token() -> str:
    return secrets.token_urlsafe(32)


def token_from(http) -> str | None:
    return http.headers.get("x-room-token")


def issue(cur, room_id: str, member_id: str, part: str | None) -> str:
    token = new_token()
    cur.execute(
        """
        INSERT INTO room_participant (room_id, member_id, token, part)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (room_id, member_id)
        DO UPDATE SET token = EXCLUDED.token, part = EXCLUDED.part
        """,
        (room_id, member_id, token, part),
    )
    return token


def member_of(cur, room_id: str, token: str | None):
    """이 열쇠의 주인을 돌려준다. 아니면 None."""
    if not token:
        return None
    cur.execute(
        """
        SELECT rp.member_id, rp.part, m.nickname
        FROM room_participant rp
        JOIN member m ON m.id = rp.member_id
        WHERE rp.room_id = %s AND rp.token = %s
        """,
        (room_id, token),
    )
    return cur.fetchone()


def room_of_score(cur, score_id: str):
    cur.execute("SELECT room_id FROM score WHERE id = %s", (score_id,))
    row = cur.fetchone()
    return row[0] if row else None


def require(cur, room_id: str | None, http):
    """통과하면 None, 막히면 그대로 돌려줄 응답을 낸다.

    방이 없을 때와 권한이 없을 때가 같은 응답이다. 일부러 그렇게 뒀다.
    다르게 답하면 방 코드를 하나씩 넣어보며 있는 방을 골라낼 수 있다.
    """
    if not ENFORCE:
        return None
    if room_id is None:
        return DENIED
    if member_of(cur, str(room_id), token_from(http)) is None:
        return DENIED
    return None
