import assert from "node:assert/strict";
import { test } from "node:test";
import { checkRun, cleanGhost, cleanNickname, isPlayerID, MAX_GHOST_INPUTS, maxDistance, RULES } from "../src/rules.js";

// Sources/GameCore/RunnerGame.swift의 Tuning 기본값과 같아야 한다 (Swift 쪽 LeaderboardRulesTests도 같은 숫자를 본다)
test("rules v1 match the game tuning", () => {
  assert.deepEqual(
    { ...RULES[1] },
    { startSpeed: 220, maxSpeed: 440, acceleration: 6, scorePerPoint: 0.04, coinValue: 10,
      maxCoinsPerObstacle: 3, minSecondsPerObstacle: 0.7 },
  );
});

test("rules v2 match the game tuning", () => {
  assert.deepEqual(
    { ...RULES[2] },
    { startSpeed: 220, rampSpeed: 440, maxSpeed: 540, acceleration: 6, lateAcceleration: 1, scorePerPoint: 0.04,
      coinValue: 10, maxCoinsPerObstacle: 3, minSecondsPerObstacle: 0.65 },
  );
});

test("v2 distance keeps speeding up slowly after the ramp", () => {
  const rule = RULES[2];
  const ramp = (440 - 220) / 6;
  assert.ok(Math.abs(maxDistance(rule, ramp) - maxDistance(RULES[1], ramp)) < 1e-6);
  assert.ok(Math.abs(maxDistance(rule, ramp + 10) - (maxDistance(rule, ramp) + 4400 + 50)) < 1e-6);
  const late = ramp + 100;
  assert.ok(Math.abs(maxDistance(rule, late + 10) - (maxDistance(rule, late) + 5400)) < 1e-6);
});

test("distance ramps up then holds at max speed", () => {
  const rule = RULES[1];
  assert.equal(maxDistance(rule, 0), 0);
  assert.equal(maxDistance(rule, 10), 220 * 10 + 0.5 * 6 * 100);
  const ramp = (440 - 220) / 6;
  assert.ok(Math.abs(maxDistance(rule, ramp + 10) - (maxDistance(rule, ramp) + 4400)) < 1e-6);
});

test("an honest run passes", () => {
  // 30초 동안 최고로 달려 코인 20개
  const distance = maxDistance(RULES[1], 30);
  const score = Math.floor(distance * 0.04) + 20 * 10;
  assert.equal(checkRun({ score, coins: 20, durationMs: 30_000, rules: 1 }), null);
});

test("impossible runs are rejected", () => {
  assert.equal(checkRun({ score: 99_999, coins: 0, durationMs: 30_000, rules: 1 }), "impossible score");
  assert.equal(checkRun({ score: 500, coins: 400, durationMs: 30_000, rules: 1 }), "too many coins");
  assert.equal(checkRun({ score: 50, coins: 10, durationMs: 30_000, rules: 1 }), "impossible score");
  assert.equal(checkRun({ score: 10, coins: 0, durationMs: 0, rules: 1 }), "out of range");
  assert.equal(checkRun({ score: 10.5, coins: 0, durationMs: 1000, rules: 1 }), "not integers");
  assert.equal(checkRun({ score: 10, coins: 0, durationMs: 1000, rules: 3 }), "unknown rules");
  for (const key of ["__proto__", "constructor", "toString", "1"]) {
    assert.equal(checkRun({ score: 1e300, coins: 0, durationMs: 1000, rules: key }), "unknown rules");
  }
  assert.equal(checkRun({ score: 20_000_000, coins: 0, durationMs: 7_000_000, rules: 1 }), "out of range");
});

test("nicknames are trimmed and limited", () => {
  assert.equal(cleanNickname("  토큰  고양이 "), "토큰 고양이");
  assert.equal(cleanNickname("cat_01"), "cat_01");
  assert.equal(cleanNickname("a"), null);
  assert.equal(cleanNickname("열세글자가넘는아주긴닉네임"), null);
  assert.equal(cleanNickname("<script>"), null);
  assert.equal(cleanNickname(42), null);
  assert.equal(cleanNickname("\u3164\u3164"), null, "보이지 않는 한글 채움 문자");
  assert.equal(cleanNickname("\u115F\u1160가"), null);
  assert.equal(cleanNickname("ㄱㄴ"), "ㄱㄴ");
  assert.equal(cleanNickname("가 "), null, "공백 빼고 2자 이상");
});

test("player ids must be UUIDs", () => {
  assert.ok(isPlayerID("0F8FAD5B-D9CB-469F-A165-70867728950E"));
  assert.ok(!isPlayerID("../../etc"));
});

test("ghost bodies are checked for shape and size", () => {
  const ok = { score: 640, seed: "18446744073709551615", inputs: "eJyLjgUAARUAuQ==", layout: "1 24.0x40.0 Tuning()", runner: "cat" };
  assert.deepEqual(cleanGhost(ok), ok);
  assert.equal(cleanGhost({ ...ok, runner: "petdex:shin-chan" }).runner, "petdex:shin-chan");
  assert.equal(cleanGhost({ ...ok, runner: "../../etc" }).runner, null, "이상한 러너 이름은 버리고 고스트는 받는다");
  assert.equal(cleanGhost({ ...ok, seed: "-1" }), null);
  assert.equal(cleanGhost({ ...ok, seed: 12 }), null);
  assert.equal(cleanGhost({ ...ok, score: 0 }), null);
  assert.equal(cleanGhost({ ...ok, inputs: "<script>" }), null);
  assert.equal(cleanGhost({ ...ok, inputs: "A".repeat(MAX_GHOST_INPUTS + 1) }), null);
  assert.equal(cleanGhost(null), null);
});
