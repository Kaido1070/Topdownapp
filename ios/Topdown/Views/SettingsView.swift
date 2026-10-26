import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(DownloadCenter.self) private var center
    @Environment(WebModel.self) private var web
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
                Section("الموقع") {
                    LabeledContent("الرابط", value: Site.home.host() ?? "")
                    Button("مسح ذاكرة الموقع المؤقتة") {
                        WKWebsiteDataStore.default().removeData(
                            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                            modifiedSince: .distantPast) { web.reload() }
                    }
                    Button("تسجيل الخروج ومسح بيانات الدخول", role: .destructive) { confirmLogout = true }
                }
                Section("المساحة") {
                    LabeledContent("المحمّلات", value: center.storageSummary)
                    Button("حذف كل التحميلات", role: .destructive) { confirmDelete = true }
                }
                Section {
                    LabeledContent("الإصدار", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                } footer: {
                    Text("الملفات المحمّلة تظهر أيضًا في تطبيق «الملفات» داخل مجلد Topdown.")
                }
            }
            .navigationTitle("الإعدادات")
            .confirmationDialog("حذف كل التحميلات؟", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("حذف الكل", role: .destructive) { center.deleteEverything() }
            }
            .confirmationDialog("تسجيل الخروج؟", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("تسجيل الخروج", role: .destructive) {
                    WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                            modifiedSince: .distantPast) { web.goHome() }
                }
            }
        }
    }
}
