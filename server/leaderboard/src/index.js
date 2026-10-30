// RunTime 미니게임 순위 서버 (Cloudflare Workers + D1).
//   POST   /v1/runs                 판 기록 올리기 → 내 순위
//   GET    /v1/leaderboard          순위표 (?period=all|week, ?limit). 내 줄은 X-Player 헤더로 찾는다.
//   GET    /v1/summary              앱이 주기적으로 받는 요약: 전체·이번 주 1위, 내 순위, 라이벌 점수
// 공개 순위와 요약은 public_cache에 30초 담아 두어, 앱이 많아도 D1 읽기가 사람 수에 비례해 늘지 않게 했다.
//   POST   /v1/ghosts               방금 올린 판의 고스트 (역대·이번 주 최고 점수와 같을 때만 그 기간에 둔다)
//   GET    /v1/ghosts/top           1위 고스트 (?period=all|week, 고스트를 올린 사람 가운데 가장 높은 점수)
//   PUT    /v1/players/:id          닉네임 바꾸기
//   DELETE /v1/players/:id          내 기록 지우기
//   POST   /v1/reports              앱의 문제 보고 (업데이트 실패 등). 만든 사람에게 메일로 알린다 (reports.js)
// 매일 한 번(예약 작업) 주간 순위에 쓰지 않는 오래된 판과 제출 횟수 기록을 지운다.
import { checkRun, cleanGhost, cleanNickname, isPlayerID, MAX_GHOST_INPUTS, SUBMIT_INTERVAL_MS, SUBMITS_PER_MINUTE } from "./rules.js";
import { submitReport } from "./reports.js";

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BODY = 2048;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/v1/runs") return await submitRun(request, env);
      if (request.method === "GET" && url.pathname === "/v1/leaderboard") return await leaderboard(request, url, env);
      if (request.method === "GET" && url.pathname === "/v1/summary") return await summary(request, env);
      if (request.method === "POST" && url.pathname === "/v1/ghosts") return await submitGhost(request, env);
      if (request.method === "GET" && url.pathname === "/v1/ghosts/top") return await topGhost(url, env);
      if (request.method === "POST" && url.pathname === "/v1/reports") return await submitReport(request, env, { readJSON, json, overIPLimit });
      const player = url.pathname.match(/^\/v1\/players\/([^/]+)$/)?.[1];
      if (player && request.method === "PUT") return await rename(player, request, env);
      if (player && request.method === "DELETE") return await forget(player, env);
      return json({ error: "not found" }, 404);
    } catch (error) {
      if (error instanceof TooLarge) return json({ error: "too large" }, 413);
      console.error(error);
      return json({ error: "server error" }, 500);
    }
  },

  async scheduled(_event, env) {
    const now = Date.now();
    await env.DB.batch([
      env.DB.prepare("DELETE FROM public_cache WHERE at < ?").bind(now - 60 * 60 * 1000),
      env.DB.prepare("DELETE FROM runs WHERE created_at < ?").bind(now - WEEK_MS - 24 * 60 * 60 * 1000),
      env.DB.prepare("DELETE FROM submit_hits WHERE minute < ?").bind(Math.floor(now / 60_000) - 60),
      env.DB.prepare("DELETE FROM reports WHERE created_at < ?").bind(now - 30 * 24 * 60 * 60 * 1000),
    ]);
  },
};

class TooLarge extends Error {}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

/// 헤더를 믿지 않고 읽은 만큼 세어 limit을 넘으면 끊는다.
async function readJSON(request, limit = MAX_BODY) {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new TooLarge();
    }
    chunks.push(value);
  }
  try {
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

/// IP는 하루마다 바뀌는 소금과 함께 해시해 1분 단위 횟수만 센다. 원래 IP는 남기지 않는다.
async function overIPLimit(request, env, now, scope = "", limit = SUBMITS_PER_MINUTE) {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const day = Math.floor(now / 86_400_000);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${day}:${scope}${ip}`));
  const key = [...new Uint8Array(digest).slice(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const minute = Math.floor(now / 60_000);
  const row = await env.DB.prepare(
    `INSERT INTO submit_hits (key, minute, count) VALUES (?, ?, 1)
     ON CONFLICT(key, minute) DO UPDATE SET count = count + 1 RETURNING count`,
  ).bind(key, minute).first();
  return row.count > limit;
}

async function submitRun(request, env) {
  const body = await readJSON(request);
  if (!body) return json({ error: "bad json" }, 400);
  const { player, score, coins, durationMs, rules, version } = body;
  if (!isPlayerID(player)) return json({ error: "bad player" }, 400);
  const nickname = cleanNickname(body.nickname);
  if (!nickname) return json({ error: "bad nickname" }, 400);
  const problem = checkRun({ score, coins, durationMs, rules });
  if (problem) return json({ error: problem }, 422);

  const now = Date.now();
  if (await overIPLimit(request, env, now)) return json({ error: "too fast" }, 429);

  // 3초 제한을 쓰기 조건으로 걸어, 동시에 온 요청도 하나만 통과한다
  const upsert = await env.DB.prepare(
    `INSERT INTO players (id, nickname, best, best_at, last_submit, created_at) VALUES (?1, ?2, ?3, ?4, ?4, ?4)
     ON CONFLICT(id) DO UPDATE SET nickname = ?2, last_submit = ?4,
       best_at = CASE WHEN ?3 > players.best THEN ?4 ELSE players.best_at END,
       best = MAX(players.best, ?3)
     WHERE ?4 - players.last_submit >= ?5`,
  ).bind(player, nickname, score, now, SUBMIT_INTERVAL_MS).run();
  if (upsert.meta.changes === 0) return json({ error: "too fast" }, 429);

  const appVersion = typeof version === "string" ? version.slice(0, 32) : null;
  await env.DB.prepare(
    "INSERT INTO runs (player_id, score, coins, duration_ms, app_version, created_at) VALUES (?, ?, ?, ?, ?, ?)",
  ).bind(player, score, coins, durationMs, appVersion, now).run();
  await invalidate(env);
  const { best } = await env.DB.prepare("SELECT best FROM players WHERE id = ?").bind(player).first();
  const row = await env.DB.prepare(
    "SELECT (SELECT COUNT(*) FROM players WHERE best > ?1) + 1 AS rank, (SELECT COUNT(*) FROM players WHERE best > 0) AS total",
  ).bind(best).first();
  return json({ best, rank: row.rank, total: row.total });
}

/// 공개 결과를 public_cache에 ttl 동안 담아 두고 꺼내 쓴다. 담긴 것이 없거나 오래됐으면 compute로 새로 만든다.
async function cached(env, key, ttl, compute) {
  const now = Date.now();
  const row = await env.DB.prepare("SELECT body, at FROM public_cache WHERE key = ?").bind(key).first();
  if (row && now - row.at < ttl) return JSON.parse(row.body);
  const value = await compute();
  await env.DB.prepare(
    "INSERT INTO public_cache (key, body, at) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET body = ?2, at = ?3",
  ).bind(key, JSON.stringify(value), now).run();
  return value;
}

const PUBLIC_TTL = 30_000;

/// 기록이 바뀌면 담아 둔 공개 결과를 버린다. 쓰기는 드물어서 읽기 대부분은 여전히 캐시에서 끝난다.
function invalidate(env) {
  return env.DB.prepare("DELETE FROM public_cache").run();
}

/// 사람을 가리는 키. 설치 ID를 되돌릴 수 없게 해시한 것이라 이 키로 이름을 바꾸거나 기록을 지울 수 없다.
/// 앱은 닉네임이 바뀌어도 같은 사람인지, 라이벌 중 누가 나인지 이 키로 안다.
async function playerKey(id) {
  // 앱(Leaderboard.swift)과 같은 키가 나와야 하고 이미 쌓인 기록도 이 키를 쓰므로 옛 이름을 그대로 둔다
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`tokencat:${id}`));
  return [...new Uint8Array(digest).slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function weekBoard() {
  return [
    `SELECT p.id, p.nickname, MAX(r.score) AS score FROM runs r JOIN players p ON p.id = r.player_id
     WHERE r.created_at >= ? GROUP BY r.player_id`,
    [Date.now() - WEEK_MS],
  ];
}

async function leaderboard(request, url, env) {
  const limit = Math.min(Math.max(Number.parseInt(url.searchParams.get("limit") ?? "20", 10) || 20, 1), 100);
  const week = url.searchParams.get("period") === "week";
  const player = request.headers.get("x-player");

  // 기간 안의 사람별 최고 점수. 이번 주는 최근 7일에 올린 판만 본다.
  const [board, params] = week ? weekBoard() : ["SELECT id, nickname, best AS score FROM players WHERE best > 0", []];

  const shared = await cached(env, `board:${week ? "week" : "all"}:${limit}`, PUBLIC_TTL, async () => {
    const { results } = await env.DB.prepare(`SELECT * FROM (${board}) ORDER BY score DESC, id LIMIT ?`)
      .bind(...params, limit).all();
    const { total } = await env.DB.prepare(`SELECT COUNT(*) AS total FROM (${board})`).bind(...params).first();
    return { total, rows: await Promise.all(results.map(async (row) => ({ ...row, key: await playerKey(row.id) }))) };
  });
  // 같은 점수는 같은 등수
  let rank = 0;
  let previous = null;
  const entries = shared.rows.map((row, index) => {
    if (row.score !== previous) {
      rank = index + 1;
      previous = row.score;
    }
    return { rank, nickname: row.nickname, score: row.score, you: row.id === player };
  });

  let you = null;
  if (isPlayerID(player)) {
    const mine = week
      ? await env.DB.prepare("SELECT MAX(score) AS score FROM runs WHERE player_id = ? AND created_at >= ?")
        .bind(player, params[0]).first()
      : await env.DB.prepare("SELECT best AS score FROM players WHERE id = ? AND best > 0").bind(player).first();
    if (mine?.score != null) {
      const { above } = await env.DB.prepare(`SELECT COUNT(*) AS above FROM (${board}) WHERE score > ?`)
        .bind(...params, mine.score).first();
      you = { rank: above + 1, score: mine.score };
    }
  }
  return json({ period: week ? "week" : "all", total: shared.total, entries, you });
}

/// 앱이 팝오버를 연 동안 30초마다, 순위에 참여 중이면 10분마다 부르는 요약.
/// 공개 부분(1위, 라이벌)은 30초 캐시에서 꺼내고, 내 순위만 그때그때 센다.
/// 1위가 같은 점수면 그 점수를 먼저 낸 사람이 1위다. 라이벌은 상위 30명과 내 바로 위 3명이다.
async function summary(request, env) {
  const player = request.headers.get("x-player");
  const me = isPlayerID(player) ? player : null;

  const shared = await cached(env, "summary", PUBLIC_TTL, async () => {
    const [top, weekTop, count, targets] = await env.DB.batch([
      env.DB.prepare("SELECT id, nickname, best AS score FROM players WHERE best > 0 ORDER BY best DESC, best_at ASC LIMIT 1"),
      env.DB.prepare(
        `SELECT p.id, p.nickname, r.score FROM runs r JOIN players p ON p.id = r.player_id
         WHERE r.created_at >= ? ORDER BY r.score DESC, r.created_at ASC LIMIT 1`,
      ).bind(Date.now() - WEEK_MS),
      env.DB.prepare("SELECT COUNT(*) AS total FROM players WHERE best > 0"),
      env.DB.prepare("SELECT id, nickname, best AS score FROM players WHERE best > 0 ORDER BY best DESC LIMIT 30"),
    ]);
    const withKey = async (row) => (row ? { ...row, key: await playerKey(row.id) } : null);
    return {
      top: await withKey(top.results[0]),
      weekTop: await withKey(weekTop.results[0]),
      total: count.results[0].total,
      rivals: await Promise.all(targets.results.map(withKey)),
    };
  });

  const champion = (row) => (row ? { nickname: row.nickname, score: row.score, key: row.key, you: row.id === me } : null);
  let you = null;
  let rivals = shared.rivals.filter((row) => row.id !== me);
  if (me) {
    const mine = await env.DB.prepare("SELECT best FROM players WHERE id = ? AND best > 0").bind(me).first();
    if (mine) {
      const [above, ahead] = await env.DB.batch([
        env.DB.prepare("SELECT COUNT(*) AS n FROM players WHERE best > ?").bind(mine.best),
        env.DB.prepare("SELECT id, nickname, best AS score FROM players WHERE best > ? ORDER BY best ASC LIMIT 3")
          .bind(mine.best),
      ]);
      you = { rank: above.results[0].n + 1, score: mine.best };
      const seen = new Set(rivals.map((row) => row.id));
      for (const row of ahead.results) {
        if (!seen.has(row.id)) rivals.push({ ...row, key: await playerKey(row.id) });
      }
    }
  }
  return json({
    top: champion(shared.top),
    weekTop: champion(shared.weekTop),
    total: shared.total,
    you,
    rivals: rivals
      .map((row) => ({ nickname: row.nickname, score: row.score, key: row.key }))
      .sort((a, b) => b.score - a.score),
  });
}

async function submitGhost(request, env) {
  const body = await readJSON(request, MAX_GHOST_INPUTS + 8 * 1024);
  const player = body?.player;
  if (!isPlayerID(player)) return json({ error: "bad player" }, 400);
  const ghost = cleanGhost(body);
  if (!ghost) return json({ error: "bad ghost" }, 400);
  const now = Date.now();
  // 순위에 오른 점수와 같은 판만 자기 줄에 받아, 순위표의 점수와 고스트가 어긋나지 않게 한다.
  // 판 올리기를 통과해야 쓸 수 있어 IP 제한은 따로 걸지 않는다 (걸면 판 하나가 두 번 세어진다).
  const store = (period, condition, ...params) => env.DB.prepare(
    `INSERT INTO ghosts (player_id, period, score, seed, inputs, layout, runner, created_at)
     SELECT ?1, '${period}', ?2, ?3, ?4, ?5, ?6, ?7 WHERE ${condition}
     ON CONFLICT(player_id, period) DO UPDATE SET score = ?2, seed = ?3, inputs = ?4, layout = ?5, runner = ?6, created_at = ?7`,
  ).bind(player, ghost.score, ghost.seed, ghost.inputs, ghost.layout, ghost.runner, now, ...params);
  const [all, week] = await env.DB.batch([
    store("all", "?2 = (SELECT best FROM players WHERE id = ?1)"),
    store("week", "?2 = (SELECT MAX(score) FROM runs WHERE player_id = ?1 AND created_at >= ?8)", now - WEEK_MS),
  ]);
  if (all.meta.changes === 0 && week.meta.changes === 0) return json({ error: "not your best" }, 409);
  await invalidate(env);
  return json({ saved: true });
}

/// 그 기간 최고 점수 그대로인 고스트 가운데 가장 높은 것. 1위가 고스트를 올리지 않았으면 그다음 사람 것이고, rank로 알린다.
async function topGhost(url, env) {
  const week = url.searchParams.get("period") === "week";
  const ghost = await cached(env, `ghost:top:${week ? "week" : "all"}`, PUBLIC_TTL, async () => {
    const since = Date.now() - WEEK_MS;
    const [board, params] = week ? weekBoard() : ["SELECT id, best AS score FROM players WHERE best > 0", []];
    const current = week
      ? "g.score = (SELECT MAX(score) FROM runs WHERE player_id = g.player_id AND created_at >= ?) AND g.created_at >= ?"
      : "g.score = p.best";
    const row = await env.DB.prepare(
      `SELECT p.id, p.nickname, g.score, g.seed, g.inputs, g.layout, g.runner,
              (SELECT COUNT(*) FROM (${board}) WHERE score > g.score) + 1 AS rank
       FROM ghosts g JOIN players p ON p.id = g.player_id
       WHERE g.period = ? AND ${current} ORDER BY g.score DESC, g.created_at ASC LIMIT 1`,
    ).bind(...params, week ? "week" : "all", ...(week ? [since, since] : [])).first();
    if (!row) return null;
    const { id, ...rest } = row;
    return { ...rest, key: await playerKey(id) };
  });
  return json({ ghost });
}

async function rename(player, request, env) {
  if (!isPlayerID(player)) return json({ error: "bad player" }, 400);
  const nickname = cleanNickname((await readJSON(request))?.nickname);
  if (!nickname) return json({ error: "bad nickname" }, 400);
  await env.DB.prepare("UPDATE players SET nickname = ? WHERE id = ?").bind(nickname, player).run();
  await invalidate(env);
  return json({ nickname });
}

async function forget(player, env) {
  if (!isPlayerID(player)) return json({ error: "bad player" }, 400);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM runs WHERE player_id = ?").bind(player),
    env.DB.prepare("DELETE FROM ghosts WHERE player_id = ?").bind(player),
    env.DB.prepare("DELETE FROM players WHERE id = ?").bind(player),
  ]);
  await invalidate(env);
  return json({ deleted: true });
}
