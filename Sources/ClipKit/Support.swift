import Foundation
import SwiftUI

/// 클립보드 기록 설정은 따로 둔 저장소에 쓴다. Pesty 설정 이름(hotkeyKeyCode 등)이 RunTime 설정(hotKeyCode)과 비슷해 섞이지 않게 한다.
/// 테스트는 scripts/test.sh가 정한 빈 저장소를 쓴다.
enum ClipDefaults {
    static let store: UserDefaults = {
        let name = ProcessInfo.processInfo.environment["RUNTIME_CLIP_DEFAULTS"] ?? "dev.runtime.RunTime.clip"
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

/// macOS 27 SDK의 `@State`는 매크로라 Command Line Tools만으로는 빌드되지 않는다 (RunTime HoverFlag와 같은 까닭).
/// sync-pesty.py가 Pesty의 `@State`를 이것으로 바꾼다. 값은 `@StateObject`로 들고 있어 뷰가 다시 만들어져도 남는다.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}

/// ContentUnavailableView는 macOS 14부터 있다. 13에서도 같은 꼴로 보이게 그린다.
struct UnavailableNotice: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text

    init(_ title: LocalizedStringKey, systemImage: String, description: Text) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
