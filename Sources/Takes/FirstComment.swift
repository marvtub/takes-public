import SwiftUI

/// Your first comment under the post, as LinkedIn shows it: photo, a grey bubble with
/// "Author", and the text. You type in the bubble; Claude reads and writes posts/first-comment.md.
struct FirstCommentRow: View {
    @Binding var text: String
    let name: String
    let headline: String
    let initials: String
    let photoStamp: Date
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Most relevant").font(LinkedIn.font(12, .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LinkedIn.muted)
            HStack(alignment: .top, spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name).font(LinkedIn.font(13, .semibold)).foregroundStyle(LinkedIn.ink)
                            Text("Author").font(LinkedIn.font(11, .medium)).foregroundStyle(LinkedIn.muted)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                            Spacer()
                            Text("Now").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
                        }
                        Text(headline).font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted).lineLimit(1)
                        TextField("Add a first comment: a link, the resources, a question…", text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(LinkedIn.font(14)).foregroundStyle(LinkedIn.ink)
                            .lineSpacing(4)
                            .focused($focused)
                            .padding(.top, 6)
                            .help("The first comment. Takes posts it under the post once it is live")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.95), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? LinkedIn.blue.opacity(0.5) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    HStack(spacing: 6) {
                        Text("Like").font(LinkedIn.font(12, .semibold))
                        Text("|").font(LinkedIn.font(12))
                        Text("Reply").font(LinkedIn.font(12, .semibold))
                    }
                    .foregroundStyle(LinkedIn.muted)
                    .padding(.leading, 8)
                    .opacity(text.isEmpty ? 0 : 1)
                }
            }
        }
    }

    private var avatar: some View {
        Group {
            if let img = LinkedIn.photo {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinkedIn.blue.opacity(0.85)
                    Text(initials).font(LinkedIn.font(13, .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .id(photoStamp)
    }
}
