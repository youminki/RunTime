import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 목록 줄을 끌어다 놓아 순서를 바꾼다. 끄는 동안 다른 줄 위에 올리면 바로 그 자리로 옮겨 보여 준다.
/// 끄는 줄은 바깥 모델에 둔다 (이 툴체인은 @State를 못 써서).
struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(from, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
}

extension View {
    /// `id` 줄을 끌 수 있고, 다른 줄을 이 줄 위로 끌어오면 `move(끈 줄, 이 줄)`을 부른다.
    func reorderable(_ id: String, dragging: Binding<String?>, move: @escaping (String, String) -> Void) -> some View {
        onDrag {
            dragging.wrappedValue = id
            // 목록 밖에 놓아 취소하면 놓기 알림이 오지 않아, 마우스 단추를 놓는 순간 끄는 상태를 푼다
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                if dragging.wrappedValue == id { dragging.wrappedValue = nil }
            }
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [UTType.plainText], delegate: ReorderDrop(target: id, dragging: dragging, move: move))
    }
}
