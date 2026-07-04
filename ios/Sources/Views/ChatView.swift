import ComposableArchitecture
import SwiftUI

/// Message transcript plus the input bar; the send button becomes a stop
/// button while a response is streaming.
struct ChatView: View {
  @Bindable var store: StoreOf<EditorFeature>

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 12) {
            if store.messages.isEmpty {
              emptyHint
            }
            ForEach(store.messages) { message in
              MessageBubble(
                message: message,
                isStreaming: message.id == store.streamingMessageID
              )
              .id(message.id)
            }
          }
          .padding()
        }
        .onChange(of: store.messages.last?.content) { _, _ in
          if let lastID = store.messages.last?.id {
            proxy.scrollTo(lastID, anchor: .bottom)
          }
        }
      }

      if let errorMessage = store.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.bottom, 4)
      }

      inputBar
    }
  }

  private var emptyHint: some View {
    VStack(spacing: 8) {
      Text("Describe a small app and I'll build it as a single HTML file.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("“Make me a tip calculator”")
        .font(.callout.italic())
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 40)
  }

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Describe your app…", text: $store.inputText, axis: .vertical)
        .lineLimit(1...4)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))

      if store.isStreaming {
        Button {
          store.send(.cancelStreamTapped)
        } label: {
          Image(systemName: "stop.circle.fill")
            .font(.system(size: 30))
        }
        .accessibilityLabel("Stop generating")
      } else {
        Button {
          store.send(.sendTapped)
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 30))
        }
        .disabled(
          store.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityLabel("Send")
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }
}

struct MessageBubble: View {
  let message: ChatMessage
  let isStreaming: Bool

  var body: some View {
    HStack {
      if message.role == .user {
        Spacer(minLength: 40)
      }
      VStack(alignment: .leading, spacing: 4) {
        if message.content.isEmpty && isStreaming {
          ProgressView()
            .padding(4)
        } else {
          Text(message.content)
            .textSelection(.enabled)
        }
        if message.isFailed {
          Label("Interrupted", systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        message.role == .user
          ? AnyShapeStyle(Color.accentColor.opacity(0.15))
          : AnyShapeStyle(Color(.secondarySystemBackground))
      )
      .clipShape(RoundedRectangle(cornerRadius: 14))
      if message.role == .assistant {
        Spacer(minLength: 40)
      }
    }
    .frame(
      maxWidth: .infinity,
      alignment: message.role == .user ? .trailing : .leading
    )
  }
}
