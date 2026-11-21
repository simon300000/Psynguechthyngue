import PsySync
import SwiftUI

/// First run: this device's ID → add a device → share/accept a folder →
/// enable in Files (skipped on Mac).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var addingDevice = false
    @State private var creatingFolder = false

    private var lastStep: Int { 3 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case 0:
                        header("Welcome", symbol: "arrow.triangle.2.circlepath",
                               text: "Keep folders in sync between this device and your other computers and phones — directly, without a cloud.")
                        LocalIDCard()
                    case 1:
                        header("Add a device", symbol: "laptopcomputer.and.iphone",
                               text: "Add the device you want to sync with. You can also add this device from the other one using the ID on the first page.")
                        if model.devices.isEmpty {
                            Button("Add Device") { addingDevice = true }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("onboarding.adddevice")
                        } else {
                            Label("\(model.devices.count) devices added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    case 2:
                        header("Share a folder", symbol: "folder.badge.plus",
                               text: "Create a folder to share, or accept a folder another device offers. Invitations appear on the Sync tab.")
                        if model.folders.isEmpty {
                            Button("New Folder") { creatingFolder = true }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("onboarding.newfolder")
                        } else {
                            Label("\(model.folders.count) folders", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    default:
                        if model.isOnMac {
                            header("Find your files in Finder", symbol: "folder",
                                   text: "On Mac this location is off at first. Open System Settings ▸ General ▸ Login Items & Extensions ▸ File Providers and turn on Psynguechthyngue. Closing the window stops syncing; minimize it to keep syncing.")
                        } else {
                            header("Find your files", symbol: "folder",
                                   text: "Your synced folders appear in the Files app under Locations → Psynguechthyngue. If you don’t see it, tap ••• in Files, choose Edit, and turn it on.")
                            Button("Open Files") { openURL(URL(string: "shareddocuments://")!) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if step > 0 { Button("Back") { step -= 1 }.accessibilityIdentifier("onboarding.back") }
                    Spacer()
                    Button(step == lastStep ? "Done" : "Next") {
                        if step == lastStep { settings.onboardingDone = true } else { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.next")
                }
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { settings.onboardingDone = true }.accessibilityIdentifier("onboarding.skip")
                }
            }
            .sheet(isPresented: $addingDevice) { AddDeviceView() }
            .sheet(isPresented: $creatingFolder) { NewFolderView() }
        }
        .interactiveDismissDisabled()
        .onAppear { model.onboardingInProgress = true }
        .onDisappear { model.onboardingInProgress = false }
    }

    private func header(_ title: LocalizedStringKey, symbol: String, text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 52)).foregroundStyle(.tint)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.title")
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}
