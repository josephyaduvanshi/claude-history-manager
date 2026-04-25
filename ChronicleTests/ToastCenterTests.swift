import XCTest
@testable import Chronicle

@MainActor
final class ToastCenterTests: XCTestCase {

    func test_post_addsToastToList() {
        let c = ToastCenter()
        XCTAssertTrue(c.toasts.isEmpty)
        c.post(Toast(message: "hi"), autoDismissAfter: nil)
        XCTAssertEqual(c.toasts.count, 1)
        XCTAssertEqual(c.toasts.first?.message, "hi")
    }

    func test_dismiss_removesToast() {
        let c = ToastCenter()
        let t = Toast(message: "one")
        c.post(t, autoDismissAfter: nil)
        c.dismiss(t.id)
        XCTAssertTrue(c.toasts.isEmpty)
    }

    func test_clearAll_removesEverything() {
        let c = ToastCenter()
        c.post(Toast(message: "a"), autoDismissAfter: nil)
        c.post(Toast(message: "b"), autoDismissAfter: nil)
        c.post(Toast(message: "c"), autoDismissAfter: nil)
        XCTAssertEqual(c.toasts.count, 3)
        c.clearAll()
        XCTAssertTrue(c.toasts.isEmpty)
    }

    func test_convenienceInfo_stampsKind() {
        let c = ToastCenter()
        c.info("x")
        XCTAssertEqual(c.toasts.first?.kind, .info)
    }

    func test_convenienceError_stampsKind() {
        let c = ToastCenter()
        c.error("oops")
        XCTAssertEqual(c.toasts.first?.kind, .error)
    }

    func test_autoDismiss_eventuallyRemovesToast() async throws {
        let c = ToastCenter()
        c.post(Toast(message: "quick"), autoDismissAfter: 0.05)
        XCTAssertEqual(c.toasts.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(c.toasts.isEmpty,
                      "toast should auto-dismiss after its window elapses")
    }

    func test_stackCap_dropsOldestAtFifth() {
        let c = ToastCenter()
        for i in 0..<5 {
            c.post(Toast(message: "t\(i)"), autoDismissAfter: nil)
        }
        XCTAssertEqual(c.toasts.count, 4, "stack must cap at 4")
        XCTAssertEqual(c.toasts.first?.message, "t1", "oldest toast must be the one dropped")
    }

    func test_undoAction_invokesCallback() {
        let c = ToastCenter()
        var didUndo = false
        c.successWithUndo("archived") {
            didUndo = true
        }
        let t = c.toasts.first
        XCTAssertEqual(t?.actionLabel, "Undo")
        XCTAssertNotNil(t?.action)
        t?.action?()
        XCTAssertTrue(didUndo)
    }
}
