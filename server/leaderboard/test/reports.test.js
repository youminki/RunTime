import assert from "node:assert/strict";
import { test } from "node:test";
import { cleanReport, mailFor, mailKey, reportKey, sourceLink } from "../src/reports.js";

const install = "3f2c1a4e-1b2c-4d5e-8f90-1234567890ab";

test("report keeps only known fields and trims them", () => {
  const report = cleanReport({ install, kind: "update-failed", message: "  빌드 실패  ", app: "1.4.12", log: "x".repeat(20_000), extra: "버림" });
  assert.equal(report.message, "빌드 실패");
  assert.equal(report.log.length, 4000);
  assert.equal(report.extra, undefined);
});

test("bad reports are refused", () => {
  assert.equal(cleanReport({ install: "nope", kind: "update-failed", message: "x" }), null);
  assert.equal(cleanReport({ install, kind: "anything", message: "x" }), null);
  assert.equal(cleanReport({ install, kind: "update-failed", message: "   " }), null);
});

test("same reason on the same day shares one key", async () => {
  const report = cleanReport({ install, kind: "update-timeout", message: "25분 넘게 끝나지 않음" });
  const day = Date.UTC(2026, 9, 30, 3);
  assert.equal(await reportKey(report, day), await reportKey(report, day + 3_600_000));
  assert.notEqual(await reportKey(report, day), await reportKey(report, day + 86_400_000));
});

test("mail names the kind and version", () => {
  const { subject, text } = mailFor(cleanReport({ install, kind: "update-failed", message: "빌드 실패", app: "1.4.12" }));
  assert.equal(subject, "[RunTime] 업데이트 실패 · 빌드 실패 (1.4.12)");
  assert.match(text, /설치 ID: 3f2c1a4e/);
});

test("control characters are dropped and odd versions are blanked", () => {
  const report = cleanReport({ install, kind: "update-failed", message: "줄1\n줄2\r\u0007", app: "1.4\nBcc: x", commit: "abc1234", os: "14.5\r\n", log: "a\tb\nc" });
  assert.equal(report.message, "줄1\n줄2");
  assert.equal(report.app, "");
  assert.equal(report.commit, "abc1234");
  assert.equal(report.os, "14.5");
  assert.equal(report.log, "ab\nc");
});

test("mail key ignores the install id", async () => {
  const now = Date.UTC(2026, 9, 30, 3);
  const a = cleanReport({ install, kind: "update-failed", message: "빌드 실패", app: "1.4.12" });
  const b = cleanReport({ install: "11111111-2222-4333-8444-555555555555", kind: "update-failed", message: "빌드 실패", app: "1.4.12" });
  assert.equal(await mailKey(a, now), await mailKey(b, now));
  assert.notEqual(await reportKey(a, now), await reportKey(b, now));
});

const sha = "df0f5fa19929887258027b106317143756ac4d1b";

test("screen report names the screen, code line and situation", () => {
  const report = cleanReport({
    install, kind: "screen-error", screen: "디자인", message: "피그마가 응답하지 않습니다 (HTTP 500)", app: "1.4.12", commit: sha,
    source: "Sources/RunTime/App/DesignSync.swift:552 sync(_:)", detail: "파일: abc\n요청: GET /v1/files/abc → 500",
  });
  const { subject, text } = mailFor(report);
  assert.equal(subject, "[RunTime] 화면 오류 · 디자인 · 피그마가 응답하지 않습니다 (HTTP 500) (1.4.12)");
  assert.match(text, /화면: 디자인/);
  assert.match(text, /코드 위치: Sources\/RunTime\/App\/DesignSync.swift:552 sync\(_:\)/);
  assert.match(text, new RegExp(`blob/${sha}/Sources/RunTime/App/DesignSync.swift#L552`));
  assert.match(text, new RegExp(`git checkout ${sha}`));
  assert.match(text, /상황\n파일: abc\n요청: GET/);
});

test("odd source or short commit makes no link", () => {
  const odd = cleanReport({ install, kind: "screen-error", message: "x", commit: sha, source: "https://evil.example/a.swift:1" });
  assert.equal(odd.source, "");
  assert.equal(sourceLink(odd), "");
  const short = cleanReport({ install, kind: "screen-error", message: "x", commit: "df0f5fa", source: "Sources/RunTime/App/A.swift:3" });
  assert.equal(sourceLink(short), "");
});

test("same reason on different screens is mailed apart", async () => {
  const now = Date.UTC(2026, 10, 3, 3);
  const a = cleanReport({ install, kind: "screen-error", screen: "업무 일지", message: "HTTP 500" });
  const b = cleanReport({ install, kind: "screen-error", screen: "디자인", message: "HTTP 500" });
  assert.notEqual(await mailKey(a, now), await mailKey(b, now));
});

test("crash report keeps the call stack and names the crashed build", () => {
  const report = cleanReport({
    install, kind: "app-crash", message: "EXC_BAD_ACCESS (SIGSEGV) · AppDelegate.layoutSprite()", app: "1.4.10", commit: sha,
    detail: "죽은 스레드 (com.apple.main-thread)\n3 ▶ RunTime AppDelegate.layoutSprite() + 120",
    log: "[죽기 전 기록]\n2026-11-03 20:26:43 [디자인] 받기 시작",
  });
  assert.equal(report.kind, "app-crash");
  const { subject, text } = mailFor(report);
  assert.equal(subject, "[RunTime] 앱 충돌 · EXC_BAD_ACCESS (SIGSEGV) · AppDelegate.layoutSprite() (1.4.10)");
  assert.match(text, /상황\n죽은 스레드 \(com.apple.main-thread\)\n3 ▶ RunTime AppDelegate.layoutSprite\(\) \+ 120/);
  assert.match(text, new RegExp(`git checkout ${sha}`));
  assert.match(text, /\[죽기 전 기록\]/);
});
