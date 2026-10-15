import XCTest
@testable import AgentCore

/// The group-chat flow contract: who must answer a message, who may, and the guarantee that a
/// human message is never left without a reply (unless it is just an acknowledgement).
final class GroupTurnTests: XCTestCase {

    private let bug = GroupMember(id: "bug", name: "Bugbot", role: "Debugging")
    private let tai = GroupMember(id: "tai", name: "Tai Lung", role: "Main Engineer")
    private let smith = GroupMember(id: "smith", name: "Mr. Smith", role: "Project Manager")
    private let polaris = GroupMember(id: "pol", name: "Polaris", role: "UI Design Expert")
    private var members: [GroupMember] { [bug, tai, smith, polaris] }

    private func analyze(_ text: String, explicit: Set<String> = []) -> Addressing {
        AddressingAnalyzer.analyze(text: text, members: members, explicitMentionIDs: explicit)
    }
    private func plan(_ text: String, explicit: Set<String> = [], coordinator: String? = nil) -> TurnPlan {
        GroupTurnPlanner.plan(forHumanMessage: text, explicitMentionIDs: explicit, members: members, coordinatorID: coordinator)
    }

    // MARK: addressing

    func testGreetingTheRoomIsACollectiveAddress() {
        for text in ["Hey Guys!", "hey guys", "HEY GUYS!!!", "Hello everyone", "Hi all", "Good morning team", "hello", "hi", "yo",
                     "Hey y'all", "good morning", "What's up everybody?", "hey everyone, how's it going"] {
            let a = analyze(text)
            XCTAssertTrue(a.isCollective, "\"\(text)\" should address the whole room")
            XCTAssertFalse(a.isAcknowledgement, text)
        }
    }

    func testEverydayNounsDoNotAddressTheRoom() {
        for text in ["Update the team doc", "The people at HR called", "Can you fix the build?", "My crew is waiting on this", "all done with the report"] {
            XCTAssertFalse(analyze(text).isCollective, text)
        }
        XCTAssertTrue(analyze("Team, please review the plan").isCollective)
        XCTAssertTrue(analyze("hey team").isCollective)
    }

    func testPlainNamesAreRecognizedWithoutAnAt() {
        XCTAssertEqual(analyze("Bugbot, can you look at this?").nameIDs, ["bug"])
        XCTAssertEqual(analyze("thanks Tai Lung for the help").nameIDs, ["tai"])
        XCTAssertEqual(analyze("ask Smith about the schedule").nameIDs, ["smith"], "a distinctive word of a name is enough")
        XCTAssertEqual(analyze("hey polaris what do you think").nameIDs, ["pol"])
        XCTAssertEqual(analyze("bugbotting is not a word").nameIDs, [], "whole words only")
        XCTAssertEqual(analyze("Bugbot and Polaris, please sync").nameIDs, ["bug", "pol"])
    }

    func testGreetingASpecificMemberIsNotACollectiveAddress() {
        let a = analyze("hey Bugbot")
        XCTAssertEqual(a.nameIDs, ["bug"])
        XCTAssertFalse(a.isCollective)
    }

    func testSharedWordsInNamesAreNotEnoughToAddressAnyone() {
        let twins = [GroupMember(id: "a", name: "Data Bot"), GroupMember(id: "b", name: "Code Bot")]
        let a = AddressingAnalyzer.analyze(text: "the bot is slow", members: twins)
        XCTAssertTrue(a.nameIDs.isEmpty)
        XCTAssertEqual(AddressingAnalyzer.analyze(text: "Data Bot, hi", members: twins).nameIDs, ["a"])
    }

    func testAcknowledgementsNeedNoReply() {
        for text in ["ok", "OK!", "thanks", "Thanks!", "thank you so much", "thanks guys!", "👍", "got it", "sounds good", "perfect, thanks everyone", "lol", "🙏🙏"] {
            XCTAssertTrue(analyze(text).isAcknowledgement, text)
        }
        for text in ["thanks, can you also fix the footer?", "ok but why did it fail", "got it?", "Hey Guys!", "great, now deploy it"] {
            XCTAssertFalse(analyze(text).isAcknowledgement, text)
        }
    }

    func testQuestionsToAnyoneAreRecognized() {
        for text in ["Is anyone able to look at the logs?", "Who can help me with the build?", "does anybody know why this fails", "Can someone check the server?"] {
            let a = analyze(text)
            XCTAssertTrue(a.isAnyoneQuestion, text)
            XCTAssertFalse(a.isCollective, text)
        }
        let mixed = analyze("Hey guys, can anyone look at this?")
        XCTAssertTrue(mixed.isAnyoneQuestion)
        XCTAssertFalse(mixed.isCollective, "one answer is enough for an 'anyone' question")
    }

    func testExplicitMentionsPassThroughAndUnknownIDsAreIgnored() {
        let a = analyze("@Bugbot do it", explicit: ["bug", "ghost"])
        XCTAssertEqual(a.explicitIDs, ["bug"])
        XCTAssertEqual(a.addressedIDs, ["bug"])
    }

    func testOddInputNeverCrashes() {
        for text in ["", " ", "\n\n", String(repeating: "a", count: 50_000), "@@@", "🙂🙂🙂", "(((", "\\", "Bugbot".uppercased(), "\u{0}"] {
            _ = analyze(text)
            _ = plan(text)
        }
        _ = GroupTurnPlanner.plan(forHumanMessage: "hi", explicitMentionIDs: [], members: [])
    }

    func testSmallTalkTakesTheFastPathAndWorkDoesNot() {
        for text in ["Hey Guys!", "hello", "how are you all doing today?", "What's your favorite color?", "Tai Lung, what do you think of Rust?"] {
            XCTAssertTrue(analyze(text).isConversational, text)
        }
        for text in ["Install nginx on the server", "Please fix the build", "check https://example.com", "look at /etc/hosts", "write a script to rename files", "thanks",
                     "Everyone doublecheck your vms for the \"gh\" cli binary.", "Is gh installed on your machine?", "tell me the version of node", "Standup in five", "who has the latest build",
                     "Where is that screenshot Tai Lung?", "did you send the picture?", "where is the result?"] {
            XCTAssertFalse(analyze(text).isConversational, text)
        }
        XCTAssertFalse(analyze(String(repeating: "chat ", count: 40)).isConversational, "long messages get the full agent")
    }

    func testATaskForEveryoneIsWorkNotSmallTalkAndRunsInParallel() {
        let text = "Everyone doublecheck your vms for the \"gh\" cli binary."
        let a = analyze(text)
        XCTAssertTrue(a.isCollective)
        XCTAssertFalse(a.isConversational, "must run real checks, not answer from imagination")
        let p = plan(text)
        XCTAssertEqual(p.mustReplyIDs.count, 4)
        XCTAssertFalse(p.isSequential)
    }

    func testGreetingsStillTakeTurnsSequentially() {
        XCTAssertTrue(plan("Hey Guys!").isSequential)
        XCTAssertTrue(plan("how are you all doing today?").isSequential)
    }

    func testStandUpsAndStatusChecksAreStatusRequests() {
        for text in ["@everyone Daily Stand-up: Please provide your status updates and any blockers. I will then hand out tasks for the day.",
                     "standup time", "Daily standup in 5", "give me a status update", "any blockers?", "what are you working on?",
                     "What have you been working on", "what did you do yesterday", "quick check-in please", "report in", "progress report?"] {
            XCTAssertTrue(AddressingAnalyzer.isStatusRequest(text), text)
        }
        for text in ["Install gh on your VM", "Hey Guys!", "thanks", "fix the build", "check the logs for errors", "who has the latest build"] {
            XCTAssertFalse(AddressingAnalyzer.isStatusRequest(text), text)
        }
        XCTAssertFalse(AddressingAnalyzer.isStatusRequest(String(repeating: "standup ", count: 200)), "a wall of text is not a stand-up call")
    }

    func testAStandUpForEveryoneIsAnsweredByEveryoneInParallelFromOwnKnowledge() {
        let text = "@everyone Daily Stand-up: Please provide your status updates and any blockers."
        let a = analyze(text, explicit: Set(members.map(\.id)))
        XCTAssertTrue(a.isStatusRequest)
        XCTAssertFalse(a.isConversational, "not small talk: needs the stand-up shape")
        let p = plan(text, explicit: Set(members.map(\.id)))
        XCTAssertEqual(p.mustReplyIDs.count, 4)
        XCTAssertFalse(p.isSequential)
    }

    // MARK: planning

    func testHeyGuysGuaranteesEveryMemberAnswersInOrder() {
        let p = plan("Hey Guys!")
        XCTAssertEqual(members.map { p.obligation(of: $0.id) }, [.mustReply, .mustReply, .mustReply, .mustReply])
        XCTAssertEqual(p.rollCall, ["bug", "tai", "smith", "pol"])
        XCTAssertTrue(p.isSequential)
        XCTAssertNotNil(p.floorResponderID)
        XCTAssertFalse(p.isAcknowledgement)
    }

    func testAnAtMentionGuaranteesThatMemberOnly() {
        let p = plan("@Bugbot can you check the build?", explicit: ["bug"])
        XCTAssertEqual(p.obligation(of: "bug"), .mustReply)
        XCTAssertEqual(p.obligation(of: "tai"), .optional)
        XCTAssertFalse(p.isSequential)
        XCTAssertEqual(p.floorResponderID, "bug")
    }

    func testAPlainNameGuaranteesThatMemberToo() {
        let p = plan("Tai Lung, are you free to pair on this?")
        XCTAssertEqual(p.obligation(of: "tai"), .mustReply)
        XCTAssertEqual(p.obligation(of: "bug"), .optional)
        XCTAssertEqual(p.reason(of: "tai"), "addressed by name")
    }

    func testAMessageForNobodyStillGetsOneGuaranteedAnswerFromTheBestFit() {
        let p = plan("What is your view on the engineering approach here?")
        XCTAssertEqual(p.obligation(of: "tai"), .mustReply, "the engineer is the best fit")
        XCTAssertEqual(p.floorResponderID, "tai")
        XCTAssertEqual(p.mustReplyIDs, ["tai"])
        XCTAssertEqual(p.obligation(of: "bug"), .optional)

        let ui = plan("Any design feedback on the new layout?")
        XCTAssertEqual(ui.floorResponderID, "pol")
    }

    func testTiesGoToTheCoordinatorThenTheFirstMember() {
        XCTAssertEqual(plan("Something unrelated happened today").floorResponderID, "bug")
        XCTAssertEqual(plan("Something unrelated happened today", coordinator: "smith").floorResponderID, "smith")
    }

    func testAnyoneQuestionsGetExactlyOneGuaranteedAnswer() {
        let p = plan("Can someone check the logs for errors?")
        XCTAssertEqual(p.mustReplyIDs.count, 1)
        XCTAssertFalse(p.isSequential)
    }

    func testAcknowledgementsNeverForceAReply() {
        for text in ["thanks", "ok 👍", "thanks guys!", "thanks Tai Lung", "got it"] {
            let p = plan(text)
            XCTAssertTrue(p.isAcknowledgement, text)
            XCTAssertTrue(p.mustReplyIDs.isEmpty, text)
            XCTAssertNil(p.floorResponderID, text)
        }
    }

    func testAtEveryoneIsARollCall() {
        let p = plan("@everyone standup in five", explicit: Set(members.map(\.id)))
        XCTAssertEqual(p.mustReplyIDs.count, 4)
        XCTAssertFalse(p.isSequential, "a task for everyone runs in parallel: each member works on its own VM")
    }

    func testNamedMembersGoFirstInTheRollCall() {
        let p = plan("Hey guys, especially Polaris: how is everyone doing today?", explicit: [])
        XCTAssertEqual(p.rollCall.first, "pol")
        XCTAssertEqual(p.mustReplyIDs.count, 4)
    }

    func testASingleMemberGroupAlwaysAnswers() {
        let solo = [bug]
        for text in ["Hey Guys!", "random thought", "can you check this?"] {
            let p = GroupTurnPlanner.plan(forHumanMessage: text, explicitMentionIDs: [], members: solo)
            XCTAssertEqual(p.obligation(of: "bug"), .mustReply, text)
        }
    }

    // MARK: ledger

    func testARollCallTakesTurnsInOrder() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("Hey Guys!"))
        XCTAssertTrue(ledger.canProceed(messageID: "m1", botID: "bug"))
        XCTAssertFalse(ledger.canProceed(messageID: "m1", botID: "tai"))
        XCTAssertFalse(ledger.canProceed(messageID: "m1", botID: "pol"))
        ledger.record(messageID: "m1", botID: "bug", .replied)
        XCTAssertTrue(ledger.canProceed(messageID: "m1", botID: "tai"))
        XCTAssertFalse(ledger.canProceed(messageID: "m1", botID: "smith"))
        ledger.record(messageID: "m1", botID: "tai", .failed("model timed out"))
        XCTAssertTrue(ledger.canProceed(messageID: "m1", botID: "smith"), "a failure must not block the ones behind it")
    }

    func testAMessageIsSettledOnlyWhenEveryoneOwingAnAnswerHasFinished() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("@Bugbot hi", explicit: ["bug"]))
        XCTAssertFalse(ledger.isSettled(messageID: "m1"))
        ledger.record(messageID: "m1", botID: "bug", .replied)
        XCTAssertFalse(ledger.isSettled(messageID: "m1"), "optional members are still thinking")
        for id in ["tai", "smith", "pol"] { ledger.record(messageID: "m1", botID: id, .passed("nothing to add")) }
        XCTAssertTrue(ledger.isSettled(messageID: "m1"))
        XCTAssertTrue(ledger.actionsAfterSettling(messageID: "m1").isEmpty)
    }

    func testIfNobodyAnswersTheFloorResponderIsAskedExactlyOnce() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("What is your view on the engineering approach here?"))
        // Even the best fit "passed" (e.g. its gate said no): the message must still be answered.
        for m in members { ledger.record(messageID: "m1", botID: m.id, .passed("gate said no")) }
        XCTAssertEqual(ledger.actionsAfterSettling(messageID: "m1"), [.fallback(botID: "tai")])
        XCTAssertTrue(ledger.actionsAfterSettling(messageID: "m1").isEmpty, "handed out once")
    }

    func testAcknowledgementsAreAllowedToGoUnanswered() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("thanks"))
        for m in members { ledger.record(messageID: "m1", botID: m.id, .passed("nothing to add")) }
        XCTAssertTrue(ledger.actionsAfterSettling(messageID: "m1").isEmpty)
    }

    func testAFailedRequiredMemberIsReportedNotSilentlyDropped() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("@Bugbot do it", explicit: ["bug"]))
        ledger.record(messageID: "m1", botID: "bug", .failed("no sandbox"))
        for id in ["tai", "smith", "pol"] { ledger.record(messageID: "m1", botID: id, .passed("not addressed")) }
        let actions = ledger.actionsAfterSettling(messageID: "m1")
        XCTAssertEqual(actions, [.failureNotice(botID: "bug", reason: "no sandbox")], "report it; do not make another bot answer in its place")
        XCTAssertTrue(ledger.actionsAfterSettling(messageID: "m1").isEmpty)
    }

    func testAFailureIsStillReportedWhenOthersAnswered() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("Hey Guys!"))
        ledger.record(messageID: "m1", botID: "bug", .replied)
        ledger.record(messageID: "m1", botID: "tai", .failed("timeout"))
        ledger.record(messageID: "m1", botID: "smith", .replied)
        ledger.record(messageID: "m1", botID: "pol", .replied)
        XCTAssertEqual(ledger.actionsAfterSettling(messageID: "m1"), [.failureNotice(botID: "tai", reason: "timeout")])
    }

    func testALeavingMemberDoesNotHangTheMessage() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("Hey Guys!"))
        for id in ["bug", "tai", "smith"] { ledger.record(messageID: "m1", botID: id, .replied) }
        XCTAssertFalse(ledger.isSettled(messageID: "m1"))
        ledger.memberLeft("pol")
        XCTAssertTrue(ledger.isSettled(messageID: "m1"))
    }

    func testAnAnswerAlreadyGivenIsNeverDowngraded() {
        var ledger = TurnLedger()
        ledger.begin(messageID: "m1", plan: plan("@Bugbot hi", explicit: ["bug"]))
        ledger.record(messageID: "m1", botID: "bug", .replied)
        ledger.record(messageID: "m1", botID: "bug", .passed("late gate"))
        XCTAssertEqual(ledger.outcome(messageID: "m1", botID: "bug"), .replied)
    }

    func testTheLedgerForgetsOldMessages() {
        var ledger = TurnLedger(capacity: 3)
        for i in 0..<5 { ledger.begin(messageID: "m\(i)", plan: plan("hello")) }
        XCTAssertFalse(ledger.isTracking("m0"))
        XCTAssertTrue(ledger.isTracking("m4"))
    }

    func testUnknownMessagesAreHarmless() {
        var ledger = TurnLedger()
        ledger.record(messageID: "nope", botID: "bug", .replied)
        XCTAssertTrue(ledger.isSettled(messageID: "nope"))
        XCTAssertTrue(ledger.actionsAfterSettling(messageID: "nope").isEmpty)
        XCTAssertTrue(ledger.canProceed(messageID: "nope", botID: "bug"))
    }

    // MARK: reply gate

    func testOnlyAClearLoneNoMeansStayQuiet() {
        for no in ["NO", "No", "no.", "**NO**", "NO!", "  no  \n", "\"No\"", "NO - it was already handled", "<think>The user said hello.</think>NO"] {
            XCTAssertFalse(ReplyGate.shouldReply(from: no), "\"\(no)\" should be a refusal")
        }
        for yes in ["YES", "yes.", "Yes, I should", "", "   ", "I think so", "NOT SURE", "NOPE, kidding: yes", "unclear",
                    "<think>NO NO NO</think>YES", "No, wait: YES, reply", "<think>never closed NO", "maybe",
                    "No one has replied to the user's greeting yet, so I should say hello back to them now"] {
            XCTAssertTrue(ReplyGate.shouldReply(from: yes), "\"\(yes)\" must still produce a reply")
        }
    }
}

final class ModelTiersTests: XCTestCase {
    func testSuggestsTheSmallestGeneralChatModel() {
        let installed = ["qwen2.5-coder:7b-base", "qwen3.5:4b", "qwen3.5:9b-mlx", "gemma4:12b-mlx", "qwen3.8:27b-mlx"]
        XCTAssertEqual(ModelTiers.suggestedFastModel(from: installed), "qwen3.5:4b")
        XCTAssertNil(ModelTiers.suggestedFastModel(from: ["qwen3.8:27b-mlx"]))
    }

    func testAskHelpersIsOfferedAndRunsInParallelInput() async throws {
        let registry = ToolRegistry(onAskHelpers: { tasks in ["count": tasks.count] })
        XCTAssertTrue(registry.schemas.contains { $0.name == "ask_helpers" })
        XCTAssertEqual(GuardrailPolicyProbe.verdictIsAllow("ask_helpers"), true)
    }
}

private enum GuardrailPolicyProbe {
    static func verdictIsAllow(_ tool: String) -> Bool {
        let c = ActionClassifier.classify(tool: tool, arguments: [:])
        return c.findings.allSatisfy { $0.clean == .allow && $0.tainted == .allow }
    }
}
