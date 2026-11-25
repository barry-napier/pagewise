import XCTest

final class SplitterTests: XCTestCase {
    func testPiecesStayOnTheirPage() {
        let long = (1...60).map { "Sentence number \($0) talks about the agreement terms." }.joined(separator: " ")
        let pieces = Splitter.split([PageText(page: 0, text: long), PageText(page: 1, text: "Short page.")], targetWords: 120)
        XCTAssertGreaterThan(pieces.count, 3)
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.page == 0 })
        XCTAssertEqual(pieces.last, Piece(page: 1, text: "Short page."))
        XCTAssertTrue(pieces.allSatisfy { Splitter.wordCount($0.text) <= 120 })
    }

    func testOverlapKeepsBorderSentence() {
        let text = (1...40).map { "Clause \($0) applies here." }.joined(separator: " ")
        let pieces = Splitter.split([PageText(page: 0, text: text)], targetWords: 30, overlapWords: 8)
        // The next piece starts with a sentence from the end of the one before.
        let firstOfSecond = pieces[1].text.components(separatedBy: ". ").first!
        XCTAssertTrue(pieces[0].text.contains(firstOfSecond), "\(pieces[0].text) | \(pieces[1].text)")
        XCTAssertNotEqual(pieces[0].text, pieces[1].text)
    }

    func testCleanJoinsWrappedLinesAndHyphens() {
        let page = "This agreement may be termin-\nated by either party with thirty days written notice to\nthe other party at any time."
        XCTAssertEqual(
            Splitter.clean(page),
            "This agreement may be terminated by either party with thirty days written notice to the other party at any time.")
    }
}

final class QuoteCheckTests: XCTestCase {
    let sources = [
        "The tenant shall pay rent on the first day of each month by bank transfer.",
        "Either party may terminate this agree-\nment by giving thirty (30) days’ written notice to the other party.",
    ]

    func testExactQuote() {
        XCTAssertEqual(QuoteCheck.find("pay rent on the first day of each month", in: sources), 0)
    }

    func testSmallDifferencesPass() {
        // Curly quote, hyphen break, case, and the model naming the wrong source.
        XCTAssertEqual(QuoteCheck.find("Either party may terminate this agreement by giving thirty (30) days' written notice", in: sources, hint: 0), 1)
        XCTAssertEqual(QuoteCheck.find("either party may terminate this agreement by giving 30 days written notice to the other party", in: sources), 1)
    }

    func testMadeUpQuoteFails() {
        XCTAssertNil(QuoteCheck.find("The landlord must return the deposit within fourteen days of the end of the lease.", in: sources))
        XCTAssertNil(QuoteCheck.find("rent", in: sources))
    }
}

final class RankingTests: XCTestCase {
    func testFusePrefersItemsHighInBoth() {
        let fused = Ranking.fuse([["a", "b", "c"], ["d", "b", "e"]])
        XCTAssertEqual(fused.first, "b")
        XCTAssertEqual(Set(fused), ["a", "b", "c", "d", "e"])
    }

    func testPackSkipsTooBig() {
        XCTAssertEqual(Ranking.pack([5, 50, 10, 3], budget: 20) { $0 }, [5, 10, 3])
    }

    func testKeywordsAndQuery() {
        XCTAssertEqual(Ranking.keywords("How much notice does the contract need in 2026?"), ["notice", "contract", "need", "2026"])
        XCTAssertEqual(Ranking.ftsQuery("What is the notice period?"), "\"notice\" OR \"period\"")
        XCTAssertNil(Ranking.ftsQuery("what is it?"))
    }

    func testSimilarity() {
        let a = Ranking.normalize([1, 2, 3])
        XCTAssertEqual(Ranking.similarity(a, a[...]), 1, accuracy: 0.0001)
    }
}

final class RelevanceTests: XCTestCase {
    func testDropsUnrelatedQuotes() {
        let good = Citation(doc: 1, title: "Lease", page: 2, quote: "Either party may end this lease by giving 60 days of written notice to the other party.")
        let filler = Citation(doc: 1, title: "Lease", page: 0, quote: "The parties agree to act in good faith and to keep each other informed of anything that affects the property.")
        let kept = Asker.relevant([good, filler], answer: "Either party may end this lease by giving 60 days of written notice.", question: "How much notice to end the lease?")
        XCTAssertEqual(kept, [good])
    }

    func testKeepsBestEvenIfLowOverlap() {
        let pets = Citation(doc: 1, title: "Lease", page: 4, quote: "Pets are allowed with written permission from the landlord. A cat or a small dog is fine.")
        let other = Citation(doc: 1, title: "Lease", page: 0, quote: "This lease is between Northwind Properties Ltd and Jamie Rivera.")
        XCTAssertEqual(Asker.relevant([other, pets], answer: "Yes, a cat is fine.", question: "Can I keep a cat?"), [pets])
    }
}

final class DuplicateQuoteTests: XCTestCase {
    func testDropsQuoteInsideAnother() {
        let long = Citation(doc: 1, title: "Lease", page: 1, quote: "The rent is €1,450 per month. A late fee of €40 applies if rent is more than five days late.")
        let short = Citation(doc: 1, title: "Lease", page: 1, quote: "A late fee of €40 applies if rent is more than five days late.")
        XCTAssertEqual(Asker.relevant([long, short], answer: "The rent is €1,450 and the late fee is €40.", question: "Rent and late fee?"), [long])
    }
}
