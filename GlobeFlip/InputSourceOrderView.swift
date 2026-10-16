import SwiftUI

struct InputSourceOrderView: View {
  let snapshot: InputSourceSnapshot
  let move: (String, Int) -> Void

  var body: some View {
    ForEach(Array(snapshot.sources.enumerated()), id: \.element.id) {
      index,
      source in
      HStack(spacing: 12) {
        Image(
          systemName: source.id == snapshot.activeSourceID
            ? "checkmark.circle.fill"
            : "circle"
        )
        .foregroundStyle(
          source.id == snapshot.activeSourceID
            ? Color.green
            : Color.secondary
        )
        .accessibilityLabel(
          source.id == snapshot.activeSourceID
            ? "Active Input Source"
            : "Inactive Input Source"
        )

        VStack(alignment: .leading, spacing: 2) {
          Text(source.localizedName)
          Text(source.id)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Button {
          move(source.id, -1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .help("Move Up")
        .accessibilityLabel("Move \(source.localizedName) up")

        Button {
          move(source.id, 1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == snapshot.sources.count - 1)
        .help("Move Down")
        .accessibilityLabel("Move \(source.localizedName) down")
      }
      .frame(minHeight: 42)
    }
  }
}
