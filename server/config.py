import os

from dotenv import load_dotenv

load_dotenv()

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

UPLOAD_ROOT = os.path.abspath(os.getenv("UPLOAD_ROOT", "uploads"))
SCORE_DIR = os.path.join(UPLOAD_ROOT, "scores")

# 악보 한 장의 최대 크기.
MAX_SCORE_MB = int(os.getenv("MAX_SCORE_MB", "30"))
MAX_SCORE_BYTES = MAX_SCORE_MB * 1024 * 1024

# 다룰 수 있는 파트. 화면의 선택지와 DB 의 CHECK 를 여기 하나로 맞춘다.
PARTS = ["vocal", "guitar", "bass", "drum", "keyboard", "other"]

PART_LABELS = {
    "vocal": "보컬",
    "guitar": "기타",
    "bass": "베이스",
    "drum": "드럼",
    "keyboard": "건반",
    "other": "그 외",
}


def public_url(path: str) -> str:
    """`/uploads/...` 경로를 앱이 받아쓸 절대 주소로 바꾼다.

    EnsembleSync 는 여기에 유효기간 서명을 붙인다. 이 프로젝트는 붙이지
    않는다 — 합칠 때 그쪽 signing.py 를 그대로 쓰면 되고, 그 전까지
    혼자 돌려보는 데 서명은 걸림돌만 된다.
    """
    return f"{PUBLIC_BASE_URL}/{path.lstrip('/')}"


def touch_room(cur, room_id: str) -> None:
    """방이 아직 쓰이고 있음을 남긴다. 정리 기준이 된다."""
    cur.execute(
        "UPDATE room SET last_active_at = now() WHERE id = %s", (room_id,)
    )
