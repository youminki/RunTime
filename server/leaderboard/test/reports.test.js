import assert from "node:assert/strict";
import { test } from "node:test";
import { cleanReport, mailFor, mailKey, reportKey } from "../src/reports.js";

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
  assert.equal(subject, "[RunTime] 업데이트 실패 · 1.4.12");
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
