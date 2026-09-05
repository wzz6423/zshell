import XCTest
import AppKit
@testable import STTextKitPlus

final class NSTextLayoutFragmentTests: XCTestCase {

    func testTextLineFragmentAtPointMultipleLines() throws {
        let textContentStorage = NSTextContentStorage()
        let textLayoutManager = NSTextLayoutManager()
        textContentStorage.addTextLayoutManager(textLayoutManager)

        let textContainer = NSTextContainer(size: CGSize(width: 100, height: 1000))
        textLayoutManager.textContainer = textContainer

        let longText = "This is a long paragraph that should wrap to multiple lines within a single layout fragment when rendered in a narrow container."
        textContentStorage.textStorage?.setAttributedString(
            NSAttributedString(string: longText, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        )

        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        var layoutFragments: [NSTextLayoutFragment] = []
        textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location, options: []) { fragment in
            layoutFragments.append(fragment)
            return true
        }

        guard let multiLineFragment = layoutFragments.first(where: { $0.textLineFragments.count > 1 }) else {
            XCTFail("Expected at least one layout fragment with multiple line fragments. Fragments: \(layoutFragments.map { $0.textLineFragments.count })")
            return
        }

        print("Layout fragment frame: \(multiLineFragment.layoutFragmentFrame)")
        print("Number of line fragments: \(multiLineFragment.textLineFragments.count)")

        for (index, lineFragment) in multiLineFragment.textLineFragments.enumerated() {
            print("Line \(index): typographicBounds = \(lineFragment.typographicBounds)")

            let expectedRect = lineFragment.typographicBounds.offsetBy(
                dx: multiLineFragment.layoutFragmentFrame.origin.x,
                dy: multiLineFragment.layoutFragmentFrame.origin.y
            )
            print("  Document rect: \(expectedRect)")
        }

        let lineFragments = multiLineFragment.textLineFragments
        XCTAssertGreaterThan(lineFragments.count, 1, "Need multiple line fragments for this test")

        let line0 = lineFragments[0]
        let line1 = lineFragments[1]

        XCTAssertNotEqual(line0.typographicBounds.origin.y, line1.typographicBounds.origin.y,
            "Line fragments should have different Y origins within layout fragment. Line0: \(line0.typographicBounds), Line1: \(line1.typographicBounds)")

        let line0DocRect = line0.typographicBounds.offsetBy(
            dx: multiLineFragment.layoutFragmentFrame.origin.x,
            dy: multiLineFragment.layoutFragmentFrame.origin.y
        )
        let line1DocRect = line1.typographicBounds.offsetBy(
            dx: multiLineFragment.layoutFragmentFrame.origin.x,
            dy: multiLineFragment.layoutFragmentFrame.origin.y
        )

        print("Line 0 document rect: \(line0DocRect)")
        print("Line 1 document rect: \(line1DocRect)")

        let pointInLine0 = CGPoint(x: line0DocRect.midX, y: line0DocRect.midY)
        let pointInLine1 = CGPoint(x: line1DocRect.midX, y: line1DocRect.midY)

        print("Testing point in line 0: \(pointInLine0)")
        print("Testing point in line 1: \(pointInLine1)")

        let foundLine0 = multiLineFragment.textLineFragment(at: pointInLine0)
        let foundLine1 = multiLineFragment.textLineFragment(at: pointInLine1)

        XCTAssertNotNil(foundLine0, "Should find line fragment for point in line 0")
        XCTAssertNotNil(foundLine1, "Should find line fragment for point in line 1")

        XCTAssertEqual(foundLine0?.characterRange, line0.characterRange,
            "Point in line 0 rect should find line 0. Found: \(String(describing: foundLine0?.characterRange)), Expected: \(line0.characterRange)")
        XCTAssertEqual(foundLine1?.characterRange, line1.characterRange,
            "Point in line 1 rect should find line 1. Found: \(String(describing: foundLine1?.characterRange)), Expected: \(line1.characterRange)")
    }
}
