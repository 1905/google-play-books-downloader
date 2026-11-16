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
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                Text("Permissions OK")
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Screen Recording and Accessibility are allowed. Click for details.")
    }

    private var title: String {
        let missing = (model.permissions.screen == .granted ? 0 : 1) + (model.permissions.accessibility ? 0 : 1)
        switch missing {
        case 0: return "Permissions"
        case 1: return "Allow one more macOS permission"
        default: return "Allow two macOS permissions"
        }
    }

    private var card: some View {
        Card(tint: model.permissions.allGranted ? nil : .orange) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(title: title,
                               symbol: model.permissions.allGranted ? "checkmark.shield" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.permissions.allGranted ? Color.primary : Color.orange)
                    Spacer()
                    if model.permissions.allGranted {
                        Button("Hide") { model.permissionsExpanded = false }
                            .buttonStyle(.link)
                    }
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
            reason: "To see the book window.",
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
                         ? "Turn on your terminal app in System Settings, then restart the terminal and this tool."
                         : "Turn on \(AppInfo.name) in System Settings, then relaunch.")
                case .needed:
                    if model.runningFromTerminal {
                        Text("Grant it to your terminal app, then restart the terminal.")
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
            reason: "To press the page-turn key.",
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
                    Text("Grant it to your terminal app.")
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
                Text("If macOS asks to bypass the private window picker, click **Allow**.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }
}

/// One permission: icon, name + status pill, reason, optional detail line; buttons on the right.
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.body.weight(.semibold))
                    pill
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
                .controlSize(.regular)
                .fixedSize()
        }
    }
}
