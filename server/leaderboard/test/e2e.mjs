// 띄워 둔 서버에 실제 요청을 보내 흐름을 확인한다.
//   npx wrangler@4 dev --local --port 8799  을 띄운 뒤  BASE=http://127.0.0.1:8799 node test/e2e.mjs
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { maxDistance, RULES } from "../src/rules.js";

const BASE = process.env.BASE ?? "http://127.0.0.1:8799";
const call = async (method, path, body, player) => {
  const response = await fetch(BASE + path, {
    method,
    headers: { "content-type": "application/json", ...(player ? { "x-player": player } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: response.status, body: await response.json() };
};
const honest = (seconds, coins) => ({
  score: Math.floor(maxDistance(RULES[1], seconds) * 0.04 * 0.9) + coins * 10,
  coins,
  durationMs: seconds * 1000,
  rules: 1,
  version: "e2e",
});

const [a, b, c] = [randomUUID(), randomUUID(), randomUUID()];
const tag = Math.floor(Math.random() * 1000);

let r = await call("POST", "/v1/runs", { player: a, nickname: `가나다${tag}`, ...honest(60, 30) });
assert.equal(r.status, 200, JSON.stringify(r.body));
const bestA = r.body.best;

r = await call("POST", "/v1/runs", { player: a, nickname: `가나다${tag}`, ...honest(20, 5) });
assert.equal(r.status, 429, "같은 사람이 3초 안에 다시 올리면 막는다");

r = await call("POST", "/v1/runs", { player: b, nickname: `bob${tag}`, ...honest(30, 10) });
assert.equal(r.status, 200);
assert.ok(r.body.rank > 1, "a보다 낮은 점수면 a 아래");

r = await call("POST", "/v1/runs", { player: c, nickname: "x", ...honest(10, 0) });
assert.equal(r.status, 400, "닉네임이 짧으면 거절");

r = await call("POST", "/v1/runs", { player: c, nickname: `cheat${tag}`, score: 999999, coins: 0, durationMs: 10000, rules: 1 });
assert.equal(r.status, 422, "불가능한 점수는 거절");

r = await call("GET", "/v1/leaderboard?limit=100", undefined, a);
assert.equal(r.status, 200);
const mine = r.body.entries.find((e) => e.you);
assert.equal(mine?.score, bestA);
assert.equal(r.body.you.rank, mine.rank);
assert.ok(r.body.entries.every((e, i, all) => i === 0 || all[i - 1].score >= e.score), "점수 내림차순");

r = await call("GET", "/v1/leaderboard?period=week", undefined, b);
assert.equal(r.status, 200);
assert.equal(r.body.period, "week");
assert.ok(r.body.you, "이번 주에 올린 b가 보인다");

r = await call("PUT", `/v1/players/${b}`, { nickname: `bobby${tag}` });
assert.equal(r.status, 200);
r = await call("GET", "/v1/leaderboard?limit=100", undefined, b);
assert.equal(r.body.entries.find((e) => e.you)?.nickname, `bobby${tag}`);

// 요약: 1위는 a, 라이벌에는 나를 빼고 담는다
r = await call("GET", "/v1/summary", undefined, b);
assert.equal(r.status, 200);
assert.equal(r.body.top.score, bestA);
assert.equal(r.body.top.you, false);
assert.ok(r.body.you.rank >= 2);
assert.ok(r.body.rivals.some((x) => x.score === bestA), "내 위의 a가 라이벌");
assert.ok(!r.body.rivals.some((x) => x.nickname === `bobby${tag}`), "나는 라이벌에서 뺀다");
r = await call("GET", "/v1/summary", undefined, a);
assert.equal(r.body.top.you, true);
r = await call("GET", "/v1/summary");
assert.equal(r.body.you, null, "참여하지 않으면 ID 없이 공개 정보만");
const keyA = r.body.top.key;
assert.match(keyA, /^[0-9a-f]{16}$/);
assert.ok(!JSON.stringify(r.body).includes(a), "설치 ID는 응답에 나가지 않는다");
r = await call("PUT", `/v1/players/${a}`, { nickname: `새이름${tag}` });
r = await call("GET", "/v1/summary");
assert.equal(r.body.top.key, keyA, "이름을 바꿔도 같은 키");
assert.equal(r.body.top.nickname, `새이름${tag}`, "쓰고 나면 캐시를 비워 바로 보인다");

// 본문이 크면 헤더와 상관없이 끊는다
r = await call("POST", "/v1/runs", { player: c, nickname: "x".repeat(5000) });
assert.equal(r.status, 413);

// 동시에 보낸 두 요청은 하나만 통과한다
const twin = randomUUID();
const both = await Promise.all([1, 2].map(() => call("POST", "/v1/runs", { player: twin, nickname: `twin${tag}`, ...honest(15, 3) })));
assert.deepEqual(both.map((x) => x.status).sort(), [200, 429]);

// 고스트: 순위 점수와 같은 판만 받고, 1위 고스트에는 설치 ID 대신 키가 나간다
const ghost = { seed: "12345678901234567890", inputs: "eJyLjgUAARUAuQ==", layout: "e2e", runner: "cat" };
r = await call("POST", "/v1/ghosts", { player: a, score: bestA + 1, ...ghost });
assert.equal(r.status, 409, "최고 기록이 아닌 점수는 거절");
r = await call("POST", "/v1/ghosts", { player: a, score: bestA, ...ghost, inputs: "<x>" });
assert.equal(r.status, 400);
r = await call("POST", "/v1/ghosts", { player: a, score: bestA, ...ghost });
assert.equal(r.status, 200, JSON.stringify(r.body));
r = await call("GET", "/v1/ghosts/top");
assert.equal(r.status, 200);
assert.equal(r.body.ghost.score, bestA);
assert.equal(r.body.ghost.rank, 1);
assert.equal(r.body.ghost.key, keyA);
assert.equal(r.body.ghost.seed, ghost.seed, "씨앗은 글자 그대로");
assert.ok(!JSON.stringify(r.body).includes(a), "설치 ID는 나가지 않는다");
r = await call("GET", "/v1/ghosts/top?period=week");
assert.equal(r.body.ghost.score, bestA, "이번 주에 올린 최고 판이라 주간 1위 고스트이기도 하다");
assert.equal(r.body.ghost.rank, 1);
r = await call("POST", "/v1/ghosts", { player: a, score: bestA, ...ghost, inputs: "A".repeat(60 * 1024) });
assert.equal(r.status, 413, "너무 큰 고스트는 끊는다");

for (const id of [a, b, twin]) assert.equal((await call("DELETE", `/v1/players/${id}`)).status, 200);
r = await call("GET", "/v1/ghosts/top");
assert.notEqual(r.body.ghost?.key, keyA, "기록을 지우면 고스트도 지운다");
r = await call("GET", "/v1/leaderboard?limit=100", undefined, a);
assert.equal(r.body.you, null, "지운 기록은 순위표에서 빠진다");

// 문제 보고는 진짜 D1 질의를 거친다 (가짜 DB로 도는 단위 시험은 SQL 예약어 오류를 놓쳤다)
r = await call("POST", "/v1/reports", { install: randomUUID(), kind: "app-hang", message: "e2e", app: "e2e", log: "x" });
assert.equal(r.status, 200, JSON.stringify(r.body));
const page = await fetch(`${BASE}/v1/reports/${"0".repeat(32)}?t=${randomUUID()}`);
assert.equal(page.status, 404, "없는 보고는 404 (질의가 깨지면 500)");

console.log("e2e ok");
