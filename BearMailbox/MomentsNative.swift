import SwiftUI
import PhotosUI
import UIKit

// Keep Discover as the tab root. Only tapping its Moments row opens the feed;
// the feed's back button (or the navigation back gesture) returns here.
struct DiscoverView: View {
    @Binding var showingMoments: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    Button {
                        showingMoments = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 29, weight: .medium))
                                .foregroundStyle(AngularGradient(
                                    colors: [.pink, .orange, .yellow, .green, .cyan, .pink],
                                    center: .center
                                ))
                                .frame(width: 44, height: 44)
                            Text("朋友圈")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开朋友圈动态")
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingMoments) {
                NativeMomentsView { showingMoments = false }
            }
        }
    }
}

// Native Moments page. The public server remains the source of truth; this view only replaces the web shell.
struct NativeMomentsView: View {
    let onClose: () -> Void

    @AppStorage("myNickname") private var nickname = "我"
    @AppStorage("mySignature") private var signature = "今天也要好好生活"
    @AppStorage("momentsBgVersion") private var backgroundVersion = 0
    @State private var feed: MomentsFeedDTO?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingComposer = false
    @State private var showingCreateMenu = false
    @State private var openedImageURL: URL?
    @State private var composerImages: [UIImage] = []

    private var me: String { feed?.me ?? "owner" }
    private var myProfile: MomentProfileDTO? { feed?.profiles[me] }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        profileHeader
                            .padding(.top, proxy.safeAreaInsets.top + 78)

                        HStack {
                            Text("动态")
                                .font(.system(size: 18, weight: .semibold))
                            Spacer()
                            if isLoading {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 26)
                        .padding(.bottom, 8)

                        if let errorMessage, feed == nil {
                            errorView(errorMessage)
                        } else {
                            ForEach(feed?.posts ?? []) { post in
                                NativeMomentRow(
                                    post: post,
                                    profile: feed?.profiles[post.author],
                                    me: me,
                                    onLike: { Task { await like(post) } },
                                    onComment: { text, replyTo in
                                        Task { await comment(post, text: text, replyTo: replyTo) }
                                    },
                                    onDeleteComment: { comment in
                                        Task { await deleteComment(post, comment: comment) }
                                    },
                                    onDelete: { Task { await delete(post) } },
                                    onOpenImage: { openedImageURL = $0 }
                                )
                            }
                        }

                        Color.clear.frame(height: proxy.safeAreaInsets.bottom + 44)
                    }
                }
                .transparentTopScrollEdge()
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .refreshable { await reload(showSpinner: false) }

                topBar
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            GeometryReader { backgroundProxy in
                momentsBackground(size: backgroundProxy.size)
            }
            .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task { await reload(showSpinner: true) }
        .sheet(isPresented: $showingComposer) {
            NativeMomentComposer(initialImages: composerImages) { text, images in
                try await MomentsAPI.publish(text: text, images: images)
                await reload(showSpinner: false)
            }
        }
        .sheet(isPresented: $showingCreateMenu) {
            NativeMomentCreateSheet(
                onPhotos: { queueComposer(images: $0) },
                onText: { queueComposer(images: []) }
            )
            .presentationDetents([.height(270)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: Binding(
            get: { openedImageURL != nil },
            set: { if !$0 { openedImageURL = nil } }
        )) {
            if let openedImageURL {
                NativeMomentImageViewer(url: openedImageURL)
            }
        }
    }

    @ViewBuilder
    private func momentsBackground(size: CGSize) -> some View {
        let localImage = UIImage(contentsOfFile: SettingsView.momentsBgPath.path)
        if let localImage {
            Image(uiImage: localImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: 3)
                .clipped()
                .id(backgroundVersion)
                .overlay(Color.white.opacity(0.45))

        } else {
            defaultBackground(size: size)
        }
    }

    private func defaultBackground(size: CGSize) -> some View {
        ZStack {
            Color(red: 0.985, green: 0.975, blue: 0.978)
            RadialGradient(
                colors: [Color(red: 1.0, green: 0.83, blue: 0.90).opacity(0.42), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: size.width * 1.05
            )
            RadialGradient(
                colors: [Color(red: 0.86, green: 0.84, blue: 1.0).opacity(0.25), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: size.width * 1.2
            )
        }
        .frame(width: size.width, height: size.height)
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .modifier(MomentsGlassCircle())
                }
                Spacer()
                Button { showingCreateMenu = true } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .modifier(MomentsGlassCircle())
                }
                .accessibilityLabel("发表动态")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.28, green: 0.25, blue: 0.29))
            .padding(.horizontal, 18)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 16) {
                MyAvatar(size: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(nickname.isEmpty ? (myProfile?.name ?? "我") : nickname)
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                    Text(signature)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text("暂时没加载出来")
                .font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("再试一次") { Task { await reload(showSpinner: true) } }
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 30)
    }

    private func queueComposer(images: [UIImage]) {
        showingCreateMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            composerImages = images
            showingComposer = true
        }
    }

    @MainActor
    private func reload(showSpinner: Bool) async {
        if showSpinner { isLoading = true }
        defer { isLoading = false }
        do {
            feed = try await MomentsAPI.feed()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func like(_ post: MomentPostDTO) async {
        do {
            try await MomentsAPI.like(id: post.id)
            await reload(showSpinner: false)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func comment(_ post: MomentPostDTO, text: String, replyTo: String?) async {
        do {
            try await MomentsAPI.comment(id: post.id, text: text, replyTo: replyTo)
            await reload(showSpinner: false)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func deleteComment(_ post: MomentPostDTO, comment: MomentCommentDTO) async {
        guard comment.author.caseInsensitiveCompare(me) == .orderedSame else { return }
        do {
            try await MomentsAPI.deleteComment(postID: post.id, commentID: comment.id)
            await reload(showSpinner: false)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func delete(_ post: MomentPostDTO) async {
        do {
            try await MomentsAPI.delete(id: post.id)
            await reload(showSpinner: false)
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NativeMomentRow: View {
    let post: MomentPostDTO
    let profile: MomentProfileDTO?
    let me: String
    let onLike: () -> Void
    let onComment: (String, String?) -> Void
    let onDeleteComment: (MomentCommentDTO) -> Void
    let onDelete: () -> Void
    let onOpenImage: (URL) -> Void

    @State private var isReplying = false
    @State private var reply = ""
    @State private var replyTarget: MomentCommentDTO?
    @State private var pendingDeleteComment: MomentCommentDTO?
    @FocusState private var replyFocused: Bool
    @AppStorage("myNickname") private var myNickname = "我"
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""

    private var authorName: String {
        localName(for: post.author, fallback: post.name ?? profile?.name)
    }
    private var liked: Bool { post.likes.contains(me) }
    private var imageURLs: [URL] { post.imagePaths.compactMap(MomentsAPI.assetURL) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            authorAvatar

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(authorName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.37, green: 0.28, blue: 0.38))
                    Spacer()
                    Text(post.time ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.38))
                    if post.author == me {
                        Menu {
                            Button("删除", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 26, height: 24)
                        }
                    }
                }

                if let text = post.text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 16))
                        .lineSpacing(6)
                        .foregroundStyle(.primary.opacity(0.82))
                        .textSelection(.enabled)
                }

                if !imageURLs.isEmpty {
                    photoGrid
                }

                if let place = post.place, !place.isEmpty {
                    Label(place, systemImage: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.42))
                }

                HStack(spacing: 22) {
                    Button(action: onLike) {
                        Label(post.likes.isEmpty ? "" : "\(post.likes.count)", systemImage: liked ? "heart.fill" : "heart")
                    }
                    Button {
                        replyTarget = nil
                        withAnimation(.easeOut(duration: 0.18)) { isReplying = true }
                        DispatchQueue.main.async { replyFocused = true }
                    } label: {
                        Label(post.comments.isEmpty ? "" : "\(post.comments.count)", systemImage: "bubble.left")
                    }
                    Spacer()
                }
                .font(.system(size: 14))
                .foregroundStyle(liked ? Color(red: 0.80, green: 0.38, blue: 0.56) : .primary.opacity(0.50))
                .buttonStyle(.plain)

                if !post.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(post.comments) { comment in
                            commentRow(comment)
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12)).frame(width: 2)
                    }
                }

                if isReplying {
                    HStack(spacing: 8) {
                        TextField(replyPlaceholder, text: $reply)
                            .focused($replyFocused)
                            .font(.system(size: 14))
                            .padding(.horizontal, 13)
                            .frame(height: 38)
                            .background(.thinMaterial, in: Capsule())
                        Button("发送") {
                            let value = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            reply = ""
                            isReplying = false
                            replyFocused = false
                            let targetID = replyTarget?.id
                            replyTarget = nil
                            onComment(value, targetID)
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 78)
        }
        .confirmationDialog(
            "删除这条评论？",
            isPresented: Binding(
                get: { pendingDeleteComment != nil },
                set: { if !$0 { pendingDeleteComment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let comment = pendingDeleteComment else { return }
                pendingDeleteComment = nil
                onDeleteComment(comment)
            }
            Button("取消", role: .cancel) { pendingDeleteComment = nil }
        }
    }

    private var replyPlaceholder: String {
        guard let replyTarget else { return "说点什么…" }
        return "回复 \(localName(for: replyTarget.author, fallback: replyTarget.name))…"
    }

    @ViewBuilder
    private func commentRow(_ comment: MomentCommentDTO) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(commentLine(comment))
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)

            if comment.author.caseInsensitiveCompare(me) == .orderedSame {
                Menu {
                    Button("删除评论", role: .destructive) {
                        pendingDeleteComment = comment
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.38))
                        .frame(width: 24, height: 24)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            replyTarget = comment
            isReplying = true
            DispatchQueue.main.async { replyFocused = true }
        }
        .contextMenu {
            Button("回复") {
                replyTarget = comment
                isReplying = true
                DispatchQueue.main.async { replyFocused = true }
            }
            if comment.author.caseInsensitiveCompare(me) == .orderedSame {
                Button("删除评论", role: .destructive) {
                    pendingDeleteComment = comment
                }
            }
        }
    }

    private func commentLine(_ comment: MomentCommentDTO) -> AttributedString {
        let name = localName(for: comment.author, fallback: comment.name)
        let replyName = comment.replyTo.flatMap { targetID in
            post.comments.first(where: { $0.id == targetID }).map {
                localName(for: $0.author, fallback: $0.name)
            }
        } ?? comment.replyName
        let prefix = replyName.map { "\(name) 回复 \($0)：" } ?? "\(name)："
        var line = AttributedString("\(prefix)\(comment.text)")
        if let range = line.range(of: prefix) {
            line[range].foregroundColor = Color(red: 0.44, green: 0.30, blue: 0.45)
            line[range].font = .system(size: 13, weight: .semibold)
        }
        return line
    }

    private var savedConversations: [AIConversation] {
        guard let data = conversationsJSON.data(using: .utf8),
              let conversations = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        return conversations
    }

    private var puppyConversation: AIConversation? {
        // 先认模型名就是 puppy 的那个，认不到再按旧规则猜。
        if let exact = savedConversations.first(where: { conversation in
            (conversation.model?.lowercased() ?? "") == "puppy"
        }) { return exact }
        return savedConversations.first { conversation in
            let id = conversation.id.lowercased()
            let name = conversation.name.lowercased()
            let remark = conversation.remark?.lowercased() ?? ""
            let provider = conversation.provider?.lowercased() ?? ""
            let model = conversation.model?.lowercased() ?? ""
            return id == "gpt" || id == "puppy" || name.contains("puppy") || remark.contains("puppy") ||
                provider.contains("openai") || model.contains("gpt")
        }
    }

    /// App-created AIs post as "ai_<lowercased conversation id>"; map them back to the local
    /// contact so the moments feed shows the same avatar and remark as the chat list.
    private func appConversation(for author: String) -> AIConversation? {
        let key = author.lowercased()
        guard key.hasPrefix("ai_") else { return nil }
        let id = String(key.dropFirst(3))
        return savedConversations.first { $0.id.lowercased() == id }
    }

    private func localName(for author: String, fallback: String?) -> String {
        let key = author.lowercased()
        if key == me.lowercased() || key == "owner" {
            let clean = myNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? (fallback ?? "我") : clean
        }
        // 服务端现在的身份 id 是 assistant / assistant-2；旧数据里的 claude / gpt 照样认。
        if key == "claude" || key == "assistant" {
            let clean = assistantRemark.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? (fallback ?? ContactKind.claude.defaultName) : clean
        }
        if key == "gpt" || key == "puppy" || key == "assistant-2" {
            return puppyConversation?.displayName ?? ContactKind.puppy.defaultName
        }
        if let conversation = appConversation(for: author) { return conversation.displayName }
        return fallback ?? author
    }

    @ViewBuilder
    private var authorAvatar: some View {
        let key = post.author.lowercased()
        if key == me.lowercased() || key == "owner" {
            MyAvatar(size: 42)
        } else if key == "claude" || key == "assistant" {
            ContactAvatar(kind: .claude, size: 42)
        } else if key == "gpt" || key == "puppy" || key == "assistant-2" {
            if let conversation = puppyConversation,
               let image = MomentLocalAvatarStore.image(named: conversation.avatarFile) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            } else {
                ContactAvatar(kind: .puppy, size: 42)
            }
        } else if let conversation = appConversation(for: post.author),
                  let image = MomentLocalAvatarStore.image(named: conversation.avatarFile) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
        } else {
            RemoteMomentAvatar(url: MomentsAPI.assetURL(profile?.avatar), name: authorName, size: 42)
        }
    }

    @ViewBuilder
    private var photoGrid: some View {
        if imageURLs.count == 1, let url = imageURLs.first {
            MomentGridImage(url: url)
                .frame(width: 236, height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onOpenImage(url) }
        } else {
            MomentRemotePhotoGrid(urls: imageURLs, onOpenImage: onOpenImage)
        }
    }
}

private enum MomentLocalAvatarStore {
    static func image(named name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAvatars", isDirectory: true)
        return UIImage(contentsOfFile: root.appendingPathComponent(name).path)
    }
}

private struct MomentRemotePhotoGrid: View {
    let urls: [URL]
    let onOpenImage: (URL) -> Void

    private let spacing: CGFloat = 4
    private var columnCount: Int { (urls.count == 2 || urls.count == 4) ? 2 : 3 }
    private var availableWidth: CGFloat {
        min(max(UIScreen.main.bounds.width - 102, 220), 292)
    }
    private var cellSize: CGFloat {
        floor((availableWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
    }
    private var rows: [[URL]] {
        stride(from: 0, to: urls.count, by: columnCount).map { start in
            Array(urls[start..<min(start + columnCount, urls.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, url in
                        MomentGridImage(url: url)
                            .frame(width: cellSize, height: cellSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenImage(url) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }
}

private struct MomentGridImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if phase.error != nil {
                Color.black.opacity(0.05)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            } else {
                Color.black.opacity(0.025)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct RemoteMomentAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.pink.opacity(0.72), .purple.opacity(0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
    }
}

private struct NativeMomentCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    let onPhotos: ([UIImage]) -> Void
    let onText: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("发表动态")
                .font(.system(size: 18, weight: .semibold))

            PhotosPicker(selection: $items, maxSelectionCount: 9, matching: .images) {
                HStack(spacing: 10) {
                    if isLoadingPhotos {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Text(isLoadingPhotos ? "正在读取照片…" : "从相册选择")
                }
                .foregroundStyle(Color(red: 0.97, green: 0.49, blue: 0.68))
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isLoadingPhotos)

            Button {
                dismiss()
                onText()
            } label: {
                Label("发表文字", systemImage: "text.alignleft")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .onChange(of: items.count) { _, count in
            guard count > 0 else { return }
            Task { await loadPhotos() }
        }
    }

    @MainActor
    private func loadPhotos() async {
        isLoadingPhotos = true
        var photos: [UIImage] = []
        for item in items.prefix(9) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            photos.append(image)
        }
        isLoadingPhotos = false
        guard !photos.isEmpty else { return }
        dismiss()
        onPhotos(photos)
    }
}

private struct NativeMomentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage]
    @State private var isPublishing = false
    @State private var errorMessage: String?
    let publish: (String, [String]) async throws -> Void

    init(initialImages: [UIImage], publish: @escaping (String, [String]) async throws -> Void) {
        _photos = State(initialValue: Array(initialImages.prefix(9)))
        self.publish = publish
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $text)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .frame(height: 150)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("这一刻想说点什么？")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                if !photos.isEmpty {
                    MomentComposerPhotoGrid(photos: $photos)
                }

                if photos.count < 9 {
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: 9 - photos.count,
                        matching: .images
                    ) {
                        Label(photos.isEmpty ? "添加照片" : "继续添加", systemImage: "photo")
                            .font(.system(size: 15, weight: .medium))
                    }
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("发动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPublishing ? "发布中…" : "发布") {
                        Task { await submit() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isPublishing || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty))
                }
            }
            .onChange(of: photoItems.count) { _, count in
                guard count > 0 else { return }
                Task { await appendSelectedPhotos() }
            }
        }
    }

    @MainActor
    private func appendSelectedPhotos() async {
        var additions: [UIImage] = []
        for item in photoItems.prefix(9 - photos.count) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            additions.append(image)
        }
        photos.append(contentsOf: additions)
        photoItems = []
    }

    @MainActor
    private func submit() async {
        isPublishing = true
        defer { isPublishing = false }
        do {
            let imageStrings = photos.compactMap(MomentsImageEncoder.base64)
            try await publish(text.trimmingCharacters(in: .whitespacesAndNewlines), imageStrings)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MomentComposerPhotoGrid: View {
    @Binding var photos: [UIImage]

    private let spacing: CGFloat = 8
    private var availableWidth: CGFloat {
        min(max(UIScreen.main.bounds.width - 40, 280), 390)
    }
    private var cellSize: CGFloat {
        floor((availableWidth - spacing * 2) / 3)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cellSize), spacing: spacing), count: 3),
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellSize, height: cellSize)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            guard photos.indices.contains(index) else { return }
                            photos.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.58))
                                .font(.system(size: 21))
                        }
                        .offset(x: 6, y: -6)
                    }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }
}

struct NativeMomentsBackgroundPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var backgroundVersion: Int
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 18) {
            Text("朋友圈背景")
                .font(.system(size: 18, weight: .semibold))
            PhotosPicker(selection: $item, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
            }
            Button(role: .destructive) {
                try? FileManager.default.removeItem(at: SettingsView.momentsBgPath)
                backgroundVersion += 1
                dismiss()
            } label: {
                Text("恢复默认背景").frame(maxWidth: .infinity).frame(height: 42)
            }
        }
        .padding(24)
        .onChange(of: item) { _, newItem in
            Task {
                guard let data = try? await newItem?.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpg = MomentsImageEncoder.jpeg(image, maxSide: 2200, quality: 0.88) else { return }
                try? jpg.write(to: SettingsView.momentsBgPath, options: .atomic)
                await MainActor.run {
                    backgroundVersion += 1
                    dismiss()
                }
            }
        }
    }
}

private struct NativeMomentImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(18)
        }
    }
}

private enum MomentsImageEncoder {
    static func jpeg(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return rendered.jpegData(compressionQuality: quality)
    }

    static func base64(_ image: UIImage) -> String? {
        jpeg(image, maxSide: 1800, quality: 0.82)?.base64EncodedString()
    }
}

private struct MomentsFeedDTO: Decodable {
    let me: String?
    let profiles: [String: MomentProfileDTO]
    let posts: [MomentPostDTO]
}

private struct MomentProfileDTO: Decodable {
    let name: String?
    let avatar: String?
    let cover: String?
}

private struct MomentPostDTO: Decodable, Identifiable {
    let id: String
    let author: String
    let name: String?
    let text: String?
    let image: String?
    let images: [String]?
    let place: String?
    let time: String?
    let likes: [String]
    let comments: [MomentCommentDTO]

    var imagePaths: [String] {
        if let images, !images.isEmpty { return Array(images.prefix(9)) }
        if let image, !image.isEmpty { return [image] }
        return []
    }
}

private struct MomentCommentDTO: Decodable, Identifiable {
    let serverID: String?
    let author: String
    let name: String?
    let text: String
    let time: String?
    let replyTo: String?
    let replyName: String?

    var id: String { serverID ?? "\(author)|\(time ?? "")|\(text)" }

    private enum CodingKeys: String, CodingKey {
        case serverID = "id", author, name, text, time
        case replyTo = "reply_to"
        case replyName = "reply_name"
    }
}

private enum MomentsAPI {
    private static var base: URL? { ServerConfig.momentsBase }

    static func assetURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard let base else { return nil }
        return URL(string: path.hasPrefix("/") ? path : "/\(path)", relativeTo: base)?.absoluteURL
    }

    static func feed() async throws -> MomentsFeedDTO {
        guard let base else { throw MomentsAPIError.server("未设置服务器地址") }
        var request = URLRequest(url: base.appendingPathComponent("api/feed"))
        request.timeoutInterval = 20
        BeardenAuth.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(MomentsFeedDTO.self, from: data)
    }

    static func publish(text: String, images: [String]) async throws {
        var body: [String: Any] = ["text": text]
        if !images.isEmpty { body["images"] = Array(images.prefix(9)) }
        try await post("api/post", body: body)
    }

    static func like(id: String) async throws {
        try await post("api/like", body: ["id": id])
    }

    static func comment(id: String, text: String, replyTo: String?) async throws {
        var body: [String: Any] = ["id": id, "text": text]
        if let replyTo { body["reply_to"] = replyTo }
        try await post("api/comment", body: body)
    }

    static func deleteComment(postID: String, commentID: String) async throws {
        try await post("api/comment/delete", body: ["id": postID, "comment_id": commentID])
    }

    static func delete(id: String) async throws {
        try await post("api/post/delete", body: ["id": id])
    }

    private static func post(_ path: String, body: [String: Any]) async throws {
        guard let base else { throw MomentsAPIError.server("未设置服务器地址") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        BeardenAuth.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MomentsAPIError.server(message ?? "朋友圈服务器暂时没有回应")
        }
    }
}

private enum MomentsAPIError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        if case let .server(message) = self { return message }
        return "朋友圈加载失败"
    }
}



/// Round liquid-glass control matching the system navigation back button in chat screens.
private struct MomentsGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}
