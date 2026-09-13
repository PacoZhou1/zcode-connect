import Foundation

@main struct GoalSubmissionJournalTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goal-journal-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = GoalSubmissionJournal(directory: directory)
        let pending = PendingGoal(text: "A real objective", sessionID: nil, creation: ["clientDraftId": .string("stable-create"), "mode": .string("default")])
        try journal.write(["new:project": pending], scope: "computer-A|workspace-A")
        var reopened = try GoalSubmissionJournal(directory: directory).read(scope: "computer-A|workspace-A")
        precondition(reopened["new:project"] == pending)
        let otherScope = try journal.read(scope: "computer-B|workspace-A")
        precondition(otherScope.isEmpty)
        let independent = PendingGoal(text: "Another goal", sessionID: "other-session")
        try journal.set(independent, key: "other-session", scope: "computer-A|workspace-A")
        reopened["new:project"]!.sessionID = "created-session"
        try journal.set(reopened["new:project"], key: "new:project", scope: "computer-A|workspace-A")
        let independentAfter = try journal.read(scope: "computer-A|workspace-A")["other-session"]
        precondition(independentAfter == independent)
        let afterCreation = try journal.read(scope: "computer-A|workspace-A")["new:project"]!
        precondition(afterCreation.id == pending.id && afterCreation.sessionID == "created-session" && afterCreation.creation == pending.creation)
        reopened["new:project"]!.rejected = true
        try journal.set(reopened["new:project"], key: "new:project", scope: "computer-A|workspace-A")
        let rejected = try journal.read(scope: "computer-A|workspace-A")["new:project"]!
        precondition(rejected.rejected)
        let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        try Data("invalid journal".utf8).write(to: file)
        var rejectedCorruption = false
        do { _ = try journal.read(scope: "computer-A|workspace-A") } catch { rejectedCorruption = true }
        precondition(rejectedCorruption)
        print("Goal journal: persisted request/creation identity, computer scope isolation, post-creation recovery, definitive rejection, corrupt-state refusal passed")
    }
}
