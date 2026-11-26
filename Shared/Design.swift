import SwiftUI

enum Paper {
    static let green = Color(red: 74/255, green: 93/255, blue: 35/255)
    static let background = Color(red: 247/255, green: 244/255, blue: 236/255)
    static let card = Color(red: 255/255, green: 253/255, blue: 247/255)
    static let ink = Color(red: 46/255, green: 49/255, blue: 38/255)
    static let muted = Color(red: 99/255, green: 99/255, blue: 86/255)
    static let border = Color(red: 222/255, green: 217/255, blue: 205/255)
    static let amber = Color(red: 201/255, green: 138/255, blue: 26/255)
    static let amberText = Color(red: 115/255, green: 68/255, blue: 5/255)
    static let amberFill = Color(red: 252/255, green: 238/255, blue: 209/255)
    static let gray = Color(red: 138/255, green: 138/255, blue: 133/255)
    static let grayFill = Color(red: 237/255, green: 235/255, blue: 229/255)
    static let greenFill = Color(red: 230/255, green: 234/255, blue: 215/255)
}

struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).background(Paper.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Paper.border).allowsHitTesting(false) }
    }
}

extension View {
    func paperCard() -> some View { modifier(PaperCard()) }
    func testID(_ id: String) -> some View { accessibilityIdentifier(id) }
}

struct PrimaryButton: View {
    var title: String
    var id: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 46).padding(.horizontal, 12)
                .foregroundStyle(.white).background(Paper.green, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).testID(id)
    }
}

struct TextAction: View {
    var title: String
    var id: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Paper.green).testID(id)
    }
}

struct JobTag: View {
    let status: JobStatus
    var dropdown = false
    var body: some View {
        HStack(spacing: 4) {
            if status == .rejected { Circle().fill(Paper.gray).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(status.title).font(.caption.weight(.semibold))
            if dropdown { Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true) }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .foregroundStyle(status == .offer ? .white : status == .interview ? Paper.green : Paper.ink)
        .background(status == .offer ? Paper.green : status == .interview ? Paper.greenFill : Paper.grayFill, in: Capsule())
    }
}
