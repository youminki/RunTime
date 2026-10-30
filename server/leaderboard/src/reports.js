// 앱이 보내는 문제 보고. 업데이트가 실패하거나 멈췄을 때 그 Mac에서 무슨 일이 있었는지 만든 사람에게 메일로 알린다.
// 앱은 무작위 설치 ID, 앱 버전, macOS 버전, 까닭, 사용자 폴더를 가린 기록 끝부분만 보낸다.
import { isPlayerID } from "./rules.js";

export const MAX_REPORT_BODY = 16 * 1024;
export const REPORT_KINDS = new Set(["update-failed", "update-timeout", "update-unknown"]);
/// 한 설치에서 하루에 메일로 보낼 보고 수. 같은 까닭은 하루 한 번만 센다.
export const REPORTS_PER_DAY = 5;
/// 설치 ID는 앱이 정하는 값이라 새로 만들면 위 제한을 피한다. 전체에도 하루 상한을 둔다.
export const STORED_PER_DAY = 200;
export const MAILS_PER_DAY = 30;
/// 한 IP(해시)에서 1분에 받는 보고 수. 순위 제출과 따로 센다.
export const REPORTS_PER_MINUTE = 2;

const LIMITS = { message: 400, app: 60, os: 60, commit: 40, log: 4000 };

/// 글로 받을 칸을 자르고 다듬는다. 모양이 틀리면 null.
/// 메일 제목과 본문에 들어가므로 제어문자를 지운다. 여러 줄은 message와 log만 둔다.
export function cleanReport(body) {
  if (!body || typeof body !== "object") return null;
  if (!isPlayerID(body.install) || !REPORT_KINDS.has(body.kind)) return null;
  const text = (value, limit, lines = false) => (typeof value === "string"
    ? value.replace(lines ? /[\u0000-\u0009\u000b-\u001f\u007f]/g : /[\u0000-\u001f\u007f]/g, "").slice(0, limit)
    : "");
  const plain = (value, limit) => (/^[\w.+\- ()]*$/.test(text(value, limit)) ? text(value, limit) : "");
  const message = text(body.message, LIMITS.message, true).trim();
  if (!message) return null;
  return {
    install: body.install.toLowerCase(),
    kind: body.kind,
    message,
    app: plain(body.app, LIMITS.app),
    os: text(body.os, LIMITS.os),
    commit: plain(body.commit, LIMITS.commit),
    log: text(body.log, LIMITS.log, true),
  };
}

async function digest(text) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(bytes).slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// 같은 설치·종류·까닭을 하루 한 번으로 묶는 열쇠.
export async function reportKey(report, now) {
  return digest(`${Math.floor(now / 86_400_000)}|${report.install}|${report.kind}|${report.message}`);
}

/// 메일을 하루 한 번으로 묶는 열쇠. 설치 ID를 바꿔 보내도 같은 까닭이면 한 통이다.
export async function mailKey(report, now) {
  return digest(`${Math.floor(now / 86_400_000)}|${report.kind}|${report.message}|${report.app}`);
}

const KIND_NAMES = { "update-failed": "업데이트 실패", "update-timeout": "업데이트 멈춤", "update-unknown": "업데이트 판정 못 함" };

/// 메일 제목과 본문.
export function mailFor(report) {
  const subject = `[RunTime] ${KIND_NAMES[report.kind]} · ${report.app || "버전 모름"}`;
  const text = [
    `종류: ${KIND_NAMES[report.kind]}`,
    `까닭: ${report.message}`,
    `앱: ${report.app || "-"} (${report.commit || "-"})`,
    `macOS: ${report.os || "-"}`,
    `설치 ID: ${report.install.slice(0, 8)}`,
    "",
    "아래는 앱이 보낸 그대로입니다. 누구나 보낼 수 있으니 링크는 누르지 마세요.",
    "",
    "기록 끝부분",
    report.log || "(없음)",
  ].join("\n");
  return { subject, text };
}

/// 받은 보고를 남기고, 같은 까닭은 하루 한 통·설치당 하루 다섯 통·전체 하루 서른 통까지만 메일로 보낸다.
/// 메일 열쇠(RESEND_API_KEY)와 받는 주소(REPORT_EMAIL)는 Worker 비밀값으로만 둔다.
export async function submitReport(request, env, { readJSON, json, overIPLimit }) {
  const now = Date.now();
  if (await overIPLimit(request, env, now, "report:", REPORTS_PER_MINUTE)) return json({ error: "too many" }, 429);
  const report = cleanReport(await readJSON(request, MAX_REPORT_BODY));
  if (!report) return json({ error: "bad report" }, 400);
  const since = now - 86_400_000;
  const counts = await env.DB.prepare(
    "SELECT COUNT(*) AS stored, COALESCE(SUM(mailed), 0) AS mailed, COALESCE(SUM(install = ?), 0) AS mine FROM reports WHERE created_at > ?",
  ).bind(report.install, since).first();
  if ((counts?.stored ?? 0) >= STORED_PER_DAY) return json({ ok: true, stored: false });
  const [key, mail] = [await reportKey(report, now), await mailKey(report, now)];
  const inserted = await env.DB.prepare(
    `INSERT INTO reports (key, install, kind, message, app, os, commit_sha, log, mail_key, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key) DO NOTHING RETURNING key`,
  ).bind(key, report.install, report.kind, report.message, report.app, report.os, report.commit, report.log, mail, now).first();
  if (!inserted) return json({ ok: true, duplicate: true });
  const sent = await env.DB.prepare("SELECT 1 FROM reports WHERE mail_key = ? AND mailed = 1 LIMIT 1").bind(mail).first();
  if (sent || (counts?.mine ?? 0) >= REPORTS_PER_DAY || (counts?.mailed ?? 0) >= MAILS_PER_DAY || !env.RESEND_API_KEY || !env.REPORT_EMAIL) {
    return json({ ok: true, mailed: false });
  }
  const { subject, text } = mailFor(report);
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({ from: env.REPORT_FROM ?? "RunTime <onboarding@resend.dev>", to: [env.REPORT_EMAIL], subject, text }),
  });
  if (response.ok) await env.DB.prepare("UPDATE reports SET mailed = 1 WHERE key = ?").bind(key).run();
  else console.error("report mail", response.status, await response.text());
  return json({ ok: true, mailed: response.ok });
}
