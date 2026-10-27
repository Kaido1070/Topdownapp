import SwiftUI

struct SettingsView: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(Auth.self) private var auth
    @AppStorage("preferredQuality") private var quality = "ask"
    @AppStorage("allowCellular") private var cellular = true
    @AppStorage("notifyOnFinish") private var notify = true
    @AppStorage("appLock") private var appLock = false
    @AppStorage("privacyBlur") private var privacyBlur = true
    @AppStorage("appearance") private var appearance = "dark"
    @State private var confirmDelete = false
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                Section("التحميل") {
                    Picker("الجودة المفضّلة", selection: $quality) {
                        Text("اسأل كل مرة").tag("ask")
                        Text("الأعلى").tag("best")
                        Text("1080p").tag("1080")
                        Text("720p").tag("720")
                        Text("480p").tag("480")
                        Text("360p").tag("360")
                        Text("الأصغر حجمًا").tag("smallest")
                    }
                    Toggle("التحميل عبر بيانات الجوال", isOn: $cellular)
                    Toggle("إشعار عند اكتمال التحميل", isOn: $notify)
                }
                Section {
                    Toggle("قفل التطبيق بـ Face ID", isOn: $appLock)
                    Toggle("إخفاء المحتوى في مبدّل التطبيقات", isOn: $privacyBlur)
                } header: { Text("الخصوصية") }
                Section("المظهر") {
                    Picker("السمة", selection: $appearance) {
                        Text("داكن").tag("dark")
                        Text("فاتح").tag("light")
                        Text("حسب النظام").tag("system")
                    }
                    .pickerStyle(.segmented)
                }
                Section("الحساب") {
                    LabeledContent("الموقع", value: Site.home.host() ?? "")
                    LabeledContent("الجلسة", value: Keychain.password != nil ? "محفوظة — دخول تلقائي" : "مؤقتة")
                    Button("مسح الصور المؤقتة") {
                        API.shared.session.configuration.urlCache?.removeAllCachedResponses()
                        Task { await ImagePipeline.shared.clear() }
                        AppModel.shared.show("تم مسح الذاكرة المؤقتة")
                    }
                    Button("تسجيل الخروج", role: .destructive) { confirmLogout = true }
                }
                Section("المساحة") {
                    LabeledContent("المحمّلات", value: center.storageSummary)
                    Button("حذف كل التحميلات", role: .destructive) { confirmDelete = true }
                }
                Section {
                    LabeledContent("الإصدار", value: AppVersion.full)
                } footer: {
                    Text("المحمّلات تبقى على جهازك وتشتغل بدون إنترنت، وتظهر أيضًا في تطبيق «الملفات» داخل مجلد Topdown.")
                }
            }
            .navigationTitle("الإعدادات")
            .confirmationDialog("حذف كل التحميلات؟", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("حذف الكل", role: .destructive) { center.deleteEverything() }
            }
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive) { Task { await auth.logout() } }
            }
        }
    }
}
