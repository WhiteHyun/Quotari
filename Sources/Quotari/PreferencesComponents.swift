import QuotariCore
import SwiftUI

struct PreferencesCard<Content: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder let content: Content

  init(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title3.weight(.semibold))
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      content
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Theme.settingsCardBackground,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Theme.settingsSeparator)
    }
    .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
  }
}

struct PreferencesRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(Theme.settingsSeparator)
      .frame(height: 1)
  }
}

struct ProviderIconView: View {
  let descriptor: ProviderDescriptor
  var size: CGFloat = 38

  private var accent: Color {
    Color(
      red: descriptor.metadata.accent.r,
      green: descriptor.metadata.accent.g,
      blue: descriptor.metadata.accent.b
    )
  }

  private var systemImage: String {
    switch descriptor.id {
    case .claude: "sparkles"
    case .codex: "terminal.fill"
    }
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .fill(accent.opacity(0.14))
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .stroke(accent.opacity(0.22))
      Image(systemName: systemImage)
        .font(.system(size: size * 0.43, weight: .semibold))
        .foregroundStyle(accent)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct PreferencesBadge: View {
  let title: String
  var color: Color = .secondary

  var body: some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.13), in: Capsule())
      .foregroundStyle(color)
  }
}

struct PreferencesToggleRow: View {
  let title: String
  let detail: String?
  @Binding var isOn: Bool

  init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.detail = detail
    _isOn = isOn
  }

  var body: some View {
    PreferencesControlRow(title, detail: detail) {
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(.blue)
        .accessibilityLabel(title)
    }
  }
}

struct PreferencesControlRow<Control: View>: View {
  let title: String
  let detail: String?
  @ViewBuilder let control: Control

  init(
    _ title: String,
    detail: String? = nil,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.detail = detail
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 24)
      control
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
