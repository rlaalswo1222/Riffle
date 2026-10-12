-- BarLink 스키마
--
-- EnsembleSync 와 합칠 것을 전제로 짰다. member / room / room_participant /
-- score 는 그쪽에 이미 있는 테이블이고, 컬럼 이름과 뜻을 그대로 맞췄다.
-- 합칠 때 이 파일에서 실제로 옮겨갈 것은 아래 두 가지뿐이다.
--
--   · score.part      새 컬럼 하나 (ALTER TABLE ... ADD COLUMN IF NOT EXISTS)
--   · score_anchor    새 테이블 하나
--
-- 나머지는 이미 있으니 버리면 된다.

CREATE EXTENSION IF NOT EXISTS pgcrypto;


CREATE TABLE member (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nickname    VARCHAR(50) NOT NULL,
    created_at  TIMESTAMP   NOT NULL DEFAULT now()
);


CREATE TABLE room (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    room_code   VARCHAR(6)  NOT NULL UNIQUE,
    name        VARCHAR(100) NOT NULL,
    created_by  UUID        NOT NULL REFERENCES member(id),
    created_at  TIMESTAMP   NOT NULL DEFAULT now(),
    last_active_at TIMESTAMP NOT NULL DEFAULT now(),
    is_active   BOOLEAN     NOT NULL DEFAULT true
);


CREATE TABLE room_participant (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id     UUID        NOT NULL REFERENCES room(id) ON DELETE CASCADE,
    member_id   UUID        NOT NULL REFERENCES member(id),
    joined_at   TIMESTAMP   NOT NULL DEFAULT now(),
    role        VARCHAR(20) NOT NULL DEFAULT 'member'
                CHECK (role IN ('leader', 'member')),
    token       TEXT        UNIQUE,
    -- 이 사람이 맡은 파트. 들어올 때 고르고, 자기 파트 악보가 열린다.
    --
    -- 로그인이 없으므로 계정에 붙일 수가 없다. 참가자 행에 둔다. 같은
    -- 사람이 다른 방에서 다른 파트를 맡아도 그대로 된다.
    part        VARCHAR(20),
    UNIQUE (room_id, member_id)
);


CREATE TABLE score (
    id           UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id      UUID      NOT NULL REFERENCES room(id) ON DELETE CASCADE,
    uploaded_by  UUID      NOT NULL REFERENCES member(id),
    file_url     TEXT      NOT NULL,
    file_type    VARCHAR(10) NOT NULL DEFAULT 'pdf'
                 CHECK (file_type IN ('jpg', 'jpeg', 'png', 'pdf')),
    -- 이 악보가 어느 파트의 것인가.
    --
    -- EnsembleSync 에는 없는 컬럼이다. 거기서는 방에 악보가 하나뿐이라
    -- 구분할 이유가 없었다. 여기서는 이게 전부의 출발점이다.
    --
    -- NULL 이면 파트 구분 없는 공용 악보로 본다. 합쳤을 때 기존 악보가
    -- 전부 NULL 이 되는데, 그게 맞는 뜻이다.
    part         VARCHAR(20),
    uploaded_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX idx_score_room ON score(room_id);


-- 악보의 한 줄이 몇 마디에서 시작하는지 적어 둔 표.
--
-- 이 프로젝트의 전부다. 서로 다른 PDF 를 하나의 좌표로 잇는 유일한 실.
--
-- 한 줄(system)마다 하나씩 찍는다. "3페이지 둘째 줄이 37마디" 를 그대로
-- 옮긴 것이다. 줄 안의 위치는 x 비율로 보간한다 — 다음 앵커의 마디
-- 번호를 알면 그 줄에 몇 마디가 들어 있는지도 알게 되기 때문이다.
--
-- 마디선을 검출하지 않는다. 줄의 시작만 알면 되고, 그건 사람이 열 번
-- 두드리면 끝난다. 나중에 자동화하더라도 필요한 건 오선 검출뿐이라,
-- 마디선까지 찾아내야 하는 것보다 훨씬 쉬운 문제로 남는다.
CREATE TABLE score_anchor (
    id         UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
    score_id   UUID   NOT NULL REFERENCES score(id) ON DELETE CASCADE,
    page       INT    NOT NULL,
    -- 페이지 안에서의 세로 위치. 0.0 이 맨 위, 1.0 이 맨 아래.
    --
    -- 픽셀이 아니라 비율로 담는다. 태블릿과 폰의 화면 크기가 다르고,
    -- 같은 기기에서도 확대 배율이 계속 바뀌기 때문이다.
    y          DOUBLE PRECISION NOT NULL,
    x_start    DOUBLE PRECISION NOT NULL DEFAULT 0,
    x_end      DOUBLE PRECISION NOT NULL DEFAULT 1,
    -- 이 줄의 첫 마디 번호.
    --
    -- 정수가 아니라 실수다. 못갖춘마디처럼 반 마디로 시작하는 곡이 있고,
    -- 보간 결과도 실수라 같은 자로 재는 편이 낫다.
    measure    DOUBLE PRECISION NOT NULL,
    end_measure DOUBLE PRECISION,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX idx_anchor_score ON score_anchor(score_id, page, y);

-- 기존 설치에도 정밀 가로 좌표와 마지막 시스템 범위를 추가한다.
ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS x_start DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS x_end DOUBLE PRECISION NOT NULL DEFAULT 1;
ALTER TABLE score_anchor ADD COLUMN IF NOT EXISTS end_measure DOUBLE PRECISION;
