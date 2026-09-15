import XCTest
@testable import GroundingContract

final class LexiconTests: XCTestCase {

    private func normalized(_ text: String) -> [String] {
        Lexicon.tokenize(text).map(\.normalized)
    }

    func testDigitBearingSeparatorsSurviveTokenization() {
        XCTAssertEqual(normalized("v1.2.3"), ["v1.2.3"])
        XCTAssertEqual(normalized("SKU-4471"), ["sku-4471"])
        XCTAssertEqual(normalized("2026-09-15"), ["2026-09-15"])
        XCTAssertEqual(normalized("3.5"), ["3.5"])
    }

    func testThousandsSeparatorsAreDroppedSoFiguresCompareEqual() {
        XCTAssertEqual(normalized("4,200"), ["4200"])
        XCTAssertEqual(normalized("4200"), ["4200"])
    }

    func testLetterOnlySeparatorsStillSplit() {
        // No digit on either side, so these are two words and a sentence end.
        XCTAssertEqual(normalized("state-of-the-art"), ["state", "of", "the", "art"])
        XCTAssertEqual(normalized("end.Next"), ["end", "next"])
    }

    func testTrailingPunctuationIsNotPartOfTheToken() {
        XCTAssertEqual(normalized("budget."), ["budget"])
        XCTAssertEqual(normalized("(cache)"), ["cache"])
    }

    func testNegationIsNotAStopword() {
        // Stripping "not" would make "not evicted" and "evicted" identical,
        // which is a silent correctness bug rather than a recall trade-off.
        XCTAssertFalse(Lexicon.stopwords.contains("not"))
        XCTAssertFalse(Lexicon.stopwords.contains("no"))
        XCTAssertTrue(Lexicon.contentTokens("not evicted").map(\.normalized).contains("not"))
    }

    func testContentTokensDropStopwordsAndBareLettersButKeepDigits() {
        let tokens = Lexicon.contentTokens("a 7 x cache of the budget").map(\.normalized)
        XCTAssertEqual(tokens, ["7", "cache", "budget"])
    }

    func testEmptyAndPunctuationOnlyInputProduceNoTokens() {
        XCTAssertTrue(Lexicon.tokenize("").isEmpty)
        XCTAssertTrue(Lexicon.tokenize("   ...  ---  ").isEmpty)
    }

    func testRareTermOutweighsCommonTermInIDF() {
        // "cache" appears in all three documents, "kubernetes" in none.
        let idf = InverseDocumentFrequency(documents: [
            "the cache is warm", "the cache is cold", "the cache is empty"
        ])
        XCTAssertGreaterThan(idf.weight(for: "kubernetes"), idf.weight(for: "cache"))
    }

    func testIDFOverAnEmptyCorpusIsFiniteAndPositive() {
        let idf = InverseDocumentFrequency(documents: [])
        let weight = idf.weight(for: "anything")
        XCTAssertTrue(weight.isFinite)
        XCTAssertGreaterThan(weight, 0)
    }
}
