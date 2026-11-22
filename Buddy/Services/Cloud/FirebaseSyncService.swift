import Foundation
import Observation

// MARK: - Firebase Configuration & Auth Models

public struct FirebaseConfig: Codable, Equatable, Sendable {
    public var projectID: String
    public var webAPIKey: String

    public init(projectID: String = "", webAPIKey: String = "") {
        self.projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.webAPIKey = webAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !projectID.isEmpty && !webAPIKey.isEmpty
    }

    /// Reads optional build-time Firebase config injected via Info.plist (e.g. GitHub Actions secrets).
    public static func fromInfoPlist(bundle: Bundle = .main) -> FirebaseConfig {
        let projectID = (bundle.object(forInfoDictionaryKey: "BUDDY_FIREBASE_PROJECT_ID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (bundle.object(forInfoDictionaryKey: "BUDDY_FIREBASE_API_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore unexpanded Xcode build variable placeholders if present.
        let cleanProject = projectID.hasPrefix("$(") ? "" : projectID
        let cleanKey = apiKey.hasPrefix("$(") ? "" : apiKey
        return FirebaseConfig(projectID: cleanProject, webAPIKey: cleanKey)
    }
}

public struct FirebaseAuthSession: Codable, Equatable, Sendable {
    public let uid: String
    public let email: String
    public var idToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpiredOrExpiringSoon: Bool {
        Date().addingTimeInterval(90) >= expiresAt
    }
}

public enum CloudSyncState: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case error(String)
}

public enum FirebaseSyncError: LocalizedError, Sendable {
    case notConfigured
    case notSignedIn
    case invalidCredentials(String)
    case sessionExpired
    case networkError(String)
    case firestoreError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Firebase Project ID and Web API Key first."
        case .notSignedIn:
            return "Sign in to sync your workouts to Firebase."
        case .invalidCredentials(let message):
            return message
        case .sessionExpired:
            return "Your Firebase session expired. Please sign in again."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .firestoreError(let detail):
            return "Firestore sync error: \(detail)"
        case .decodingError(let detail):
            return "Could not decode cloud backup: \(detail)"
        }
    }
}

// MARK: - Firestore REST Wire Helpers

public enum FirestoreDocumentCodec {
    private struct FirestoreDocument: Codable {
        let fields: [String: FirestoreValue]?
    }

    private struct FirestoreValue: Codable {
        let stringValue: String?
        let integerValue: String?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.integerValue = nil
        }

        init(integerValue: Int) {
            self.stringValue = nil
            self.integerValue = String(integerValue)
        }
    }

    public static func encodeBackupDocument(_ backup: BuddyCloudBackup) throws -> Data {
        let payloadData = try backup.encodedJSONData(prettyPrinted: false)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw FirebaseSyncError.decodingError("UTF-8 encoding failed")
        }

        let isoFormatter = ISO8601DateFormatter()
        let document = FirestoreDocument(fields: [
            "schemaVersion": FirestoreValue(integerValue: backup.schemaVersion),
            "updatedAt": FirestoreValue(stringValue: isoFormatter.string(from: backup.updatedAt)),
            "workoutCount": FirestoreValue(integerValue: backup.sessions.count),
            "payload": FirestoreValue(stringValue: payloadString)
        ])

        return try JSONEncoder().encode(document)
    }

    public static func decodeBackupDocument(from data: Data) throws -> BuddyCloudBackup? {
        let document = try JSONDecoder().decode(FirestoreDocument.self, from: data)
        guard let payloadString = document.fields?["payload"]?.stringValue,
              !payloadString.isEmpty,
              let payloadData = payloadString.data(using: .utf8) else {
            return nil
        }
        return try BuddyCloudBackup.decode(from: payloadData)
    }

    public static func friendlyAuthError(from rawCode: String) -> String {
        let code = rawCode.uppercased()
        if code.contains("EMAIL_EXISTS") {
            return "An account with this email already exists. Try signing in instead."
        }
        if code.contains("INVALID_LOGIN_CREDENTIALS") || code.contains("INVALID_PASSWORD") || code.contains("EMAIL_NOT_FOUND") {
            return "Invalid email or password. Double-check your credentials and try again."
        }
        if code.contains("INVALID_EMAIL") {
            return "Please enter a valid email address."
        }
        if code.contains("WEAK_PASSWORD") {
            return "Password must be at least 6 characters long."
        }
        if code.contains("TOO_MANY_ATTEMPTS") {
            return "Too many attempts. Please wait a minute and try again."
        }
        if code.contains("API_KEY_INVALID") {
            return "Your Firebase Web API Key looks invalid. Check Project Settings in Firebase Console."
        }
        if code.contains("OPERATION_NOT_ALLOWED") {
            return "Enable Email/Password sign-in under Firebase Console → Authentication → Sign-in method."
        }
        if code.contains("USER_DISABLED") {
            return "This Firebase user account has been disabled."
        }
        return rawCode
    }
}

// MARK: - Zero-SDK Firebase Auth & Firestore REST Sync Coordinator

/// Talks directly to Firebase Auth + Cloud Firestore REST APIs over `URLSession` with tokens stored
/// in iOS Keychain. Works 100% free on SideStore with zero paid entitlements and zero SDK bloat.
@Observable
@MainActor
public final class FirebaseSyncService {
    private static let configProjectKey = "buddy.firebase.projectID"
    private static let configAPIKeyAccount = "firebase_web_api_key"
    private static let authSessionAccount = "firebase_auth_session"
    private static let autoSyncDefaultsKey = "buddy.firebase.autoSyncEnabled"
    private static let lastSyncedDefaultsKey = "buddy.firebase.lastSyncedAt"

    public static let recommendedFirestoreRules: String = """
    rules_version = '2';
    service cloud.firestore {
      match /databases/{database}/documents {
        match /users/{userId}/{document=**} {
          allow read, write: if request.auth != nil && request.auth.uid == userId;
        }
      }
    }
    """

    public var config: FirebaseConfig
    public var authSession: FirebaseAuthSession?
    public var syncState: CloudSyncState = .idle
    public var isAuthenticating: Bool = false
    public var authError: String?
    public var authInfoMessage: String?
    public var lastSyncedAt: Date?
    public var autoSyncEnabled: Bool {
        didSet {
            defaults.set(autoSyncEnabled, forKey: Self.autoSyncDefaultsKey)
        }
    }

    public var isConfigured: Bool { config.isConfigured }
    public var isSignedIn: Bool { authSession != nil }
    public var userEmail: String? { authSession?.email }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncInFlight: Bool = false
    @ObservationIgnored private var pendingResyncStore: WorkoutStore?
    @ObservationIgnored private var lastForegroundSyncAttempt: Date = .distantPast

    public init(
        defaults: UserDefaults = UserDefaults.standard,
        urlSession: URLSession = .shared
    ) {
        self.defaults = defaults
        self.session = urlSession

        // Load user-saved Firebase config first, falling back to Info.plist build-time secrets.
        let infoConfig = FirebaseConfig.fromInfoPlist()
        let savedProject = defaults.string(forKey: Self.configProjectKey) ?? ""
        let savedKey = KeychainHelper.loadString(account: Self.configAPIKeyAccount) ?? ""
        if !savedProject.isEmpty && !savedKey.isEmpty {
            self.config = FirebaseConfig(projectID: savedProject, webAPIKey: savedKey)
        } else {
            self.config = infoConfig
        }

        if let rawSessionData = KeychainHelper.loadData(account: Self.authSessionAccount),
           let decoded = try? JSONDecoder().decode(FirebaseAuthSession.self, from: rawSessionData) {
            self.authSession = decoded
        } else {
            self.authSession = nil
        }

        if defaults.object(forKey: Self.autoSyncDefaultsKey) != nil {
            self.autoSyncEnabled = defaults.bool(forKey: Self.autoSyncDefaultsKey)
        } else {
            self.autoSyncEnabled = true
        }

        if let timestamp = defaults.object(forKey: Self.lastSyncedDefaultsKey) as? Double, timestamp > 0 {
            let date = Date(timeIntervalSince1970: timestamp)
            self.lastSyncedAt = date
            self.syncState = .synced(date)
        }
    }

    // MARK: - Configuration

    public func saveConfig(projectID: String, webAPIKey: String) {
        let updated = FirebaseConfig(projectID: projectID, webAPIKey: webAPIKey)
        let projectChanged = (updated.projectID != config.projectID || updated.webAPIKey != config.webAPIKey)
        config = updated

        if updated.isConfigured {
            defaults.set(updated.projectID, forKey: Self.configProjectKey)
            KeychainHelper.saveString(updated.webAPIKey, account: Self.configAPIKeyAccount)
        } else {
            defaults.removeObject(forKey: Self.configProjectKey)
            KeychainHelper.delete(account: Self.configAPIKeyAccount)
        }

        if projectChanged && isSignedIn {
            signOut()
        }
        authError = nil
        authInfoMessage = updated.isConfigured ? "Firebase project saved." : "Firebase configuration cleared."
    }

    // MARK: - Authentication

    public func signUp(email: String, password: String, store: WorkoutStore) async {
        await authenticate(endpoint: "accounts:signUp", email: email, password: password, store: store)
    }

    public func signIn(email: String, password: String, store: WorkoutStore) async {
        await authenticate(endpoint: "accounts:signInWithPassword", email: email, password: password, store: store)
    }

    public func sendPasswordReset(email: String) async {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured else {
            authError = FirebaseSyncError.notConfigured.localizedDescription
            return
        }
        guard !cleanEmail.isEmpty else {
            authError = "Enter your email address first to receive a password reset link."
            return
        }

        isAuthenticating = true
        authError = nil
        authInfoMessage = nil
        defer { isAuthenticating = false }

        do {
            let encodedKey = percentEncodeQuery(config.webAPIKey)
            guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=\(encodedKey)") else {
                throw FirebaseSyncError.notConfigured
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "requestType": "PASSWORD_RESET",
                "email": cleanEmail
            ])

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FirebaseSyncError.networkError("Invalid server response.")
            }
            guard (200...299).contains(http.statusCode) else {
                let rawMessage = parseFirebaseErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                throw FirebaseSyncError.invalidCredentials(FirestoreDocumentCodec.friendlyAuthError(from: rawMessage))
            }

            authInfoMessage = "Password reset email sent to \(cleanEmail)."
        } catch {
            authError = error.localizedDescription
        }
    }

    public func signOut() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingResyncStore = nil
        authSession = nil
        KeychainHelper.delete(account: Self.authSessionAccount)
        syncState = .idle
        authError = nil
        authInfoMessage = nil
    }

    // MARK: - Automatic & Manual Cloud Sync

    /// Debounces automatic background uploads (3s) when local workouts or preferences change.
    public func scheduleAutoSync(for store: WorkoutStore) {
        guard isConfigured, isSignedIn, autoSyncEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let store else { return }
            await self.syncNow(store: store)
        }
    }

    /// Lightweight throttled sync triggered when Buddy returns to the foreground.
    public func syncOnForegroundIfNeeded(store: WorkoutStore) {
        guard isConfigured, isSignedIn, autoSyncEnabled else { return }
        guard Date().timeIntervalSince(lastForegroundSyncAttempt) >= 30 else { return }
        lastForegroundSyncAttempt = Date()
        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            await self.syncNow(store: store)
        }
    }

    /// Performs a two-way conflict-safe merge with Cloud Firestore and uploads the unified state.
    @discardableResult
    public func syncNow(store: WorkoutStore) async -> CloudMergeReport? {
        guard config.isConfigured else {
            syncState = .error(FirebaseSyncError.notConfigured.localizedDescription)
            return nil
        }
        guard isSignedIn else {
            syncState = .error(FirebaseSyncError.notSignedIn.localizedDescription)
            return nil
        }

        if isSyncInFlight {
            pendingResyncStore = store
            return nil
        }

        isSyncInFlight = true
        syncState = .syncing

        defer {
            isSyncInFlight = false
            if let queuedStore = pendingResyncStore {
                pendingResyncStore = nil
                Task { @MainActor [weak self] in
                    await self?.syncNow(store: queuedStore)
                }
            }
        }

        do {
            let activeAuth = try await validAuthSession()

            // 1. Fetch existing remote Firestore document (nil on first sync if 404).
            let remoteBackup = try await fetchRemoteBackup(auth: activeAuth)

            // 2. Merge remote into local SwiftData store without losing sets or undoing deletions.
            let report: CloudMergeReport
            if let remoteBackup {
                report = store.mergeCloudBackup(remoteBackup)
            } else {
                report = CloudMergeReport(needsPushToCloud: true)
            }

            // 3. Push merged local state back to Firestore whenever needed (or on first upload).
            let mergedLocalBackup = store.exportCloudBackup()
            let remoteMatchesMerged = (remoteBackup != nil
                && !report.needsPushToCloud
                && remoteBackup?.sessions.count == mergedLocalBackup.sessions.count
                && remoteBackup?.profile == mergedLocalBackup.profile
                && Set(remoteBackup?.deletedSessionIDs ?? []) == Set(mergedLocalBackup.deletedSessionIDs))

            if !remoteMatchesMerged {
                let latestAuth = try await validAuthSession()
                try await uploadRemoteBackup(mergedLocalBackup, auth: latestAuth)
            }

            let now = Date()
            lastSyncedAt = now
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastSyncedDefaultsKey)
            syncState = .synced(now)
            return report
        } catch let syncError as FirebaseSyncError {
            if case .sessionExpired = syncError {
                signOut()
            }
            syncState = .error(syncError.localizedDescription)
            return nil
        } catch {
            syncState = .error(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Private Firebase REST Calls

    private struct AuthResponsePayload: Decodable {
        let idToken: String
        let email: String
        let refreshToken: String
        let expiresIn: String
        let localId: String
    }

    private struct RefreshResponsePayload: Decodable {
        let id_token: String
        let refresh_token: String
        let expires_in: String
        let user_id: String
    }

    private func authenticate(
        endpoint: String,
        email: String,
        password: String,
        store: WorkoutStore
    ) async {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured else {
            authError = FirebaseSyncError.notConfigured.localizedDescription
            return
        }
        guard !cleanEmail.isEmpty, !password.isEmpty else {
            authError = "Enter both your email and password."
            return
        }

        isAuthenticating = true
        authError = nil
        authInfoMessage = nil
        defer { isAuthenticating = false }

        do {
            let encodedKey = percentEncodeQuery(config.webAPIKey)
            guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/\(endpoint)?key=\(encodedKey)") else {
                throw FirebaseSyncError.notConfigured
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "email": cleanEmail,
                "password": password,
                "returnSecureToken": true
            ])

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FirebaseSyncError.networkError("Invalid response from Firebase Auth.")
            }
            guard (200...299).contains(http.statusCode) else {
                let rawMessage = parseFirebaseErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                throw FirebaseSyncError.invalidCredentials(FirestoreDocumentCodec.friendlyAuthError(from: rawMessage))
            }

            let decoded = try JSONDecoder().decode(AuthResponsePayload.self, from: data)
            let ttl = TimeInterval(Int(decoded.expiresIn) ?? 3600)
            let newSession = FirebaseAuthSession(
                uid: decoded.localId,
                email: decoded.email,
                idToken: decoded.idToken,
                refreshToken: decoded.refreshToken,
                expiresAt: Date().addingTimeInterval(ttl)
            )
            persistAuthSession(newSession)

            // Immediately sync & merge workouts upon sign-in/sign-up.
            _ = await syncNow(store: store)
        } catch {
            authError = error.localizedDescription
        }
    }

    private func validAuthSession(forceRefresh: Bool = false) async throws -> FirebaseAuthSession {
        guard var current = authSession else {
            throw FirebaseSyncError.notSignedIn
        }
        if !forceRefresh && !current.isExpiredOrExpiringSoon {
            return current
        }

        let encodedKey = percentEncodeQuery(config.webAPIKey)
        guard let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(encodedKey)") else {
            throw FirebaseSyncError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedRefresh = percentEncodeQuery(current.refreshToken)
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(encodedRefresh)".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FirebaseSyncError.networkError("Could not refresh Firebase token.")
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw FirebaseSyncError.sessionExpired
            }
            throw FirebaseSyncError.networkError("Token refresh failed (HTTP \(http.statusCode)).")
        }

        let refreshed = try JSONDecoder().decode(RefreshResponsePayload.self, from: data)
        let ttl = TimeInterval(Int(refreshed.expires_in) ?? 3600)
        current.idToken = refreshed.id_token
        current.refreshToken = refreshed.refresh_token
        current.expiresAt = Date().addingTimeInterval(ttl)
        persistAuthSession(current)
        return current
    }

    private func firestoreDocumentURL(uid: String) throws -> URL {
        let project = percentEncodePath(config.projectID)
        let safeUID = percentEncodePath(uid)
        guard let url = URL(
            string: "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents/users/\(safeUID)/backups/primary"
        ) else {
            throw FirebaseSyncError.notConfigured
        }
        return url
    }

    private func fetchRemoteBackup(auth: FirebaseAuthSession, didRetryAuth: Bool = false) async throws -> BuddyCloudBackup? {
        let url = try firestoreDocumentURL(uid: auth.uid)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FirebaseSyncError.networkError("Invalid response from Firestore.")
        }

        if http.statusCode == 404 {
            return nil
        }

        if http.statusCode == 401 && !didRetryAuth {
            let refreshed = try await validAuthSession(forceRefresh: true)
            return try await fetchRemoteBackup(auth: refreshed, didRetryAuth: true)
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = parseFirebaseErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 403 {
                throw FirebaseSyncError.firestoreError("Permission denied. Make sure Cloud Firestore is enabled and the user-scoped Security Rules are published.")
            }
            throw FirebaseSyncError.firestoreError(detail)
        }

        return try FirestoreDocumentCodec.decodeBackupDocument(from: data)
    }

    private func uploadRemoteBackup(
        _ backup: BuddyCloudBackup,
        auth: FirebaseAuthSession,
        didRetryAuth: Bool = false
    ) async throws {
        let url = try firestoreDocumentURL(uid: auth.uid)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(auth.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try FirestoreDocumentCodec.encodeBackupDocument(backup)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FirebaseSyncError.networkError("Invalid response from Firestore.")
        }

        if http.statusCode == 401 && !didRetryAuth {
            let refreshed = try await validAuthSession(forceRefresh: true)
            try await uploadRemoteBackup(backup, auth: refreshed, didRetryAuth: true)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = parseFirebaseErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 403 {
                throw FirebaseSyncError.firestoreError("Permission denied. Check your Firestore Security Rules in Firebase Console.")
            }
            throw FirebaseSyncError.firestoreError(detail)
        }
    }

    private func persistAuthSession(_ session: FirebaseAuthSession) {
        authSession = session
        if let data = try? JSONEncoder().encode(session) {
            KeychainHelper.saveData(data, account: Self.authSessionAccount)
        }
    }

    private func parseFirebaseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let message = errorObj["message"] as? String else {
            return nil
        }
        return message
    }

    private func percentEncodeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func percentEncodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
