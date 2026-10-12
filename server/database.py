import os

import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

load_dotenv()


def get_db():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        database=os.getenv("DB_NAME", "barlink"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )


def ensure_score_anchor_geometry() -> None:
    """기존 DB에 정밀 악보 좌표 컬럼을 멱등으로 추가한다."""
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            "ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS "
            "x_start DOUBLE PRECISION NOT NULL DEFAULT 0"
        )
        cur.execute(
            "ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS "
            "x_end DOUBLE PRECISION NOT NULL DEFAULT 1"
        )
        cur.execute(
            "ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS "
            "end_measure DOUBLE PRECISION"
        )
        conn.commit()
    finally:
        conn.close()
