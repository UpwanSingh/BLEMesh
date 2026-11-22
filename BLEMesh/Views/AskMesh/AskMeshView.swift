import SwiftUI
import SwiftData
import MeshCore

/// "Ask the mesh": answered by this phone's on-device model, or by the nearest phone that has
/// one, or by the offline guidance library — no internet in any case.
struct AskMeshView: View {
    @EnvironmentObject private var mesh: MeshService
    @Query(filter: #Predicate<StoredMessage> { $0.conversationKey == "ai" }, sort: \StoredMessage.sentAt)
    private var messages: [StoredMessage]
    @State private var question = ""
    @State private var asking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                source
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if messages.isEmpty {
                                suggestions
                            }
                            ForEach(messages) { message in
                                MessageBubble(message: message, showSender: true).id(message.id)
                            }
                            if !mesh.pendingQuestions.isEmpty || asking {
                                HStack {
                                    ProgressView()
                                    Text(asking ? "Thinking…" : "Waiting for an answer from the mesh…")
                                        .font(.caption).foregroundStyle(Theme.Colors.secondaryText)
                                    Spacer()
                                }
                                .accessibilityIdentifier("ask.pending")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack(spacing: 10) {
                    TextField("Ask anything — first aid, safety, translation…", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(ask)
                        .accessibilityIdentifier("ask.text")
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
                        .accessibilityIdentifier("ask.send")
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Ask the Mesh")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var source: some View {
        HStack(spacing: 6) {
            Image(systemName: mesh.ai.hasGenerativeModel ? "iphone.gen3" : (mesh.node.bestAIHelper() != nil ? "person.wave.2" : "book.closed"))
            Text(sourceText).font(.caption)
            Spacer()
        }
        .foregroundStyle(Theme.Colors.secondaryText)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Theme.Colors.card)
        .accessibilityIdentifier("ask.source")
    }

    private var sourceText: String {
        if mesh.ai.hasGenerativeModel { return "Answered by this phone's on-device AI — private and offline" }
        if let helper = mesh.node.bestAIHelper() {
            let hops = helper.hops.map { $0 == 0 ? "nearby" : "\($0 + 1) hops away" } ?? ""
            return "Answered by \(helper.nickname)'s on-device AI (\(hops)), end-to-end encrypted"
        }
        return "Answered from the built-in offline first-aid & safety guide"
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking").font(.headline)
            ForEach(["How do I stop heavy bleeding?", "Someone is choking, what do I do?", "What should I do in a flood?", "How do I treat a burn?"], id: \.self) { s in
                Button(s) { question = s; ask() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ask() {
        let q = question
        question = ""
        asking = true
        Task {
            await mesh.ask(q)
            asking = false
        }
    }
}
