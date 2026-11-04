import Foundation
import GameCore

/// 한 판의 씨앗과 입력. 고스트와 겨룰 때 같은 코스를 만들고 그때 움직임을 그대로 다시 돌린다.
struct GhostRecord: Codable {
    /// JSON 숫자는 2^53을 넘으면 어긋날 수 있어 글자로 둔다.
    let seed: String
    let score: Int
    /// 규칙·장애물 목록이 바뀌면 같은 입력으로 다른 판이 나오니, 저장할 때의 규칙을 함께 둔다.
    let layout: String
    let inputs: [RunnerGame.InputRecord]
    /// 그 판을 달린 러너 (AppSettings.runnerID). 고스트를 이 러너 모습으로 그린다.
    var runner: String?
    /// 그 판에 쓴 능력. 같은 능력으로 돌려야 같은 판이 나온다.
    var abilities: RunnerGame.Abilities?

    var seedValue: UInt64? { UInt64(seed) }
}

/// 내 최고 판 고스트. 이 Mac에만 저장한다.
enum GhostStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunTime/ghost.json")
    }

    /// 남의 고스트를 확인할 때 돌려 보는 상한 (1시간).
    static let maxReplayTicks = Int(3600 / RunnerGame.step)

    static func layout(of game: RunnerGame) -> String {
        "\(RunnerGame.rulesVersion) \(game.runnerWidth)x\(game.runnerHeight) \(String(describing: game.tuning))"
    }

    /// 지금 규칙으로 다시 돌릴 수 있는 고스트만.
    static func load(for game: RunnerGame) -> GhostRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(GhostRecord.self, from: data),
              record.layout == layout(of: game), record.seedValue != nil
        else { return nil }
        return record
    }

    static func record(of game: RunnerGame, runner: String?) -> GhostRecord {
        GhostRecord(seed: String(game.seed), score: game.score, layout: layout(of: game), inputs: game.inputLog,
                    runner: runner, abilities: game.abilities.isEmpty ? nil : game.abilities)
    }

    /// 방금 끝난 판을 내 고스트로 남긴다.
    static func save(_ record: GhostRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[RunTime] 고스트 저장 실패: %@", error.localizedDescription)
            return false
        }
    }

    /// 끝까지 돌려 본 점수가 적힌 점수와 같은 고스트만 믿는다. 오래 걸릴 수 있어 메인 스레드 밖에서 부른다.
    static func verified(_ record: GhostRecord, tuning: RunnerGame.Tuning, runnerWidth: Double, runnerHeight: Double) -> Bool {
        guard let seed = record.seedValue else { return false }
        let ghost = GhostRunner(tuning: tuning, runnerWidth: runnerWidth, runnerHeight: runnerHeight,
                                seed: seed, inputs: record.inputs, abilities: record.abilities ?? RunnerGame.Abilities())
        return ghost.finalScore(maxTicks: maxReplayTicks) == record.score
    }

}
