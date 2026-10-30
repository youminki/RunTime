-- 미니게임 순위. 앱에서 순위 참여를 켠 사람의 무작위 설치 ID, 닉네임, 점수만 둔다.
CREATE TABLE IF NOT EXISTS players (
  id TEXT PRIMARY KEY,
  nickname TEXT NOT NULL,
  best INTEGER NOT NULL DEFAULT 0,
  best_at INTEGER,
  last_submit INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  score INTEGER NOT NULL,
  coins INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  app_version TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS players_best ON players (best DESC);
CREATE INDEX IF NOT EXISTS runs_recent ON runs (created_at, player_id, score);

-- 제출 횟수 (해시한 IP, 1분 단위). 예약 작업이 1시간 지난 것을 지운다.
CREATE TABLE IF NOT EXISTS submit_hits (
  key TEXT NOT NULL,
  minute INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (key, minute)
);

-- 공개 요약·순위표를 30초 동안 담아 두는 곳. 앱 여러 대가 자주 불러도 무거운 질의는 30초에 한 번만 돈다.
CREATE TABLE IF NOT EXISTS public_cache (
  key TEXT PRIMARY KEY,
  body TEXT NOT NULL,
  at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS runs_player ON runs (player_id, created_at);

-- 사람마다 역대 최고 판과 이번 주 최고 판의 고스트 (씨앗과 압축한 입력). 1위 고스트로 보여 준다.
CREATE TABLE IF NOT EXISTS ghosts (
  player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  period TEXT NOT NULL,
  score INTEGER NOT NULL,
  seed TEXT NOT NULL,
  inputs TEXT NOT NULL,
  layout TEXT NOT NULL,
  runner TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (player_id, period)
);

-- 앱의 문제 보고 (업데이트 실패 등). 무작위 설치 ID와 사용자 폴더를 가린 기록 끝부분만 둔다. 예약 작업이 30일 지난 것을 지운다.
CREATE TABLE IF NOT EXISTS reports (
  key TEXT PRIMARY KEY,
  install TEXT NOT NULL,
  kind TEXT NOT NULL,
  message TEXT NOT NULL,
  app TEXT,
  os TEXT,
  commit_sha TEXT,
  log TEXT,
  mail_key TEXT NOT NULL,
  mailed INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS reports_install ON reports (install, created_at);
CREATE INDEX IF NOT EXISTS reports_created ON reports (created_at);
CREATE INDEX IF NOT EXISTS reports_mail ON reports (mail_key);
