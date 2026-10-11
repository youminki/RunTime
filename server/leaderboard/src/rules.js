// 점수가 플레이 시간 안에 낼 수 있는 값인지 가린다. 앱이 오픈소스라 누구나 요청을 만들 수 있어서
// 막을 수는 없고, 규칙상 불가능한 점수만 걸러 낸다.
// 값은 Sources/GameCore/RunnerGame.swift의 Tuning 기본값과 같아야 한다 (양쪽 테스트가 같은 숫자를 확인한다).

export const RULES = {
  1: {
    startSpeed: 220,
    maxSpeed: 440,
    acceleration: 6,
    scorePerPoint: 0.04,
    coinValue: 10,
    // 장애물 하나에 코인은 최대 3개, 장애물은 체공+반응 시간(약 0.75초)보다 촘촘하지 않다
    maxCoinsPerObstacle: 3,
    minSecondsPerObstacle: 0.7,
  },
  // rampSpeed까지는 acceleration으로, 그 뒤로는 lateAcceleration으로 maxSpeed까지 오른다.
  // 시간이 갈수록 장애물 간격이 체공+반응 시간(약 0.69초)까지 좁아진다.
  2: {
    startSpeed: 220,
    rampSpeed: 440,
    maxSpeed: 540,
    acceleration: 6,
    lateAcceleration: 1,
    scorePerPoint: 0.04,
    coinValue: 10,
    maxCoinsPerObstacle: 3,
    minSecondsPerObstacle: 0.65,
  },
};

export const MAX_DURATION_MS = 2 * 60 * 60 * 1000;
export const MAX_SCORE = 10_000_000;
export const SUBMIT_INTERVAL_MS = 3000;
/// 한 IP(해시)에서 1분에 받는 제출 수. 설치 ID를 새로 만들어 3초 제한을 피하는 것을 막는다.
export const SUBMITS_PER_MINUTE = 6;

/// 속도가 시작 속도에서 가속해 최고 속도에 머무를 때, t초 동안 달릴 수 있는 최대 거리.
/// rampSpeed가 있으면 거기서부터는 lateAcceleration으로 오른다.
export function maxDistance(rule, seconds) {
  const stages = rule.rampSpeed === undefined
    ? [[rule.maxSpeed, rule.acceleration]]
    : [[rule.rampSpeed, rule.acceleration], [rule.maxSpeed, rule.lateAcceleration]];
  let speed = rule.startSpeed;
  let left = seconds;
  let distance = 0;
  for (const [top, acceleration] of stages) {
    const t = Math.min(left, (top - speed) / acceleration);
    distance += speed * t + 0.5 * acceleration * t * t;
    speed += acceleration * t;
    left -= t;
  }
  return distance + speed * left;
}

export function checkRun({ score, coins, durationMs, rules }) {
  // "__proto__" 같은 키로 Object.prototype을 꺼내 검사를 건너뛰지 못하게 자기 키만 본다
  if (!Number.isInteger(rules) || !Object.hasOwn(RULES, rules)) return "unknown rules";
  const rule = RULES[rules];
  if (![score, coins, durationMs].every(Number.isInteger)) return "not integers";
  if (score < 0 || score > MAX_SCORE || coins < 0 || durationMs <= 0 || durationMs > MAX_DURATION_MS) {
    return "out of range";
  }
  const seconds = durationMs / 1000;
  const maxCoins = rule.maxCoinsPerObstacle * (Math.floor(seconds / rule.minSecondsPerObstacle) + 2);
  if (coins > maxCoins) return "too many coins";
  const distanceScore = score - coins * rule.coinValue;
  // 고정 간격 반올림과 시간 측정 오차를 2%와 2점까지 봐준다
  const maxDistanceScore = Math.floor(maxDistance(rule, seconds) * rule.scorePerPoint * 1.02) + 2;
  if (distanceScore < 0 || distanceScore > maxDistanceScore) return "impossible score";
  return null;
}

// 완성형 한글과 호환 자모(채움 문자 U+3164 제외), 영문, 숫자, 공백 _ . -
// 앱의 Leaderboard.isValid와 같은 범위이고, 길이는 NFC로 맞춘 코드포인트 수로 센다.
const NICKNAME_CHAR = /^[\uAC00-\uD7A3\u3131-\u3163A-Za-z0-9 _.\-]$/u;

export function cleanNickname(raw) {
  if (typeof raw !== "string") return null;
  const name = raw.normalize("NFC").trim().replace(/ +/g, " ");
  const chars = [...name];
  if (chars.length < 2 || chars.length > 12) return null;
  if (!chars.every((c) => NICKNAME_CHAR.test(c))) return null;
  return chars.filter((c) => c !== " ").length >= 2 ? name : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isPlayerID(raw) {
  return typeof raw === "string" && UUID.test(raw);
}

/// 고스트 본문 상한. 입력 기록을 압축한 base64라 몇 분짜리 판도 수십 KB 안이다.
export const MAX_GHOST_INPUTS = 48 * 1024;

/// 1위 고스트로 보여 줄 판. 서버는 판을 다시 돌릴 수 없어 모양만 보고, 앱이 받아서 끝까지 돌려 본 점수가
/// 순위 점수와 같을 때만 보여 준다. 러너는 기본 러너 이름이나 Petdex 펫("petdex:slug")만 받는다.
export function cleanGhost(body) {
  if (!body || typeof body !== "object") return null;
  const { score, seed, inputs, layout, runner } = body;
  if (!Number.isInteger(score) || score <= 0 || score > MAX_SCORE) return null;
  if (typeof seed !== "string" || !/^\d{1,20}$/.test(seed)) return null;
  if (typeof inputs !== "string" || inputs.length > MAX_GHOST_INPUTS || !/^[A-Za-z0-9+/=]+$/.test(inputs)) return null;
  if (typeof layout !== "string" || layout.length > 4000) return null;
  const cleanRunner = typeof runner === "string" && /^[a-z0-9][a-z0-9:_.-]{0,63}$/i.test(runner) ? runner : null;
  return { score, seed, inputs, layout, runner: cleanRunner };
}
