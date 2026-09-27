import SwiftUI

/// First card on the setup screen. Expanded while a permission is missing; a green chip when
/// both are granted (click the chip to expand it again).
struct PermissionsCard: View {
    @Bindable var model: AppModel

    private var collapsed: Bool { model.permissions.allGranted && !model.permissionsExpanded }

    var body: some View {
        Group {
            if collapsed {
                chip.transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                card.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: collapsed)
        .animation(.easeInOut(duration: 0.2), value: model.permissions)
    }

    private var chip: some View {
        Button {
            model.permissionsExpanded = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                Text("Permissions OK")
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.green.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Screen Recording and Accessibility are allowed. Click for details.")
    }

    private var card: some View {
        Card(tint: model.permissions.allGranted ? nil : .orange) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(title: model.permissions.allGranted ? "Permissions" : "Permissions needed",
                               symbol: model.permissions.allGranted ? "checkmark.shield" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.permissions.allGranted ? Color.primary : Color.orange)
                    Spacer()
                    if model.permissions.allGranted {
                        Button("Hide") { model.permissionsExpanded = false }
                            .buttonStyle(.link)
                    }
                }
                if !model.permissions.allGranted {
                    Text("The app needs two macOS permissions before it can capture.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    screenRow
                    Divider().padding(.vertical, 10)
                    accessibilityRow
                }
                footnotes
            }
        }
    }

    // MARK: Rows

    private var screenRow: some View {
        let state = model.permissions.screen
        return PermissionRow(
            symbol: "rectangle.dashed.badge.record",
            name: "Screen Recording",
            reason: "To see the Play Books window.",
            pill: {
                switch state {
                case .granted: StatusPill(text: "Granted", color: .green, symbol: "checkmark")
                case .needed: StatusPill(text: "Needed", color: .orange)
                case .needsRelaunch: StatusPill(text: "Relaunch needed", color: .blue, symbol: "arrow.clockwise")
                }
            },
            actions: {
                switch state {
                case .granted:
                    EmptyView()
                case .needsRelaunch:
                    relaunchButton
                    Button("Open Settings") { model.openSettings(.screenRecording) }
                case .needed:
                    Button("Allow…") { model.requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings") { model.openSettings(.screenRecording) }
                }
            },
            detail: {
                switch state {
                case .granted:
                    EmptyView()
                case .needsRelaunch:
                    Text(model.runningFromTerminal
                         ? "Turn on your terminal app in System Settings, then quit it, open it again and restart google-play-books-downloader."
                         : "Turn on \(AppInfo.name) in System Settings, then relaunch. macOS applies it only after a restart.")
                case .needed:
                    if model.runningFromTerminal {
                        Text("Running from a terminal: grant it to your terminal app (Terminal, iTerm…) and restart it.")
                    }
                }
            }
        )
    }

    private var accessibilityRow: some View {
        let granted = model.permissions.accessibility
        return PermissionRow(
            symbol: "accessibility",
            name: "Accessibility",
            reason: "To press the next-page key.",
            pill: {
                if granted {
                    StatusPill(text: "Granted", color: .green, symbol: "checkmark")
                } else {
                    StatusPill(text: "Needed", color: .orange)
                }
            },
            actions: {
                if !granted {
                    Button("Allow…") { model.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings") { model.openSettings(.accessibility) }
                }
            },
            detail: {
                if !granted && model.runningFromTerminal {
                    Text("Running from a terminal: grant it to your terminal app. It takes effect at once.")
                } else if !granted {
                    Text("Takes effect at once, no relaunch.")
                }
            }
        )
    }

    @ViewBuilder
    private var relaunchButton: some View {
        if !model.runningFromTerminal {
            Button {
                model.relaunch()
            } label: {
                Label("Relaunch app", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var footnotes: some View {
        if #available(macOS 15, *), !model.permissions.allGranted {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                Text("macOS may also ask whether the app may bypass the private window picker. Click **Allow**, or the first key presses go to that dialog.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }
}

/// One permission: icon, name, reason, status pill, buttons, optional detail line.
private struct PermissionRow<Pill: View, Actions: View, Detail: View>: View {
    let symbol: String
    let name: String
    let reason: String
    @ViewBuilder let pill: Pill
    @ViewBuilder let actions: Actions
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.body.weight(.semibold))
                    pill
                    Spacer(minLength: 0)
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) { actions }
                    .controlSize(.regular)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
