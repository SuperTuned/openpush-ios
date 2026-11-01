import XCTest
@testable import OpenPush

/// The deadline arithmetic behind a time-based trigger, on its own: no engine,
/// no clock, no queue — just "how long until this condition could be true".
final class OpenPushInAppTriggerTests: XCTestCase {
    private func condition(_ kind: String, _ op: String, _ value: Double) -> OpenPush.IamCondition {
        OpenPush.IamCondition(id: UUID().uuidString, kind: kind, property: nil, op: op,
                              value: .number(value))
    }

    func testSessionTimeDeadlineIsTheRemainingSeconds() {
        let groups = [[condition("session_time", "greater", 30)]]
        XCTAssertEqual(OpenPush.iamNextDynamicDeadline(groups, triggers: [:], sessionAge: 10,
                                                       timeSinceLast: .greatestFiniteMagnitude), 20)
    }

    func testASatisfiedDynamicConditionHasNoDeadline() {
        let groups = [[condition("session_time", "greater_or_equal", 5)]]
        XCTAssertNil(OpenPush.iamNextDynamicDeadline(groups, triggers: [:], sessionAge: 9,
                                                     timeSinceLast: .greatestFiniteMagnitude))
    }

    func testTheEarliestOfSeveralDeadlinesWins() {
        let groups = [[condition("session_time", "greater", 30)],
                      [condition("min_time_since", "greater", 120)]]
        XCTAssertEqual(OpenPush.iamNextDynamicDeadline(groups, triggers: [:], sessionAge: 0,
                                                       timeSinceLast: 100), 20)
    }

    /// "Nothing has ever been dismissed" reaches the matcher as
    /// `Double.greatestFiniteMagnitude`, so the very first evaluation of a
    /// `min_time_since` trigger on a fresh install runs the sentinel through
    /// every comparison path there is.
    func testMinTimeSinceOnAFreshInstallEvaluatesWithoutTrapping() {
        let groups = [[condition("min_time_since", "greater", 60)]]
        XCTAssertTrue(OpenPush.iamConditionsMatch(groups, triggers: [:], sessionAge: 0,
                                                  timeSinceLast: .greatestFiniteMagnitude),
                      "no in-app message has been dismissed, so any minimum gap has passed")
    }

    func testHugeNumericTriggerValuesRenderAsText() {
        XCTAssertFalse(OpenPush.IamTriggerValue.number(.greatestFiniteMagnitude).text.isEmpty)
        XCTAssertEqual(OpenPush.IamTriggerValue.number(42).text, "42")
        XCTAssertEqual(OpenPush.IamTriggerValue.number(2.5).text, "2.5")
    }

    private func custom(_ property: String, _ op: String,
                        _ value: OpenPush.IamTriggerValue) -> [[OpenPush.IamCondition]] {
        [[OpenPush.IamCondition(id: "c", kind: "custom", property: property, op: op, value: value)]]
    }

    /// A trigger value that carries commas is a list of members, not a sentence:
    /// "gold,silver" holds "silver" and does not hold "sil".
    func testInMatchesAMemberOfACommaSeparatedTriggerValue() {
        let triggers: [String: OpenPush.IamTriggerValue] = ["tiers": .string("gold, silver")]
        XCTAssertTrue(OpenPush.iamConditionsMatch(custom("tiers", "in", .string("silver")),
                                                  triggers: triggers, sessionAge: 0,
                                                  timeSinceLast: 0))
        XCTAssertFalse(OpenPush.iamConditionsMatch(custom("tiers", "in", .string("sil")),
                                                   triggers: triggers, sessionAge: 0,
                                                   timeSinceLast: 0),
                       "a prefix of a member is not a member")
        XCTAssertTrue(OpenPush.iamConditionsMatch(custom("tiers", "in", .string(" gold ")),
                                                  triggers: triggers, sessionAge: 0,
                                                  timeSinceLast: 0),
                      "members and the value looked for are both trimmed")
    }

    /// Without a comma there is no list to read, so `in` stays what it has
    /// always been: a substring test.
    func testInFallsBackToSubstringForPlainValues() {
        XCTAssertTrue(OpenPush.iamConditionsMatch(custom("plan", "in", .string("old")),
                                                  triggers: ["plan": .string("gold")],
                                                  sessionAge: 0, timeSinceLast: 0))
        XCTAssertFalse(OpenPush.iamConditionsMatch(custom("plan", "in", .string("silver")),
                                                   triggers: ["plan": .string("gold")],
                                                   sessionAge: 0, timeSinceLast: 0))
    }

    func testCustomTriggersProduceNoDeadline() {
        let groups = [[OpenPush.IamCondition(id: "c", kind: "custom", property: "k",
                                             op: "equal", value: .string("v"))]]
        XCTAssertNil(OpenPush.iamNextDynamicDeadline(groups, triggers: [:], sessionAge: 0,
                                                     timeSinceLast: 0))
    }
}
