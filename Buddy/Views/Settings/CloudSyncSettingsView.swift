import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Dedicated OLED monochrome sub-page for Firebase Auth + Cloud Firestore sync
/// and offline portable JSON export/import backup.
struct CloudSyncSettingsView: View {
    let store: WorkoutStore
    let cloudSync: FirebaseSyncService

    @State private var authMode: AuthMode = .signIn
    @State private var emailText: String = ""
    @State private var passwordText: String = ""

    @State private var projectIDDraft: String = ""
    @State private var webAPIKeyDraft: String = ""
    @State private var isEditingProjectConfig: Bool = false
    @State private var showSetupGuide: Bool = false
    @State private var didCopyRules: Bool = false

    @State private var showExportSheet: Bool = false
    @State private var exportDocument: BuddyBackupDocument?
    @State private var showImportSheet: Bool = false
    @State private var localBackupStatus: String?
    @State private var localBackupIsError: Bool = false

    private enum AuthMode: String, CaseIterable {
        case signIn = "Sign In"
        case signUp = "Create Account"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if cloudSync.isSignedIn {
                    signedInSyncCard
                } else if cloudSync.isConfigured {
                    emailAuthCard
                }

                firebaseConfigCard

                localJSONBackupCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .navigationTitle("Cloud Sync & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            projectIDDraft = cloudSync.config.projectID
            webAPIKeyDraft = cloudSync.config.webAPIKey
            isEditingProjectConfig = !cloudSync.isConfigured
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: exportDocument,
            contentType: .json,
            defaultFilename: defaultBackupFilename()
        ) { result in
            switch result {
            case .success:
                BuddyHaptics.success()
                localBackupIsError = false
                localBackupStatus = "Exported JSON backup cleanly."
            case .failure(let error):
                BuddyHaptics.error()
                localBackupIsError = true
                localBackupStatus = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json]
        ) { result in
            handleJSONImport(result)
        }
    }

    // MARK: - Signed-In Sync Status Card

    private var signedInSyncCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionEyebrow("FIREBASE CLOUD SYNC")
                    Spacer()
                    syncStatusBadge
                }

                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(BuddyTheme.emeraldLive.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(BuddyTheme.emeraldLive)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(cloudSync.userEmail ?? "Signed In")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)

                        Text(lastSyncedSubtitle)
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                    }

                    Spacer(minLength: 4)
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Sync Workouts")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text("Syncs automatically after logging sets and on launch")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { cloudSync.autoSyncEnabled },
                            set: { newValue in
                                BuddyHaptics.selection()
                                cloudSync.autoSyncEnabled = newValue
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(BuddyTheme.emeraldLive)
                }

                if case .error(let message) = cloudSync.syncState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        BuddyHaptics.mediumImpact()
                        Task {
                            _ = await cloudSync.syncNow(store: store)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if cloudSync.syncState == .syncing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(BuddyTheme.inkInverse)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            Text(cloudSync.syncState == .syncing ? "Syncing…" : "Sync Now")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(BuddyTheme.inkPrimary))
                    }
                    .buttonStyle(.plain)
                    .disabled(cloudSync.syncState == .syncing)

                    Button {
                        BuddyHaptics.warning()
                        cloudSync.signOut()
                    } label: {
                        Text("Sign Out")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(BuddyTheme.destructive)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(BuddyTheme.destructive.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Email / Password Sign-In Card

    private var emailAuthCard: some View {
        let canSubmit = !emailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && passwordText.count >= 6
            && !cloudSync.isAuthenticating

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("FIREBASE ACCOUNT")

                HStack(spacing: 6) {
                    ForEach(AuthMode.allCases, id: \.self) { mode in
                        let selected = (authMode == mode)
                        Button {
                            BuddyHaptics.selection()
                            authMode = mode
                            cloudSync.authError = nil
                            cloudSync.authInfoMessage = nil
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(selected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 10) {
                    TextField("Email address", text: $emailText)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                        )

                    SecureField("Password (6+ characters)", text: $passwordText)
                        .textContentType(authMode == .signUp ? .newPassword : .password)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                        )
                }

                if let error = cloudSync.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let info = cloudSync.authInfoMessage {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.emeraldLive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    BuddyHaptics.mediumImpact()
                    Task {
                        if authMode == .signIn {
                            await cloudSync.signIn(email: emailText, password: passwordText, store: store)
                        } else {
                            await cloudSync.signUp(email: emailText, password: passwordText, store: store)
                        }
                        if cloudSync.isSignedIn {
                            passwordText = ""
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if cloudSync.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(BuddyTheme.inkInverse)
                        }
                        Text(authMode == .signIn ? "Sign In & Sync" : "Create Account & Sync")
                            .font(.system(size: 14.5, weight: .bold))
                    }
                    .foregroundStyle(canSubmit ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(canSubmit ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)

                if authMode == .signIn {
                    Button {
                        BuddyHaptics.lightImpact()
                        Task {
                            await cloudSync.sendPasswordReset(email: emailText)
                        }
                    } label: {
                        Text("Forgot password?")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .disabled(cloudSync.isAuthenticating)
                }
            }
        }
    }

    // MARK: - Firebase Project Configuration Card

    private var firebaseConfigCard: some View {
        let canSaveConfig = !projectIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !webAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionEyebrow("FIREBASE PROJECT")
                    Spacer()
                    if cloudSync.isConfigured && !isEditingProjectConfig {
                        Button("Edit") {
                            BuddyHaptics.lightImpact()
                            projectIDDraft = cloudSync.config.projectID
                            webAPIKeyDraft = cloudSync.config.webAPIKey
                            withAnimation(.snappy(duration: 0.2)) {
                                isEditingProjectConfig = true
                            }
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.primary)
                    }
                }

                if cloudSync.isConfigured && !isEditingProjectConfig {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(BuddyTheme.emeraldLive)
                            .frame(width: 7, height: 7)
                        Text(cloudSync.config.projectID)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("Spark Free Tier")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                } else {
                    Text("Connect your free Firebase Spark project using its Project ID and Web API Key (stored securely on-device).")
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)

                    VStack(spacing: 9) {
                        TextField("Firebase Project ID (e.g. buddy-workout-123)", text: $projectIDDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )

                        SecureField("Firebase Web API Key (AIza…)", text: $webAPIKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                    }

                    HStack(spacing: 8) {
                        Button {
                            BuddyHaptics.success()
                            cloudSync.saveConfig(projectID: projectIDDraft, webAPIKey: webAPIKeyDraft)
                            withAnimation(.snappy(duration: 0.2)) {
                                isEditingProjectConfig = !cloudSync.isConfigured
                            }
                        } label: {
                            Text("Save Project")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(canSaveConfig ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(canSaveConfig ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSaveConfig)

                        if cloudSync.isConfigured {
                            Button {
                                BuddyHaptics.lightImpact()
                                withAnimation(.snappy(duration: 0.2)) {
                                    isEditingProjectConfig = false
                                }
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .background(Capsule().fill(BuddyTheme.chipSurface))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                // Expandable 2-minute Firebase Console setup guide + copyable Firestore rules
                Button {
                    BuddyHaptics.lightImpact()
                    withAnimation(.snappy(duration: 0.22)) {
                        showSetupGuide.toggle()
                    }
                } label: {
                    HStack {
                        Label("2-Minute Firebase Setup & Rules", systemImage: "book.closed")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: showSetupGuide ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
                .buttonStyle(.plain)

                if showSetupGuide {
                    VStack(alignment: .leading, spacing: 8) {
                        setupStep("1", "Create a free Spark project at console.firebase.google.com.")
                        setupStep("2", "Authentication → Sign-in method → Enable Email/Password.")
                        setupStep("3", "Firestore Database → Create database (Production mode).")
                        setupStep("4", "Firestore → Rules → Paste & Publish the rules below.")
                        setupStep("5", "Project Settings → General → Copy Project ID & Web API Key.")

                        Text(FirebaseSyncService.recommendedFirestoreRules)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )

                        Button {
                            BuddyHaptics.success()
                            UIPasteboard.general.string = FirebaseSyncService.recommendedFirestoreRules
                            didCopyRules = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: didCopyRules ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12, weight: .bold))
                                Text(didCopyRules ? "Copied Firestore Rules" : "Copy Firestore Rules")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(BuddyTheme.chipSurface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Local JSON Export / Import Card

    private var localJSONBackupCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("LOCAL FILE BACKUP")

                Text("Export your entire workout log & weekly goal as a portable JSON file (works with iCloud Drive, Files, or AirDrop).")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)

                HStack(spacing: 10) {
                    Button {
                        BuddyHaptics.lightImpact()
                        exportDocument = BuddyBackupDocument(backup: store.exportCloudBackup())
                        showExportSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12.5, weight: .bold))
                            Text("Export JSON")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)

                    Button {
                        BuddyHaptics.lightImpact()
                        showImportSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12.5, weight: .bold))
                            Text("Import JSON")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)
                }

                if let localBackupStatus {
                    Text(localBackupStatus)
                        .font(.caption)
                        .foregroundStyle(localBackupIsError ? BuddyTheme.destructive : BuddyTheme.emeraldLive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var syncStatusBadge: some View {
        switch cloudSync.syncState {
        case .syncing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(BuddyTheme.inkPrimary)
                Text("Syncing")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
        case .synced:
            HStack(spacing: 5) {
                Circle().fill(BuddyTheme.emeraldLive).frame(width: 6.5, height: 6.5)
                Text("Synced")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BuddyTheme.emeraldLive)
            }
        case .error:
            HStack(spacing: 5) {
                Circle().fill(BuddyTheme.destructive).frame(width: 6.5, height: 6.5)
                Text("Sync Error")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BuddyTheme.destructive)
            }
        case .idle:
            HStack(spacing: 5) {
                Circle().fill(BuddyTheme.emeraldLive).frame(width: 6.5, height: 6.5)
                Text("Ready")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BuddyTheme.emeraldLive)
            }
        }
    }

    private var lastSyncedSubtitle: String {
        if let date = cloudSync.lastSyncedAt {
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Tap Sync Now to upload your workouts"
    }

    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(BuddyTheme.inkInverse)
                .frame(width: 18, height: 18)
                .background(Circle().fill(BuddyTheme.inkPrimary))
            Text(text)
                .font(.caption)
                .foregroundStyle(BuddyTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(BuddyTheme.mutedText)
    }

    private func defaultBackupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "buddy-backup-\(formatter.string(from: Date()))"
    }

    private func handleJSONImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let backup = try BuddyCloudBackup.decode(from: data)
                let report = store.mergeCloudBackup(backup, isManualImport: true)
                BuddyHaptics.success()
                localBackupIsError = false
                localBackupStatus = "Imported \(report.importedSessions) new & updated \(report.updatedSessions) workouts."
                if cloudSync.isSignedIn && cloudSync.autoSyncEnabled {
                    cloudSync.scheduleAutoSync(for: store)
                }
            } catch {
                BuddyHaptics.error()
                localBackupIsError = true
                localBackupStatus = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            BuddyHaptics.error()
            localBackupIsError = true
            localBackupStatus = "File picker error: \(error.localizedDescription)"
        }
    }
}
