import AppKit
import SwiftUI

/// Settings › Plugins: the master switch, a row per installed plugin, and where they live on disk.
struct PluginsSettingsView: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        @Bindable var settings = core.settings
        return Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { settings.pluginsEnabled },
                        set: { core.pluginCoordinator.setPluginsEnabled($0) })
                ) {
                    Text("Enable plugins")
                    Text(
                        "Run native Swift plugins. A plugin is compiled code that runs inside "
                        + "Tinycast with full access to this Mac — enable only plugins you trust.")
                }
                Toggle(isOn: $settings.pluginsShowInLauncher) {
                    Text("Show in launcher")
                    Text("List installed plugins in launcher search.")
                }
                .disabled(!settings.pluginsEnabled)
                .onChange(of: settings.pluginsShowInLauncher) {
                    core.pluginCoordinator.applyPluginsLauncherPresence()
                }
            }

            Section("Installed") {
                if core.plugins.installed.isEmpty {
                    Text("No plugins installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(core.plugins.installed) { install in
                        PluginRowView(install: install)
                    }
                }
                Button("Reveal Plugins Folder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([PluginCatalog.pluginsDirectory()])
                }
            }
            .settingsEnabled(settings.pluginsEnabled)
        }
        .formStyle(.grouped)
        .releasesFocusOnOutsideClick()
    }
}

private struct PluginRowView: View {
    @Environment(AppCore.self) private var core
    let install: PluginInstall

    var body: some View {
        HStack {
            Image(systemName: install.manifest.icon ?? "puzzlepiece.extension")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(install.manifest.name)
                if let subtitle = install.manifest.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([install.directory])
            }
            Button("Uninstall", role: .destructive) {
                core.pluginCoordinator.confirmUninstall(install)
            }
        }
    }
}
