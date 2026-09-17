// The semantic-intent module's pure half: how a typed query classifies, and how ties resolve.

import Foundation

@main
@MainActor
struct IntentTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        reminderPhrasesClassify()
        shellCommandsClassify()
        fileLookupsClassify()
        aiQuestionsClassify()
        plainTextMatchesNothing()
        specificIntentBeatsBroadOne()
        rankingIsStrongestFirst()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let classifier = IntentClassifier.standard

    static func reminderPhrasesClassify() {
        expect(
            classifier.best("remind me to drink water in 10 min") == .reminder,
            "'remind me…' reads as reminder intent")
        expect(
            classifier.best("notify me when the build is done") == .reminder,
            "'notify me…' reads as reminder intent")
    }

    static func shellCommandsClassify() {
        expect(classifier.best("git status") == .shellCommand, "a known binary up front is a shell run")
        expect(classifier.best("ls -la ~/Documents") == .shellCommand, "flags after a binary are shell")
        expect(
            classifier.best("cat log.txt | grep error") == .shellCommand,
            "a pipe operator is a shell run whatever leads it")
        expect(
            classifier.best("find my notes about the trip") == nil,
            "'find' as plain English is not promoted into a shell run")
    }

    static func fileLookupsClassify() {
        expect(classifier.best("search files for invoice") == .fileSearch, "'search files' is a lookup")
        expect(classifier.best("report.pdf") == .fileSearch, "a bare filename is a lookup")
        expect(classifier.best("*.png") == .fileSearch, "a glob is a lookup")
        expect(classifier.best("teamlunch") == nil, "a single plain word is not a filename")
    }

    static func aiQuestionsClassify() {
        expect(
            classifier.best("what is the capital of france") == .aiQuestion,
            "a question opener with body is an AI question")
        expect(classifier.best("how do I center a div?") == .aiQuestion, "a trailing '?' is an AI question")
        expect(classifier.best("translate hello into spanish") == .aiQuestion, "an instruction opener too")
    }

    static func plainTextMatchesNothing() {
        expect(classifier.best("hello world") == nil, "an ordinary phrase expresses no intent")
        expect(classifier.ranked("").isEmpty, "an empty query ranks nothing")
    }

    static func specificIntentBeatsBroadOne() {
        // "remind me" (1.0) must outrank the broad question opener, so scheduling stays the default.
        expect(
            classifier.best("remind me what the git command was") == .reminder,
            "reminder intent outranks a co-occurring question")
    }

    static func rankingIsStrongestFirst() {
        let ranked = classifier.ranked("search files and notify me").map(\.intent)
        expect(ranked == [.reminder, .fileSearch], "reminder (1.0) leads file search (0.8)")
    }
}
