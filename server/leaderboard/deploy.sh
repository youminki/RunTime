#!/bin/zsh
# 순위 서버 배포. Cloudflare 계정에 로그인(npx wrangler@4 login)한 뒤 한 번 실행한다.
# 데이터베이스가 없으면 만들고, 표를 만든 뒤 Worker를 올리고 주소를 알려 준다.
set -euo pipefail
cd "$(dirname "$0")"
WRANGLER=(npx --yes wrangler@4)
NAME=tokencat-leaderboard

# whoami는 로그인하지 않아도 0으로 끝나서 출력으로 가린다
if "${WRANGLER[@]}" whoami 2>&1 | grep -qi "not authenticated"; then
  echo "먼저 로그인하세요: npx wrangler@4 login" >&2
  exit 1
fi

ID=$("${WRANGLER[@]}" d1 list --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const db=JSON.parse(s).find(d=>d.name===process.argv[1]);console.log(db?db.uuid:"")})' "$NAME")
if [[ -z "$ID" ]]; then
  "${WRANGLER[@]}" d1 create "$NAME" >/dev/null
  ID=$("${WRANGLER[@]}" d1 list --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).find(d=>d.name===process.argv[1]).uuid)})' "$NAME")
fi
sed -i '' -E "s/\"database_id\": \"[^\"]*\"/\"database_id\": \"$ID\"/" wrangler.jsonc

"${WRANGLER[@]}" d1 execute "$NAME" --remote --file=schema.sql --yes
# 먼저 만든 표에는 나중에 더한 칸이 없다. 이미 있으면 오류가 나서 무시한다
for COLUMN in screen source detail; do
  "${WRANGLER[@]}" d1 execute "$NAME" --remote --command "ALTER TABLE reports ADD COLUMN $COLUMN TEXT" --yes >/dev/null 2>&1 || true
done
"${WRANGLER[@]}" deploy
echo "배포했습니다. 위의 workers.dev 주소를 Sources/RunTime/Game/Leaderboard.swift의 serverURL에 넣고 앱을 다시 빌드하세요."
